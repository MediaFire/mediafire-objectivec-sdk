//
//  MFUploadAPI.m
//  MediaFireSDK
//
//  Created by Daniel Dean on 2/25/14.
//  Copyright (c) 2014 MediaFire. All rights reserved.
//

#import "MFUploadAPI.h"
#import "NSDictionary+Callbacks.h"
#import "MFErrorMessage.h"
#import "MFREST.h"
#import "NSDictionary+MapObject.h"
#import "MFHTTPOptions.h"
#import "MFConfig.h"

@implementation MFUploadAPI

//------------------------------------------------------------------------------
- (id)init {
    self = [self initWithVersion:[MFConfig defaultAPIVersionForModule:@"MFUploadAPI"]];
    if (self == nil) {
        return nil;
    }
    return self;
}

//------------------------------------------------------------------------------
- (id)initWithVersion:(NSString*)version {
    self = [super initWithPath:@"upload" version:version];
    if (self == nil) {
        return nil;
    }
    return self;
}

//------------------------------------------------------------------------------
- (void)check:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self check:@{} query:parameters callbacks:callbacks];
}

- (void)check:(NSDictionary*)options query:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self createRequest:[self checkConf:options query:parameters]
              callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (void)instant:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self instant:@{} query:parameters callbacks:callbacks];
}

- (void)instant:(NSDictionary*)options query:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self createRequest:[self instantConf:options query:parameters]
              callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (void)uploadFile:(NSDictionary*)options fileInfo:(NSDictionary*)fileInfo callbacks:(NSDictionary*)callbacks {
    NSDictionary* headers = [self getHeadersFrom:options];
    if (headers == nil) {
        callbacks.onerror([MFErrorMessage nullField]);
        return;
    }
    
    [self createRequest:[self uploadFileConf:options fileInfo:fileInfo] callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (void)uploadUnit:(NSDictionary*)fileInfo query:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self uploadUnit:@{} fileInfo:fileInfo query:parameters callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (void)uploadUnit:(NSDictionary*)options fileInfo:(NSDictionary*)fileInfo query:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    NSDictionary* headers = [self getHeadersFrom:fileInfo];
    if (headers == nil) {
        callbacks.onerror([MFErrorMessage nullField:@"headers"]);
        return;
    }
    if (fileInfo[@"unit_data"] == nil) {
        callbacks.onerror([MFErrorMessage nullField:@"unit_data"]);
        return;
    }
    
    [self createRequest:[self uploadUnitConf:options fileInfo:fileInfo query:parameters]
              callbacks:callbacks];
    
}

//------------------------------------------------------------------------------
- (void)upload:(NSDictionary*)options query:(NSDictionary*)parameters callbacks:(NSDictionary *)callbacks {
    [self createRequest:[self uploadConf:options query:parameters] callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (void)pollUpload:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self pollUpload:@{} query:parameters callbacks:callbacks];
}

- (void)pollUpload:(NSDictionary*)options query:(NSDictionary*)parameters callbacks:(NSDictionary*)callbacks {
    [self createRequest:[self pollUploadConf:options query:parameters] callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (NSDictionary*)getHeadersFrom:(NSDictionary*)info {
    // sanity check on normal upload
    if (info[@"file_name"] == nil || info[@"file_hash"] == nil || info[@"file_size"] == nil) {
        return nil;
    }
    NSMutableDictionary* headers = [[NSMutableDictionary alloc] initWithDictionary:
                                    @{@"x-filehash"  : info[@"file_hash"],
                                      @"x-filename"  : info[@"file_name"],
                                      @"x-filesize"  : info[@"file_size"],
                                      @"Content-Type": @"application/octet-stream"}];
    
    // sanity check on chunked upload
    if (info[@"unit_hash"] != nil || info[@"unit_id"] != nil || info[@"unit_size"] != nil) {
        if (info[@"unit_hash"] == nil || info[@"unit_id"] == nil || info[@"unit_size"] == nil) {
            return nil;
        }
        headers[@"x-unit-hash"] = info[@"unit_hash"];
        headers[@"x-unit-id"]   = info[@"unit_id"];
        headers[@"x-unit-size"] = info[@"unit_size"];
    }
    
    return headers;
}

//------------------------------------------------------------------------------
+ (int)getFirstEmptyBitFromWord:(int32_t)bitmap {
    if (bitmap == 0) {
        // All zeros, no need to check this one.
        return 0;
    }
    int emptyBit = 0;   // Return value
    int currentBit = 0; // Contains the last shifted bit
    
    for (int i=0; i<16 ; i++) {
        currentBit = (bitmap >> i) & 1;
        if (currentBit == 0) {
            break;
        }
        currentBit = 0;
        emptyBit++;
    }
    
    return emptyBit;
}

//------------------------------------------------------------------------------
+ (int)getFirstEmptyBit:(NSDictionary*)bitmap {
    if (bitmap == nil) {
        return 0;
    }
    if (bitmap[@"count"] == nil || bitmap[@"count"] == nil) {
        return 0;
    }
    int count = [bitmap[@"count"] intValue];
    NSArray* words = bitmap[@"words"];
    int32_t word = 0;
    int emptyBit=0;
    int emptyBitFromWord=0;
    
    for (int i=0 ; i<count ; i++) {
        word = [words[i] intValue];
        if (word == 0) {
            // Obviously we have found a zero bit.
            break;
        }
        emptyBitFromWord = [self getFirstEmptyBitFromWord:word];
        emptyBit = emptyBit + emptyBitFromWord;
        if (emptyBitFromWord < 16) {
            // bit 0-15 was returned, so we have found a zero bit.
            break;
        }
    }
    return emptyBit;
}

//------------------------------------------------------------------------------
- (MFAPIURLRequestConfig*)checkConf:(NSDictionary*)options query:(NSDictionary*)parameters {
    return [self createConfigWithOptions:[options merge:@{HURL : @"check.php",
                                                          HMETHOD : @"POST"}]
                                   query:parameters];
}

//------------------------------------------------------------------------------
- (MFAPIURLRequestConfig*)instantConf:(NSDictionary*)options query:(NSDictionary*)parameters {
    return [self createConfigWithOptions:[options merge:@{HURL : @"instant.php",
                                                          HTOKEN: HTKT_PARA,
                                                          HPARALLEL : HPTT_UPLOAD}]
                                   query:parameters];
}

//------------------------------------------------------------------------------
- (MFAPIURLRequestConfig*)uploadFileConf:(NSDictionary*)options fileInfo:(NSDictionary*)fileInfo {
    NSDictionary* headers = [self getHeadersFrom:fileInfo];
    NSMutableDictionary* reqOptions = [[NSMutableDictionary alloc] initWithDictionary:
                                       @{HREQHEADERS    : headers, HTOKEN: HTKT_PARA, HPARALLEL : HPTT_UPLOAD}];
    reqOptions[HCLIENT] = options[HCLIENT];
    if (options[@"file_path"] != nil) {
        reqOptions[@"upload"]       = @"path";
        reqOptions[@"upload_path"]  = options[@"file_path"];
    } else {
        reqOptions[@"upload"]         = @"data";
        reqOptions[@"upload_data"]  = options[@"file_data"];
    }
    
    NSMutableDictionary* optionsMutable = [options mutableCopy];
    [optionsMutable addEntriesFromDictionary:@{@"type" : @"basic"}];
    
    return [self uploadConf:reqOptions query:optionsMutable];
}

//------------------------------------------------------------------------------
- (MFAPIURLRequestConfig*)uploadUnitConf:(NSDictionary*)options fileInfo:(NSDictionary*)fileInfo query:(NSDictionary*)parameters {
    NSDictionary* headers = [self getHeadersFrom:fileInfo];
    NSDictionary* reqOptions = [@{HHOST: [MFREST host]} merge: options];

    reqOptions = [reqOptions merge:
                  @{HREQHEADERS   : headers,
                    HUPTYPE       : @"data",
                    HUPDATA       : fileInfo[@"unit_data"],
                    HTOKEN        : HTKT_PARA,
                    HPARALLEL     : HPTT_UPLOAD}];
    
    return [self uploadConf:reqOptions query:parameters];
}

//------------------------------------------------------------------------------
- (MFAPIURLRequestConfig*)uploadConf:(NSDictionary*)options query:(NSDictionary*)parameters {
    return [self createConfigWithOptions:[options merge:@{HURL : @"resumable.php",
                                                          HURLPARAMS : @"true",
                                                          HMETHOD : @"POST"}]
                                   query:parameters];
}

//------------------------------------------------------------------------------
- (MFAPIURLRequestConfig*)pollUploadConf:(NSDictionary*)options query:(NSDictionary*)parameters {
    return [self createConfigWithOptions:[options merge:@{HURL : @"poll_upload.php",
                                                          HMETHOD : @"POST",
                                                          HTOKEN : HTKT_NONE}]
                                   query:parameters];
}


@end
