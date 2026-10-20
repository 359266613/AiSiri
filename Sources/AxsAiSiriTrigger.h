#pragma once
#import <Foundation/Foundation.h>

// Empty prefixes never match. Whitespace inside a prefix is ignored; a question must follow.
FOUNDATION_EXPORT BOOL AxsAiSiriMatchesTrigger(NSString *transcript, NSString *prefix);
