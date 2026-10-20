#import "AxsAiSiriTranscript.h"
#import "AxsAiSiriPrivate.h"

// Structural protocols avoid linking private classes or importing dependent dumps.
@protocol AxsAiSiriACECommand <NSObject>
- (id)recognition;
@end
@protocol AxsAiSiriACERecognition <NSObject>
- (id)phrases;
@end
@protocol AxsAiSiriACEPhrase <NSObject>
- (id)interpretations;
@end
@protocol AxsAiSiriACEInterpretation <NSObject>
- (id)tokens;
@end
@protocol AxsAiSiriACEToken <NSObject>
- (id)text;
- (BOOL)removeSpaceBefore;
- (BOOL)removeSpaceAfter;
- (BOOL)addSpaceAfter;
@end

NSString *AxsAiSiriExtractTranscript(id result, NSString **path) {
    if (path) *path = nil;
    if ([result respondsToSelector:@selector(oneBestTranscript)]) {
        if (path) *path = @"one-best-transcript";
        id text = [(AFSpeechRecognition *)result oneBestTranscript];
        return [text isKindOfClass:NSString.class] && [text length] ? text : nil;
    }
    if (![result respondsToSelector:@selector(recognition)]) return nil;
    if (path) *path = @"ace-first-interpretation";
    id recognition = [(id<AxsAiSiriACECommand>)result recognition];
    if (![recognition respondsToSelector:@selector(phrases)]) return nil;
    id phrases = [(id<AxsAiSiriACERecognition>)recognition phrases];
    if (![phrases isKindOfClass:NSArray.class] || ![phrases count] || [phrases count] > 256) return nil;

    NSMutableString *transcript = [NSMutableString string];
    BOOL previousRemovesSpace = NO;
    BOOL previousAddsSpace = NO;
    NSUInteger tokenCount = 0;
    for (id phrase in phrases) {
        if (![phrase respondsToSelector:@selector(interpretations)]) return nil;
        id interpretations = [(id<AxsAiSiriACEPhrase>)phrase interpretations];
        if (![interpretations isKindOfClass:NSArray.class] || ![interpretations count]) return nil;
        // Never concatenate competing interpretations or select by trigger match.
        id interpretation = [interpretations firstObject];
        if (![interpretation respondsToSelector:@selector(tokens)]) return nil;
        id tokens = [(id<AxsAiSiriACEInterpretation>)interpretation tokens];
        if (![tokens isKindOfClass:NSArray.class] || ![tokens count] || [tokens count] > 2048) return nil;
        for (id token in tokens) {
            if (++tokenCount > 2048 || ![token respondsToSelector:@selector(text)]) return nil;
            id text = [(id<AxsAiSiriACEToken>)token text];
            if (![text isKindOfClass:NSString.class] || ![text length] || [text length] > 8192) return nil;
            id<AxsAiSiriACEToken> word = token;
            BOOL removesBefore = [token respondsToSelector:@selector(removeSpaceBefore)] && [word removeSpaceBefore];
            BOOL removesAfter = [token respondsToSelector:@selector(removeSpaceAfter)] && [word removeSpaceAfter];
            BOOL addsAfter = [token respondsToSelector:@selector(addSpaceAfter)] && [word addSpaceAfter];
            BOOL boundaryHasSpace = transcript.length &&
                ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[transcript characterAtIndex:transcript.length - 1]] ||
                 [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[text characterAtIndex:0]]);
            if (transcript.length && !boundaryHasSpace && !removesBefore &&
                (!previousRemovesSpace || previousAddsSpace)) {
                [transcript appendString:@" "];
            }
            [transcript appendString:text];
            if (transcript.length > 16384) return nil;
            previousRemovesSpace = removesAfter;
            previousAddsSpace = addsAfter && !removesAfter;
        }
    }
    NSString *text = [transcript stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}
