#import <Foundation/Foundation.h>
#import "AxsAiSiriPrivate.h"
#import "AxsAiSiriConfig.h"
#import "AxsAiSiriDiagnostics.h"
#import "AxsAiSiriProbeManager.h"
#import "AxsAiSiriTrigger.h"
#import "AxsAiSiriTranscript.h"
#include <stdlib.h>
#include <math.h>

static NSMutableDictionary *AxsAiSiriTestValues;
static NSMutableArray *AxsAiSiriTestEvents;
static NSUInteger AxsAiSiriChecks;

static void AxsAiSiriCheck(BOOL condition, NSString *message) {
    AxsAiSiriChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

// No preferences, files, audio, network, hooks or system Siri are used by this test.
@implementation AxsAiSiriConfig
+ (NSDictionary *)defaults {
    return @{@"enabled": @YES, @"speakReply": @NO, @"prefix": @"\u95eeAI", @"reply": @"Local probe."};
}
+ (id)valueForKey:(NSString *)key {
    @synchronized (self) { return AxsAiSiriTestValues[key]; }
}
+ (BOOL)setValue:(id)value forPreferenceKey:(NSString *)key {
    @synchronized (self) { AxsAiSiriTestValues[key] = value; }
    return YES;
}
+ (BOOL)registerDefaults { return YES; }
+ (NSString *)axsAiSiriSourceForPreferenceKey:(NSString *)key { return @"test-fixture"; }
- (BOOL)enabled { return [[AxsAiSiriConfig valueForKey:@"enabled"] boolValue]; }
- (BOOL)speakReply { return [[AxsAiSiriConfig valueForKey:@"speakReply"] boolValue]; }
- (NSString *)prefix { return [AxsAiSiriConfig valueForKey:@"prefix"]; }
- (NSString *)reply { return [AxsAiSiriConfig valueForKey:@"reply"]; }
@end

void AxsAiSiriRecord(NSString *event, NSDictionary *details) {
    @synchronized (AxsAiSiriTestEvents) { [AxsAiSiriTestEvents addObject:event]; }
}
NSString *AxsAiSiriReadDiagnostics(void) { return @"test"; }

@implementation SAUIAddViews
+ (instancetype)addViews { return [self new]; }
@end
@implementation SAUIAssistantUtteranceView
+ (instancetype)assistantUtteranceView { return [self new]; }
@end

@interface AxsAiSiriTestRecognition : NSObject
@property (copy) NSString *transcript;
- (id)oneBestTranscript;
@end
@implementation AxsAiSiriTestRecognition
- (id)oneBestTranscript { return self.transcript; }
@end

// ACE-shaped fixtures use only selectors declared by the supplied 16.5 headers.
@interface AxsAiSiriTestACENode : NSObject
@property (strong) id recognition;
@property (copy) NSArray *phrases;
@property (copy) NSArray *interpretations;
@property (copy) NSArray *tokens;
@property (copy) NSString *text;
@property BOOL removeSpaceBefore;
@property BOOL removeSpaceAfter;
@property BOOL addSpaceAfter;
@end
@implementation AxsAiSiriTestACENode
@end

static AxsAiSiriTestACENode *AxsAiSiriACEToken(NSString *text, BOOL before, BOOL after) {
    AxsAiSiriTestACENode *token = [AxsAiSiriTestACENode new];
    token.text = text;
    token.removeSpaceBefore = before;
    token.removeSpaceAfter = after;
    return token;
}

static AxsAiSiriTestACENode *AxsAiSiriACEPhrase(NSArray *tokens) {
    AxsAiSiriTestACENode *interpretation = [AxsAiSiriTestACENode new];
    interpretation.tokens = tokens;
    AxsAiSiriTestACENode *phrase = [AxsAiSiriTestACENode new];
    phrase.interpretations = @[interpretation];
    return phrase;
}

static AxsAiSiriTestACENode *AxsAiSiriACEResult(NSArray *phrases) {
    AxsAiSiriTestACENode *recognition = [AxsAiSiriTestACENode new];
    recognition.phrases = phrases;
    AxsAiSiriTestACENode *result = [AxsAiSiriTestACENode new];
    result.recognition = recognition;
    return result;
}

@interface AFUISiriSession ()
@property (strong) NSMutableArray *axsAiSiriSubmitted;
@end
@implementation AFUISiriSession
- (instancetype)init {
    self = [super init];
    if (self) _axsAiSiriSubmitted = [NSMutableArray array];
    return self;
}
- (void)assistantConnection:(id)connection speechRecognized:(id)recognized {
    [[AxsAiSiriProbeManager shared] observeRecognition:recognized session:self];
}
- (void)assistantConnectionRequestWillStart:(id)connection {
    [[AxsAiSiriProbeManager shared] beginSession:self];
}
- (void)assistantConnectionDismissAssistant:(id)connection { [self end]; }
- (void)end { [[AxsAiSiriProbeManager shared] endSession:self]; }
- (void)endForReason:(long long)reason { [self end]; }
- (void)assistantConnection:(id)connection receivedCommand:(id)command completion:(id)completion {
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:nil time:NAN source:@"received-command"];
}
- (void)_performAceCommand:(id)command turnIdentifier:(id)identifier machAbsoluteTime:(double)time conflictHandler:(id)handler {
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:identifier time:time source:@"internal-execute"];
}
- (void)_performAceCommands:(id)commands {
    if (![commands isKindOfClass:NSArray.class]) return;
    for (id command in commands) {
        [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:nil time:NAN source:@"batch-execute"];
    }
}
- (void)performAceCommand:(id)command turnIdentifier:(id)identifier machAbsoluteTime:(double)time {
    AxsAiSiriCheck(NSThread.isMainThread, @"submission on main thread");
    AxsAiSiriCheck([identifier isEqual:@"native-turn"], @"reuse native turn");
    AxsAiSiriCheck(time == 123.5, @"reuse native timestamp");
    [self.axsAiSiriSubmitted addObject:command];
    // Simulate the production post-hook to exercise recursion suppression.
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:identifier time:time];
}
@end

static BOOL AxsAiSiriHasEvent(NSString *event) {
    @synchronized (AxsAiSiriTestEvents) { return [AxsAiSiriTestEvents containsObject:event]; }
}

static void AxsAiSiriPump(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
        [NSThread sleepForTimeInterval:0.001];
    }
}

static void AxsAiSiriWait(BOOL (^predicate)(void), NSString *message) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!predicate() && deadline.timeIntervalSinceNow > 0) AxsAiSiriPump(0.005);
    AxsAiSiriCheck(predicate(), message);
}

static AFUISiriSession *AxsAiSiriNewSession(void) {
    [[AxsAiSiriProbeManager shared] preferencesChanged];
    @synchronized (AxsAiSiriConfig.class) { AxsAiSiriTestValues = [[AxsAiSiriConfig defaults] mutableCopy]; }
    @synchronized (AxsAiSiriTestEvents) { [AxsAiSiriTestEvents removeAllObjects]; }
    AFUISiriSession *session = [AFUISiriSession new];
    [session assistantConnectionRequestWillStart:nil];
    return session;
}

static void AxsAiSiriRecognize(AFUISiriSession *session, NSString *text) {
    AxsAiSiriTestRecognition *recognition = [AxsAiSiriTestRecognition new];
    recognition.transcript = text;
    [session assistantConnection:nil speechRecognized:recognition];
}

static void AxsAiSiriNativeContext(AFUISiriSession *session) {
    SAUIAddViews *native = [SAUIAddViews addViews];
    native.refId = @"native-ref";
    native.displayTarget = @"Primary";
    native.dialogPhase = @"Summary";
    [[AxsAiSiriProbeManager shared] observeCommand:native session:session turn:@"native-turn" time:123.5];
}

static void AxsAiSiriTestTriggers(void) {
    AxsAiSiriCheck(AxsAiSiriMatchesTrigger(@"\u95eeAI\u4f60\u597d", @"\u95eeAI"), @"Chinese trigger");
    AxsAiSiriCheck(AxsAiSiriMatchesTrigger(@" \u95ee A I\uFF0C\u4f60\u597d ", @"\u95eeAI"), @"ASR spaces");
    AxsAiSiriCheck(AxsAiSiriMatchesTrigger(@"\u95ee\uFF21\uFF29\u4f60\u597d", @"\u95eeAI"), @"full-width letters");
    AxsAiSiriCheck(AxsAiSiriMatchesTrigger(@"Ask AI explain this", @"ask ai"), @"case-insensitive word boundary");
    AxsAiSiriCheck(AxsAiSiriMatchesTrigger(@"Ask A I: explain", @"ask ai"), @"spaced English prefix");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(@"ask aioli", @"ask ai"), @"reject partial English word");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(@"hello ask ai", @"ask ai"), @"prefix only");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(@"hello", @""), @"empty prefix");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(@"hello", @"  "), @"whitespace prefix");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(@"\u95eeAI", @"\u95eeAI"), @"bare prefix");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(@"\u95eeAI:  ", @"\u95eeAI"), @"punctuation-only question");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(nil, @"ask ai"), @"nil transcript");
}

static void AxsAiSiriTestACEExtraction(void) {
    AxsAiSiriTestACENode *phrase = AxsAiSiriACEPhrase(@[
        AxsAiSiriACEToken(@"\u95ee", NO, YES),
        AxsAiSiriACEToken(@"AI", NO, NO),
        AxsAiSiriACEToken(@"\uFF0C", YES, YES),
        AxsAiSiriACEToken(@"\u4f60\u597d", NO, NO)
    ]);
    AxsAiSiriTestACENode *result = AxsAiSiriACEResult(@[phrase]);
    NSString *path = nil;
    NSString *text = AxsAiSiriExtractTranscript(result, &path);
    AxsAiSiriCheck([text isEqual:@"\u95eeAI\uFF0C\u4f60\u597d"], @"ACE token spacing flags");
    AxsAiSiriCheck([path isEqual:@"ace-first-interpretation"], @"ACE path diagnostics");
    AxsAiSiriCheck(AxsAiSiriMatchesTrigger(text, @"\u95eeAI"), @"ACE text triggers probe");

    AxsAiSiriTestACENode *ordinary = AxsAiSiriACEPhrase(@[AxsAiSiriACEToken(@"weather", NO, NO)]);
    ordinary.interpretations = @[ordinary.interpretations.firstObject, phrase.interpretations.firstObject];
    text = AxsAiSiriExtractTranscript(AxsAiSiriACEResult(@[ordinary]), NULL);
    AxsAiSiriCheck([text isEqual:@"weather"], @"ignore alternate interpretations");
    AxsAiSiriCheck(!AxsAiSiriMatchesTrigger(text, @"\u95eeAI"), @"alternate candidate cannot trigger");

    text = AxsAiSiriExtractTranscript(AxsAiSiriACEResult(@[
        AxsAiSiriACEPhrase(@[AxsAiSiriACEToken(@"Ask", NO, NO)]),
        AxsAiSiriACEPhrase(@[AxsAiSiriACEToken(@"AI", NO, NO), AxsAiSiriACEToken(@"hello", NO, NO)])
    ]), NULL);
    AxsAiSiriCheck([text isEqual:@"Ask AI hello"], @"join multiple ACE phrases");
    AxsAiSiriCheck(!AxsAiSiriExtractTranscript(AxsAiSiriACEResult(@[]), NULL), @"empty ACE result");
    AxsAiSiriCheck(!AxsAiSiriExtractTranscript(AxsAiSiriACEResult(@[[NSObject new]]), NULL), @"invalid ACE phrase");
    AxsAiSiriCheck(!AxsAiSiriExtractTranscript(AxsAiSiriACEResult(@[
        AxsAiSiriACEPhrase(@[AxsAiSiriACEToken(nil, NO, NO)])
    ]), NULL), @"invalid ACE token");
    AxsAiSiriCheck(!AxsAiSiriExtractTranscript([NSObject new], &path) && !path, @"unsupported shape");

    AFUISiriSession *session = AxsAiSiriNewSession();
    AxsAiSiriNativeContext(session);
    [session assistantConnection:nil speechRecognized:result];
    AxsAiSiriWait(^BOOL { return session.axsAiSiriSubmitted.count == 1; }, @"ACE recognition submits fixed reply");
    [session end];
}

static void AxsAiSiriTestSubmission(void) {
    AFUISiriSession *session = AxsAiSiriNewSession();
    AxsAiSiriNativeContext(session);
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return session.axsAiSiriSubmitted.count == 1; }, @"submit fixed reply");
    SAUIAddViews *command = session.axsAiSiriSubmitted.firstObject;
    SAUIAssistantUtteranceView *view = command.views.firstObject;
    AxsAiSiriCheck([view.text isEqual:@"Local probe."], @"fixed text");
    AxsAiSiriCheck(view.speakableText == nil, @"speech off by default");
    AxsAiSiriCheck([command.refId isEqual:@"native-ref"], @"reuse native refId");
    AxsAiSiriCheck(command.supplemental && !command.requiresResponse, @"nonblocking supplemental reply");
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriNativeContext(session);
    AxsAiSiriPump(0.05);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 1, @"one submission per turn; no recursion");
    [session end];

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:@YES forPreferenceKey:@"speakReply"];
    AxsAiSiriNativeContext(session);
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return session.axsAiSiriSubmitted.count == 1; }, @"submit speech request");
    command = session.axsAiSiriSubmitted.firstObject;
    view = command.views.firstObject;
    AxsAiSiriCheck([view.speakableText isEqual:view.text], @"speech text opt-in");
    [session end];

    session = AxsAiSiriNewSession();
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"recognition without context");
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"never fabricate native context");
    [[AxsAiSiriProbeManager shared] observeCommand:[SAUIAddViews addViews] session:session turn:nil time:0];
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"nil native turn is not guessed");
    AxsAiSiriNativeContext(session);
    AxsAiSiriWait(^BOOL { return session.axsAiSiriSubmitted.count == 1; }, @"wait for real native context");
    [session end];
}

static void AxsAiSiriTestCancellation(void) {
    AFUISiriSession *session = AxsAiSiriNewSession();
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"recognition before end");
    AxsAiSiriPump(0.03);
    [session end];
    AxsAiSiriNativeContext(session);
    AxsAiSiriPump(0.05);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"closed session cannot publish");

    session = AxsAiSiriNewSession();
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"recognition before new turn");
    AxsAiSiriPump(0.03);
    [session assistantConnectionRequestWillStart:nil];
    AxsAiSiriNativeContext(session);
    AxsAiSiriPump(0.05);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"old result cannot enter next turn");
    [session end];

    session = AxsAiSiriNewSession();
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"recognition before preference change");
    AxsAiSiriPump(0.03);
    [[AxsAiSiriProbeManager shared] preferencesChanged];
    AxsAiSiriNativeContext(session);
    AxsAiSiriPump(0.05);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"preference change invalidates pending result");
    [session end];
}

static void AxsAiSiriTestCommandPaths(void) {
    AFUISiriSession *session = AxsAiSiriNewSession();
    SAUIAddViews *native = [SAUIAddViews addViews];
    native.refId = @"native-ref";
    [session assistantConnection:nil receivedCommand:native completion:nil];
    [session _performAceCommands:@[native]];
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"received path recognition");
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(AxsAiSiriHasEvent(@"native-command-path"), @"command paths diagnosed");
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"received and batch paths never invent context");
    [session _performAceCommand:native turnIdentifier:@"native-turn" machAbsoluteTime:NAN conflictHandler:nil];
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"nonfinite execution time rejected");
    [session _performAceCommand:native turnIdentifier:@"native-turn" machAbsoluteTime:123.5 conflictHandler:nil];
    // These arrive before the main-queue presentation and cannot erase its context.
    [session assistantConnection:nil receivedCommand:native completion:nil];
    [session _performAceCommands:@[native]];
    AxsAiSiriWait(^BOOL { return session.axsAiSiriSubmitted.count == 1; }, @"internal path supplies real context");
    SAUIAddViews *submitted = session.axsAiSiriSubmitted.firstObject;
    AxsAiSiriCheck([submitted.refId isEqual:@"native-ref"], @"internal context preserves view metadata");
    [session _performAceCommand:native turnIdentifier:@"native-turn" machAbsoluteTime:123.5 conflictHandler:nil];
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 1, @"multiple paths cannot duplicate submission");
    [session end];

    session = AxsAiSiriNewSession();
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"pending recognition before close");
    AxsAiSiriPump(0.03);
    [session end];
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"probe-session-ended"); }, @"pending cancellation has diagnostics");
    [session _performAceCommand:native turnIdentifier:@"native-turn" machAbsoluteTime:123.5 conflictHandler:nil];
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"internal path respects ended session");

    session = AxsAiSiriNewSession();
    [session assistantConnection:nil receivedCommand:[NSObject new] completion:nil];
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    [session end];
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"probe-session-ended"); }, @"early close is diagnosed before reply is queued");
    AxsAiSiriCheck(AxsAiSiriHasEvent(@"native-command-path"), @"path snapshot survives synchronous session close");

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:@NO forPreferenceKey:@"enabled"];
    [session assistantConnection:nil receivedCommand:[NSObject new] completion:nil];
    AxsAiSiriPump(0.05);
    AxsAiSiriCheck(!AxsAiSiriHasEvent(@"native-command-path"), @"path diagnostics respect disabled preference");
    [session end];
}

static void AxsAiSiriTestRejection(void) {
    AFUISiriSession *session = AxsAiSiriNewSession();
    AxsAiSiriNativeContext(session);
    AxsAiSiriRecognize(session, @"\u4eca\u5929\u5929\u6c14");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"ordinary recognition");
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"ordinary Siri request untouched");
    [session end];

    session = AxsAiSiriNewSession();
    [session assistantConnection:nil speechRecognized:[NSObject new]];
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"unsupported-recognition"); }, @"unknown type is diagnostic only");
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"unknown type not submitted");
    [session end];

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:@NO forPreferenceKey:@"enabled"];
    AxsAiSiriNativeContext(session);
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriPump(0.08);
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0 && !AxsAiSiriHasEvent(@"final-recognition"), @"disabled probe is silent");
    [session end];

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:@"" forPreferenceKey:@"reply"];
    AxsAiSiriNativeContext(session);
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"invalid-reply"); }, @"empty reply rejected");
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"empty reply not submitted");
    [session end];

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:[@"" stringByPaddingToLength:513 withString:@"x" startingAtIndex:0]
        forPreferenceKey:@"reply"];
    AxsAiSiriNativeContext(session);
    AxsAiSiriRecognize(session, @"\u95eeAI\u4f60\u597d");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"invalid-reply"); }, @"oversized reply rejected");
    AxsAiSiriCheck(session.axsAiSiriSubmitted.count == 0, @"oversized reply not submitted");
    [session end];
}

static void AxsAiSiriTestOptInCapture(void) {
    AFUISiriSession *session = AxsAiSiriNewSession();
    AxsAiSiriRecognize(session, @"ordinary test");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"default diagnostic completed");
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(!AxsAiSiriHasEvent(@"opt-in-test-transcript"), @"no text capture by default");
    [session end];

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:@(NSDate.date.timeIntervalSince1970 + 120)
        forPreferenceKey:@"transcriptCaptureUntil"];
    AxsAiSiriRecognize(session, @"ordinary test");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"opt-in-test-transcript"); }, @"explicit capture works on unmatched question");
    [session assistantConnectionRequestWillStart:nil];
    AxsAiSiriRecognize(session, @"second test");
    AxsAiSiriPump(0.08);
    NSUInteger count = 0;
    @synchronized (AxsAiSiriTestEvents) {
        for (NSString *event in AxsAiSiriTestEvents) {
            if ([event isEqual:@"opt-in-test-transcript"]) count++;
        }
    }
    AxsAiSiriCheck(count == 1, @"capture consumed once per process");
    [session end];

    session = AxsAiSiriNewSession();
    [AxsAiSiriConfig setValue:@(NSDate.date.timeIntervalSince1970 - 1)
        forPreferenceKey:@"transcriptCaptureUntil"];
    AxsAiSiriRecognize(session, @"expired test");
    AxsAiSiriWait(^BOOL { return AxsAiSiriHasEvent(@"final-recognition"); }, @"expired capture recognition");
    AxsAiSiriPump(0.03);
    AxsAiSiriCheck(!AxsAiSiriHasEvent(@"opt-in-test-transcript"), @"expired capture stays off");
    [session end];
}

int main(void) {
    @autoreleasepool {
        AxsAiSiriTestValues = [[AxsAiSiriConfig defaults] mutableCopy];
        AxsAiSiriTestEvents = [NSMutableArray array];
        AxsAiSiriTestTriggers();
        AxsAiSiriTestACEExtraction();
        AxsAiSiriTestSubmission();
        AxsAiSiriTestCancellation();
        AxsAiSiriTestCommandPaths();
        AxsAiSiriTestRejection();
        AxsAiSiriTestOptInCapture();
        NSLog(@"PASS: %lu checks", (unsigned long)AxsAiSiriChecks);
    }
    return 0;
}
