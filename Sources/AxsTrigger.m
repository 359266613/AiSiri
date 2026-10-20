#import "AxsTrigger.h"

static NSString *AxsNormalizeTrigger(NSString *text) {
    NSCharacterSet *ignored = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *parts = [[text precomposedStringWithCompatibilityMapping] componentsSeparatedByCharactersInSet:ignored];
    return [[parts componentsJoinedByString:@""] lowercaseString];
}

BOOL AxsMatchesTrigger(NSString *transcript, NSString *prefix) {
    if (![transcript isKindOfClass:NSString.class] || ![prefix isKindOfClass:NSString.class]) return NO;
    NSString *wanted = AxsNormalizeTrigger(prefix);
    NSString *actual = [[transcript precomposedStringWithCompatibilityMapping] lowercaseString];
    if (!wanted.length) return NO;
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSUInteger index = 0;
    // Keep the original boundary while tolerating ASR spaces inside "AI".
    for (NSUInteger i = 0; i < wanted.length; i++) {
        while (index < actual.length && [spaces characterIsMember:[actual characterAtIndex:index]]) index++;
        if (index == actual.length || [actual characterAtIndex:index] != [wanted characterAtIndex:i]) return NO;
        index++;
    }
    if (index == actual.length) return NO;
    unichar end = [wanted characterAtIndex:wanted.length - 1];
    unichar next = [actual characterAtIndex:index];
    BOOL asciiWord = (end >= 'a' && end <= 'z') || (end >= '0' && end <= '9');
    BOOL nextWord = (next >= 'a' && next <= 'z') || (next >= '0' && next <= '9');
    if (asciiWord && nextWord) return NO;
    NSMutableCharacterSet *separators = [[NSCharacterSet punctuationCharacterSet] mutableCopy];
    [separators formUnionWithCharacterSet:spaces];
    return [[actual substringFromIndex:index] stringByTrimmingCharactersInSet:separators].length > 0;
}
