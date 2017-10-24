//
//  MFUploadTransaction.m
//  MediaFireSDK
//
//  Created by Mike Jablonski on 3/5/14.
//  Copyright (c) 2014 MediaFire. All rights reserved.
//

#import "MFHTTP.h"
#import "MFUploadTransaction.h"
#import "MFUploaderConstants.h"
#import "MFUploadAPI.h"
#import "NSDictionary+Callbacks.h"
#import "MFHash.h"
#import "MFErrorLog.h"
#import "MFErrorMessage.h"
#import "MFHTTPOptions.h"
#import "MFUploadHelper.h"
#import "NSData+BytesRange.h"

//==============================================================================
static const double POLL_INTERVAL   = 10.0; // poll interval in seconds
static const int    POLL_ATTEMPTS   = 6;    // number of polling attempts
static NSString*    ON_FIND_DUP     = @"keep";
typedef void (^StandardCallback)(NSDictionary* response);

//==============================================================================
@interface MFUploadTransaction()

@property (nonatomic,strong) MFUploadAPI* api;
@property (nonatomic,strong) NSLock* pollLock;
@property (nonatomic,strong) NSLock* statusLock;

@property (nonatomic,strong) NSDictionary* opCallbacks;

@property (nonatomic,strong) NSData* uploadData;
@property (nonatomic,strong) NSURLSessionTask* connection;
@property (nonatomic,strong) NSString* currentStatus;
@property (nonatomic,strong) NSString* fileName;
@property (nonatomic,strong) NSString* fileHash;
@property (nonatomic,strong) NSString* filePath;
@property (nonatomic,strong) NSString* identifier;

@property (nonatomic,strong) NSString* verificationKey;
@property (nonatomic,strong) NSString* quickkey;

@property (nonatomic,assign) int64_t fileSize;
@property (nonatomic,assign) long     unitCount;
@property (nonatomic,assign) long     unitSize;
@property (nonatomic,assign) int     lastUnit;
@property (nonatomic,assign) int     pollCount;

@property (nonatomic,assign) BOOL cancelled;


@end

//==============================================================================
@implementation MFUploadTransaction

@synthesize httpClientId = _httpClientId;
//==============================================================================
// PUBLIC METHODS
//==============================================================================

//------------------------------------------------------------------------------
- (id)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    return self;
}

//------------------------------------------------------------------------------
- (id)initWithUploadAPI:(MFUploadAPI*)api {
    self = [self init];
    if (api == nil) {
        _api = [[MFUploadAPI alloc] init];
    } else {
        _api = api;
    }
    return self;
}

//------------------------------------------------------------------------------
- (id)initWithFilePath:(NSString*)filePath {
    self = [self initWithFilePath:filePath uploadAPI:nil];
    return self;
}

//------------------------------------------------------------------------------
- (id)initWithFilePath:(NSString*)filePath uploadAPI:(MFUploadAPI*)api {
    
    self = [self initWithUploadAPI:api];
    
    if (self != nil) {
        _filePath  = filePath;
        _folderkey = @"";
        _fileName  = [NSString stringWithFormat:@"%@",[filePath lastPathComponent]];
        
        _fileSize  = 0;
        _unitCount = 0;
        _unitSize  = 0;
        _lastUnit  = 0;
        _pollCount = 0;
        
        _currentStatus  = @"new";
        _cancelled      = FALSE;
    }

    return self;
}


//------------------------------------------------------------------------------
- (void)startWithCallbacks:(NSDictionary*)callbacks {
    if (callbacks == nil) {
        callbacks = @{};
    }
    
    self.opCallbacks = callbacks;
    
    self.fileName = [NSString stringWithFormat:@"%@",[self.filePath lastPathComponent]];
    
    self.unitCount      = 0;
    self.lastUnit       = 0;
    self.unitSize       = 0;
    self.pollCount      = 0;
    
    self.uploadData     = nil;
    
    self.currentStatus  = @"new";
    self.cancelled      = FALSE;
    
    self.verificationKey= nil;
    
    [self prepareFile];
}

//------------------------------------------------------------------------------
- (void)start {
    [self startWithCallbacks:self.opCallbacks];
}

//------------------------------------------------------------------------------
- (void)cancel {
    [self.statusLock lock];
    self.cancelled = true;
    [self.statusLock unlock];
    if (self.connection != nil) {
        [self.connection cancel];
    }
}

//==============================================================================
// PRIVATE METHODS
//==============================================================================

//------------------------------------------------------------------------------
- (BOOL)shouldCancel {
    return self.cancelled;
}

//------------------------------------------------------------------------------
- (void)prepareFile {
    id<MFUploadHelperDelegate> helper = self.helper;
    if (helper == nil) {
        helper = [[MFUploadHelper alloc] init];
    }
    
    __weak MFUploadTransaction* bself = self;
    
    [helper prepareFileForUpload:[self fileInfo] withCompletionHandler:^(MFUploadFileInfo* fileInfo, NSError* err) {
        if (err != nil) {
            if (err.code == MFUploadHelperErrFileNotFound) {
                [self fail:[MFErrorMessage fileNotFound]];
                return;
            }
            [self fail:[MFErrorMessage nullField:@"filePath"]];
            return;
        }
        if (fileInfo == nil) {
            [self fail:[MFErrorMessage nullField:@"fileInfo"]];
            return;
        }
        if (fileInfo.fileHash == nil) {
            [self fail:[MFErrorMessage nullField:@"fileHash"]];
            return;
        }
        if ((fileInfo.filePath == nil) && (fileInfo.uploadData == nil)) {
            [self fail:[MFErrorMessage nullField:@"fileData"]];
            return;
        }
        
        if ((fileInfo.fileName != nil) && ![fileInfo.fileName isEqualToString:@""]) {
            self.fileName = fileInfo.fileName;
        }
        self.fileSize = fileInfo.fileSize;
        self.fileHash = fileInfo.fileHash;
        
        if (fileInfo.uploadData != nil) {
            self.uploadData = fileInfo.uploadData;
        }
        if (fileInfo.filePath != nil) {
            self.filePath = fileInfo.filePath;
        }
        [bself checkUpload];
    }];
}

//------------------------------------------------------------------------------
- (NSDictionary*)getCheckOptions {
    NSString* fileName = self.fileName;
    if (fileName == nil) {
        fileName = @"";
    }
    NSString* fileHash = self.fileHash;
    if (fileHash == nil) {
        fileHash = @"";
    }
    NSString* folderkey = self.folderkey;
    if (folderkey == nil) {
        folderkey = @"";
    }
    return @{@"filename"          : fileName,
             @"hash"              : fileHash,
             @"size"              : [NSString stringWithFormat:@"%lli",self.fileSize],
             @"folder_key"        : folderkey,
             @"resumable"         : @"yes"};
}

//------------------------------------------------------------------------------
- (void)checkUpload {
    if ([self shouldCancel]) {
        [self fail:[MFErrorMessage cancelled]];
        return;
    }
    
    NSDictionary* checkUploadCallbacks =
    @{@"httpTask" : [self httpTask],
      ONLOAD    : ^(NSDictionary* response) {
          if ([self shouldSucceed:response]) {
              self.quickkey = response[@"duplicate_quickkey"];
              [self success:response];
              return;
          }
          
          if ([self shouldCheckAgain:response]) {
              [self event:@{UEVENT : UESETUP} status:UESETUP];
              [self checkUpload];
              return;
          }
          
          // Check to ensure user has sufficient storage space
          if (response[@"storage_limit_exceeded"] != nil && [[response[@"storage_limit_exceeded"] lowercaseString] isEqualToString:@"yes"]) {
              [self fail:[MFErrorMessage storageLimitExceeded]];
              return;
          }
          
          if ([self shouldInstantUpload:response]){
              [self event:@{UEVENT : UESETUP} status:UESETUP];
              [self instantUpload];
              return;
          }
          
          // Check to make sure we can proceed with resumable upload.
          NSDictionary* resumable = response[@"resumable_upload"];
          if (resumable == nil) {
              [self fail:[MFErrorMessage nullField]];
              return;
          }
          
          self.unitCount = [resumable[@"number_of_units"] longLongValue];
          self.unitSize = [resumable[@"unit_size"] longLongValue];
          
          int firstEmptyBit = [[self.api class] getFirstEmptyBit:resumable[@"bitmap"]];
          if (firstEmptyBit >= self.unitCount) {
              mflog(@"Cannot checkUpload. Bitmap failure. - %@.", self.filePath);
              [self fail:[MFErrorMessage bitmapError]];
              return;
          }
          self.lastUnit = firstEmptyBit;
          
          [self event:@{UEVENT : UESETUP} status:@"uploading"];
          [self resumableUpload];
      },
      ONERROR   : ^(NSDictionary* response) {
          if ([self shouldCancel]) {
              [self fail:[MFErrorMessage cancelled]];
          } else {
              mflog(@"Cannot checkUpload. - %@", response);
              [self fail:response];
          }
      }};
    
    NSDictionary* options = [self getCheckOptions];
    
    [self setStatus:@"setup"];
    
    [self.api check:[self optionsForCheckUpload] query:options callbacks:checkUploadCallbacks];
}

//------------------------------------------------------------------------------
- (NSDictionary*)optionsForCheckUpload {
    return @{};
}

//------------------------------------------------------------------------------
- (BOOL)shouldSucceed:(NSDictionary*)checkResponse {
    if (checkResponse[@"hash_exists"] != nil && [checkResponse[@"hash_exists"] isEqualToString:@"yes"]) {
        // Our file hash was found on the server.
        if (checkResponse[@"file_exists"] != nil && [checkResponse[@"file_exists"] isEqualToString:@"yes"]) {
            // A file has the same name and location.
            if (checkResponse[@"different_hash"] != nil && [checkResponse[@"different_hash"] isEqualToString:@"no"]) {
                // No upload needed. File exists with same name, location, and hash.
                return TRUE;
            }
        }
    }
    if ((checkResponse[@"resumable_upload"] != nil) && ([checkResponse[@"resumable_upload"] isKindOfClass:[NSDictionary class] ])) {
        NSDictionary* resumable = checkResponse[@"resumable_upload"];
        if ([resumable[@"all_units_ready"] isEqualToString:@"yes"]) {
            return TRUE;
        }
    }
    
    return FALSE;
}

//------------------------------------------------------------------------------
- (BOOL)shouldInstantUpload:(NSDictionary*)checkResponse {
    if (checkResponse[@"hash_exists"] != nil && [checkResponse[@"hash_exists"] isEqualToString:@"yes"]) {
        // Our file hash was found on the server.
        return TRUE;
    }
    
    return FALSE;
}

//------------------------------------------------------------------------------
- (NSDictionary*)getInstantOptions {
    NSString* fileName = self.fileName;
    if (fileName == nil) {
        fileName = @"";
    }
    NSString* fileHash = self.fileHash;
    if (fileHash == nil) {
        fileHash = @"";
    }
    NSString* folderkey = self.folderkey;
    if (folderkey == nil) {
        folderkey = @"";
    }
    return @{@"filename"            : fileName,
             @"hash"                : fileHash,
             @"size"                : [NSString stringWithFormat:@"%lli",self.fileSize],
             @"folder_key"          : folderkey,
             @"action_on_duplicate" : ON_FIND_DUP};
}


//------------------------------------------------------------------------------
-(void)instantUpload {
    if ([self shouldCancel]) {
        [self fail:[MFErrorMessage cancelled]];
        return;
    }
    
    NSDictionary* instantUploadCallbacks =
    @{@"httpTask" : [self httpTask],
      ONLOAD    : ^(NSDictionary* response) {
          if (response[@"quickkey"]!= nil && ![response[@"quickkey"] isEqualToString:@""]) {
              // Instant upload success!
              self.quickkey = response[@"quickkey"];
              [self success:response];
              return;
          } else {
              // Expecting a quickkey upon instant upload success
              [self fail:[MFErrorMessage nullField:@"quickkey"]];
          }
      },
      ONERROR   : ^(NSDictionary* response) {
          if ([self shouldCancel]) {
              [self fail:[MFErrorMessage cancelled]];
          } else {
              mflog(@"Cannot instantUpload. - %@", response);
              [self fail:response];
          }
      }};
    
    NSDictionary* options = [self getInstantOptions];
    
    [self setStatus:@"uploading"];
    
    [self.api instant:[self optionsForInstantUpload] query:options callbacks:instantUploadCallbacks];
}

//------------------------------------------------------------------------------
- (NSDictionary*)optionsForInstantUpload {
    return @{};
}

//------------------------------------------------------------------------------
- (void)resumableUpload {
    if ([self shouldCancel]) {
        [self fail:[MFErrorMessage cancelled]];
        return;
    }
    
    id<MFUploadHelperDelegate> helper = self.helper;
    if (helper == nil) {
        helper = [[MFUploadHelper alloc] init];
    }
    
    NSData* unit = nil;
    
    if (self.uploadData != nil) {
        unit = [self.uploadData getBytesFromIndex:(self.lastUnit*self.unitSize) length:self.unitSize];
    } else {
        unit = [helper getChunk:self.lastUnit forFile:[self fileInfo]];
    }
    
    if (unit == nil) {
        [self fail:[MFErrorMessage nullField:@"unit"]];
        return;
    }
    
    NSString* fileName = self.fileName;
    if (fileName == nil) {
        fileName = @"";
    }
    NSString* fileHash = self.fileHash;
    if (fileHash == nil) {
        fileHash = @"";
    }
    NSString* client = self.httpClientId;
    if (client == nil) {
        client = @"";
    }
    
    NSDictionary* unitInfo =
    @{@"unit_data"  : unit,
      @"unit_hash"  : [MFHash sha256Hex:unit],
      @"unit_size"  : [NSString stringWithFormat:@"%lu", (unsigned long)unit.length],
      @"unit_id"    : [NSString stringWithFormat:@"%i", self.lastUnit],
      @"file_name"  : fileName,
      @"file_size"  : [NSString stringWithFormat:@"%lli", self.fileSize],
      @"file_hash"  : fileHash,
      @"action_on_duplicate" : ON_FIND_DUP,
      @"http_client_id" : client};
    
    NSDictionary* params = [self parametersForResumableUpload];
    NSDictionary* uploadOptions = [self optionsForResumableUpload];
    
    NSDictionary* uploadCallbacks =
    @{ONPROGRESS : self.opCallbacks.onprogress,
      @"httpTask" : [self httpTask],
      ONLOAD    : ^(NSDictionary* response) {
          [self event:@{UEVENT : UECHUNK, UCHUNKID : [NSNumber numberWithInt:self.lastUnit]} status:nil];
          self.lastUnit++;
          
          // See if we've reached the last chunk yet
          if (self.lastUnit < self.unitCount) {
              [self resumableUpload];
              return;
          }
          
          // This was the last upload, so we should expect a "doupload" object in the response
          if (response[@"doupload"] == nil) {
              mflog(@"Cannot upload. Response missing doupload - %@", response);
              [self fail:response];
              return;
          }
          
          NSDictionary* doUploadResponse = response[@"doupload"];
          // Sanity check the doupload object
          if (doUploadResponse[@"result"] == nil || ![doUploadResponse[@"result"] isEqualToString:@"0"]) {
              mflog(@"Cannot upload. Response's doupload parameter result invalid - %@", doUploadResponse);
              [self fail:response];
              return;
          }
          if (doUploadResponse[@"key"] == nil || [doUploadResponse[@"result"] isEqualToString:@""]) {
              mflog(@"Cannot upload. Response's doupload parameters result and/or key invalid - %@", doUploadResponse);
              [self fail:response];
              return;
          }
          
          // doupload parameters are valid, so store the key and begin the polling cycle
          self.verificationKey = doUploadResponse[@"key"];
          
          [self.statusLock lock];
          self.status = @"verifying";
          [self.statusLock unlock];
          
          [self event:@{UEVENT : UECHUNKS} status:@"chunks_complete"];
          
          [self pollUploadAfterDelay];
          
      },
      ONERROR   : ^(NSDictionary* response) {
          if ([self shouldCancel]) {
              [self fail:[MFErrorMessage cancelled]];
          } else {
              if ([self shouldRetryResumable:response originalOptions:uploadOptions unitInfo:unitInfo]) {
                  mflog(@"Will retry upload. - %@", response);
                  [self resumableUpload];
              } else {
                  mflog(@"Cannot upload. - %@", response);
                  [self fail:response];
              }
          }
      }};
    
    
    [self setStatus:@"uploading"];
    [self.api uploadUnit:uploadOptions fileInfo:unitInfo query:params callbacks:uploadCallbacks];
    
}

//------------------------------------------------------------------------------
- (BOOL)shouldRetryResumable:(NSDictionary*)response originalOptions:(NSDictionary*)options unitInfo:(NSDictionary*)unitInfo {
    return false;
}

//------------------------------------------------------------------------------
- (NSDictionary*)optionsForResumableUpload {
    return @{};
}

//------------------------------------------------------------------------------
- (NSDictionary*)parametersForResumableUpload {
    NSString* folderkey = self.folderkey;
    if (folderkey == nil) {
        folderkey = @"";
    }
    return @{@"action_on_duplicate" : ON_FIND_DUP,
             @"folder_key"          : folderkey};
}

//------------------------------------------------------------------------------
- (void)pollUploadAfterDelay {
    // Check for timeout
    [self.pollLock lock];
    self.pollCount++;
    if (self.pollCount > POLL_ATTEMPTS) {
        [self.pollLock unlock];
        mflog(@"Poll upload timeout. File may or may not be uploaded.");
        [self fail:[MFErrorMessage maxPolls]];
        return;
    }
    [self.pollLock unlock];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, POLL_INTERVAL * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        [self pollUpload];
    });
}

//------------------------------------------------------------------------------
- (void)pollUpload {
    if ([self shouldCancel]) {
        [self fail:[MFErrorMessage cancelled]];
        return;
    }
    
    NSDictionary* pollCallbacks =
    @{@"httpTask" : [self httpTask],
      ONLOAD    : ^(NSDictionary* response) {
          // Check status code for successful upload
          if (response[@"doupload"] == nil) {
              [self event:@{UEVENT : UEHANG} status:nil];
              [self pollUploadAfterDelay];
              return;
          }
          
          NSDictionary* doUploadResponse = response[@"doupload"];
          if (doUploadResponse[@"result"] == nil || ![doUploadResponse[@"result"] isEqualToString:@"0"]) {
              mflog(@"Cannot pollupload. Response's doupload parameter result invalid - %@", doUploadResponse);
              [self fail:response];
              return;
          }
          if (doUploadResponse[@"fileerror"] == nil && ![doUploadResponse[@"fileerror"] isEqualToString:@""]) {
              mflog(@"Cannot pollupload. Response's doupload parameters result and/or key invalid - %@", doUploadResponse);
              [self fail:response];
              return;
          }
          NSString* pollStatus = doUploadResponse[@"status"];
          if ([pollStatus isEqualToString:@"99"] || [pollStatus isEqualToString:@"98"]) {
              // UPLOAD COMPLETE!
              NSString* quickkeyResult = doUploadResponse[@"quickkey"];
              
              if (quickkeyResult != nil && ![quickkeyResult isEqualToString:@""]) {
                  self.quickkey = quickkeyResult;
                  [self success:response];
                  return;
              } else {
                  mflog(@"Cannot pollupload. Quickkey not found in response - %@", doUploadResponse);
                  [self fail:response];
              }
          }
          
          // No success or failure indicators, so keep polling.
          [self event:@{UEVENT : UEPOLL} status:nil];
          [self pollUploadAfterDelay];
      },
      ONERROR   : ^(NSDictionary* response) {
          // If we failed because of a network error, try again.
          if (response == nil || response[@"result"] == nil) {
              [self event:@{UEVENT : UEHANG} status:nil];
              [self pollUploadAfterDelay];
              return;
          }
          // If the error was because the upload was bad, then we bubble up.
          if ([self shouldCancel]) {
              [self fail:[MFErrorMessage cancelled]];
          } else {
              mflog(@"Cannot pollupload. - %@", response);
              [self fail:response];
          }
      }};
    
    [self setStatus:@"polling"];
    NSString* verificationKey = self.verificationKey;
    if (verificationKey == nil) {
        verificationKey = @"";
    }
    [self.api pollUpload:[self optionsForPollUpload] query:@{@"key" : verificationKey} callbacks:pollCallbacks];
}

//------------------------------------------------------------------------------
- (NSDictionary*)optionsForPollUpload {
    return @{};
}

//------------------------------------------------------------------------------
- (void)event:(NSDictionary*)response status:(NSString*)status {
    [self statusChange:self.opCallbacks.onupdate response:response status:status];
}

//------------------------------------------------------------------------------
- (void)success:(NSDictionary*)response {
    [self statusChange:self.opCallbacks.onload response:response status:UESUCCESS];
    if ([self.helper respondsToSelector:@selector(uploadDidCompleteForFile:withResult:)]) {
        [self.helper uploadDidCompleteForFile:[self fileInfo] withResult:@{USTATUS : UESUCCESS}];
    }
}

//------------------------------------------------------------------------------
- (void)fail:(NSDictionary*)response {
    [self statusChange:self.opCallbacks.onerror response:response status:UEFAIL];
    if ([self.helper respondsToSelector:@selector(uploadDidCompleteForFile:withResult:)]) {
        [self.helper uploadDidCompleteForFile:[self fileInfo] withResult:@{USTATUS : UEFAIL}];
    }
}

//------------------------------------------------------------------------------
- (void)statusChange:(StandardCallback)callback response:(NSDictionary*)response status:(NSString*)status{
    self.connection = nil;
    if (status != nil) {
        [self setStatus:status];
    }
    
    if (response == nil) {
        response = @{};
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        callback(@{ @"fileInfo" : [self fileInfo], @"response" : response});
    });
}

//------------------------------------------------------------------------------
- (void)setStatus:(NSString*)status {
    [self.statusLock lock];
    self.currentStatus = status;
    [self.statusLock unlock];
}

//------------------------------------------------------------------------------
- (ReferenceCallback)httpTask {
    __weak typeof(self) bself = self;
    return ^(NSURLSessionTask* connection) {
        bself.connection = connection;
    };
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
//------------------------------------------------------------------------------
- (BOOL)shouldCheckAgain:(NSDictionary*)checkResponse {
    return FALSE;
}
#pragma clang diagnostic pop

//------------------------------------------------------------------------------
- (NSDictionary*)fileInfo {
    return
    @{UFILENAME : (self.fileName.length ? self.fileName : @""),
      UFILEHASH : (self.fileHash.length ? self.fileHash : @""),
      UFILEPATH : (self.filePath.length ? self.filePath : @""),
      USTATUS   : (self.currentStatus.length ? self.currentStatus : @""),
      UUPLOADKEY: (self.verificationKey.length ? self.verificationKey : @""),
      UQUICKKEY : (self.quickkey.length ? self.quickkey : @"") ,
      UUNITCOUNT: [NSNumber numberWithInteger:self.unitCount],
      UFILESIZE : [NSNumber numberWithLongLong:self.fileSize],
      UUNITSIZE : [NSNumber numberWithInteger:self.unitSize],
      ULASTUNIT : [NSNumber numberWithInteger:self.lastUnit],
      UIDENT    : (self.identifier.length ? self.identifier : @"")
      };
}

//------------------------------------------------------------------------------
- (void)dealloc {
    self.connection = nil;
    self.opCallbacks = nil;
}

//==============================================================================
// GETTER METHODS
//==============================================================================

//------------------------------------------------------------------------------
- (NSString*)fileName {
    if (_fileName == nil) {
        _fileName = @"";
    }
    return _fileName;
}

//------------------------------------------------------------------------------
- (NSString*)fileHash {
    if (_fileHash == nil) {
        _fileHash = @"";
    }
    return _fileHash;
}

//------------------------------------------------------------------------------
- (NSString*)filePath {
    if (_filePath == nil) {
        _filePath = @"";
    }
    return _filePath;
}

//------------------------------------------------------------------------------
- (NSString*)currentStatus {
    if (_currentStatus == nil) {
        _currentStatus = @"";
    }
    return _currentStatus;
}

//------------------------------------------------------------------------------
- (NSString*)verificationKey {
    if (_verificationKey ==  nil) {
        _verificationKey = @"";
    }
    return _verificationKey;
}

//------------------------------------------------------------------------------
- (NSString*)quickkey {
    if (_quickkey ==  nil) {
        _quickkey = @"";
    }
    return _quickkey;
}

//------------------------------------------------------------------------------
- (NSString*)folderkey {
    if (_folderkey ==  nil) {
        _folderkey = @"";
    }
    return _folderkey;
}

//------------------------------------------------------------------------------
- (void)setHttpClientId:(NSString*)clientId {
    [self.statusLock lock];
    _httpClientId = clientId;
    [self.statusLock unlock];
    
}

//------------------------------------------------------------------------------
- (NSString*)httpClientId {
    NSString* clientId = nil;
    [self.statusLock lock];
    if (_httpClientId == nil) {
        _httpClientId = @"";
    }
    clientId = _httpClientId;
    [self.statusLock unlock];
    return clientId;
}

@end

