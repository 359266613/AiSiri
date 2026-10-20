#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#include <atomic>
#import "AxsPrivate.h"
#import "AxsConfig.h"
#import "AxsDiagnostics.h"
#import "AxsProbeManager.h"

%group AxsSiriProbe
%hook AFUISiriSession

- (void)assistantConnection:(id)connection speechRecognized:(id)recognized {
    %orig;
    // Preference reads and transcript processing run on the probe worker.
    [[AxsProbeManager shared] observeRecognition:recognized session:self];
}

- (void)assistantConnectionRequestWillStart:(id)connection {
    [[AxsProbeManager shared] beginSession:self];
    %orig;
}

- (void)performAceCommand:(id)command turnIdentifier:(id)turn machAbsoluteTime:(double)time {
    %orig;
    [[AxsProbeManager shared] observeCommand:command session:self turn:turn time:time];
}

- (void)assistantConnectionDismissAssistant:(id)connection {
    [[AxsProbeManager shared] endSession:self];
    %orig;
}

- (void)end {
    [[AxsProbeManager shared] endSession:self];
    %orig;
}

- (void)endForReason:(long long)reason {
    [[AxsProbeManager shared] endSession:self];
    %orig;
}

%end
%end

#pragma mark - Install only when the class and every required method exist
static BOOL AxsInstalled;
static std::atomic<bool> AxsInstallScheduled(false);

static void AxsInstallIfAvailable(void) {
    if (AxsInstalled) return;
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
            AxsRecord(@"hook-method-missing", @{@"selector": name});
            return;
        }
    }
    %init(AxsSiriProbe, AFUISiriSession = cls);
    AxsInstalled = YES;
    AxsRecord(@"hooks-installed", @{@"class": NSStringFromClass(cls)});
}

static void AxsImageLoaded(const struct mach_header *header, intptr_t slide) {
    // Never look up ObjC classes or initialize hooks while dyld holds its lock.
    if (AxsInstallScheduled.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        AxsInstallScheduled.store(false);
        AxsInstallIfAvailable();
    });
}

static void AxsPreferencesDidChange(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[AxsProbeManager shared] preferencesChanged];
}

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion != 16 || version.minorVersion != 5) return;
        AxsRecord(@"probe-loaded", @{
            @"system": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown"
        });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            AxsPreferencesDidChange, (__bridge CFStringRef)AxsPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        _dyld_register_func_for_add_image(AxsImageLoaded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (!AxsInstalled) AxsRecord(@"session-class-not-hooked", @{});
        });
    }
}
