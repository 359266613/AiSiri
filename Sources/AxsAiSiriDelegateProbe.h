#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef void (*AxsAiSiriMessageHook)(Class cls, SEL selector, IMP replacement, IMP *original);

// Only prepare delegates actually obtained from an AFUISiriSession.
FOUNDATION_EXPORT void AxsAiSiriPrepareDelegateProbe(id delegate, NSString *role, AxsAiSiriMessageHook install);
FOUNDATION_EXPORT id AxsAiSiriIndependentCompletion(id nativeCompletion);
