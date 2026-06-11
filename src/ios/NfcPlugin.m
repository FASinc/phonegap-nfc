//
//  NfcPlugin.m
//  PhoneGap NFC - Cordova Plugin
//
//  (c) 2107-2020 Don Coleman

#import "NfcPlugin.h"
#import <CoreNFC/CoreNFC.h>

@interface NfcPlugin() {
    NSString* sessionCallbackId;
    NSString* channelCallbackId;
    id<NFCNDEFTag> connectedTag API_AVAILABLE(ios(13.0));
    NFCNDEFStatus connectedTagStatus API_AVAILABLE(ios(13.0));
}
@property (nonatomic, assign) BOOL goplantTestMode;
@property (nonatomic, assign) BOOL writeMode;
@property (nonatomic, assign) BOOL shouldUseTagReaderSession;
@property (nonatomic, assign) BOOL sendCallbackOnSessionStart;
@property (nonatomic, assign) BOOL returnTagInCallback;
@property (nonatomic, assign) BOOL returnTagInEvent;
@property (nonatomic, assign) BOOL keepSessionOpen;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) NSInteger maxRetryCount;
@property (nonatomic, assign) NSInteger retryDelayMilliseconds;
@property (nonatomic, assign) NSInteger noTagDetectedTimeoutMilliseconds;
@property (nonatomic, assign) NSInteger nfcSessionToken;
@property (nonatomic, assign) BOOL nfcTagWasDetected;
@property (nonatomic, assign) BOOL noTagDetectedTimeoutReached;
@property (nonatomic, copy) NSString *lastRetryStage;
@property (nonatomic, copy) NSString *lastRetryErrorMessage;
@property (nonatomic, copy) dispatch_block_t noTagDetectedTimeoutBlock;
@property (strong, nonatomic) NFCReaderSession *nfcSession API_AVAILABLE(ios(11.0));
@property (strong, nonatomic) NFCNDEFMessage *messageToWrite API_AVAILABLE(ios(11.0));
@end

@implementation NfcPlugin

- (void)pluginInitialize {

    NSLog(@"PGNFC-PhoneGap NFC - Cordova Plugin");
    NSLog(@"PGNFC-(c) 2017-2020 Don Coleman");

    [super pluginInitialize];
    
    if (@available(iOS 11, *)) {
        if (![NFCNDEFReaderSession readingAvailable]) {
            NSLog(@"PGNFC-NFC Support is NOT available");
        }
    } else {
        NSLog(@"PGNFC-NFC Support is NOT available before iOS 11");
    }
}

#pragma mark - Cordova Plugin Methods

- (void)channel:(CDVInvokedUrlCommand *)command {
    // the channel is used to send NFC tag data to the web view
    channelCallbackId = [command.callbackId copy];
}

- (void)beginSession:(CDVInvokedUrlCommand*)command {
    NSLog(@"PGNFC-beginSession");
    NSLog(@"PGNFC-WARNING: beginSession is deprecated. Use scanNdef or scanTag.");

    self.shouldUseTagReaderSession = NO;
    self.sendCallbackOnSessionStart = YES;  // Not sure why we were doing this
    self.returnTagInCallback = NO;
    self.returnTagInEvent = YES;
    self.keepSessionOpen = NO;

    [self startScanSession:command];
}

- (void)scanNdef:(CDVInvokedUrlCommand*)command {
    NSLog(@"PGNFC-scanNdef");

    self.shouldUseTagReaderSession = NO;
    self.sendCallbackOnSessionStart = NO;
    self.returnTagInCallback = YES;
    self.returnTagInEvent = NO;

    NSArray<NSDictionary *> *options = [command argumentAtIndex:0];
    self.keepSessionOpen = [options valueForKey:@"keepSessionOpen"];

    [self startScanSession:command];
}

- (void)scanTag:(CDVInvokedUrlCommand*)command {
    NSLog(@"PGNFC-scanTag");

    if (@available(iOS 11.0, *)) {
        if (self.nfcSession && self.nfcSession.isReady) {
            NSLog(@"PGNFC-scanTag rejected because an NFC session is already active.");
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"NFC session already active."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }
    }
    self.shouldUseTagReaderSession = YES;
    self.sendCallbackOnSessionStart = NO;
    self.returnTagInCallback = YES;
    self.returnTagInEvent = NO;

    NSArray<NSDictionary *> *options = [command argumentAtIndex:0];
    self.keepSessionOpen = [options valueForKey:@"keepSessionOpen"];

    [self startScanSession:command];
}

- (void)writeTag:(CDVInvokedUrlCommand*)command API_AVAILABLE(ios(13.0)){
    NSLog(@"PGNFC-writeTag");
    
    self.writeMode = YES;
    self.shouldUseTagReaderSession = NO;
    BOOL reusingSession = NO;
    
    NSArray<NSDictionary *> *ndefData = [command argumentAtIndex:0];

    // Create the NDEF Message
    NSMutableArray<NFCNDEFPayload*> *payloads = [NSMutableArray new];
                              
    @try {
        for (id recordData in ndefData) {
            NSNumber *tnfNumber = [recordData objectForKey:@"tnf"];
            NFCTypeNameFormat tnf = (uint8_t)[tnfNumber intValue];
            NSData *type = [self uint8ArrayToNSData:[recordData objectForKey:@"type"]];
            NSData *identifier = [self uint8ArrayToNSData:[recordData objectForKey:@"identifiers"]];
            NSData *payload  = [self uint8ArrayToNSData:[recordData objectForKey:@"payload"]];
            NFCNDEFPayload *record = [[NFCNDEFPayload alloc] initWithFormat:tnf type:type identifier:identifier payload:payload];
            [payloads addObject:record];
        }
        NSLog(@"PGNFC-%@", payloads);
        NFCNDEFMessage *message = [[NFCNDEFMessage alloc] initWithNDEFRecords:payloads];
        self.messageToWrite = message;
    } @catch(NSException *e) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid NDEF Message"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if (self.nfcSession && self.nfcSession.isReady) {       // reuse existing session
        reusingSession = YES;
    } else {                                                // create a new session
        if (self.shouldUseTagReaderSession) {
            NSLog(@"PGNFC-Using NFCTagReaderSession");

            self.nfcSession = [[NFCTagReaderSession alloc]
                       initWithPollingOption:(NFCPollingISO14443 | NFCPollingISO15693)
                       delegate:self queue:dispatch_get_main_queue()];

        } else {
            NSLog(@"PGNFC-Using NFCTagReaderSession");
            self.nfcSession = [[NFCNDEFReaderSession alloc]initWithDelegate:self queue:nil invalidateAfterFirstRead:FALSE];
        }
    }

    self.nfcSession.alertMessage = [self localizeString:@"NFCHoldNearWritableTag" defaultValue:@"Hold near writable NFC tag to update."];
    sessionCallbackId = [command.callbackId copy];

    if (reusingSession) {                   // reusing a read session to write
        self.keepSessionOpen = NO;          // close session after writing
        [self writeNDEFTag:self.nfcSession status:connectedTagStatus tag:connectedTag];
    } else {
        [self.nfcSession beginSession];
    }
}

- (void)cancelScan:(CDVInvokedUrlCommand*)command API_AVAILABLE(ios(11.0)){
    NSLog(@"PGNFC-cancelScan");
    [self clearNoTagDetectedTimeout];
    if (self.nfcSession) {
        [self.nfcSession invalidateSession];
    }
    connectedTag = NULL;
    connectedTagStatus = NFCNDEFStatusNotSupported;
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)invalidateSession:(CDVInvokedUrlCommand*)command {
    NSLog(@"PGNFC-invalidateSession");
    NSLog(@"PGNFC-WARNING: invalidateSession is deprecated. Use cancelScan.");
    [self clearNoTagDetectedTimeout];
    
    if (_nfcSession) {
        [_nfcSession invalidateSession];
    }
    // Always return OK. Alternately could send status from the NFCNDEFReaderSessionDelegate
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

// Nothing happens here, the event listener is registered in JavaScript
- (void)registerNdef:(CDVInvokedUrlCommand *)command {
    NSLog(@"PGNFC-registerNdef");
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

// Nothing happens here, the event listener is removed in JavaScript
- (void)removeNdef:(CDVInvokedUrlCommand *)command {
    NSLog(@"PGNFC-removeNdef");
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)enabled:(CDVInvokedUrlCommand *)command {
    NSLog(@"PGNFC-enabled");
    CDVPluginResult *pluginResult;
    if (@available(iOS 11.0, *)) {
        if ([NFCNDEFReaderSession readingAvailable]) {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"NO_NFC"];
        }
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"NO_NFC"];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

#pragma mark - NFCNDEFReaderSessionDelegate

// iOS 11 & 12
- (void) readerSession:(NFCNDEFReaderSession *)session didDetectNDEFs:(NSArray<NFCNDEFMessage *> *)messages API_AVAILABLE(ios(11.0)) {
    NSLog(@"PGNFC-NFCNDEFReaderSession didDetectNDEFs");
    self.nfcTagWasDetected = YES;
    [self clearNoTagDetectedTimeout];
    
    session.alertMessage = [self localizeString:@"NFCTagRead" defaultValue:@"Tag successfully read."];
    for (NFCNDEFMessage *message in messages) {
        [self fireNdefEvent: message];
    }
}

// iOS 13
- (void) readerSession:(NFCNDEFReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCNDEFTag>> *)tags API_AVAILABLE(ios(13.0)) {
    self.nfcTagWasDetected = YES;
    [self clearNoTagDetectedTimeout];
    
    if (tags.count > 1) {
        session.alertMessage = [self localizeString:@"NFCMoreThanOneTag" defaultValue:@"More than 1 tag detected. Please remove all tags and try again."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSLog(@"PGNFC-restaring polling");
            [session restartPolling];
        });
        return;
    }
    
    id<NFCNDEFTag> tag = [tags firstObject];
    
    [session connectToTag:tag completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"PGNFC-connectToTag-error: B1 %@", error);

            if ([self retryTagReadIfAvailable:session stage:@"connectToTag" error:error]) {
                NSLog(@"PGNFC-connectToTag-error: B2 %@", error);
                return;
            }

            [self closeSession:session withError:[self localizeString:@"NFCErrorTagConnection" defaultValue:@"Error connecting to tag."]];
            NSLog(@"PGNFC-connectToTag-error: B3 %@", error);
            return;
        }
        NSLog(@"PGNFC-connectToTag-ok: B4 ");
        [self processNDEFTag:session tag:tag];
    }];
    
}

- (void) readerSession:(NFCNDEFReaderSession *)session didInvalidateWithError:(NSError *)error API_AVAILABLE(ios(11.0)) {
    NSLog(@"PGNFC-readerSession ended");
    [self clearNoTagDetectedTimeout];

    if (error.code == NFCReaderSessionInvalidationErrorFirstNDEFTagRead) { // not an error
        self.noTagDetectedTimeoutReached = NO;
        NSLog(@"PGNFC-Session ended after successful NDEF tag read");
        return;
    } else if (sessionCallbackId) {
        NSString *message = self.noTagDetectedTimeoutReached
            ? [self localizeString:@"NFCNoTagDetectedTimeout" defaultValue:@"NFC scan timed out. Please try again."]
            : error.localizedDescription;
        [self sendError:message];
        sessionCallbackId = NULL;
    }

    self.noTagDetectedTimeoutReached = NO;
    connectedTag = NULL;
    connectedTagStatus = NFCNDEFStatusNotSupported;
}

- (void) readerSessionDidBecomeActive:(nonnull NFCReaderSession *)session API_AVAILABLE(ios(11.0)) {
    NSLog(@"PGNFC-readerSessionDidBecomeActive");
    [self sessionDidBecomeActive:session];
}

#pragma mark - NFCTagReaderSessionDelegate

- (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session API_AVAILABLE(ios(13.0)) {
    NSLog(@"PGNFC-tagReaderSessionDidBecomeActive");
    [self sessionDidBecomeActive:session];
}

- (void)tagReaderSession:(NFCTagReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags API_AVAILABLE(ios(13.0)) {
    NSLog(@"PGNFC-tagReaderSession didDetectTags");
    self.nfcTagWasDetected = YES;
    [self clearNoTagDetectedTimeout];
    
    if (tags.count > 1) {
        session.alertMessage = [self localizeString:@"NFCMoreThanOneTag" defaultValue:@"More than 1 tag detected. Please remove all tags and try again."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSLog(@"PGNFC-restaring polling");
            [session restartPolling];
        });
        return;
    }
    
    id<NFCTag> tag = [tags firstObject];
    NSMutableDictionary *tagMetaData = [self getTagInfo:tag];
    id<NFCNDEFTag> ndefTag = (id<NFCNDEFTag>)tag;
    
    [session connectToTag:tag completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"PGNFC-connectToTag-error: A1 %@", error);

            if ([self retryTagReadIfAvailable:session stage:@"connectToTag" error:error]) {
                NSLog(@"PGNFC-connectToTag-error: A2 %@", error);
                return;
            }

            [self closeSession:session withError:[self localizeString:@"NFCErrorTagConnection" defaultValue:@"Error connecting to tag."]];
            NSLog(@"PGNFC-connectToTag-error: A3 %@", error);
            return;
        }
        NSLog(@"PGNFC-connectToTag-ok: A4");
        [self processNDEFTag:session tag:ndefTag metaData:tagMetaData];
    }];
}

- (void)tagReaderSession:(NFCTagReaderSession *)session didInvalidateWithError:(NSError *)error API_AVAILABLE(ios(13.0)) {
    NSLog(@"PGNFC-tagReaderSession ended");
    [self clearNoTagDetectedTimeout];

    if (sessionCallbackId) {
        NSString *message = self.noTagDetectedTimeoutReached
            ? [self localizeString:@"NFCNoTagDetectedTimeout" defaultValue:@"NFC scan timed out. Please try again."]
            : error.localizedDescription;
        [self sendError:message];
        sessionCallbackId = NULL;
    }

    self.noTagDetectedTimeoutReached = NO;
    connectedTag = NULL;
    connectedTagStatus = NFCNDEFStatusNotSupported;
}

#pragma mark - Common NDEF Processing

// Handles scanNdef, scanTag, and beginSession
- (void)startScanSession:(CDVInvokedUrlCommand*)command {
    
    self.writeMode = NO;
    self.retryCount = 0;
    self.maxRetryCount = 5;
    self.retryDelayMilliseconds = 500; // gives CoreNFC a time to settle before calling restartPolling.
    self.noTagDetectedTimeoutMilliseconds = 10000;
    self.nfcTagWasDetected = NO;
    self.noTagDetectedTimeoutReached = NO;
    self.lastRetryStage = nil;
    self.lastRetryErrorMessage = nil;
    self.nfcSessionToken++;
    
    self.goplantTestMode = YES;
    if(self.goplantTestMode == YES){
        self.maxRetryCount = 20;
        self.retryDelayMilliseconds = 2000; // gives CoreNFC a time to settle before calling restartPolling.
        self.noTagDetectedTimeoutMilliseconds = 20000;
    }
    NSLog(@"PGNFC-shouldUseTagReaderSession %d", self.shouldUseTagReaderSession);
    NSLog(@"PGNFC-callbackOnSessionStart %d", self.sendCallbackOnSessionStart);
    NSLog(@"PGNFC-returnTagInCallback %d", self.returnTagInCallback);
    NSLog(@"PGNFC-returnTagInEvent %d", self.returnTagInEvent);
    
    if (@available(iOS 13.0, *)) {
        
        if (self.shouldUseTagReaderSession) {
            NSLog(@"PGNFC-Using NFCTagReaderSession");
            self.nfcSession = [[NFCTagReaderSession alloc]
                           initWithPollingOption:(NFCPollingISO14443 | NFCPollingISO15693)
                           delegate:self queue:dispatch_get_main_queue()];
        } else {
            NSLog(@"PGNFC-Using NFCNDEFReaderSession");
            self.nfcSession = [[NFCNDEFReaderSession alloc]initWithDelegate:self queue:nil invalidateAfterFirstRead:TRUE];
        }
        if (!self.nfcSession) {
            NSLog(@"PGNFC-startScanSession failed because nfcSession was not created.");
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to start NFC session."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }
        sessionCallbackId = [command.callbackId copy];
        self.nfcSession.alertMessage = [self localizeString:@"NFCHoldNearTag" defaultValue:@"Hold near NFC tag to scan."];
        [self.nfcSession beginSession];
        [self startNoTagDetectedTimeoutForSession:self.nfcSession token:self.nfcSessionToken];
        
    } else if (@available(iOS 11.0, *)) {
        NSLog(@"PGNFC-iOS < 13, using NFCNDEFReaderSession");
        self.nfcSession = [[NFCNDEFReaderSession alloc]initWithDelegate:self queue:nil invalidateAfterFirstRead:TRUE];
        if (!self.nfcSession) {
            NSLog(@"PGNFC-startScanSession failed because nfcSession was not created.");
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to start NFC session."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }
        sessionCallbackId = [command.callbackId copy];
        self.nfcSession.alertMessage = [self localizeString:@"NFCHoldNearTag" defaultValue:@"Hold near NFC tag to scan."];
        [self.nfcSession beginSession];
        [self startNoTagDetectedTimeoutForSession:self.nfcSession token:self.nfcSessionToken];
    } else {
        NSLog(@"PGNFC-iOS < 11, no NFC support");
        CDVPluginResult *pluginResult;
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"NFC requires iOS 11"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
        
}

- (void)processNDEFTag: (NFCReaderSession *)session tag:(__kindof id<NFCNDEFTag>)tag API_AVAILABLE(ios(13.0)) {
    [self processNDEFTag:session tag:tag metaData:[NSMutableDictionary new]];
}

- (void)processNDEFTag: (NFCReaderSession *)session tag:(__kindof id<NFCNDEFTag>)tag metaData: (NSMutableDictionary * _Nonnull)metaData API_AVAILABLE(ios(13.0)) {
                            
    [tag queryNDEFStatusWithCompletionHandler:^(NFCNDEFStatus status, NSUInteger capacity, NSError * _Nullable error) {
        if (error) {
            NSLog(@"PGNFC-%@", error);

            if ([self retryTagReadIfAvailable:session stage:@"queryNDEFStatus" error:error]) {
                return;
            }

            [self closeSession:session withError:[self localizeString:@"NFCErrorTagStatus" defaultValue:@"Error getting tag status."]];
            return;
        }
                
        if (self.writeMode) {
            [self writeNDEFTag:session status:status tag:tag];
        } else {
            // save tag & status so we can re-use in write
            if (self.keepSessionOpen) {
                self->connectedTagStatus = status;
                self->connectedTag = tag;
            }
            [self readNDEFTag:session status:status tag:tag metaData:metaData];
        }

    }];
}

- (void)readNDEFTag:(NFCReaderSession * _Nonnull)session status:(NFCNDEFStatus)status tag:(id<NFCNDEFTag>)tag metaData:(NSMutableDictionary * _Nonnull)metaData  API_AVAILABLE(ios(13.0)){
        
    if (status == NFCNDEFStatusNotSupported) {
        NSLog(@"PGNFC-Tag does not support NDEF");
        [self fireTagEvent:metaData];
        [self closeSession:session];
        return;
    }
    
    if (status == NFCNDEFStatusReadOnly) {
        metaData[@"isWritable"] = @FALSE;
    } else if (status == NFCNDEFStatusReadWrite) {
        metaData[@"isWritable"] = @TRUE;
    }
    
    [tag readNDEFWithCompletionHandler:^(NFCNDEFMessage * _Nullable message, NSError * _Nullable error) {

        // Error Code=403 "NDEF tag does not contain any NDEF message" is not an error for this plugin
        if (error && error.code != 403) {
            NSLog(@"PGNFC-%@", error);

            if ([self retryTagReadIfAvailable:session stage:@"readNDEF" error:error]) {
                return;
            }

            [self closeSession:session withError:[self localizeString:@"NFCDataReadFailed" defaultValue:@"Read Failed."]];
            return;
        } else {
            NSLog(@"PGNFC-%@", message);
            session.alertMessage = [self localizeString:@"NFCTagRead" defaultValue:@"Tag successfully read."];
            [self fireNdefEvent:message metaData:metaData];
            [self closeSession:session];
        }

    }];

}

- (void)writeNDEFTag:(NFCReaderSession * _Nonnull)session status:(NFCNDEFStatus)status tag:(id<NFCNDEFTag>)tag  API_AVAILABLE(ios(13.0)){
    switch (status) {
        case NFCNDEFStatusNotSupported:
            [self closeSession:session withError:[self localizeString:@"NFCNotNdefCompliant" defaultValue:@"Tag is not NDEF compliant."]];  // alternate message "Tag does not support NDEF."
            break;
        case NFCNDEFStatusReadOnly:
            [self closeSession:session withError:[self localizeString:@"NFCReadOnlyTag" defaultValue:@"Tag is read only."]];
            break;
        case NFCNDEFStatusReadWrite: {
            
            [tag writeNDEF: self.messageToWrite completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    NSLog(@"PGNFC-%@", error);
                    [self closeSession:session withError:[self localizeString:@"NFCDataWriteFailed" defaultValue:@"Write failed."]];
                } else {
                    session.alertMessage = [self localizeString:@"NFCDataWrote" defaultValue:@"Wrote data to NFC tag."];
                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:self->sessionCallbackId];
                    [self closeSession:session];
                }
            }];
            break;
            
        }
        default:
            [self closeSession:session withError:[self localizeString:@"NFCUnknownNdefTag" defaultValue:@"Unknown NDEF tag status."]];
    }
}

#pragma mark - Tag Reader Helper Functions

// Gets the tag meta data - type and uid
- (NSMutableDictionary *) getTagInfo:(id<NFCTag>)tag API_AVAILABLE(ios(13.0)) {
    
    NSMutableDictionary *tagInfo = [NSMutableDictionary new];
    
    NSData *uid;
    NSString *type;
    
    switch (tag.type) {
        case NFCTagTypeFeliCa:
            type = @"NFCTagTypeFeliCa";
            uid = nil;
            break;
        case NFCTagTypeMiFare:
            type = @"NFCTagTypeMiFare";
            uid = [[tag asNFCMiFareTag] identifier];
            break;
        case NFCTagTypeISO15693:
            type = @"NFCTagTypeISO15693";
            uid = [[tag asNFCISO15693Tag] identifier];
            break;
        case NFCTagTypeISO7816Compatible:
            type = @"NFCTagTypeISO7816Compatible";
            uid = [[tag asNFCISO7816Tag] identifier];
            break;
        default:
            type = @"Unknown";
            uid = nil;
            break;
    }
                    
    NSLog(@"PGNFC-getTagInfo: %@ with uid %@", type, uid);
    
    [tagInfo setValue:type forKey:@"type"];
    if (uid) {
        [tagInfo setValue:uid forKey:@"id"];
    }
    return tagInfo;
}

#pragma mark - internal implementation

- (void) clearNoTagDetectedTimeout {
    NSLog(@"PGNFC-clearNoTagDetectedTimeout - 1");
    if (self.noTagDetectedTimeoutBlock) {
        NSLog(@"PGNFC-clearNoTagDetectedTimeout - 2");
        dispatch_block_cancel(self.noTagDetectedTimeoutBlock);
        self.noTagDetectedTimeoutBlock = nil;
    }
    NSLog(@"PGNFC-clearNoTagDetectedTimeout - 3");
}

- (void) startNoTagDetectedTimeoutForSession:(NFCReaderSession *)session token:(NSInteger)token API_AVAILABLE(ios(11.0)) {
    [self clearNoTagDetectedTimeout];
    NSLog(@"PGNFC-startNoTagDetectedTimeoutForSession - 1");
    if (self.noTagDetectedTimeoutMilliseconds <= 0) {
        return;
    }
    NSLog(@"PGNFC-startNoTagDetectedTimeoutForSession - 1");
    __weak NfcPlugin *weakSelf = self;
    dispatch_block_t timeoutBlock = dispatch_block_create(0, ^{
        NfcPlugin *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (strongSelf.nfcSessionToken != token) {
            NSLog(@"PGNFC-NFC no-tag timeout ignored because session token changed. token=%ld currentToken=%ld", (long)token, (long)strongSelf.nfcSessionToken);
            return;
        }

        if (strongSelf.nfcTagWasDetected) {
            NSLog(@"PGNFC-NFC no-tag timeout ignored because a tag was already detected.");
            return;
        }

        if (!strongSelf->sessionCallbackId) {
            NSLog(@"PGNFC-NFC no-tag timeout ignored because sessionCallbackId is empty.");
            return;
        }

        NSString *message = [strongSelf localizeString:@"NFCNoTagDetectedTimeout" defaultValue:@"NFC scan timed out. Please try again."];

        strongSelf.noTagDetectedTimeoutReached = YES;
        NSLog(@"PGNFC-NFC no-tag timeout reached. Invalidating session. timeoutMilliseconds=%ld token=%ld", (long)strongSelf.noTagDetectedTimeoutMilliseconds, (long)token);

        if (@available(iOS 13.0, *)) {
            [session invalidateSessionWithErrorMessage:message];
        } else {
            [session invalidateSession];
        }
    });

    self.noTagDetectedTimeoutBlock = timeoutBlock;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.noTagDetectedTimeoutMilliseconds * NSEC_PER_MSEC), dispatch_get_main_queue(), timeoutBlock);
}
- (BOOL) retryTagReadIfAvailable:(NFCReaderSession *)session stage:(NSString *)stage error:(NSError *)error API_AVAILABLE(ios(13.0)) {
    NSString *errorMessage = error.localizedDescription ?: @"Unknown NFC error";
    NSLog(@"PGNFC-NFC 0 retry begin for %@. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);

    if (![session respondsToSelector:@selector(restartPolling)]) {
        NSLog(@"PGNFC-NFC 1 retry not scheduled for %@ because restartPolling is unavailable. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
        return NO;
    }

    self.retryCount++;
    self.lastRetryStage = stage;
    self.lastRetryErrorMessage = errorMessage;

    if (self.retryCount >= self.maxRetryCount) {
        NSLog(@"PGNFC-NFC 2 retry not scheduled for %@ because max retry count was reached. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
        return NO;
    }
    NSLog(@"PGNFC-NFC 3 retry scheduled for %@. retryCount=%ld maxRetryCount=%ld retryDelayMilliseconds=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, (long)self.retryDelayMilliseconds, errorMessage);
    [self sendRetryLogEvent:stage error:error];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.retryDelayMilliseconds * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSLog(@"PGNFC-NFC 4 retry executing restartPolling for %@. retryCount=%ld", stage, (long)self.retryCount);

        NSLog(@"PGNFC-NFC 4a retry checking session readiness for %@. isReady=%d respondsToRestartPolling=%d retryCount=%ld maxRetryCount=%ld", stage, session.isReady, [session respondsToSelector:@selector(restartPolling)], (long)self.retryCount, (long)self.maxRetryCount);

            if (self.nfcSession != session) {
                NSLog(@"PGNFC-NFC 5a retry not restarted for %@ because session is no longer the active NFC session. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
                return;
            }

            if (![session respondsToSelector:@selector(restartPolling)]) {
                NSLog(@"PGNFC-NFC 5b retry not restarted for %@ because restartPolling is unavailable. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
                return;
            }

            if (!session.isReady) {
                NSLog(@"PGNFC-NFC 5c retry not restarted for %@ because session is not ready. Will try once more. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.retryDelayMilliseconds * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    NSLog(@"PGNFC-NFC 6 retry executing second restartPolling attempt for %@. retryCount=%ld", stage, (long)self.retryCount);

                    NSLog(@"PGNFC-NFC 6a retry checking session readiness for %@. isReady=%d respondsToRestartPolling=%d retryCount=%ld maxRetryCount=%ld", stage, session.isReady, [session respondsToSelector:@selector(restartPolling)], (long)self.retryCount, (long)self.maxRetryCount);

                    if (self.nfcSession != session) {
                        NSLog(@"PGNFC-NFC 7a retry not restarted for %@ because session is no longer the active NFC session. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
                        return;
                    }

                    if (![session respondsToSelector:@selector(restartPolling)]) {
                        NSLog(@"PGNFC-NFC 7b retry not restarted for %@ because restartPolling is unavailable for the session. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
                        return;
                    }

                    if (!session.isReady) {
                        NSLog(@"PGNFC-NFC 7c retry not restarted for %@ because session is still not ready. retryCount=%ld maxRetryCount=%ld error=%@", stage, (long)self.retryCount, (long)self.maxRetryCount, errorMessage);
                        return;
                    }

                    [(id)session restartPolling];
                });
                return;
            }
        [(id)session restartPolling];
    });
    return YES;
}

- (void) sendRetryLogEvent:(NSString *)stage error:(NSError *)error {
    if (!channelCallbackId) {
        return;
    }
    NSString *errorMessage = error.localizedDescription ?: @"Unknown NFC error";
    NSMutableDictionary *tag = [NSMutableDictionary new];
    tag[@"type"] = @"sendLogEvent";
    tag[@"message"] = @"NFC retry scheduled";
    tag[@"retryCount"] = [NSNumber numberWithInteger:self.retryCount];
    tag[@"maxRetryCount"] = [NSNumber numberWithInteger:self.maxRetryCount];
    tag[@"retryDelayMilliseconds"] = [NSNumber numberWithInteger:self.retryDelayMilliseconds];
    tag[@"nfcSessionToken"] = [NSNumber numberWithInteger:self.nfcSessionToken];
    if (stage) {
        tag[@"retryStage"] = stage;
    }
    tag[@"error"] = errorMessage;
    tag[@"errorLevel"] = @1;
    tag[@"nfcStatus"] = @"NFC_OK";
    NSMutableDictionary *evt = [NSMutableDictionary new];
    evt[@"type"] = @"ndef";
    evt[@"tag"] = tag;
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:evt];
    [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:channelCallbackId];
}
- (void) sendError:(NSString *)message {
    if (channelCallbackId) {
        NSMutableDictionary *tag = [NSMutableDictionary new];
        tag[@"type"] = @"sendLogEvent";
        tag[@"message"] = @"NFC scan error";
        tag[@"error"] = message ?: @"Unknown NFC error";
        tag[@"retryCount"] = [NSNumber numberWithInteger:self.retryCount];
        tag[@"maxRetryCount"] = [NSNumber numberWithInteger:self.maxRetryCount];
        tag[@"retryDelayMilliseconds"] = [NSNumber numberWithInteger:self.retryDelayMilliseconds];
        tag[@"nfcSessionToken"] = [NSNumber numberWithInteger:self.nfcSessionToken];
        if (self.lastRetryStage) {
            tag[@"retryStage"] = self.lastRetryStage;
        }
        if (self.lastRetryErrorMessage) {
            tag[@"lastRetryError"] = self.lastRetryErrorMessage;
        }
        tag[@"errorLevel"] = @2;
        tag[@"nfcStatus"] = @"NFC_ERROR";
        NSMutableDictionary *evt = [NSMutableDictionary new];
        evt[@"type"] = @"ndef";
        evt[@"tag"] = tag;
        CDVPluginResult *logResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:evt];
        [logResult setKeepCallback:[NSNumber numberWithBool:YES]];
        [self.commandDelegate sendPluginResult:logResult callbackId:channelCallbackId];
    }
    // only send the error if the callback id exists
    if (sessionCallbackId) {
        NSLog(@"PGNFC-sendError: %@", message);
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:sessionCallbackId];
    }
}

- (void) sessionDidBecomeActive:(NFCReaderSession *) session  API_AVAILABLE(ios(11.0)){
    if (sessionCallbackId && self.sendCallbackOnSessionStart) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [pluginResult setKeepCallback:@YES];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:sessionCallbackId];
    }
}

- (void) closeSession:(NFCReaderSession *) session  API_AVAILABLE(ios(11.0)){

    [self clearNoTagDetectedTimeout];
    // this is a hack to keep a read session open to allow writing
    if (self.keepSessionOpen) {
        return;
    }

    // kill the callback so the Cordova doesn't get "Session invalidated by user"
    sessionCallbackId = NULL;
    connectedTag = NULL;
    connectedTagStatus = NFCNDEFStatusNotSupported;
    [session invalidateSession];
}

- (void) closeSession:(NFCReaderSession *) session withError:(NSString *) errorMessage  API_AVAILABLE(ios(11.0)){
    [self clearNoTagDetectedTimeout];
    [self sendError:errorMessage];

    // kill the callback so Cordova doesn't get "Session invalidated by user"
    sessionCallbackId = NULL;
    connectedTag = NULL;
    connectedTagStatus = NFCNDEFStatusNotSupported;
    
    if (@available(iOS 13.0, *)) {
        [session invalidateSessionWithErrorMessage:errorMessage];
    } else {
        [session invalidateSession];
    }
}

-(void) fireTagEvent:(NSDictionary *)metaData API_AVAILABLE(ios(11.0)) {
    // Data is from a tag, but still ends up as an NDEF event in Javascript
    [self fireNdefEvent:nil metaData:metaData];
}

-(void) fireNdefEvent:(NFCNDEFMessage *) ndefMessage API_AVAILABLE(ios(11.0)) {
    [self fireNdefEvent:ndefMessage metaData:nil];
}

// TODO rename method since we're using the channel or callback instead of firing an event
-(void) fireNdefEvent:(NFCNDEFMessage *) ndefMessage metaData:(NSDictionary *)metaData API_AVAILABLE(ios(11.0)) {
    NSLog(@"PGNFC-fireNdefEvent");
    
    NSMutableDictionary *nfcEvent = [NSMutableDictionary new];
    nfcEvent[@"type"] = @"ndef";
    nfcEvent[@"tag"] = [self buildTagDictionary:ndefMessage metaData:metaData];

    if (sessionCallbackId && self.returnTagInCallback) {
        NSLog(@"PGNFC-Sending NFC data via sessionCallbackId");
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:nfcEvent[@"tag"]];
//        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:sessionCallbackId];
        sessionCallbackId = NULL;
    }
    
    if (channelCallbackId && self.returnTagInEvent) {
        NSLog(@"PGNFC-Sending NFC data via channelCallbackId so an NDEF event fires)");
        
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:nfcEvent];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:channelCallbackId];
    }
}

// NSDictionary representing an NFC tag
// NSData fields are converted to uint8_t arrays
-(NSDictionary *) buildTagDictionary:(NFCNDEFMessage *) ndefMessage metaData: (NSDictionary *)metaData API_AVAILABLE(ios(11.0)) {
    
    NSMutableDictionary *dictionary = [NSMutableDictionary new];
    
    // start with tag meta data
    if (metaData) {
        [dictionary setDictionary:metaData];
    }

    // convert uid from NSData to a uint8_t array
    NSData *uid = [dictionary objectForKey:@"id"];
    if (uid) {
        dictionary[@"id"] = [self uint8ArrayFromNSData: uid];
    }
    
    if (ndefMessage) {
        NSMutableArray *array = [NSMutableArray new];
        for (NFCNDEFPayload *record in ndefMessage.records){
            NSDictionary* recordDictionary = [self ndefRecordToNSDictionary:record];
            [array addObject:recordDictionary];
        }
        [dictionary setObject:array forKey:@"ndefMessage"];
    }
    dictionary[@"retryCount"] = [NSNumber numberWithInteger:self.retryCount];
    dictionary[@"maxRetryCount"] = [NSNumber numberWithInteger:self.maxRetryCount];
    dictionary[@"nfcSessionToken"] = [NSNumber numberWithInteger:self.nfcSessionToken];
    if (self.lastRetryStage) {
        dictionary[@"retryStage"] = self.lastRetryStage;
    }
    if (self.lastRetryErrorMessage) {
        dictionary[@"lastRetryError"] = self.lastRetryErrorMessage;
    }
    
    return [dictionary copy];
}

-(NSDictionary *) ndefRecordToNSDictionary:(NFCNDEFPayload *) ndefRecord API_AVAILABLE(ios(11.0)) {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"tnf"] = [NSNumber numberWithInt:(int)ndefRecord.typeNameFormat];
    dict[@"type"] = [self uint8ArrayFromNSData: ndefRecord.type];
    dict[@"id"] = [self uint8ArrayFromNSData: ndefRecord.identifier];
    dict[@"payload"] = [self uint8ArrayFromNSData: ndefRecord.payload];
    NSDictionary *copy = [dict copy];
    return copy;
}

- (NSArray *) uint8ArrayFromNSData:(NSData *) data {
    const void *bytes = [data bytes];
    NSMutableArray *array = [NSMutableArray array];
    for (NSUInteger i = 0; i < [data length]; i += sizeof(uint8_t)) {
        uint8_t elem = OSReadLittleInt(bytes, i);
        [array addObject:[NSNumber numberWithInt:elem]];
    }
    return array;
}

- (NSData *) uint8ArrayToNSData:(NSArray *) array {
    // NSLog(@"nsDataFromUint8Array input %@", array);
    
    NSMutableData *data = [[NSMutableData alloc] initWithCapacity: [array count]];
    for (NSNumber *number in array) {
        uint8_t b = (uint8_t)[number unsignedIntValue];
        // NSLog(@"> %hhu", b);
        [data appendBytes:&b length:1];
    }
    return data;
}

- (NSString*) dictionaryAsJSONString:(NSDictionary *)dict {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    NSString *jsonString;
    if (! jsonData) {
        jsonString = [NSString stringWithFormat:@"Error creating JSON for NDEF Message: %@", error];
        NSLog(@"PGNFC-%@", jsonString);
    } else {
        jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return jsonString;
}

- (NSString*) localizeString:(NSString *)key defaultValue:(NSString*) defaultValue {
    return NSLocalizedString(key, comment: @"") != key ? NSLocalizedString(key, comment: @"") : defaultValue;
}

@end
