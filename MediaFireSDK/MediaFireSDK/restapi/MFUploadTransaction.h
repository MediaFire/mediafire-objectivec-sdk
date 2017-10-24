//
//  MFUploadTransaction.h
//  MediaFireSDK
//
//  Created by Mike Jablonski on 3/5/14.
//  Copyright (c) 2014 MediaFire. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MFUploadHelperDelegate.h"

/**
  @brief Uploads a file to the cloud.
 
  The desired file's path is passed as an NSString to MFUploadTransaction
  during initialization. If the file represented by the given file path
  is not existing or not readable by the app, the upload will fail.
 
  To start the upload process, call start or startWithCallbacks. To cancel,
  call cancel.
 
  Callbacks are represented by a NSDictionary with ONLOAD, ONERROR,
  ONPROGRESS, ONUPDATE blocks. Each block has a NSDictionary parameter
  that can expected nested NSDictionaries for following keys: "fileInfo" and
  "response". The "fileInfo" dictionary contains the following
  keys: UFILENAME, UFILEHASH, UFILEPATH, USTATUS, UUPLOADKEY, UQUICKKEY,
  UUNITCOUNT, UFILESIZE, UUNITSIZE, ULASTUNIT. The objects for these keys
  are NSNumbers or NSStrings.
  The "response" dictionary will be an MFErrorMessage or dictionary with
  key UEVENT (and UCHUNKID key if object for key UEVENT matches UECHUNK).
  These blocks are called on successful or failed uploads as well as multiple
  times for status changes. The same callback property may be used for
  multiple MFUploadTransactions.
 */

@class MFUploadAPI;

@interface MFUploadTransaction : NSObject

/**
 @brief The destination folderkey for the upload.  Defaults to the root folder if left blank.
 */
@property (nonatomic,strong) NSString* folderkey;
/**
 @brief A unique http client name registered thru MFConfig.
 */
@property (strong,nonatomic) NSString* httpClientId;

/**
 @brief A delegate that conforms to the MFUploadHelper protocol. (Optional)
 */
@property (nonatomic, strong) id<MFUploadHelperDelegate> helper;
/**
 @brief Returns an MFUploadTransaction object initialized with a given MFUploadAPI instance.
 
 @param api An preconfigured instance of the MFUploadAPI class.  If left nil, a default-configured instance will be created.
 */
- (id)initWithUploadAPI:(MFUploadAPI*)api;

/**
 @brief Returns an MFUploadTransaction object initialized with a given file path and MFUploadAPI instance.

 @param filePath The local path of the file to be uploaded.
 
 @param api An preconfigured instance of the MFUploadAPI class.  If left nil, a default-configured instance will be created.
*/
- (id)initWithFilePath:(NSString*)filePath uploadAPI:(MFUploadAPI*)api;

/**
  @brief Returns a MFUploadTransaction for a file.
 
  @param filePath The desired file to be uploaded as a NSString file system
  path
 */
- (id)initWithFilePath:(NSString*)filePath;

/**
  @brief Starts the upload process with callbacks.
 
  @param callbacks A NSDictionary with ONLOAD, ONERROR, ONPROGRESS, ONUPDATE
  blocks to be called on successful or failed uploads as well as multiple
  times for status changes. Callback dictionary may be used for multiple
  MFUploadTransactions.
 */
- (void)startWithCallbacks:(NSDictionary*)callbacks;

/**
 @brief Starts the upload process.
 */
- (void)start;

/**
 @brief Cancels the upload process. May be restarted with a call to start.
 */
- (void)cancel;

/**
 @brief Called by internal functions to prepare a file for upload.
 */
- (void)prepareFile;

/**
 @brief Called by internal functions to begin a resumable upload.
 */
- (void)checkUpload;

/**
 @brief Called by internal functions when a failure happens.
 */
- (void)fail:(NSDictionary*)response;

/**
 @brief Returns http client options for the check api call.
 */
- (NSDictionary*)optionsForCheckUpload;

/**
 @brief Returns http client options for the instant api call.
 */
- (NSDictionary*)optionsForInstantUpload;

/**
 @brief Returns true if the failed unit should be retried instead of failing the upload.
 */
- (BOOL)shouldRetryResumable:(NSDictionary*)response originalOptions:(NSDictionary*)options unitInfo:(NSDictionary*)unitInfo;

/**
 @brief Returns http client options for the resumable api call.
 */
- (NSDictionary*)optionsForResumableUpload;

/**
 @brief Returns additional parameters for the resumable api call.
 */
- (NSDictionary*)parametersForResumableUpload;

/**
 @brief Returns http client options for the poll_upload api call.
 */
- (NSDictionary*)optionsForPollUpload;



@end
