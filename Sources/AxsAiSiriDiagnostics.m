#import "AxsAiSiriDiagnostics.h"
#import "AxsAiSiriJailbreakPath.h"
#import <os/log.h>

void AxsAiSiriRecord(NSString *event, NSDictionary *details) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.axs.aisiri.diagnostics", DISPATCH_QUEUE_SERIAL);
    });
    NSDictionary *entry = @{
        @"time": @([NSDate date].timeIntervalSince1970),
        @"process": NSProcessInfo.processInfo.processName,
        @"pid": @(NSProcessInfo.processInfo.processIdentifier),
        @"event": event,
        @"details": details ?: @{}
    };
    dispatch_async(queue, ^{
        @autoreleasepool {
            static NSMutableArray *entries;
            static os_log_t log;
            if (!entries) entries = [NSMutableArray array];
            if (!log) log = os_log_create("com.axs.aisiri", "probe");
            [entries addObject:entry];
            if (entries.count > 120) [entries removeObjectAtIndex:0];
            // Opt-in test text stays in the bounded local file, never the unified log.
            if ([event isEqualToString:@"opt-in-test-transcript"]) {
                os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "%{public}@", event);
            } else {
                os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "%{public}@ %{public}@",
                                 event, details.description ?: @"");
            }
            NSString *directory = AxsAiSiriDiagnosticDirectory();
            NSError *error;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
                os_log_error(log, "Diagnostic directory unavailable: %{public}@", error.localizedDescription);
                return;
            }
            NSString *name = [NSProcessInfo.processInfo.processName
                stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
            if (![entries writeToFile:path atomically:YES]) {
                os_log_error(log, "Diagnostic write failed");
            } else {
                [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                    ofItemAtPath:path error:NULL];
            }
        }
    });
}

NSString *AxsAiSiriReadDiagnostics(void) {
    NSMutableString *output = [NSMutableString stringWithString:@"AiSiri local probe / delegate-binding-v6\n"];
    NSString *directory = AxsAiSiriDiagnosticDirectory();
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name.pathExtension isEqualToString:@"plist"]) continue;
        NSArray *entries = [NSArray arrayWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        if (!entries) continue;
        [output appendFormat:@"\n[%@]\n%@\n", name, entries];
    }
    if (!names.count) [output appendString:@"No readable file diagnostics. Check unified log: com.axs.aisiri.\n"];
    return output;
}
