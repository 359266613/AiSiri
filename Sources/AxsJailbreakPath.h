#pragma once
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// User data stays outside the rootless package prefix. Never scan for jbroot.
static inline NSString *AxsIsolatedUserPath(NSString *path) {
    typedef const char *(*AxsConvertPath)(const char *);
    static AxsConvertPath convert;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("libroothide.dylib", RTLD_LAZY | RTLD_LOCAL);
        convert = (AxsConvertPath)dlsym(handle ?: RTLD_DEFAULT, "jbroot");
    });
    if (!convert) return nil;
    const char *value = convert(path.fileSystemRepresentation);
    return value && value[0] ? [NSString stringWithUTF8String:value] : nil;
}

static inline NSArray<NSString *> *AxsPreferencesPaths(void) {
    NSString *plain = @"/var/mobile/Library/Preferences/com.axs.aisiri.plist";
    NSString *isolated = AxsIsolatedUserPath(plain);
    NSMutableArray *paths = [NSMutableArray array];
    if (isolated.length) [paths addObject:isolated];
    [paths addObject:@"/var/jb/var/mobile/Library/Preferences/com.axs.aisiri.plist"];
    if (![paths containsObject:plain]) [paths addObject:plain];
    return paths;
}

static inline NSString *AxsDiagnosticDirectory(void) {
    NSString *plain = @"/var/mobile/Library/Logs/AiSiri";
    return AxsIsolatedUserPath(plain) ?: plain;
}
