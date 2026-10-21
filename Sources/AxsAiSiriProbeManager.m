#import "AxsAiSiriProbeManager.h"
#import "AxsAiSiriPrivate.h"
#import "AxsAiSiriConfig.h"
#import "AxsAiSiriDiagnostics.h"
#import "AxsAiSiriTrigger.h"
#import "AxsAiSiriTranscript.h"
#import "AxsAiSiriDelegateProbe.h"
#import <objc/runtime.h>
#include <math.h>

static char AxsAiSiriStateKey;
static char AxsAiSiriSyntheticCommandKey;
static char AxsAiSiriNativeCommandContextKey;

@interface AxsAiSiriNativeCommandContext : NSObject
@property (weak) id session;
@property NSUInteger generation;
@end
@implementation AxsAiSiriNativeCommandContext
@end

@interface AxsAiSiriProbeState : NSObject
@property NSUInteger generation;
@property BOOL active;
@property BOOL finalSeen;
@property BOOL contextReady;
@property BOOL nativeViewsSeen;
@property BOOL nativeTurnAvailable;
@property BOOL nativeTimeValid;
@property BOOL published;
@property BOOL speak;
@property (copy) NSString *reply;
@property (strong) id turn;
@property double commandTime;
@property (copy) NSString *refId;
@property (copy) NSString *displayTarget;
@property (copy) NSString *dialogPhase;
@property (copy) NSString *responseMode;
@property NSUInteger preferenceEpoch;
@property (strong) NSMutableSet<NSString *> *commandPaths;
@property (copy) NSString *contextSource;
@property BOOL delegateDispatchSeen;
@property (weak) id presentationDelegate;
@property (strong) id deliveryCompletion;
@end
@implementation AxsAiSiriProbeState
@end

static AxsAiSiriProbeState *AxsAiSiriState(id session) {
    // Caller holds the recursive session monitor.
    AxsAiSiriProbeState *state = objc_getAssociatedObject(session, &AxsAiSiriStateKey);
    if (!state) {
        state = [AxsAiSiriProbeState new];
        state.active = YES;
        objc_setAssociatedObject(session, &AxsAiSiriStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL AxsAiSiriCopyPresentationMetadata(SAUIAddViews *views, AxsAiSiriProbeState *state, NSString *source) {
    @try {
        NSString *refId = [views.refId copy];
        NSString *displayTarget = [views.displayTarget copy];
        NSString *dialogPhase = [views.dialogPhase copy];
        NSString *responseMode = [views.responseMode copy];
        state.refId = refId;
        state.displayTarget = displayTarget;
        state.dialogPhase = dialogPhase;
        state.responseMode = responseMode;
        return YES;
    } @catch (NSException *exception) {
        AxsAiSiriRecord(@"context-exception", @{@"name": exception.name, @"path": source});
        return NO;
    }
}

@interface AxsAiSiriProbeManager ()
@property (strong) dispatch_queue_t worker;
@property NSUInteger epoch;
// Accessed only on worker; each explicit, time-limited capture is consumed once.
@property NSTimeInterval axsAiSiriConsumedCapture;
// Metadata-only deduplication, confined to worker.
@property (strong) NSMutableSet<NSString *> *delegateInventoryKeys;
@property (strong) NSMutableSet<NSString *> *delegateCallbackKeys;
@property (strong) NSMutableSet<NSString *> *bindingDiagnosticKeys;
@end

@implementation AxsAiSiriProbeManager
+ (instancetype)shared {
    static AxsAiSiriProbeManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [self new];
        manager.worker = dispatch_queue_create("com.axs.aisiri.probe", DISPATCH_QUEUE_SERIAL);
    });
    return manager;
}

#pragma mark - Lifecycle invalidation
- (void)preferencesChanged {
    @synchronized (self) { self.epoch++; }
    dispatch_async(self.worker, ^{
        [self.delegateInventoryKeys removeAllObjects];
        [self.delegateCallbackKeys removeAllObjects];
        [self.bindingDiagnosticKeys removeAllObjects];
    });
}

#pragma mark - Observed delegate route and diagnostics
- (void)recordBindingStage:(NSString *)stage reason:(NSString *)reason details:(NSDictionary *)details {
    // Adjust: snapshot every binding exit, including failures without a session.
    // Deduplicate on worker so hook threads never read preferences or perform IO.
    NSMutableDictionary *snapshot = [details mutableCopy] ?: [NSMutableDictionary dictionary];
    snapshot[@"stage"] = stage;
    snapshot[@"reason"] = reason;
    NSDictionary *entry = [snapshot copy];
    dispatch_async(self.worker, ^{
        if (![AxsAiSiriConfig new].enabled) return;
        if (!self.bindingDiagnosticKeys) self.bindingDiagnosticKeys = [NSMutableSet set];
        NSString *key = [NSString stringWithFormat:@"%@/%@", stage, reason];
        if ([self.bindingDiagnosticKeys containsObject:key] || self.bindingDiagnosticKeys.count >= 32) return;
        [self.bindingDiagnosticKeys addObject:key];
        AxsAiSiriRecord(@"delegate-binding", entry);
    });
}

- (void)recordDelegateInventory:(NSDictionary *)details {
    if (!details) return;
    dispatch_async(self.worker, ^{
        if (![AxsAiSiriConfig new].enabled) return;
        if (!self.delegateInventoryKeys) self.delegateInventoryKeys = [NSMutableSet set];
        NSString *key = [NSString stringWithFormat:@"%@/%@/%@", details[@"role"], details[@"class"], details[@"exception"]];
        if ([self.delegateInventoryKeys containsObject:key] || self.delegateInventoryKeys.count >= 8) return;
        [self.delegateInventoryKeys addObject:key];
        AxsAiSiriRecord(@"delegate-inventory", details);
    });
}

- (void)observeDelegateDispatchForSession:(id)session {
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        if (!state.active || state.delegateDispatchSeen) return;
        state.delegateDispatchSeen = YES;
    }
    dispatch_async(self.worker, ^{
        if ([AxsAiSiriConfig new].enabled) AxsAiSiriRecord(@"delegate-dispatch", @{});
    });
}

- (void)observeDelegate:(id)delegate selector:(NSString *)selector arguments:(NSArray *)arguments {
    NSMutableArray *classes = [NSMutableArray array];
    BOOL hasViews = NO;
    Class viewsClass = NSClassFromString(@"SAUIAddViews");
    for (id argument in arguments) {
        if (argument == NSNull.null) {
            [classes addObject:@"nil"];
            continue;
        }
        // Do not retain argument objects or completion blocks on the worker.
        [classes addObject:NSStringFromClass(object_getClass(argument))];
        if (viewsClass && [argument isKindOfClass:viewsClass]) {
            if (objc_getAssociatedObject(argument, &AxsAiSiriSyntheticCommandKey)) return;
            hasViews = YES;
        }
    }
    NSDictionary *details = @{
        @"class": NSStringFromClass(object_getClass(delegate)), @"selector": selector,
        @"argumentClasses": [classes copy], @"hasAddViews": @(hasViews),
        @"mainThread": @(NSThread.isMainThread)
    };
    dispatch_async(self.worker, ^{
        if (![AxsAiSiriConfig new].enabled) return;
        if (!self.delegateCallbackKeys) self.delegateCallbackKeys = [NSMutableSet set];
        NSString *key = [NSString stringWithFormat:@"%@/%@/%d", details[@"class"], selector, hasViews];
        if ([self.delegateCallbackKeys containsObject:key] || self.delegateCallbackKeys.count >= 24) return;
        [self.delegateCallbackKeys addObject:key];
        AxsAiSiriRecord(@"delegate-command-path", details);
    });
    // Adjust: the confirmed XPC addViews route has no turn/timestamp arguments.
    // Bind it only through a native command already received by this exact session.
    if (![selector isEqualToString:@"siriSessionDidReceiveAddViewsCommand:completion:"]) return;
    if (!NSThread.isMainThread) {
        [self recordBindingStage:@"callback" reason:@"not-main-thread" details:nil];
        return;
    }
    if (arguments.count != 2) {
        [self recordBindingStage:@"callback" reason:@"argument-count" details:@{@"count": @(arguments.count)}];
        return;
    }
    id command = arguments.firstObject;
    if (!hasViews || ![command isKindOfClass:viewsClass]) {
        [self recordBindingStage:@"callback" reason:@"not-add-views" details:nil];
        return;
    }
    AxsAiSiriNativeCommandContext *context = objc_getAssociatedObject(command, &AxsAiSiriNativeCommandContextKey);
    if (!context) {
        [self recordBindingStage:@"callback" reason:@"command-context-missing" details:nil];
        return;
    }
    AFUISiriSession *session = context.session;
    if (!session) {
        [self recordBindingStage:@"callback" reason:@"session-released" details:nil];
        return;
    }
    id currentDelegate = [session delegate];
    if (currentDelegate != delegate) {
        [self recordBindingStage:@"callback" reason:@"delegate-mismatch" details:@{
            @"currentDelegateClass": currentDelegate ? NSStringFromClass(object_getClass(currentDelegate)) : @"nil",
            @"callbackDelegateClass": NSStringFromClass(object_getClass(delegate))
        }];
        return;
    }
    id completion = AxsAiSiriIndependentCompletion(arguments[1]);
    if (!completion) {
        [self recordBindingStage:@"callback" reason:@"completion-unsupported" details:nil];
        dispatch_async(self.worker, ^{
            if ([AxsAiSiriConfig new].enabled) AxsAiSiriRecord(@"delegate-completion-unsupported", @{});
        });
        return;
    }
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        if (!state.active || state.generation != context.generation || state.published) {
            NSString *reason = !state.active ? @"session-inactive" :
                (state.generation != context.generation ? @"generation-mismatch" : @"already-published");
            [self recordBindingStage:@"callback" reason:reason details:nil];
            return;
        }
        if (!AxsAiSiriCopyPresentationMetadata(command, state, @"delegate-add-views")) {
            [self recordBindingStage:@"callback" reason:@"metadata-exception" details:nil];
            return;
        }
        state.presentationDelegate = delegate;
        state.deliveryCompletion = completion;
        state.contextReady = YES;
        state.contextSource = @"delegate-add-views";
        [self recordBindingStage:@"callback" reason:@"context-ready" details:@{@"replyPending": @(state.reply != nil)}];
    }
    __weak id weakSession = session;
    // Return through the native forwarding call before submitting our supplement.
    dispatch_async(dispatch_get_main_queue(), ^{
        id target = weakSession;
        if (target) [self tryPresentForSession:target];
        else [self recordBindingStage:@"scheduled" reason:@"session-released" details:nil];
    });
}

- (void)beginSession:(id)session {
    @synchronized (session) {
        AxsAiSiriProbeState *old = AxsAiSiriState(session);
        AxsAiSiriProbeState *fresh = [AxsAiSiriProbeState new];
        fresh.active = YES;
        fresh.generation = old.generation + 1;
        objc_setAssociatedObject(session, &AxsAiSiriStateKey, fresh, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)endSession:(id)session {
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        // Explain pending-result cancellation without logging any Siri content.
        if (state.active && state.finalSeen && !state.published) {
            NSDictionary *details = @{
                @"nativeViewsSeen": @(state.nativeViewsSeen),
                @"nativeContextAvailable": @(state.contextReady),
                @"replyPending": @(state.reply != nil)
            };
            dispatch_async(self.worker, ^{
                if ([AxsAiSiriConfig new].enabled) AxsAiSiriRecord(@"probe-session-ended", details);
            });
        }
        state.active = NO;
        state.generation++;
        state.reply = nil;
        state.turn = nil;
        state.presentationDelegate = nil;
        state.deliveryCompletion = nil;
    }
}

#pragma mark - Final recognition, never partial results
- (void)observeRecognition:(id)recognition session:(id)session {
    NSUInteger generation;
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        if (!state.active || state.finalSeen) return;
        state.finalSeen = YES;
        generation = state.generation;
    }
    NSUInteger epoch;
    @synchronized (self) { epoch = self.epoch; }
    __weak id weakSession = session;
    dispatch_async(self.worker, ^{
        @autoreleasepool {
            AxsAiSiriConfig *config = [AxsAiSiriConfig new];
            if (!config.enabled) return;
            NSString *prefix = config.prefix;
            NSString *prefixSource = [AxsAiSiriConfig axsAiSiriSourceForPreferenceKey:@"prefix"];
            NSString *className = recognition ? NSStringFromClass([recognition class]) : @"nil";
            NSString *transcript;
            NSString *transcriptPath = nil;
            // iOS 16.5 delivers SASSpeechRecognized, not necessarily AFSpeechRecognition.
            @try { transcript = AxsAiSiriExtractTranscript(recognition, &transcriptPath); }
            @catch (NSException *exception) {
                AxsAiSiriRecord(@"transcript-exception", @{@"name": exception.name});
                return;
            }
            if (!transcript.length) {
                AxsAiSiriRecord(transcriptPath ? @"invalid-transcript" : @"unsupported-recognition",
                    @{@"class": className, @"path": transcriptPath ?: @"unsupported"});
                return;
            }
            BOOL match = AxsAiSiriMatchesTrigger(transcript, prefix);
            AxsAiSiriRecord(@"final-recognition", @{
                @"class": className, @"path": transcriptPath,
                @"characters": @(transcript.length), @"prefixMatched": @(match),
                @"configuredPrefix": prefix, @"prefixSource": prefixSource
            });
            // Only a panel-confirmed, unexpired request can persist the next test text.
            id captureValue = [AxsAiSiriConfig valueForKey:@"transcriptCaptureUntil"];
            NSTimeInterval captureUntil = [captureValue isKindOfClass:NSNumber.class] ? [captureValue doubleValue] : 0;
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            if (captureUntil > now && captureUntil <= now + 125 &&
                captureUntil != self.axsAiSiriConsumedCapture) {
                self.axsAiSiriConsumedCapture = captureUntil;
                AxsAiSiriRecord(@"opt-in-test-transcript", @{
                    @"testText": transcript, @"configuredPrefix": prefix,
                    @"captureRequest": @(captureUntil), @"prefixMatched": @(match)
                });
            }
            if (!match) return;
            NSString *reply = [config.reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!reply.length || reply.length > 512) {
                AxsAiSiriRecord(@"invalid-reply", @{@"characters": @(reply.length)});
                return;
            }
            BOOL speak = config.speakReply;
            dispatch_async(dispatch_get_main_queue(), ^{
                id target = weakSession;
                if (!target) {
                    [self recordBindingStage:@"reply" reason:@"session-released" details:nil];
                    return;
                }
                @synchronized (target) {
                    AxsAiSiriProbeState *state = AxsAiSiriState(target);
                    if (!state.active || state.generation != generation) {
                        [self recordBindingStage:@"reply" reason:!state.active ? @"session-inactive" : @"generation-mismatch" details:nil];
                        return;
                    }
                    state.reply = reply;
                    state.speak = speak;
                    state.preferenceEpoch = epoch;
                }
                [self tryPresentForSession:target];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                id target = weakSession;
                if (!target) return;
                @synchronized (target) {
                    AxsAiSiriProbeState *state = AxsAiSiriState(target);
                    if (!state.active || state.generation != generation || state.published || !state.reply) return;
                    state.reply = nil;
                    AxsAiSiriRecord(@"probe-timeout", @{
                        @"nativeContextAvailable": @(state.contextReady),
                        @"nativeViewsSeen": @(state.nativeViewsSeen),
                        @"nativeTurnAvailable": @(state.nativeTurnAvailable),
                        @"nativeTimeValid": @(state.nativeTimeValid),
                        @"delegateDispatchSeen": @(state.delegateDispatchSeen),
                        @"commandPathsSeen": @(state.commandPaths.count)
                    });
                }
            });
        }
    });
}

#pragma mark - Reuse observed native ACE metadata
- (void)observeCommand:(id)command session:(id)session turn:(id)turn time:(double)time {
    [self observeCommand:command session:session turn:turn time:time source:@"public-execute"];
}

- (void)observeCommand:(id)command session:(id)session turn:(id)turn time:(double)time source:(NSString *)source {
    if (!command) return;
    if (objc_getAssociatedObject(command, &AxsAiSiriSyntheticCommandKey)) return;
    Class addViewsClass = NSClassFromString(@"SAUIAddViews");
    BOOL isViews = addViewsClass && [command isKindOfClass:addViewsClass];
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        if (!state.active) {
            if (isViews && [source isEqualToString:@"received-command"])
                [self recordBindingStage:@"receive" reason:@"session-inactive" details:nil];
            return;
        }
        // Bounded path/class summaries identify alternate routes, never payloads.
        if (!state.commandPaths) state.commandPaths = [NSMutableSet set];
        NSString *className = NSStringFromClass([command class]);
        NSString *key = [NSString stringWithFormat:@"%@/%@", source, className];
        if (state.commandPaths.count < 16 && ![state.commandPaths containsObject:key]) {
            [state.commandPaths addObject:key];
            NSDictionary *details = @{
                @"path": source, @"class": className, @"isAddViews": @(isViews),
                @"hasTurn": @(turn != nil), @"timeValid": @(isfinite(time))
            };
            // Snapshot events must survive a synchronous native session close.
            dispatch_async(self.worker, ^{
                if (![AxsAiSiriConfig new].enabled) return;
                AxsAiSiriRecord(@"native-command-path", details);
            });
        }
        if (!isViews) return;
        state.nativeViewsSeen = YES;
        if ([source isEqualToString:@"received-command"]) {
            AxsAiSiriNativeCommandContext *context = [AxsAiSiriNativeCommandContext new];
            context.session = session;
            context.generation = state.generation;
            objc_setAssociatedObject(command, &AxsAiSiriNativeCommandContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL linked = objc_getAssociatedObject(command, &AxsAiSiriNativeCommandContextKey) == context;
            [self recordBindingStage:@"receive" reason:linked ? @"command-linked" : @"association-failed"
                details:@{@"finalSeen": @(state.finalSeen)}];
        }
        state.nativeTurnAvailable |= turn != nil;
        state.nativeTimeValid |= isfinite(time);
        if (!turn || !isfinite(time)) return;
        // A reception-only observation must never erase usable execution metadata.
        if (state.presentationDelegate) return;
        if (!AxsAiSiriCopyPresentationMetadata(command, state, source)) return;
        state.turn = turn;
        state.commandTime = time;
        state.contextReady = YES;
        state.contextSource = source;
    }
    __weak id weakSession = session;
    dispatch_async(dispatch_get_main_queue(), ^{
        id target = weakSession;
        if (target) [self tryPresentForSession:target];
    });
}

- (void)tryPresentForSession:(AFUISiriSession *)session {
    NSAssert(NSThread.isMainThread, @"ACE presentation must run on the main thread");
    SAUIAddViews *command;
    id turn;
    double time = 0;
    NSUInteger generation = 0;
    NSUInteger epoch = 0;
    NSDictionary *details;
    id<AxsAiSiriAddViewsDelivery> presentationDelegate;
    id deliveryCompletion;
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        if (!state.active || !state.reply || !state.contextReady || state.published) {
            NSString *reason = !state.active ? @"session-inactive" : (state.published ? @"already-published" :
                (!state.reply ? @"reply-not-ready" : @"context-not-ready"));
            [self recordBindingStage:@"present" reason:reason details:nil];
            return;
        }
        @synchronized (self) {
            if (state.preferenceEpoch != self.epoch) {
                state.reply = nil;
                [self recordBindingStage:@"present" reason:@"preferences-changed" details:nil];
                return;
            }
        }
        Class commandClass = NSClassFromString(@"SAUIAddViews");
        Class utteranceClass = NSClassFromString(@"SAUIAssistantUtteranceView");
        BOOL delegateRoute = [state.contextSource isEqualToString:@"delegate-add-views"];
        presentationDelegate = state.presentationDelegate;
        deliveryCompletion = state.deliveryCompletion;
        if (![commandClass respondsToSelector:@selector(addViews)] ||
            ![utteranceClass respondsToSelector:@selector(assistantUtteranceView)] ||
            (delegateRoute && (!presentationDelegate || !deliveryCompletion || [session delegate] != presentationDelegate ||
                ![presentationDelegate respondsToSelector:@selector(siriSessionDidReceiveAddViewsCommand:completion:)])) ||
            (!delegateRoute && ![session respondsToSelector:@selector(performAceCommand:turnIdentifier:machAbsoluteTime:)])) {
            state.reply = nil;
            [self recordBindingStage:@"present" reason:@"presentation-unavailable" details:@{
                @"delegateRoute": @(delegateRoute), @"delegateAlive": @(presentationDelegate != nil),
                @"delegateMatches": @([session delegate] == presentationDelegate),
                @"completionReady": @(deliveryCompletion != nil)
            }];
            AxsAiSiriRecord(@"presentation-unavailable", @{});
            return;
        }
        // Mark before calling Siri: the hook re-enters synchronously for our command.
        state.published = YES;
        @try {
            SAUIAssistantUtteranceView *view = [(id)utteranceClass assistantUtteranceView];
            view.viewId = NSUUID.UUID.UUIDString;
            view.text = state.reply;
            view.speakableText = state.speak ? state.reply : nil;
            command = [(id)commandClass addViews];
            command.aceId = NSUUID.UUID.UUIDString;
            command.refId = state.refId;
            command.displayTarget = state.displayTarget;
            command.dialogPhase = state.dialogPhase;
            command.responseMode = state.responseMode;
            command.supplemental = YES;
            command.requiresResponse = NO;
            command.views = @[view];
            objc_setAssociatedObject(command, &AxsAiSiriSyntheticCommandKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            turn = state.turn;
            time = state.commandTime;
            generation = state.generation;
            epoch = state.preferenceEpoch;
            details = @{
                @"speechRequested": @(state.speak),
                @"hasRefId": @(state.refId.length > 0),
                @"characters": @(state.reply.length),
                @"contextSource": state.contextSource ?: @"unknown"
            };
        } @catch (NSException *exception) {
            AxsAiSiriRecord(@"presentation-exception", @{@"name": exception.name});
            command = nil;
        }
        state.reply = nil;
    }
    if (!command) return;
    @synchronized (session) {
        AxsAiSiriProbeState *state = AxsAiSiriState(session);
        if (!state.active || state.generation != generation) {
            [self recordBindingStage:@"submit" reason:!state.active ? @"session-inactive" : @"generation-mismatch" details:nil];
            return;
        }
    }
    @synchronized (self) {
        if (epoch != self.epoch) {
            [self recordBindingStage:@"submit" reason:@"preferences-changed" details:nil];
            return;
        }
    }
    // Do not hold our monitor across system code or delegate callbacks.
    @try {
        if (presentationDelegate) {
            if ([session delegate] != presentationDelegate) {
                [self recordBindingStage:@"submit" reason:@"delegate-mismatch" details:nil];
                return;
            }
            // The signature-checked reply block owns no session or native completion.
            // Acknowledgements are not proof of UI rendering.
            [presentationDelegate siriSessionDidReceiveAddViewsCommand:command completion:deliveryCompletion];
        } else {
            [session performAceCommand:command turnIdentifier:turn machAbsoluteTime:time];
        }
        AxsAiSiriRecord(@"answer-submitted", details);
    } @catch (NSException *exception) {
        AxsAiSiriRecord(@"presentation-exception", @{@"name": exception.name});
    }
}
@end
