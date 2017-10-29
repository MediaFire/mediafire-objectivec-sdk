//
//  MFHash.m
//  MediaFireSDK
//
//  Created by Ken Hartness
//  Copyright 2013, MediaFire, LLC. All rights reserved.
//
#import "MFHash.h"
#import "MFEncode.h"
#include <CommonCrypto/CommonCrypto.h>

typedef int (^UpdateDigest)(NSData* chunkData);

@implementation MFHash

//------------------------------------------------------------------------------
+ (NSData*)sha1:(id)data {
    CC_SHA1_CTX* ctx = (CC_SHA1_CTX*)malloc(sizeof(CC_SHA1_CTX));
    NSMutableData* result = [NSMutableData dataWithLength:CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1_Init(ctx);
    if ( [data isKindOfClass:[NSData class]] ) {
        CC_SHA1_Update(ctx, [data bytes], (CC_LONG)[data length]);
    } else if ( [data isKindOfClass:[NSString class]] ) {
        const char* str = [data UTF8String];
        CC_SHA1_Update(ctx, str, (CC_LONG)strlen(str));
    } else {
        free(ctx);
        return nil;
    }
    CC_SHA1_Final([result mutableBytes], ctx);
    free(ctx);
    
    return result;
}

//------------------------------------------------------------------------------
+ (NSString*)sha1Hex:(id)data {
    return [MFEncode dataToHex:[self sha1:data]];
}

//------------------------------------------------------------------------------
+ (NSData*)sha1Chunked:(MFHashChunkBlock)block {
    CC_SHA1_CTX* ctx = (CC_SHA1_CTX*)malloc(sizeof(CC_SHA1_CTX));
    NSMutableData* result = [NSMutableData dataWithLength:CC_SHA1_DIGEST_LENGTH];
    
    NSData* data;
    BOOL done = false;
    
    CC_SHA1_Init(ctx);
    for(int i=0 ; !done && i<INT32_MAX ; i++) {
        data = block(i, &done);
        if (data == nil) {
            done = true;
            break;
        }
        CC_SHA1_Update(ctx, [data bytes], (CC_LONG)[data length]);
    }
    CC_SHA1_Final([result mutableBytes], ctx);
    free(ctx);
    
    return result;
}

//------------------------------------------------------------------------------
+ (NSString*)sha1HexChunked:(MFHashChunkBlock)block {
    return [MFEncode dataToHex:[self sha1Chunked:block]];
}

//------------------------------------------------------------------------------
+ (NSString*)sha1HashFileAtPath:(NSString*)path blockSize:(unsigned long long)size {
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:path];
    __block NSMutableData* dataBuffer = [[NSMutableData alloc]init];
    
    MFHashChunkBlock block = ^(int index, BOOL* done) {
        [file seekToFileOffset: (((unsigned long long)index)*size)];
        @autoreleasepool {
            [dataBuffer setData:[file readDataOfLength:size]];
            if (dataBuffer.length < size) {
                *done = true;
            }
        }
        return dataBuffer;
    };
    return [MFHash sha1HexChunked:block];
}

//------------------------------------------------------------------------------
+ (NSData*)sha256:(id)data {
    CC_SHA256_CTX* ctx = (CC_SHA256_CTX*)malloc(sizeof(CC_SHA256_CTX));
    NSMutableData* result = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    
    CC_SHA256_Init(ctx);
    if ( [data isKindOfClass:[NSData class]] ) {
        CC_SHA256_Update(ctx, [data bytes], (CC_LONG)[data length]);
    } else if ( [data isKindOfClass:[NSString class]] ) {
        const char* str = [data UTF8String];
        CC_SHA256_Update(ctx, str, (CC_LONG)strlen(str));
    } else {
        free(ctx);
        return nil;
    }
    CC_SHA256_Final([result mutableBytes], ctx);
    free(ctx);
    
    return result;
}

//------------------------------------------------------------------------------
+ (NSString*)sha256Hex:(id)data {
    return [MFEncode dataToHex:[self sha256:data]];
}

//------------------------------------------------------------------------------
+ (NSData*)sha256Chunked:(MFHashChunkBlock)block {
    CC_SHA256_CTX* ctx = (CC_SHA256_CTX*)malloc(sizeof(CC_SHA256_CTX));
    NSMutableData* result = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    
    NSData* data;
    BOOL done = false;

    CC_SHA256_Init(ctx);
    for(int i=0 ; !done && i<INT32_MAX ; i++) {
        data = block(i, &done);
        if (data == nil) {
            done = true;
            break;
        }
        CC_SHA256_Update(ctx, [data bytes], (CC_LONG)[data length]);
    }
    CC_SHA256_Final([result mutableBytes], ctx);
    free(ctx);
    
    return result;
}

//------------------------------------------------------------------------------
+ (NSString*)sha256HexChunked:(MFHashChunkBlock)block {
    return [MFEncode dataToHex:[self sha256Chunked:block]];
}

//------------------------------------------------------------------------------
+ (NSString*)sha256HashFileAtPath:(NSString*)path blockSize:(unsigned long long)size {
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:path];
    __block NSMutableData* dataBuffer = [[NSMutableData alloc]init];
    
    MFHashChunkBlock block = ^(int index, BOOL* done) {
        [file seekToFileOffset: (((unsigned long long)index)*size)];
        @autoreleasepool {
            [dataBuffer setData:[file readDataOfLength:size]];
            if (dataBuffer.length < size) {
                *done = true;
            }
        }
        return dataBuffer;
    };
    return [MFHash sha256HexChunked:block];
}


//------------------------------------------------------------------------------
+ (NSData*)md5:(id)data {
    CC_MD5_CTX* ctx = (CC_MD5_CTX*)malloc(sizeof(CC_MD5_CTX));
    NSMutableData* result = [NSMutableData dataWithLength:CC_MD5_DIGEST_LENGTH];
    
    CC_MD5_Init(ctx);
    if ( [data isKindOfClass:[NSData class]] ) {
        CC_MD5_Update(ctx, [data bytes], (CC_LONG)[data length]);
    } else if ( [data isKindOfClass:[NSString class]] ) {
        const char* str = [data UTF8String];
        CC_MD5_Update(ctx, str, (CC_LONG)strlen(str));
    } else {
        free(ctx);
        return false;
    }
    CC_MD5_Final([result mutableBytes], ctx);
    free(ctx);
    
    return result;
}

//------------------------------------------------------------------------------
+ (NSString*)md5Hex:(id)data {
    return [MFEncode dataToHex:[self md5:data]];
}

//------------------------------------------------------------------------------
+ (NSData*)md5Chunked:(MFHashChunkBlock)block {
    CC_MD5_CTX* ctx = (CC_MD5_CTX*)malloc(sizeof(CC_MD5_CTX));
    NSMutableData* result = [NSMutableData dataWithLength:CC_MD5_DIGEST_LENGTH];

    NSMutableData* data = [[NSMutableData alloc] init];
    BOOL done = false;
    
    CC_MD5_Init(ctx);
    for(int i=0 ; !done && i<INT32_MAX ; i++) {
        [data setData:block(i, &done)];
        if (data == nil) {
            done = true;
            break;
        }
        CC_MD5_Update(ctx, [data bytes], (CC_LONG)[data length]);
    }
    CC_MD5_Final([result mutableBytes], ctx);
    free(ctx);
    
    return result;
}

//------------------------------------------------------------------------------
+ (NSString*)md5HexChunked:(MFHashChunkBlock)block {
    return [MFEncode dataToHex:[self md5Chunked:block]];
}

//------------------------------------------------------------------------------
+ (NSString*)md5HashFileAtPath:(NSString*)path blockSize:(unsigned long long)size {
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:path];
    __block NSMutableData* dataBuffer = [[NSMutableData alloc]init];
    
    MFHashChunkBlock block = ^(int index, BOOL* done) {
        [file seekToFileOffset: (((unsigned long long)index)*size)];
        @autoreleasepool {
            [dataBuffer setData:[file readDataOfLength:size]];
            if (dataBuffer.length < size) {
                *done = true;
            }
        }
        return dataBuffer;
    };
    return [MFHash md5HexChunked:block];
}

@end
