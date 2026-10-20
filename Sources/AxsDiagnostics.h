#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void AxsRecord(NSString *event, NSDictionary *details);
FOUNDATION_EXPORT NSString *AxsReadDiagnostics(void);
