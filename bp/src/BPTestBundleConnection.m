//
//  BPTestBundleConnection.m
//  Bluepill-cli
//
//  Created by Keqiu Hu on 2/7/17.
//  Copyright © 2017 LinkedIn. All rights reserved.
//

#import "BPTestBundleConnection.h"
#import "BPUtils.h"
#import "BPTestDaemonConnection.h"
#import "BPConstants.h"
#import "SimulatorHelper.h"
#import "BPConfiguration.h"

// XCTAutomationSupport framework
#import "PrivateHeaders/XCTAutomationSupport/XCElementSnapshot.h"

// XCTest framework
#import "PrivateHeaders/XCTest/XCTMessagingChannel_IDEToDaemon-Protocol.h"
#import "PrivateHeaders/XCTest/XCTMessagingChannel_IDEToRunner-Protocol.h"
#import "PrivateHeaders/XCTest/XCTMessagingChannel_RunnerToIDE-Protocol.h"


// DTX framework
#import "PrivateHeaders/DTXConnectionServices/DTXConnection.h"
#import "PrivateHeaders/DTXConnectionServices/DTXProxyChannel.h"
#import "PrivateHeaders/DTXConnectionServices/DTXRemoteInvocationReceipt.h"
#import "PrivateHeaders/DTXConnectionServices/DTXTransport.h"
#import "PrivateHeaders/DTXConnectionServices/DTXSocketTransport.h"

// CoreSimulator
#import "PrivateHeaders/CoreSimulator/SimDevice.h"

// sys
#import <sys/socket.h>
#import <sys/un.h>

// runtime
#import <objc/runtime.h>

static const NSString * const testManagerEnv = @"TESTMANAGERD_SIM_SOCK";

@interface BPTestBundleConnection()<XCTMessagingChannel_IDEToRunner>

@property (atomic, nullable, strong) id<XCTMessagingChannel_IDEToRunner> testBundleProxy;
@property (atomic, nullable, strong, readwrite) DTXConnection *testBundleConnection;

@property (nonatomic, weak) id<BPTestBundleConnectionDelegate> interface;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSString *bundleID;
@property (nonatomic, assign) pid_t appProcessPID;
@property (nonatomic, nullable) NSTask *recordVideoTask;
//@property (nonatomic, nullable) NSPipe *recordVideoPipe;


@end

@implementation BPTestBundleConnection

- (instancetype)initWithContext:(BPExecutionContext *)context andInterface:(id<BPTestBundleConnectionDelegate>)interface {
    self = [super init];
    if (self) {
        self.context = context;
        self.simulator = context.runner;
        self.interface = interface;
        self.queue = dispatch_queue_create("com.linkedin.bluepill.connection.queue", DISPATCH_QUEUE_PRIORITY_DEFAULT);
    }
    return self;
}

- (void)connectWithTimeout:(NSTimeInterval)timeout {
    NSAssert(NSThread.isMainThread, @"-[%@ %@] should be called from the main thread", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
    [self connect];

    // Pool connection status till it passes.
    [BPUtils runWithTimeOut:timeout until:^BOOL{
        return self.connected;
    }];
    if (!self.connected) {
        [BPUtils printInfo:ERROR withString:@"Timeout establishing a control session!"];
    }
}

- (void)connect {
    dispatch_async(self.queue, ^{
        DTXTransport *transport = [self connectTransport];
        DTXConnection *connection = [[objc_lookUpClass("DTXConnection") alloc] initWithTransport:transport];
        [connection registerDisconnectHandler:^{
            // This is called when the task is abruptly terminated (e.g. if the test times out)
            [self stopVideoRecording:YES];
            [BPUtils printInfo:INFO withString:@"DTXConnection disconnected."];
        }];
        [connection
         handleProxyRequestForInterface:@protocol(XCTMessagingChannel_IDEToRunner)
         peerInterface:@protocol(XCTMessagingChannel_RunnerToIDE)
         handler:^(DTXProxyChannel *channel){
             [BPUtils printInfo:INFO withString:@"Got proxy channel request from test bundle"];
             [channel setExportedObject:self queue:dispatch_get_main_queue()];
             id<XCTMessagingChannel_IDEToRunner> interface = channel.remoteObjectProxy;
             self.testBundleProxy = interface;
         }];
        self.testBundleConnection = connection;
        [self.testBundleConnection resume];

        dispatch_async(dispatch_get_main_queue(), ^{
            DTXProxyChannel *proxyChannel = [self.testBundleConnection
                                             makeProxyChannelWithRemoteInterface:@protocol(XCTMessagingChannel_IDEToDaemon)
                                             exportedInterface:@protocol(XCTMessagingChannel_IDEToRunner)];
            [proxyChannel setExportedObject:self queue:dispatch_get_main_queue()];
            id<XCTMessagingChannel_IDEToDaemon> remoteProxy = (id<XCTMessagingChannel_IDEToDaemon>) proxyChannel.remoteObjectProxy;

            NSString *path = NSBundle.mainBundle.bundlePath;
            if (![path.pathExtension isEqualToString:@"app"]) {
                path = NSBundle.mainBundle.executablePath;
            }
            __block DTXRemoteInvocationReceipt *receipt = [remoteProxy
                                                           _IDE_initiateSessionWithIdentifier:self.context.config.sessionIdentifier
                                                           forClient:[self clientProcessUniqueIdentifier]
                                                           atPath:path
                                                           protocolVersion:@(BP_DAEMON_PROTOCOL_VERSION)];
            [receipt handleCompletion:^(NSNumber *version, NSError *error){
                if (error || !version) {
                    [BPUtils printInfo:ERROR withString:@"Retry count: %@", error];
                    return;
                }
                [proxyChannel cancel];
            }];
        });
    });
}

- (void)startTestPlan {
    dispatch_async(self.queue, ^{
        [BPUtils printInfo:INFO withString:@"Test plan started!"];
        [self.testBundleProxy _IDE_startExecutingTestPlanWithProtocolVersion:@(BP_TM_PROTOCOL_VERSION)];
    });
}

- (NSString *)clientProcessUniqueIdentifier {
    static dispatch_once_t onceToken;
    static NSString *_clientProcessUniqueIdentifier;
    dispatch_once(&onceToken, ^{
        _clientProcessUniqueIdentifier = NSProcessInfo.processInfo.globallyUniqueString;
    });
    return _clientProcessUniqueIdentifier;
}

- (int)testManagerSocket {
    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD == -1) {
        [BPUtils printInfo:ERROR withString:@"Error in creating socketFD"];
        return -1;
    }
    NSString *socketString = [self.simulator.device getenv:testManagerEnv error:nil];
    const char *socketPath = socketString.UTF8String;

    if(![[NSFileManager new] fileExistsAtPath:socketString]) {
        [BPUtils printInfo:ERROR withString:@"Does not exist - %@", socketString];
        return -1;
    }
    if(strnlen(socketPath, 1024) >= 104) {
        [BPUtils printInfo:ERROR withString:@"Socket path is too big %@", socketString];
        return -1;
    }
    struct sockaddr_un remote;
    remote.sun_family = AF_UNIX;
    strncpy(remote.sun_path, socketPath, 104);
    socklen_t length = (socklen_t)(strnlen(remote.sun_path, 1024) + sizeof(remote.sun_family) + sizeof(remote.sun_len));
    if (connect(socketFD, (struct sockaddr *)&remote, length) == -1) {
        [BPUtils printInfo:ERROR withString:@"Failed to connect to socket"];
        return -1;
    }
    return socketFD;
}

- (DTXTransport *)connectTransport {
    if ([NSThread isMainThread]) {assert(NO);}
    int socketFD = [self testManagerSocket];
    if (socketFD == -1) {
        [BPUtils printInfo:ERROR withString:@"Failed to get socket fd to test bundle."];
        return NULL;
    }
    DTXTransport *transport = [[objc_lookUpClass("DTXSocketTransport") alloc] initWithConnectedSocket:socketFD disconnectAction:^{
        [BPUtils printInfo:INFO withString:@"Socket transport disconneted"];
    }];
    if (!transport) {
        [BPUtils printInfo:ERROR withString:@"Transport creation failed."];
        return NULL;
    }
    return transport;
}

#pragma mark XCTMessagingChannel_RunnerToIDE

- (id)_XCT_didBeginExecutingTestPlan {
    [BPUtils printInfo:INFO withString:@"_XCT_didBeginExecutingTestPlan"];
    return nil;
}

- (id)_XCT_didFinishExecutingTestPlan {
    [BPUtils printInfo:INFO withString:@"_XCT_didFinishExecutingTestPlan"];
    return nil;
}

- (id)_XCT_testBundleReadyWithProtocolVersion:(NSNumber *)protocolVersion minimumVersion:(NSNumber *)minimumVersion {
    self.connected = YES;
    [BPUtils printInfo:INFO withString:@"Test bundle is connected.protocolVersion= %@, minimumVersion = %@", protocolVersion, minimumVersion];
    return nil;
}

- (id)_XCT_didBeginInitializingForUITesting {
    [BPUtils printInfo:INFO withString:@"Start initialization UI tests"];
    return nil;
}

- (id)_XCT_initializationForUITestingDidFailWithError:(NSError *__strong)errPtr {
    [BPUtils printInfo:INFO withString:@"_XCT_initializationForUITestingDidFailWithError is %@", errPtr];
    return nil;
}

#pragma mark - Video Recording

static inline NSString* getVideoPath(NSString *directory, NSString *testClass, NSString *method, NSInteger attemptNumber)
{
    return [NSString stringWithFormat:@"%@/%@__%@__%ld.mp4", directory, testClass, method, (long)attemptNumber];
}

- (BOOL)shouldRecordVideo {
    return self.context.config.videosDirectory.length > 0;
}

- (void)startVideoRecordingForTestClass:(NSString *)testClass method:(NSString *)method
{
    [self stopVideoRecording:YES];
    NSString *videoFileName = getVideoPath(self.context.config.videosDirectory, testClass, method, self.context.attemptNumber);
    NSString *command = [NSString stringWithFormat:@"xcrun simctl io %@ recordVideo --force %@", [self.simulator UDID], videoFileName];
    NSTask *task = [BPUtils buildShellTaskForCommand:command];
    self.recordVideoTask = task;
    [task launch];
    [BPUtils printInfo:INFO withString:@"Started recording video to %@", videoFileName];
    [BPUtils printInfo:DEBUGINFO withString:@"Started recording video task with pid %d and command: %@",  [task processIdentifier], [BPUtils getCommandStringForTask:task]];
}

- (void)stopVideoRecording:(BOOL)forced
{
    NSTask *task = self.recordVideoTask;
    if (task == nil) {
        if (!forced) {
            [BPUtils printInfo:ERROR withString: @"Tried to end video recording task normally, but there was no task."];
        }
        return;
    }
    
    if (forced) {
        [BPUtils printInfo:ERROR withString: @"Found dangling video recording task. Stopping it."];
    }
    
    if (![task isRunning]) {
        [BPUtils printInfo:ERROR withString:@"Video task exists but it was already terminated with status %d", [task terminationStatus]];
    }
    
    [BPUtils printInfo:INFO withString:@"Stopping recording video."];
    [BPUtils printInfo:DEBUGINFO withString:@"Stopping video recording task with pid %d and command: %@", [task processIdentifier], [BPUtils getCommandStringForTask:task]];
    [task interrupt];
    [task waitUntilExit];

    if ([task terminationStatus] != 0) {
        [BPUtils printInfo:ERROR withString:@"Video task was interrupted, but exited with non-zero status %d", [task terminationStatus]];
    }

    NSString *filePath = [[task arguments].lastObject componentsSeparatedByString:@" "].lastObject;
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        [BPUtils printInfo:ERROR withString:@"Video recording file missing, expected at path %@!", filePath];
    }
    self.recordVideoTask = nil;
}

#pragma mark - XCTMessagingChannel_IDEToRunner protocol

#pragma mark Process Launch Delegation

- (id)_XCT_launchProcessWithPath:(NSString *)path bundleID:(NSString *)bundleID arguments:(NSArray *)arguments environmentVariables:(NSDictionary *)environment
{
    NSMutableDictionary<NSString *, NSString *> *env = [[NSMutableDictionary alloc] init];
    [env addEntriesFromDictionary:[SimulatorHelper appLaunchEnvironmentWithBundleID:bundleID device:nil config:_context.config]];
    [env addEntriesFromDictionary:environment];
    NSDictionary *options = @{
                              @"arguments": arguments,
                              @"environment": env,
                              };
    NSError *error;
    DTXRemoteInvocationReceipt *receipt = [objc_lookUpClass("DTXRemoteInvocationReceipt") new];
    [BPUtils printInfo:DEBUGINFO withString:@"Installing UITargetApp: %@", path];
    [self.simulator.device installApplication:[NSURL fileURLWithPath:path] withOptions:@{kCFBundleIdentifier: bundleID} error:&error];
    if (error) {
        [BPUtils printInfo:ERROR withString:@"Launch application during UI tests failed %@", error];
        return nil;
    }
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection Launching app: %@ with options %@", bundleID, options];
    
    self.appProcessPID = [self.simulator.device launchApplicationWithID:bundleID options:options error:&error];
    self.bundleID = bundleID;
    if (error) {
        [BPUtils printInfo:ERROR withString:@"Launch application during UI tests failed %@", error];
        return nil;
    }
    id token = @(receipt.hash);
    [receipt invokeCompletionWithReturnValue:token error:error];
    return receipt;
}

- (id)_XCT_getProgressForLaunch:(id)token {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnectionTest process requested launch process status with token %@", token];
    DTXRemoteInvocationReceipt *receipt = [objc_lookUpClass("DTXRemoteInvocationReceipt") new];
    [receipt invokeCompletionWithReturnValue:@1 error:nil];
    return receipt;
}

- (id)_XCT_terminateProcess:(id)token {
    NSError *error;
    kill(self.appProcessPID, SIGINT);
    DTXRemoteInvocationReceipt *receipt = [objc_lookUpClass("DTXRemoteInvocationReceipt") new];
    [receipt invokeCompletionWithReturnValue:token error:error];
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection_XCT_terminateProcess with token %@", token];
    return receipt;
}

#pragma mark iOS 10.x
- (id)_XCT_handleCrashReportData:(NSData *)arg1 fromFileWithName:(NSString *)arg2 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection_XCT_handleCrashReportData : %@, from file with name: %@", arg1, arg2];
    return nil;
}

#pragma mark Test Suite Progress

- (id)_XCT_testSuite:(NSString *)tests didStartAt:(NSString *)time {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection_XCT_testSuite: %@, start %@", tests, time];
    return nil;
}

- (id)_XCT_testCaseDidStartForTestClass:(NSString *)testClass method:(NSString *)method {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection_XCT_testCaseDidStartForTestClass: %@ and method: %@", testClass, method];
    if ([self shouldRecordVideo]) {
        [self startVideoRecordingForTestClass:testClass method:method];
    }
    return nil;
}

- (id)_XCT_testCaseDidFailForTestClass:(NSString *)testClass method:(NSString *)method withMessage:(NSString *)message file:(NSString *)file line:(NSNumber *)line {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection_XCT_testCaseDidFailForTestClass: %@, method: %@, withMessage: %@, file: %@, line: %@", testClass, method, message, file, line];
    return nil;
}

// This looks like tested application logs
- (id)_XCT_logDebugMessage:(NSString *)debugMessage {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection debug message: %@", debugMessage];
    return nil;
}

- (id)_XCT_logMessage:(NSString *)message {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection log message: %@", message];
    return nil;
}

- (id)_XCT_testCaseDidFinishForTestClass:(NSString *)testClass method:(NSString *)method withStatus:(NSString *)statusString duration:(NSNumber *)duration {
    [BPUtils printInfo:DEBUGINFO withString: @"BPTestBundleConnection_XCT_testCaseDidFinishForTestClass: %@, method: %@, withStatus: %@, duration: %@", testClass, method, statusString, duration];
    if ([self shouldRecordVideo]) {
        [self stopVideoRecording:NO];
    }
    return nil;
}

- (id)_XCT_testSuite:(NSString *)arg1 didFinishAt:(NSString *)time runCount:(NSNumber *)count withFailures:(NSNumber *)failureCount unexpected:(NSNumber *)unexpectedCount testDuration:(NSNumber *)testDuration totalDuration:(NSNumber *)totalTime {
    [BPUtils printInfo:DEBUGINFO withString: @"BPTestBundleConnection_XCT_testSuite: %@, didFinishAt: %@, runCount: %@, withFailures: %@, unexpectedCount: %@, testDuration: %@, totalDuration: %@", arg1, time, count, failureCount, unexpectedCount, testDuration, totalTime];

    if ([self shouldRecordVideo]) {
        [self stopVideoRecording:YES];
    }
    return nil;
}

- (id)_XCT_testMethod:(NSString *)arg1 ofClass:(NSString *)arg2 didMeasureMetric:(NSDictionary *)arg3 file:(NSString *)arg4 line:(NSNumber *)arg5 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection_XCT_testMethod: %@, ofClass: %@, didMeasureMetric: %@, file: %@, line: %@", arg1, arg2, arg3, arg4, arg5];
    return nil;
}

- (id)_XCT_testCase:(NSString *)arg1 method:(NSString *)arg2 didFinishActivity:(XCActivityRecord *)arg3 {
    [BPUtils printInfo:DEBUGINFO withString: @"BPTestBundleConnection_XCT_testCase %@, method: %@, didFinishActivity: %@", arg1, arg2, arg3];
    return nil;
}

- (id)_XCT_testCase:(NSString *)arg1 method:(NSString *)arg2 willStartActivity:(XCActivityRecord *)arg3 {
    [BPUtils printInfo:DEBUGINFO withString: @"BPTestBundleConnection_XCT_testCase %@, method: %@, willStartActivity: %@", arg1, arg2, arg3];
    return nil;
}

#pragma mark - Unimplemented

- (id)_XCT_nativeFocusItemDidChangeAtTime:(NSNumber *)arg1 parameterSnapshot:(XCElementSnapshot *)arg2 applicationSnapshot:(XCElementSnapshot *)arg3 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection nativeFocusItemDidChangeAtATime"];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedEventNames:(NSArray *)arg1 timestamp:(NSNumber *)arg2 duration:(NSNumber *)arg3 startLocation:(NSDictionary *)arg4 startElementSnapshot:(XCElementSnapshot *)arg5 startApplicationSnapshot:(XCElementSnapshot *)arg6 endLocation:(NSDictionary *)arg7 endElementSnapshot:(XCElementSnapshot *)arg8 endApplicationSnapshot:(XCElementSnapshot *)arg9 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection recordedEventNames, ag1: %@", arg1];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedOrientationChange:(NSString *)arg1 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedOrientationChange: %@", arg1];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedFirstResponderChangedWithApplicationSnapshot:(XCElementSnapshot *)arg1 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedFirstResponderChanged"];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_exchangeCurrentProtocolVersion:(NSNumber *)arg1 minimumVersion:(NSNumber *)arg2 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: exhangeCurrentProtocolVersion: %@, minimumVersion: %@", arg1, arg2];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedKeyEventsWithApplicationSnapshot:(XCElementSnapshot *)arg1 characters:(NSString *)arg2 charactersIgnoringModifiers:(NSString *)arg3 modifierFlags:(NSNumber *)arg4 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedKeyEventsWithApplicationSnapshot"];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedEventNames:(NSArray *)arg1 duration:(NSNumber *)arg2 startLocation:(NSDictionary *)arg3 startElementSnapshot:(XCElementSnapshot *)arg4 startApplicationSnapshot:(XCElementSnapshot *)arg5 endLocation:(NSDictionary *)arg6 endElementSnapshot:(XCElementSnapshot *)arg7 endApplicationSnapshot:(XCElementSnapshot *)arg8 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedEventNames: %@", arg1];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedKeyEventsWithCharacters:(NSString *)arg1 charactersIgnoringModifiers:(NSString *)arg2 modifierFlags:(NSNumber *)arg3 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedKeyEventsWithCharacters: %@", arg1];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedEventNames:(NSArray *)arg1 duration:(NSNumber *)arg2 startElement:(XCAccessibilityElement *)arg3 startApplicationSnapshot:(XCElementSnapshot *)arg4 endElement:(XCAccessibilityElement *)arg5 endApplicationSnapshot:(XCElementSnapshot *)arg6 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedEventsName: %@, duration: %@", arg1, arg2];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedEvent:(NSString *)arg1 targetElementID:(NSDictionary *)arg2 applicationSnapshot:(XCElementSnapshot *)arg3 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedEvent: %@, targetElementID: %@", arg1, arg2];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_recordedEvent:(NSString *)arg1 forElement:(NSString *)arg2 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: recordedEvent: %@, forElement: %@",arg1, arg2];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_testCase:(NSString *)arg1 method:(NSString *)arg2 didStallOnMainThreadInFile:(NSString *)arg3 line:(NSNumber *)arg4 {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: testCase: %@, method: %@, didStallOnMainThreadInFile: %@, line: %@", arg1, arg2, arg3, arg4];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_testMethod:(NSString *)arg1 ofClass:(NSString *)arg2 didMeasureValues:(NSArray *)arg3 forPerformanceMetricID:(NSString *)arg4 name:(NSString *)arg5 withUnits:(NSString *)arg6 baselineName:(NSString *)arg7 baselineAverage:(NSNumber *)arg8 maxPercentRegression:(NSNumber *)arg9 maxPercentRelativeStandardDeviation:(NSNumber *)arg10 file:(NSString *)arg11 line:(NSNumber *)arg12
{
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: testMethod..."];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (id)_XCT_testBundleReady {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: testBundle Ready!"];
    return [self handleUnimplementedXCTRequest:_cmd];
}

- (NSString *)unknownMessageForSelector:(SEL)aSelector {
    [BPUtils printInfo:DEBUGINFO withString:@"BPTestBundleConnection: unknownMessageForSelector: %@", NSStringFromSelector(aSelector)];
    return [NSString stringWithFormat:@"Received call for unhandled method (%@). Probably you should have a look at _IDETestManagerAPIMediator in IDEFoundation.framework and implement it. Good luck!", NSStringFromSelector(aSelector)];
}

// This will add more logs when unimplemented method from XCTMessagingChannel_IDEToRunner protocol is called
- (id)handleUnimplementedXCTRequest:(SEL)aSelector {
    NSAssert(nil, [self unknownMessageForSelector:_cmd]);
    return nil;
}

@end
