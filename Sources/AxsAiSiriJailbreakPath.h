#pragma once
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// User data stays outside the rootless package prefix. Never scan for jbroot.
static inline NSString *AxsAiSiriIsolatedUserPath(NSString *path) {
    typedef const char *(*AxsAiSiriConvertPath)(const char *);
    static AxsAiSiriConvertPath convert;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("libroothide.dylib", RTLD_LAZY | RTLD_LOCAL);
        convert = (AxsAiSiriConvertPath)dlsym(handle ?: RTLD_DEFAULT, "jbroot");
    });
    if (!convert) return nil;
    const char *value = convert(path.fileSystemRepresentation);
    return value && value[0] ? [NSString stringWithUTF8String:value] : nil;
}

static inline NSArray<NSString *> *AxsAiSiriPreferencesPaths(void) {
    NSString *plain = @"/var/mobile/Library/Preferences/com.axs.aisiri.plist";
    NSString *isolated = AxsAiSiriIsolatedUserPath(plain);
    NSMutableArray *paths = [NSMutableArray array];
    if (isolated.length) [paths addObject:isolated];
    [paths addObject:@"/var/jb/var/mobile/Library/Preferences/com.axs.aisiri.plist"];
    if (![paths containsObject:plain]) [paths addObject:plain];
    return paths;
}

static inline NSString *AxsAiSiriDiagnosticDirectory(void) {
    NSString *plain = @"/var/mobile/Library/Logs/AiSiri";
    return AxsAiSiriIsolatedUserPath(plain) ?: plain;
}
