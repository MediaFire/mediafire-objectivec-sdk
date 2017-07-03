//
//  SessionManager.m
//  MediaFireSDK
//
//  Created by Daniel Dean on 7/31/13.
//  Copyright (c) 2013 MediaFire. All rights reserved.
//
//  Maintains a dictionary of sessions indexed by session token,
//  a queue of available tokens, and a queue of token requests.
//  The sessions dictionary is nil unless a session has been started.
//  Any requests for a token when none are available (first token hasn't arrived
//  from the server or all tokens are in use) causes the parameters of the
//  request to be added to the token request queue. If the number of sessions is
//  less than some max parallel sessions, a new session token is requested
//  whenever none are available. Whenever a token is released or a new token
//  arrives, the next request is removed from the queue and filled.

#import "MFSerialRequestManager.h"
#import "NSDictionary+Callbacks.h"
#import "MFCircularQueue.h"
#import "MFHash.h"
#import "NSString+StringURL.h"
#import "NSDictionary+JSONExtender.h"
#import "NSArray+JSONExtender.h"
#import "NSString+JSONExtender.h"
#import "NSDictionary+MapObject.h"
#import "MFErrorMessage.h"
#import "MFErrorLog.h"
#import "MFREST.h"
#import "MFHTTP.h"
#import "MFHTTPOptions.h"
#import "MFCredentials.h"
#import "MFConfig.h"
#import "MFAPIURLRequestConfig.h"
#import "MFRequestHandler.h"
#import "MFSessionAPI.h"

static int LCG_SECRET = 16807;
static int LCG_MOD = 2147483647;

@interface MFSerialRequestManager()
@property(strong, nonatomic) NSMutableDictionary* sessions;
@property(strong, nonatomic) MFCircularQueue* available;
@property(strong, nonatomic) MFCircularQueue* tokenRequests;
@property(strong, nonatomic) NSLock* statusLock;
@property(strong, nonatomic) NSLock* sessionLock;
@property(nonatomic) NSUInteger awaitingTokens;
@property (nonatomic) NSUInteger suggestedTokens;
@property (nonatomic) NSUInteger maxTokens;
@property(strong, nonatomic) NSMutableDictionary* tempCredentials;
@end

static id instance = nil;

@implementation MFSerialRequestManager

@synthesize sessionAPI = _sessionAPI;

//------------------------------------------------------------------------------
- (id)init {
    if (instance != nil) {
        return instance;
    }
    
    self = [super init];
    if ( self == nil ) {
        return nil;
    }
    
    _suggestedTokens = 3;
    _maxTokens       = 10;
    _sessions        = nil;
    _available       = [[MFCircularQueue alloc] init];
    _tokenRequests   = [[MFCircularQueue alloc] init];
    _statusLock     = [[NSLock alloc] init];
    _sessionLock     = [[NSLock alloc] init];
    _awaitingTokens  = 0;
    return self;
}

//------------------------------------------------------------------------------
- (id)initWithTokensFrom:(NSUInteger)suggested to:(NSUInteger)max {
    if (instance != nil) {
        return instance;
    }
    if ( [self init] != nil ) {
        if ( suggested == 0 ) {
            suggested = 1;
        }
        if ( max < suggested ) {
            max = suggested;
        }
        _suggestedTokens = suggested;
        _maxTokens = max;
    }

    return self;
}

//------------------------------------------------------------------------------
- (void)dealloc {
    if ( self.sessions != nil ) {
        [self endSession];
    }
}

//------------------------------------------------------------------------------
+ (instancetype)getInstance {
    if (instance == nil) {
        @synchronized(self) {
            if (instance == nil) {
                instance =[[self alloc] initWithTokensFrom:[[MFConfig instance] minTokens] to:[[MFConfig instance] maxTokens]];
            }
        }
    }
    return instance;
}

//------------------------------------------------------------------------------
+ (void)endSession {
    [instance endSession];
}

+ (BOOL)hasSession {
    return ([[instance sessions] count] > 0);
}

//------------------------------------------------------------------------------
+ (void)destroy {
    [instance endSession];
    @synchronized(self) {
        instance = nil;
    }
}

//==============================================================================
//==============================================================================
// TOKEN MANAGEMENT
//==============================================================================
//==============================================================================

//------------------------------------------------------------------------------
- (void)askForAdditionalSessionTokens {
    NSDictionary* credentials = [[MFConfig credentialsDelegate] getCredentials];
    if ( credentials == nil ) {
       erm(noCredentials);
        return;
    }
    // Sanity check for password before attempting token request.
    if ((![(NSString*)credentials[MFCRD_MF_PASS] length]) && ([(NSString*)credentials[@"type"] isEqualToString:MFCRD_TYPE_MF] || [(NSString*)credentials[@"type"] isEqualToString:MFCRD_TYPE_EKEY])) {
        erm(nullField:@"Password");
        return;
    }
    
    // success callback
    MFCallback newTokenAvailable = ^(NSDictionary* response) {
        [self.sessionLock lock];
        self.awaitingTokens--;
        [self.sessionLock unlock];
        [self processNewToken:response];
        
        if ( [self doesNeedMoreTokens] ) {
            [self askForAdditionalSessionTokens];
        }
        [self nextRequest];
    };
    
    // failure callback
    MFCallback failedToGetToken = ^(NSDictionary * response) {
        [self.sessionLock lock];
        self.awaitingTokens--;
        [self.sessionLock unlock];
        erm(obtainTokenFailure:response);
        if ([MFErrorMessage isAuthenticationError:response]) {
            MFConfig.authenticationFailureCallback(response);
        }
        [self nextRequest];
    };
    
    [self.sessionLock lock];
    self.awaitingTokens++;
    [self.sessionLock unlock];
    
    // request another token
    [self.sessionAPI getSessionToken:credentials callbacks:@{ONLOAD:newTokenAvailable,ONERROR:failedToGetToken}];
}

//------------------------------------------------------------------------------
- (void)releaseToken:(NSString*)sessionToken updateSecret:(BOOL)update {
    // locate token in sessions
    NSUInteger tokenCount = 0;
    [self.sessionLock lock];
    NSMutableDictionary* tokenPacket = self.sessions[sessionToken];
    [self.sessionLock unlock];
    // if token is not found, then bail out
    if (tokenPacket == nil) {
        erm(nullField:@"token packet");
        return;
    }
    if (!([tokenPacket[@"locked"] boolValue])) {
        erm(badTokenState);
        return;
    }
    // if the request was aborted we don't update the counter.
    if (update) {
        [self updateSecretForTokenPacket:tokenPacket];
    }
    // put the token back in the available pool.
    [self.sessionLock lock];
    tokenPacket[@"locked"] = @NO;
    [self.available enqueue:sessionToken];
    tokenCount = self.sessions.count;
    [self.sessionLock unlock];
    [self nextRequest];
}

//------------------------------------------------------------------------------
/*  Based on presence of new_key=yes in response, token may be updated.
 In any case, it is released for re-use. */
//------------------------------------------------------------------------------
+ (void)releaseToken:(NSString*)token forResponse:(NSDictionary*) response {
    NSString* update_token_str = response[@"new_key"];
    BOOL updateToken = ( update_token_str != nil && [update_token_str isEqualToString:@"yes"] );
    
    if ( updateToken ) {
        [[self getInstance] releaseToken:token updateSecret:true];
    } else {
        [[self getInstance] releaseToken:token updateSecret:false];
    }
}

//------------------------------------------------------------------------------
- (void)updateSecretForTokenPacket:(NSMutableDictionary*)tokenPacket {
    uint64_t secret = [tokenPacket[@"secret_key"] unsignedIntegerValue];
    secret = (secret * LCG_SECRET) % LCG_MOD;
    tokenPacket[@"secret_key"] = [NSNumber numberWithUnsignedInteger:(NSUInteger)secret];
}

//------------------------------------------------------------------------------
+ (void)abandonToken:(NSString*)token {
    [instance abandonToken:token];
}

//------------------------------------------------------------------------------
- (void)abandonToken:(NSString*)token {
    // sanity check
    if (token == nil) {
        erm(nullField:@"abandoned token");
        return;
    }
    [self.sessionLock lock];
    // locate token in sessions
    NSMutableDictionary* tokenPacket = self.sessions[token];
    [self.sessionLock unlock];
    // sanity check
    if (tokenPacket == nil) {
        erm(nullField:@"token packet for abandoned token");
        return;
    }
    
    // remove token from sessions.
    [self.sessionLock lock];
    [self.sessions removeObjectForKey:token];
    [self.sessionLock unlock];
    
    // in case someone is referencing this token
    tokenPacket[@"locked"] = @NO;

    if ([self doesNeedMoreTokens]) {
        [self askForAdditionalSessionTokens];
    }
    
    [self nextRequest];
}

//------------------------------------------------------------------------------
- (BOOL)doesNeedMoreTokens {
    BOOL needMore = false;
    [self.sessionLock lock];
    NSUInteger totalTokens        = self.sessions.count + self.awaitingTokens;
    NSUInteger pendingRequests  = self.tokenRequests.count;
    // if we have more requests waiting to process than we have session tokens,
    // then we should increase the number of tokens we want.
    if ((totalTokens < self.suggestedTokens) || ((self.awaitingTokens < pendingRequests) && (totalTokens < self.maxTokens))) {
        needMore = true;
    }
    [self.sessionLock unlock];
    return needMore;
}

//------------------------------------------------------------------------------
- (void)processNewToken:(NSDictionary*)response {
    // sanity check
    if (response == nil) {
        mflog(@"Unable to process new token, response is nil.");
        return;
    }
    // the response object should look like a valid token packet.
    NSMutableDictionary*    tokenPacket = [[NSMutableDictionary alloc] initWithDictionary:response];
    
    //sanity check
    if (tokenPacket == nil || (![tokenPacket[@"session_token"] isKindOfClass:[NSString class]])) {
        mflog(@"Unable to find new token in response.");
        return;
    }
    // "tokenHash" is only the string value of the token, ie the hash.
    // The "tokenPacket" object contains other properties, including the pkey, secret, etc.
    NSString* tokenHash = tokenPacket[@"session_token"];
    // sanity check
    if (tokenHash == nil || [tokenHash isEqualToString:@""]) {
        mflog(@"Unable to find token hash.");
        return;
    }
    
    [self.sessionLock lock];
    if ( self.sessions == nil ) {
        self.sessions = [[NSMutableDictionary alloc] init];
    }
    // store the token using the hash as the index key
    self.sessions[tokenHash] = tokenPacket;
    tokenPacket[@"locked"] = @NO;
    // Add this token to the token pool.
    [self.available enqueue:tokenHash];

    [self.sessionLock unlock];
}

//==============================================================================
//==============================================================================
// REQUEST MANAGEMENT
//==============================================================================
//==============================================================================

//------------------------------------------------------------------------------
/**
 * Request a session token; callback executed when one is available.
 *
 * The getTokenForRequest:postParameters: method is used to complete the request
 * immediately. If no token is presently available, the request is encoded in a
 * packet and added to a queue; as tokens become available, the requests are
 * removed and filled with the token. The onload callback is executed with the
 * result.
 *
 * The response supplied to the onload callback is an NSDictionary with the
 * following keys:
 *
 * Key                | Value
 * ------------------ | -----
 * session_token      | Same as session_token in parameters.
 * parameters         | Params modified with the session_token and signature.
 * parameter_sequence | NOT IMPLEMENTED
 *
 * A temporary use of GET instead of POST for MFAPI calls resulted in a change
 * in which parameters is an NSString to be appended to the URL. This should
 * be changed to the dictionary expected by the http module for POST communications.
 * However, changes may be necessary to this design. The signature is a hash that
 * depends on the sequence of the parameters, and NSDictionary does not guarantee
 * the sequence used when it enumerates its key/value pairs. One possibility is
 * to give the http module's sendData: the entire response and include an NSArray
 * under parameter_sequence to enforce the sequence of parameter processing.
 *
 * The onerror callback can be executed when the session is closed
 * (ERRCODE_SESSION_CLOSED), if invoked before starting a session
 * (ERRCODE_NO_CURRENT_SESSION), or because of a network/server problem. Assuming
 * network issues may be temporary, only one of the blocked requests are terminated
 * if a new session token request fails; this allows a client to be aware of the
 * network problems without terminating all waiting requests. The exception is
 * when ALL tokens have been abandoned as invalid; then, failure of a new token
 * request will close the session, invoking onerror on all blocked requests.
 *
 * If the number of session tokens in use is less than the maximum allowed, then
 * a new session token is automatically requested for each waiting request,
 * allowing the number of tokens to gradually grow to the maximum if the app
 * actually needs that many simultaneous tokens. (Note that if, for any reason,
 * the number of tokens available is less than the suggested minimum, new token
 * requests will automatically daisy chain to attempt to restore this number.)
 *
 * @warning Unlike the initial burst of _suggested_ token requests at login that
 * only occur one at a time, the requests for additional tokens occur as quickly
 * as the calls to this method can be made, possibly resulting in _max_ - _suggested_
 * simultaneous SSL connections tying up resources that could be spent handling
 * MFAPI calls with the tokens available. If this becomes a performance issue,
 * consider using a similar daisy-chain approach (if additional tokens are not
 * still needed when the next token arrives, maybe they weren't really needed,
 * anyway).
 */

//------------------------------------------------------------------------------
- (void)addRequest:(MFAPIURLRequestConfig*)config callbacks:(NSDictionary*)callbacks {
    // sanity checks
    if (callbacks == nil) {
        return;
    }
    
    if (config == nil) {
        callbacks.onerror(erm(nullField:@"config"));
        return;
    }
    //  create a packet containing this method's parameters and save it for
    //  eventual processing when a session token is available. If we haven't
    //  requested some maximum number of tokens, initiate another request
    NSDictionary* request = @{@"config" : config, @"callbacks" : callbacks};
    
    [self.sessionLock lock];
    BOOL noSession = ( self.sessions == nil && self.awaitingTokens == 0 ); // Looks at value
    [self.sessionLock unlock];
    
    // if there's no active session, we abort this request and bail out.
    if ( noSession ) {
        callbacks.onerror(erm(noCurrentSession));
        return;
    }
    
    [self.sessionLock lock];
    [self.tokenRequests enqueue:request];
    [self.sessionLock unlock];
    
    // if we have more requests waiting to process than we have session tokens,
    // then we should increase the number of tokens we want.
    if ( [self doesNeedMoreTokens] ) {
        [self askForAdditionalSessionTokens];
    }
    
    [self nextRequest];
}

//------------------------------------------------------------------------------
+ (NSMutableArray*)getOrderedArrayOfParameters:(NSDictionary*)params {
    NSMutableArray* orderedParams = [[NSMutableArray alloc]init];
    for (NSString* paramName in params) {
        [orderedParams addObject:@{@"name" : paramName, @"value" : params[paramName]}];
    }
    return orderedParams;
}

//------------------------------------------------------------------------------
+ (NSString*)getQueryStringFromOrderedParameters:(NSArray*)orderedParams {
    NSMutableString* queryString = [[NSMutableString alloc]init];
    NSDictionary* params = nil;
    NSString* uriString = nil;
    for (int i=0; i<orderedParams.count; i++) {
        params = orderedParams[i];
        
        NSString* paramValueString = @"";
        if ([params[@"value"] isKindOfClass:[NSString class]]) {
            paramValueString = params[@"value"];
        } else if ([params[@"value"] isKindOfClass:[NSArray class]]) {
            paramValueString = [params[@"value"] serializeJSON];
        } else if ([params[@"value"] isKindOfClass:[NSDictionary class]]) {
            paramValueString = [params[@"value"] serializeJSON];
        } else {
            paramValueString = [params[@"value"] stringValue];
        }

        if (queryString.length == 0) {
            uriString = [NSString stringWithFormat:@"%@=%@",params[@"name"],paramValueString];
        } else {
            uriString = [NSString stringWithFormat:@"&%@=%@",params[@"name"],paramValueString];
        }
        [queryString appendString:uriString];
    }
    return queryString;
}

//------------------------------------------------------------------------------
+ (void)urlEncodeOrderedParameters:(NSMutableArray*)orderedParams {
    NSMutableDictionary* params = nil;
    NSString* urlEncoded = nil;
    for (int i=0; i<orderedParams.count; i++) {
        params = [orderedParams[i] mutableCopy];
        if ([params[@"value"] isKindOfClass:[NSString class]]) {
            urlEncoded = params[@"value"];
        } else if ([params[@"value"] isKindOfClass:[NSArray class]]) {
            urlEncoded = [params[@"value"] serializeJSON];
        } else if ([params[@"value"] isKindOfClass:[NSDictionary class]]) {
            urlEncoded = [params[@"value"] serializeJSON];
        } else {
            urlEncoded = [params[@"value"] stringValue];
        }
        urlEncoded = [urlEncoded urlEncode];
        params[@"value"] = urlEncoded;
        [orderedParams replaceObjectAtIndex:i withObject:params];
    }
}

//------------------------------------------------------------------------------
// In order to make a successful API call, we have to take a session token, and
// a url for our request, and use that to generate a signature which is then
// added to the url.  So this function expects a url, a dict with your url
// parameters, and a session token packet.  It will return the session token
// packet object, with 2 additional parameters, which are used to compose the
// final url.
//------------------------------------------------------------------------------
+ (NSString*)generateQueryStringWithSignature:(NSDictionary*)tokenPacket url:(NSString*)baseUrl query:(NSDictionary*)params{
    // sanity check
    if ( baseUrl == nil || tokenPacket == nil ) {
        return nil;
    }
    
    NSString*   signature   = nil;
    id unparsedSecret = tokenPacket[@"secret_key"];
    NSUInteger  secret = 0;    // = [tokenPacket[@"secret_key"] unsignedIntegerValue];
    if ([unparsedSecret isKindOfClass:[NSString class]]) {
        secret = (NSUInteger)[(NSString*)unparsedSecret integerValue];
    } else if ([unparsedSecret isKindOfClass:[NSNumber class]]) {
        secret = [(NSNumber*)unparsedSecret unsignedIntegerValue];
    } else {
        erm(invalidField:@"secret");
        secret = 0;
    }
    
    NSMutableDictionary* newParams = [params mutableCopy];
    newParams[@"session_token"] = tokenPacket[@"session_token"];
    
    NSMutableArray* orderedParams = [MFSerialRequestManager getOrderedArrayOfParameters:newParams];
    
    signature = [NSString stringWithFormat:@"%lu%@%@?%@", (unsigned long)(secret % 256), tokenPacket[@"time"], baseUrl, [MFSerialRequestManager getQueryStringFromOrderedParameters:orderedParams]];
    
    NSString * sig = [MFHash md5Hex:signature];
    [MFSerialRequestManager urlEncodeOrderedParameters:orderedParams];
    
    NSString* queryString = [MFSerialRequestManager getQueryStringFromOrderedParameters:orderedParams];
    if ( queryString == nil ) {
        // if this request did not require any parameters, then queryString would be nil.
        queryString = [NSString stringWithFormat:@"signature=%@", sig];
    } else {
        queryString = [queryString stringByAppendingFormat:@"&signature=%@", sig];
    }
    
    return queryString;
}


//------------------------------------------------------------------------------
// We "resume" requests that have been put into the pending requests queue.
+ (void)resumeRequest:(NSDictionary*)request withTokenPacket:(NSDictionary*)tokenPacket {
    NSDictionary* callbacks = request[@"callbacks"];
    if ( callbacks == nil ) {
        erm(nullField:@"callbacks for resumed request");
        return;
    }
    if (tokenPacket[@"session_token"] == nil) {
        callbacks.onerror(erm(nullField:@"session_token"));
        return;
    }
    MFAPIURLRequestConfig* config = request[@"config"];
    if (config == nil) {
        callbacks.onerror(erm(nullField:@"config"));
        return;
    }
    config.query = [self generateQueryStringWithSignature:tokenPacket url:config.location query:config.queryDict];
    
    if ( config.query == nil ) {
        callbacks.onerror(erm(badRequestFormat));
    } else {
        callbacks.onload(@{@"session_token": tokenPacket[@"session_token"], @"parameters" : config.query});
    }
}

//------------------------------------------------------------------------------
- (void)nextRequest {
    [self.sessionLock lock];
    // check the token pool and pending requests queue.
    if ([self.available isEmpty] || [self.tokenRequests isEmpty]) {
        // Either we have nothing to do, or there's no free tokens to use at the
        // moment, or both.
        [self.sessionLock unlock];
        return;
    }
    NSDictionary* request = [self.tokenRequests dequeueObject];
    // sanity check.  Shouldn't be nil anyway.
    if ( request == nil ) {
        [self.sessionLock unlock];
        return;
    }
    
    // get next available token.
    NSMutableDictionary* tokenPacket = self.sessions[[self.available dequeueObject]];
    // replace following with error log if token nil or locked
    assert(![tokenPacket[@"locked"] isEqualToNumber: @YES]);
    tokenPacket[@"locked"] =@YES;
    [self.sessionLock unlock];
    
    [[self class] resumeRequest:request withTokenPacket:tokenPacket];
}

//==============================================================================
//==============================================================================
// SIGN-IN / SESSION MANAGEMENT
//==============================================================================
//==============================================================================

//------------------------------------------------------------------------------
- (void)endSession {
    NSMutableArray* callbacks = [[NSMutableArray alloc] init];
    [self.sessionLock lock];
    self.sessions = nil;
    [self.available clear];
    self.awaitingTokens = 0;
    [self.sessionLock unlock];
    
    // Now that session completely cleared and lock released, notify waiting requests
    for ( NSDictionary* cb in callbacks ) {
        cb.onerror(erm(sessionClosed));
    }
}
//------------------------------------------------------------------------------
+ (void)login:(NSDictionary*)credentials callbacks:(NSDictionary *)callbacks {
    [[self getInstance] login:credentials callbacks:callbacks];
}

//------------------------------------------------------------------------------
- (void)login:(NSDictionary*)credentials callbacks:(NSDictionary *)callbacks {
    // success callback
    MFCallback tokenAvailable = ^(NSDictionary * response) {
        [self.sessionLock lock];
        self.awaitingTokens--;
        [self.sessionLock unlock];
        [self processNewToken:response];
        
        // successful login, so mark credentials as valid
        [[MFConfig credentialsDelegate] validate];
        if ([credentials[@"type"] isEqualToString:MFCRD_TYPE_MF]) {
            id ekey = response[@"ekey"];
            if ((ekey != nil) && [ekey isKindOfClass:[NSString class]]) {
                [[MFConfig credentialsDelegate] convertToEKey:ekey];
            }
        }
        if ( [self doesNeedMoreTokens] ) {
            [self askForAdditionalSessionTokens];
        }
        [self nextRequest];
        callbacks.onload(response);
    };
    
    // failure callback
    MFCallback noToken = ^(NSDictionary * response) {
        [self.sessionLock lock];
        self.awaitingTokens--;
        [self.sessionLock unlock];

        if (!response) {
            // bad response, so generate a default error message
            [self endSession];
            callbacks.onerror(erm(nullField:@"login response"));
        } else {
            // handle specific error codes
            NSInteger code = [response[@"error"] integerValue];
            if ( code == ERRCODE_INVALID_CREDENTIALS ) {
                [self endSession];
            }
        }
        [self nextRequest];
        callbacks.onerror(response);
    };
    
    // attempt login using get_session_token
    if ( self.sessions != nil ) {
    [self endSession];
    }
    [self.sessionLock lock];
    self.awaitingTokens++;
    [self.sessionLock unlock];
    
    [self.sessionAPI getSessionToken:credentials callbacks:@{ONLOAD:tokenAvailable,ONERROR:noToken}];
}

//==============================================================================
//==============================================================================
// REST HTTP
//==============================================================================
//==============================================================================

//------------------------------------------------------------------------------
+ (void)createRequest:(MFAPIURLRequestConfig*)config callbacks:(NSDictionary*)callbacks {
    // sanity checks
    if ( callbacks == nil) {
        callbacks = @{};
    }
    if (config == nil ) {
        callbacks.onerror(erm(nullField:@"request options"));
        return;
    }
    if ( config.location == nil ) {
        callbacks.onerror(erm(nullURL));
        return;
    }
    config.url = [config generateURL];

    config.queryDict = [MFREST addResponseFormat:config.queryDict];
    
    NSDictionary * handleToken =
    @{ONERROR:callbacks.onerror,
      ONLOAD: ^(NSDictionary * response) {
          if (response == nil || response[@"parameters"] == nil || (![response[@"parameters"] isKindOfClass:[NSString class]])) {
              callbacks.onerror(erm(nullField:@"parameters"));
              return;
          }
          NSDictionary* apiWrapperCallbacks = [self getCallbacksForAPIRequest:config.url token:response[@"session_token"] callbacks:callbacks];
          config.httpSuccess = apiWrapperCallbacks[ONLOAD];
          config.httpFail = apiWrapperCallbacks[ONERROR];
          config.httpProgress = apiWrapperCallbacks[ONPROGRESS];
          config.httpReference = apiWrapperCallbacks[@"httpTask"];
          
          [MFHTTP execute:config];
      }};
    // Add this request to the queue so it can be processed when a token becomes available.
    [[self getInstance] addRequest:config callbacks:handleToken];
    return;
}

//------------------------------------------------------------------------------
+ (NSDictionary*)getCallbacksForAPIRequest:(NSURL*)url token:(NSString*)sessionToken callbacks:(NSDictionary*)callbacks {
    
    Class selfClass = self;
    
    NSDictionary* customizedCallbacks = [MFRequestHandler getCallbacksForRequest:url callbacks:
    @{ONLOAD:^(NSDictionary* response) {
        id newKey = response[@"new_key"];
        if (((newKey == nil) || ![newKey isKindOfClass:[NSString class]]) && (response[@"blob"] == nil)) {
            [[self getInstance] abandonToken:sessionToken];
            callbacks.onerror(erm(invalidField:@"new key"));
            return;
        }
        [selfClass releaseToken:sessionToken forResponse:response];
        callbacks.onload(response);
    },
      ONERROR:^(NSDictionary* response) {
            // sanity check to make sure our response is an MFError dictionary.
          NSDictionary* errorMessage = response;
          if (![MFErrorMessage isErrorMessage:response]) {
              errorMessage = [MFErrorMessage badResponse:response];
          }
          
          id originalResponse = errorMessage[@"response"];
          // if we can't parse response then we don't know if the token is still usable.
          if ((originalResponse == nil) || ![originalResponse isKindOfClass:[NSDictionary class]]) {
              [[self getInstance] abandonToken:sessionToken];
              callbacks.onerror(errorMessage);
              return;
          }
          // if we get a signature/token error, abandon it and ask for more.
          NSInteger code = [MFErrorMessage code:errorMessage];
          if ((code == ERRCODE_INVALID_SIGNATURE) || (code == ERRCODE_INVALID_SESSION_TOKEN)) {
              // This was a signature error, which is not recoverable.
              [[self getInstance] abandonToken:sessionToken];
              [[self getInstance] askForAdditionalSessionTokens];
              callbacks.onerror(errorMessage);
              return;
          }
          
          id newKey = originalResponse[@"new_key"];
          if ((newKey == nil) || ![newKey isKindOfClass:[NSString class]]) {
              [selfClass abandonToken:sessionToken];
          } else {
              [selfClass releaseToken:sessionToken forResponse:originalResponse];
          }
            callbacks.onerror(errorMessage);

            return;
      }}];
    NSMutableDictionary* cb =
    [[NSMutableDictionary alloc] initWithDictionary: @{ONLOAD:[customizedCallbacks[ONLOAD] copy] , ONERROR:[customizedCallbacks[ONERROR] copy]}];
    // set up extra callbacks
    if (callbacks[ONPROGRESS] != nil) {
        cb[ONPROGRESS] = [callbacks[ONPROGRESS] copy];
    }
    if (callbacks[@"httpTask"] != nil) {
        cb[@"httpTask"] = [callbacks[@"httpTask"] copy];
    }
    
    return cb;
}

- (MFSessionAPI*)sessionAPI {
    MFSessionAPI* api=nil;
    [self.statusLock lock];
    if (_sessionAPI == nil) {
        _sessionAPI = [[MFSessionAPI alloc] init];
    }
    api = _sessionAPI;
    [self.statusLock unlock];
    return api;
}

- (void)setSessionAPI:(MFSessionAPI*)api {
    [self.statusLock lock];
    _sessionAPI = api;
    [self.statusLock unlock];
}
@end



