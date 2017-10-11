//
//  MFUploadHelper.m
//  MediaFireSDK
//
//  Created by Daniel Dean on 11/10/14.
//  Copyright (c) 2014 MediaFire. All rights reserved.
//

#import "MFUploadHelper.h"
#import "MFUploaderConstants.h"
#import "MFErrorLog.h"
#import "MFHash.h"

static int64_t      MAX_FILESIZE_MEM= 10000000;
static unsigned long long HASH_BLOCK_SIZE = 262144;

@implementation MFUploadHelper

- (NSData*)getChunk:(int)chunkNumber forFile:(NSDictionary*)fileInfo {
    if (fileInfo == nil) {
        return nil;
    }
    
    int64_t fileSize = [fileInfo[UFILESIZE] longLongValue];
    unsigned long chunkSize = [fileInfo[UUNITSIZE] longLongValue];
    unsigned long startFrom = [fileInfo[ULASTUNIT] longLongValue] * chunkSize;
    
    if ((startFrom >= LLONG_MAX) || (startFrom > fileSize) || (fileSize < 0)) {
        mflog(@"Cannot get chunk. fileSize(%lli) startFrom(%llu) chunkNumber(%i) chunkSize(%llu)", fileSize, startFrom, chunkNumber, chunkSize);
        return nil;
    }
    
    if (startFrom + chunkSize > fileSize) {
        chunkSize = (unsigned long)(fileSize - startFrom);
    }
    if (chunkNumber < 0) {
        chunkSize = (unsigned long)(fileSize);
        startFrom = 0;
    }
    
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:fileInfo[UFILEPATH]];
    if (file == nil) {
        return nil;
    }
    NSMutableData* dataBuffer = [[NSMutableData alloc] init];
    [file seekToFileOffset:startFrom];
    [dataBuffer setData:[file readDataOfLength:chunkSize]];
    
    return dataBuffer;
}

- (void)prepareFileForUpload:(NSDictionary*)fileInfo withCompletionHandler:(MFUploadFilePrepCallback)block {
    // Check for empty file path
    NSString* path = fileInfo[UFILEPATH];
    MFUploadFileInfo* file = [[MFUploadFileInfo alloc] init];
    
    // File Path
    file.filePath = path;
    
    if (path == nil || [path isEqualToString:@""]) {
        mflog(@"Cannot prepare file for upload. File path is empty. - %@",path);
        block(nil, [[NSError alloc] initWithDomain:@"null field." code:53000 userInfo:@{@"name" : @"file path"}]);
        return;
    }
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        block(nil, [[NSError alloc] initWithDomain:@"file does not exist." code:53000 userInfo:@{@"name" : path}]);
        return;
    }

    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
        mflog(@"Cannot prepare file for upload. App does not have read privileges or the existence of the file could not be determined - %@", path);
        block(nil, [[NSError alloc] initWithDomain:@"file is not readable." code:53000 userInfo:@{@"name" : path}]);
        return;
    }

    // File name
    file.fileName = [NSString stringWithFormat:@"%@",[path lastPathComponent]];
    
    // Get file size
    NSError* sizeError = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&sizeError];
    
    if (sizeError) {
        mflog(@"Cannot prepare file for upload. Could not get file size. - %@. Error: %@", path, [sizeError userInfo]);
        block(nil, sizeError);
        return;
    }
    
    file.fileSize = [fileAttributes fileSize];
    
    // File Hash and upload data
    if (file.fileSize < MAX_FILESIZE_MEM) {
        NSError* dataError = nil;
        file.uploadData = [NSData dataWithContentsOfFile:path options:NSMappedRead error:&dataError];
        if (dataError) {
            mflog(@"Cannot prepare file for upload. Cannot memory map the file data. - %@. Error: %@", path, [dataError userInfo]);
            block(nil, dataError);
            return;
        }
        file.fileHash = [MFHash sha256Hex:file.uploadData];
    } else {
        file.fileHash = [MFHash sha256HashFileAtPath:file.filePath blockSize:HASH_BLOCK_SIZE];
    }

    block(file, nil);
}

@end
