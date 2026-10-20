#pragma once
#import <Foundation/Foundation.h>

@interface AxsAiSiriProbeManager : NSObject
+ (instancetype)shared;
- (void)beginSession:(id)session;
- (void)endSession:(id)session;
- (void)observeRecognition:(id)recognition session:(id)session;
- (void)observeCommand:(id)command session:(id)session turn:(id)turn time:(double)time;
- (void)observeCommand:(id)command session:(id)session turn:(id)turn time:(double)time source:(NSString *)source;
- (void)preferencesChanged;
@end
