#import "AxsAiSiriConfig.h"
#import "AxsAiSiriJailbreakPath.h"

NSString *const AxsAiSiriPreferencesChanged = @"com.axs.aisiri/preferences-changed";
static NSString *const AxsAiSiriDomain = @"com.axs.aisiri";

static NSUserDefaults *AxsAiSiriDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:AxsAiSiriDomain];
}

@implementation AxsAiSiriConfig

#pragma mark - Shared preferences
+ (NSDictionary *)defaults {
    return @{
        @"enabled": @NO,
        @"speakReply": @NO,
        @"transcriptCaptureUntil": @0,
        @"prefix": @"\u95eeAI",
        @"reply": @"AiSiri \u672c\u5730\u6d4b\u8bd5\u56de\u7b54\u3002"
                   "\u8fd9\u4e0d\u662f OpenAI \u751f\u6210\u7684\u5185\u5bb9\u3002"
    };
}

+ (id)valueForKey:(NSString *)key {
    for (NSString *path in AxsAiSiriPreferencesPaths()) {
        id value = [NSDictionary dictionaryWithContentsOfFile:path][key];
        if (value) return value;
    }
    return [AxsAiSiriDefaults() objectForKey:key] ?: [self defaults][key];
}

+ (NSString *)axsAiSiriSourceForPreferenceKey:(NSString *)key {
    for (NSString *path in AxsAiSiriPreferencesPaths()) {
        if ([NSDictionary dictionaryWithContentsOfFile:path][key]) return path;
    }
    return [AxsAiSiriDefaults() objectForKey:key] ? @"NSUserDefaults" : @"built-in-default";
}

+ (BOOL)setValue:(id)value forPreferenceKey:(NSString *)key {
    if (![self defaults][key] || !value) return NO;
    NSArray *paths = AxsAiSiriPreferencesPaths();
    NSString *isolated = AxsAiSiriIsolatedUserPath(paths.lastObject);
    BOOL wrote = NO;
    // Only the panel writes. Existing copies are merged; isolated copies must exist.
    for (NSString *path in paths) {
        BOOL required = [path isEqualToString:isolated] || [path isEqualToString:paths.lastObject];
        if (!required && ![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSString *parent = path.stringByDeletingLastPathComponent;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:parent
                                     withIntermediateDirectories:YES attributes:nil error:NULL]) continue;
        NSMutableDictionary *values = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
        if (!values) values = [NSMutableDictionary dictionary];
        values[key] = value;
        if ([values writeToFile:path atomically:YES]) wrote = YES;
    }
    if (wrote) {
        NSUserDefaults *defaults = AxsAiSiriDefaults();
        [defaults setObject:value forKey:key];
        [defaults synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)AxsAiSiriPreferencesChanged, NULL, NULL, true);
    }
    return wrote;
}

+ (BOOL)registerDefaults {
    // Runtime hosts are read-only, including during tweak initialization.
    if (!NSClassFromString(@"PSListController")) return NO;
    BOOL success = YES;
    for (NSString *key in [self defaults]) {
        BOOL exists = [AxsAiSiriDefaults() objectForKey:key] != nil;
        for (NSString *path in AxsAiSiriPreferencesPaths()) {
            if ([NSDictionary dictionaryWithContentsOfFile:path][key]) exists = YES;
        }
        if (!exists && ![self setValue:[self defaults][key] forPreferenceKey:key]) success = NO;
    }
    return success;
}

#pragma mark - Uncached typed access
- (BOOL)enabled {
    id value = [AxsAiSiriConfig valueForKey:@"enabled"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (BOOL)speakReply {
    id value = [AxsAiSiriConfig valueForKey:@"speakReply"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (NSString *)prefix {
    id value = [AxsAiSiriConfig valueForKey:@"prefix"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
- (NSString *)reply {
    id value = [AxsAiSiriConfig valueForKey:@"reply"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
@end
