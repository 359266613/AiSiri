#pragma once
#import <Foundation/Foundation.h>

// Returns nil for unsupported or malformed results; path contains no user text.
FOUNDATION_EXPORT NSString *AxsAiSiriExtractTranscript(id result, NSString **path);
