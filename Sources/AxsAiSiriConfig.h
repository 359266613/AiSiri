#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const AxsAiSiriPreferencesChanged;

@interface AxsAiSiriConfig : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL speakReply;
@property (nonatomic, readonly, copy) NSString *prefix;
@property (nonatomic, readonly, copy) NSString *reply;
+ (NSDictionary *)defaults;
+ (id)valueForKey:(NSString *)key;
+ (BOOL)setValue:(id)value forPreferenceKey:(NSString *)key;
+ (BOOL)registerDefaults;
@end
