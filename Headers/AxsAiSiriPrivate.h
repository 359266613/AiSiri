#pragma once
#import <Foundation/Foundation.h>

// Minimal declarations from the supplied iOS 16.5 dumps; do not import the dumps.
@interface AFUISiriSession : NSObject
- (void)assistantConnection:(id)connection speechRecognized:(id)recognized;
- (void)assistantConnectionRequestWillStart:(id)connection;
- (void)assistantConnectionDismissAssistant:(id)connection;
- (void)end;
- (void)endForReason:(long long)reason;
- (void)performAceCommand:(id)command turnIdentifier:(id)identifier machAbsoluteTime:(double)time;
@end

@interface AFSpeechRecognition : NSObject
- (id)oneBestTranscript;
@end

@interface SAUIAddViews : NSObject
+ (instancetype)addViews;
@property (copy, nonatomic) NSString *aceId;
@property (copy, nonatomic) NSString *refId;
@property (copy, nonatomic) NSString *dialogPhase;
@property (copy, nonatomic) NSString *displayTarget;
@property (copy, nonatomic) NSString *responseMode;
@property (copy, nonatomic) NSArray *views;
@property (nonatomic) BOOL requiresResponse;
@property (nonatomic) BOOL supplemental;
@end

@interface SAUIAssistantUtteranceView : NSObject
+ (instancetype)assistantUtteranceView;
@property (copy, nonatomic) NSString *viewId;
@property (copy, nonatomic) NSString *text;
@property (copy, nonatomic) NSString *speakableText;
@end
