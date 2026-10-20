#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#include <atomic>
#import "AxsAiSiriPrivate.h"
#import "AxsAiSiriConfig.h"
#import "AxsAiSiriDiagnostics.h"
#import "AxsAiSiriProbeManager.h"

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
    %orig;
    [[AxsAiSiriProbeManager shared] observeCommand:command session:self turn:turn time:time];
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
