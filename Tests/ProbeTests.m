#import <Foundation/Foundation.h>
#import "AxsPrivate.h"
#import "AxsConfig.h"
#import "AxsDiagnostics.h"
#import "AxsProbeManager.h"
#import "AxsTrigger.h"
#include <stdlib.h>

static NSMutableDictionary *AxsTestValues;
static NSMutableArray *AxsTestEvents;
static NSUInteger AxsChecks;

static void AxsCheck(BOOL condition, NSString *message) {
    AxsChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

// No preferences, files, audio, network, hooks or system Siri are used by this test.
@implementation AxsConfig
+ (NSDictionary *)defaults {
    return @{@"enabled": @YES, @"speakReply": @NO, @"prefix": @"\u95eeAI", @"reply": @"Local probe."};
}
+ (id)valueForKey:(NSString *)key {
    @synchronized (self) { return AxsTestValues[key]; }
}
+ (BOOL)setValue:(id)value forPreferenceKey:(NSString *)key {
    @synchronized (self) { AxsTestValues[key] = value; }
    return YES;
}
+ (BOOL)registerDefaults { return YES; }
- (BOOL)enabled { return [[AxsConfig valueForKey:@"enabled"] boolValue]; }
- (BOOL)speakReply { return [[AxsConfig valueForKey:@"speakReply"] boolValue]; }
- (NSString *)prefix { return [AxsConfig valueForKey:@"prefix"]; }
- (NSString *)reply { return [AxsConfig valueForKey:@"reply"]; }
@end

void AxsRecord(NSString *event, NSDictionary *details) {
    @synchronized (AxsTestEvents) { [AxsTestEvents addObject:event]; }
}
NSString *AxsReadDiagnostics(void) { return @"test"; }

@implementation SAUIAddViews
+ (instancetype)addViews { return [self new]; }
@end
@implementation SAUIAssistantUtteranceView
+ (instancetype)assistantUtteranceView { return [self new]; }
@end

@interface AxsTestRecognition : NSObject
@property (copy) NSString *transcript;
- (id)oneBestTranscript;
@end
@implementation AxsTestRecognition
- (id)oneBestTranscript { return self.transcript; }
@end

@interface AFUISiriSession ()
@property (strong) NSMutableArray *axsSubmitted;
@end
@implementation AFUISiriSession
- (instancetype)init {
    self = [super init];
    if (self) _axsSubmitted = [NSMutableArray array];
    return self;
}
- (void)assistantConnection:(id)connection speechRecognized:(id)recognized {
    [[AxsProbeManager shared] observeRecognition:recognized session:self];
}
- (void)assistantConnectionRequestWillStart:(id)connection {
    [[AxsProbeManager shared] beginSession:self];
}
- (void)assistantConnectionDismissAssistant:(id)connection { [self end]; }
- (void)end { [[AxsProbeManager shared] endSession:self]; }
- (void)endForReason:(long long)reason { [self end]; }
- (void)performAceCommand:(id)command turnIdentifier:(id)identifier machAbsoluteTime:(double)time {
    AxsCheck(NSThread.isMainThread, @"submission on main thread");
    AxsCheck([identifier isEqual:@"native-turn"], @"reuse native turn");
    AxsCheck(time == 123.5, @"reuse native timestamp");
    [self.axsSubmitted addObject:command];
    // Simulate the production post-hook to exercise recursion suppression.
    [[AxsProbeManager shared] observeCommand:command session:self turn:identifier time:time];
}
@end

static BOOL AxsHasEvent(NSString *event) {
    @synchronized (AxsTestEvents) { return [AxsTestEvents containsObject:event]; }
}

static void AxsPump(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
        [NSThread sleepForTimeInterval:0.001];
    }
}

static void AxsWait(BOOL (^predicate)(void), NSString *message) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!predicate() && deadline.timeIntervalSinceNow > 0) AxsPump(0.005);
    AxsCheck(predicate(), message);
}

static AFUISiriSession *AxsNewSession(void) {
    [[AxsProbeManager shared] preferencesChanged];
    @synchronized (AxsConfig.class) { AxsTestValues = [[AxsConfig defaults] mutableCopy]; }
    @synchronized (AxsTestEvents) { [AxsTestEvents removeAllObjects]; }
    AFUISiriSession *session = [AFUISiriSession new];
    [session assistantConnectionRequestWillStart:nil];
    return session;
}

static void AxsRecognize(AFUISiriSession *session, NSString *text) {
    AxsTestRecognition *recognition = [AxsTestRecognition new];
    recognition.transcript = text;
    [session assistantConnection:nil speechRecognized:recognition];
}

static void AxsNativeContext(AFUISiriSession *session) {
    SAUIAddViews *native = [SAUIAddViews addViews];
    native.refId = @"native-ref";
    native.displayTarget = @"Primary";
    native.dialogPhase = @"Summary";
    [[AxsProbeManager shared] observeCommand:native session:session turn:@"native-turn" time:123.5];
}

static void AxsTestTriggers(void) {
    AxsCheck(AxsMatchesTrigger(@"\u95eeAI\u4f60\u597d", @"\u95eeAI"), @"Chinese trigger");
    AxsCheck(AxsMatchesTrigger(@" \u95ee A I\uFF0C\u4f60\u597d ", @"\u95eeAI"), @"ASR spaces");
    AxsCheck(AxsMatchesTrigger(@"\u95ee\uFF21\uFF29\u4f60\u597d", @"\u95eeAI"), @"full-width letters");
    AxsCheck(AxsMatchesTrigger(@"Ask AI explain this", @"ask ai"), @"case-insensitive word boundary");
    AxsCheck(AxsMatchesTrigger(@"Ask A I: explain", @"ask ai"), @"spaced English prefix");
    AxsCheck(!AxsMatchesTrigger(@"ask aioli", @"ask ai"), @"reject partial English word");
    AxsCheck(!AxsMatchesTrigger(@"hello ask ai", @"ask ai"), @"prefix only");
    AxsCheck(!AxsMatchesTrigger(@"hello", @""), @"empty prefix");
    AxsCheck(!AxsMatchesTrigger(@"hello", @"  "), @"whitespace prefix");
    AxsCheck(!AxsMatchesTrigger(@"\u95eeAI", @"\u95eeAI"), @"bare prefix");
    AxsCheck(!AxsMatchesTrigger(@"\u95eeAI:  ", @"\u95eeAI"), @"punctuation-only question");
    AxsCheck(!AxsMatchesTrigger(nil, @"ask ai"), @"nil transcript");
}

static void AxsTestSubmission(void) {
    AFUISiriSession *session = AxsNewSession();
    AxsNativeContext(session);
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return session.axsSubmitted.count == 1; }, @"submit fixed reply");
    SAUIAddViews *command = session.axsSubmitted.firstObject;
    SAUIAssistantUtteranceView *view = command.views.firstObject;
    AxsCheck([view.text isEqual:@"Local probe."], @"fixed text");
    AxsCheck(view.speakableText == nil, @"speech off by default");
    AxsCheck([command.refId isEqual:@"native-ref"], @"reuse native refId");
    AxsCheck(command.supplemental && !command.requiresResponse, @"nonblocking supplemental reply");
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsNativeContext(session);
    AxsPump(0.05);
    AxsCheck(session.axsSubmitted.count == 1, @"one submission per turn; no recursion");
    [session end];

    session = AxsNewSession();
    [AxsConfig setValue:@YES forPreferenceKey:@"speakReply"];
    AxsNativeContext(session);
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return session.axsSubmitted.count == 1; }, @"submit speech request");
    command = session.axsSubmitted.firstObject;
    view = command.views.firstObject;
    AxsCheck([view.speakableText isEqual:view.text], @"speech text opt-in");
    [session end];

    session = AxsNewSession();
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return AxsHasEvent(@"final-recognition"); }, @"recognition without context");
    AxsPump(0.03);
    AxsCheck(session.axsSubmitted.count == 0, @"never fabricate native context");
    [[AxsProbeManager shared] observeCommand:[SAUIAddViews addViews] session:session turn:nil time:0];
    AxsPump(0.03);
    AxsCheck(session.axsSubmitted.count == 0, @"nil native turn is not guessed");
    AxsNativeContext(session);
    AxsWait(^BOOL { return session.axsSubmitted.count == 1; }, @"wait for real native context");
    [session end];
}

static void AxsTestCancellation(void) {
    AFUISiriSession *session = AxsNewSession();
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return AxsHasEvent(@"final-recognition"); }, @"recognition before end");
    AxsPump(0.03);
    [session end];
    AxsNativeContext(session);
    AxsPump(0.05);
    AxsCheck(session.axsSubmitted.count == 0, @"closed session cannot publish");

    session = AxsNewSession();
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return AxsHasEvent(@"final-recognition"); }, @"recognition before new turn");
    AxsPump(0.03);
    [session assistantConnectionRequestWillStart:nil];
    AxsNativeContext(session);
    AxsPump(0.05);
    AxsCheck(session.axsSubmitted.count == 0, @"old result cannot enter next turn");
    [session end];

    session = AxsNewSession();
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return AxsHasEvent(@"final-recognition"); }, @"recognition before preference change");
    AxsPump(0.03);
    [[AxsProbeManager shared] preferencesChanged];
    AxsNativeContext(session);
    AxsPump(0.05);
    AxsCheck(session.axsSubmitted.count == 0, @"preference change invalidates pending result");
    [session end];
}

static void AxsTestRejection(void) {
    AFUISiriSession *session = AxsNewSession();
    AxsNativeContext(session);
    AxsRecognize(session, @"\u4eca\u5929\u5929\u6c14");
    AxsWait(^BOOL { return AxsHasEvent(@"final-recognition"); }, @"ordinary recognition");
    AxsPump(0.03);
    AxsCheck(session.axsSubmitted.count == 0, @"ordinary Siri request untouched");
    [session end];

    session = AxsNewSession();
    [session assistantConnection:nil speechRecognized:[NSObject new]];
    AxsWait(^BOOL { return AxsHasEvent(@"unsupported-recognition"); }, @"unknown type is diagnostic only");
    AxsCheck(session.axsSubmitted.count == 0, @"unknown type not submitted");
    [session end];

    session = AxsNewSession();
    [AxsConfig setValue:@NO forPreferenceKey:@"enabled"];
    AxsNativeContext(session);
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsPump(0.08);
    AxsCheck(session.axsSubmitted.count == 0 && !AxsHasEvent(@"final-recognition"), @"disabled probe is silent");
    [session end];

    session = AxsNewSession();
    [AxsConfig setValue:@"" forPreferenceKey:@"reply"];
    AxsNativeContext(session);
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return AxsHasEvent(@"invalid-reply"); }, @"empty reply rejected");
    AxsCheck(session.axsSubmitted.count == 0, @"empty reply not submitted");
    [session end];

    session = AxsNewSession();
    [AxsConfig setValue:[@"" stringByPaddingToLength:513 withString:@"x" startingAtIndex:0]
        forPreferenceKey:@"reply"];
    AxsNativeContext(session);
    AxsRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsWait(^BOOL { return AxsHasEvent(@"invalid-reply"); }, @"oversized reply rejected");
    AxsCheck(session.axsSubmitted.count == 0, @"oversized reply not submitted");
    [session end];
}

int main(void) {
    @autoreleasepool {
        AxsTestValues = [[AxsConfig defaults] mutableCopy];
        AxsTestEvents = [NSMutableArray array];
        AxsTestTriggers();
        AxsTestSubmission();
        AxsTestCancellation();
        AxsTestRejection();
        NSLog(@"PASS: %lu checks", (unsigned long)AxsChecks);
    }
    return 0;
}
