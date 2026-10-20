#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <atomic>
#include <math.h>
#import "AxsAiSiriPrivate.h"
#import "AxsAiSiriConfig.h"
#import "AxsAiSiriDiagnostics.h"
#import "AxsAiSiriProbeManager.h"
#import "AxsAiSiriDelegateProbe.h"

// Read only declared accessors; never traverse private ivars or invoke candidates.
static void AxsAiSiriPrepareSessionDelegates(AFUISiriSession *session) {
    @try {
        if ([session respondsToSelector:@selector(delegate)])
            AxsAiSiriPrepareDelegateProbe([session delegate], @"delegate", MSHookMessageEx);
        if ([session respondsToSelector:@selector(localDelegate)])
            AxsAiSiriPrepareDelegateProbe([session localDelegate], @"localDelegate", MSHookMessageEx);
    } @catch (NSException *exception) {
        [[AxsAiSiriProbeManager shared] recordDelegateInventory:@{@"exception": exception.name}];
    }
}

%group AxsAiSiriSiriProbe
%hook AFUISiriSession

- (void)assistantConnection:(id)connection speechRecognized:(id)recognized {
    %orig;
    // Preference reads and transcript processing run on the probe worker.
    [[AxsAiSiriProbeManager shared] observeRecognition:recognized session:self];
}

- (void)assistantConnectionRequestWillStart:(id)connection {
    [[AxsAiSiriProbeManager shared] beginSession:self];
    %orig;
}

- (void)performAceCommand:(id)command turnIdentifier:(id)turn machAbsoluteTime:(double)time {
    // Capture before native forwarding can synchronously end or replace the turn.
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:turn time:time source:@"public-execute"];
    %orig;
}

- (void)assistantConnectionDismissAssistant:(id)connection {
    [[AxsAiSiriProbeManager shared] endSession:self];
    %orig;
}

- (void)end {
    [[AxsAiSiriProbeManager shared] endSession:self];
    %orig;
}

- (void)endForReason:(long long)reason {
    [[AxsAiSiriProbeManager shared] endSession:self];
    %orig;
}

%end
%end

// Optional paths are independent: a missing selector must not disable core hooks.
%group AxsAiSiriReceivedProbe
%hook AFUISiriSession
- (void)assistantConnection:(id)connection receivedCommand:(id)command completion:(id)completion {
    AxsAiSiriPrepareSessionDelegates(self);
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:nil time:NAN source:@"received-command"];
    %orig;
}
%end
%end

%group AxsAiSiriDelegateDispatchProbe
%hook AFUISiriSession
- (void)_performBlockWithDelegate:(id)block {
    AxsAiSiriPrepareSessionDelegates(self);
    [[AxsAiSiriProbeManager shared] observeDelegateDispatchForSession:self];
    // The dump does not describe the block ABI. Do not wrap or invoke it.
    %orig;
}
%end
%end

%group AxsAiSiriInternalProbe
%hook AFUISiriSession
- (void)_performAceCommand:(id)command turnIdentifier:(id)turn machAbsoluteTime:(double)time conflictHandler:(id)handler {
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:turn time:time source:@"internal-execute"];
    %orig;
}
%end
%end

%group AxsAiSiriBatchProbe
%hook AFUISiriSession
- (void)_performAceCommands:(id)commands {
    // The dump does not guarantee an array; never enumerate arbitrary objects.
    if ([commands isKindOfClass:NSArray.class]) {
        NSUInteger count = 0;
        for (id command in commands) {
            if (count++ >= 32) break;
            [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:nil time:NAN source:@"batch-execute"];
        }
    }
    %orig;
}
%end
%end

#pragma mark - AiSiri guarded hook installation
static BOOL AxsAiSiriInstalled;
static std::atomic<bool> AxsAiSiriInstallScheduled(false);

static void AxsAiSiriInstallIfAvailable(void) {
    if (AxsAiSiriInstalled) return;
    Class cls = NSClassFromString(@"AFUISiriSession");
    if (!cls) return;
    NSArray<NSString *> *methods = @[
        @"assistantConnection:speechRecognized:",
        @"assistantConnectionRequestWillStart:",
        @"performAceCommand:turnIdentifier:machAbsoluteTime:",
        @"assistantConnectionDismissAssistant:", @"end", @"endForReason:"
    ];
    for (NSString *name in methods) {
        if (!class_getInstanceMethod(cls, NSSelectorFromString(name))) {
            AxsAiSiriRecord(@"hook-method-missing", @{@"selector": name});
            return;
        }
    }
    %init(AxsAiSiriSiriProbe, AFUISiriSession = cls);
    if (class_getInstanceMethod(cls, @selector(assistantConnection:receivedCommand:completion:))) {
        %init(AxsAiSiriReceivedProbe, AFUISiriSession = cls);
        AxsAiSiriRecord(@"command-hook-installed", @{@"path": @"received-command"});
    } else {
        AxsAiSiriRecord(@"command-hook-unavailable", @{@"path": @"received-command"});
    }
    if (class_getInstanceMethod(cls, @selector(_performAceCommand:turnIdentifier:machAbsoluteTime:conflictHandler:))) {
        %init(AxsAiSiriInternalProbe, AFUISiriSession = cls);
        AxsAiSiriRecord(@"command-hook-installed", @{@"path": @"internal-execute"});
    } else {
        AxsAiSiriRecord(@"command-hook-unavailable", @{@"path": @"internal-execute"});
    }
    if (class_getInstanceMethod(cls, @selector(_performAceCommands:))) {
        %init(AxsAiSiriBatchProbe, AFUISiriSession = cls);
        AxsAiSiriRecord(@"command-hook-installed", @{@"path": @"batch-execute"});
    } else {
        AxsAiSiriRecord(@"command-hook-unavailable", @{@"path": @"batch-execute"});
    }
    if (class_getInstanceMethod(cls, @selector(_performBlockWithDelegate:))) {
        %init(AxsAiSiriDelegateDispatchProbe, AFUISiriSession = cls);
        AxsAiSiriRecord(@"command-hook-installed", @{@"path": @"delegate-dispatch"});
    } else {
        AxsAiSiriRecord(@"command-hook-unavailable", @{@"path": @"delegate-dispatch"});
    }
    AxsAiSiriInstalled = YES;
    AxsAiSiriRecord(@"hooks-installed", @{@"class": NSStringFromClass(cls)});
}

static void AxsAiSiriImageLoaded(const struct mach_header *header, intptr_t slide) {
    // Never look up ObjC classes or initialize hooks while dyld holds its lock.
    if (AxsAiSiriInstallScheduled.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        AxsAiSiriInstallScheduled.store(false);
        AxsAiSiriInstallIfAvailable();
    });
}

static void AxsAiSiriPreferencesDidChange(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[AxsAiSiriProbeManager shared] preferencesChanged];
}

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion != 16 || version.minorVersion != 5) return;
        AxsAiSiriRecord(@"probe-loaded", @{
            @"system": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown"
        });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            AxsAiSiriPreferencesDidChange, (__bridge CFStringRef)AxsAiSiriPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        _dyld_register_func_for_add_image(AxsAiSiriImageLoaded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (!AxsAiSiriInstalled) AxsAiSiriRecord(@"session-class-not-hooked", @{});
        });
    }
}
