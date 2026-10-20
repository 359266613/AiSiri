#import "AxsAiSiriDelegateProbe.h"
#import "AxsAiSiriProbeManager.h"
#include <stdlib.h>
#include <string.h>

static BOOL AxsAiSiriCommandSelector(NSString *name) {
    return [name rangeOfString:@"command" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [name rangeOfString:@"addViews" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Include inherited protocol requirements without assuming their private signatures.
static void AxsAiSiriCollectProtocol(Protocol *protocol, NSMutableSet<NSString *> *names,
                                     NSMutableSet<NSString *> *visited) {
    if (!protocol) return;
    NSString *name = NSStringFromProtocol(protocol);
    if ([visited containsObject:name] || visited.count >= 16) return;
    [visited addObject:name];
    for (NSUInteger required = 0; required < 2; required++) {
        unsigned int count = 0;
        struct objc_method_description *methods =
            protocol_copyMethodDescriptionList(protocol, required != 0, YES, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *selector = NSStringFromSelector(methods[i].name);
            if (names.count < 64 && AxsAiSiriCommandSelector(selector)) [names addObject:selector];
        }
        free(methods);
    }
    unsigned int count = 0;
    Protocol *__unsafe_unretained *parents = protocol_copyProtocolList(protocol, &count);
    for (unsigned int i = 0; i < count; i++) AxsAiSiriCollectProtocol(parents[i], names, visited);
    free(parents);
}

static BOOL AxsAiSiriObjectCallback(Method method) {
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (strcmp(signature.methodReturnType, @encode(void)) != 0 ||
        signature.numberOfArguments < 3 || signature.numberOfArguments > 6) return NO;
    for (NSUInteger i = 2; i < signature.numberOfArguments; i++) {
        // @ and @? share the object ABI; completion blocks are forwarded untouched.
        if ([signature getArgumentTypeAtIndex:i][0] != '@') return NO;
    }
    return YES;
}

static NSArray *AxsAiSiriArguments(NSUInteger count, id a, id b, id c, id d) {
    NSArray *values = @[a ?: NSNull.null, b ?: NSNull.null, c ?: NSNull.null, d ?: NSNull.null];
    return [values subarrayWithRange:NSMakeRange(0, count)];
}

static void AxsAiSiriObserveDelegateSafely(id receiver, NSString *selector, NSArray *arguments) {
    @try {
        [[AxsAiSiriProbeManager shared] observeDelegate:receiver selector:selector arguments:arguments];
    } @catch (NSException *exception) {
        [[AxsAiSiriProbeManager shared] recordDelegateInventory:@{@"exception": exception.name}];
    }
}

void AxsAiSiriPrepareDelegateProbe(id delegate, NSString *role, AxsAiSiriMessageHook install) {
    if (!delegate) {
        [[AxsAiSiriProbeManager shared] recordDelegateInventory:@{
            @"role": role, @"class": @"nil", @"methods": @[]
        }];
        return;
    }
    if (!install) return;
    // Adjust: install only protocol-declared callbacks on observed concrete delegates.
    // The bounded registry also serializes setup before native command forwarding.
    static NSMutableSet<NSString *> *seen;
    static NSMutableSet<NSString *> *hooked;
    static NSMutableDictionary<NSString *, NSDictionary *> *snapshots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
        hooked = [NSMutableSet set];
        snapshots = [NSMutableDictionary dictionary];
    });
    @synchronized (seen) {
        Class cls = object_getClass(delegate);
        if (cls == NSObject.class || cls == NSProxy.class) return;
        NSString *className = NSStringFromClass(cls);
        NSString *identity = [NSString stringWithFormat:@"%@/%@", role, className];
        if ([seen containsObject:identity]) {
            [[AxsAiSiriProbeManager shared] recordDelegateInventory:snapshots[identity]];
            return;
        }
        if (seen.count >= 8) return;
        [seen addObject:identity];
        NSMutableSet<NSString *> *names = [NSMutableSet set];
        NSMutableSet<NSString *> *visited = [NSMutableSet set];
        AxsAiSiriCollectProtocol(NSProtocolFromString(@"AFUISiriSessionDelegate"), names, visited);
        AxsAiSiriCollectProtocol(NSProtocolFromString(@"AFUISiriSessionLocalDelegate"), names, visited);

        // Also report class-local candidates when protocol metadata is unavailable.
        NSMutableArray *candidates = [NSMutableArray array];
        NSMutableSet<NSString *> *listed = [NSMutableSet set];
        for (Class current = cls; current && current != NSObject.class && current != NSProxy.class && candidates.count < 24;
             current = class_getSuperclass(current)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(current, &count);
            for (unsigned int i = 0; i < count && candidates.count < 24; i++) {
                SEL selector = method_getName(methods[i]);
                NSString *name = NSStringFromSelector(selector);
                if (!AxsAiSiriCommandSelector(name) || [listed containsObject:name]) continue;
                [listed addObject:name];
                BOOL declared = [names containsObject:name];
                BOOL compatible = AxsAiSiriObjectCallback(methods[i]);
                NSString *key = [NSString stringWithFormat:@"%@/%@", className, name];
                BOOL installed = [hooked containsObject:key];
                if (declared && compatible && !installed && hooked.count < 24) {
                    NSUInteger args = method_getNumberOfArguments(methods[i]) - 2;
                    // Each block owns its original trampoline for this exact method.
                    __block IMP original = NULL;
                    id block = nil;
                    if (args == 1) {
                        block = ^(id receiver, id a) {
                            AxsAiSiriObserveDelegateSafely(receiver, name, AxsAiSiriArguments(1, a, nil, nil, nil));
                            ((void (*)(id, SEL, id))original)(receiver, selector, a);
                        };
                    } else if (args == 2) {
                        block = ^(id receiver, id a, id b) {
                            AxsAiSiriObserveDelegateSafely(receiver, name, AxsAiSiriArguments(2, a, b, nil, nil));
                            ((void (*)(id, SEL, id, id))original)(receiver, selector, a, b);
                        };
                    } else if (args == 3) {
                        block = ^(id receiver, id a, id b, id c) {
                            AxsAiSiriObserveDelegateSafely(receiver, name, AxsAiSiriArguments(3, a, b, c, nil));
                            ((void (*)(id, SEL, id, id, id))original)(receiver, selector, a, b, c);
                        };
                    } else if (args == 4) {
                        block = ^(id receiver, id a, id b, id c, id d) {
                            AxsAiSiriObserveDelegateSafely(receiver, name, AxsAiSiriArguments(4, a, b, c, d));
                            ((void (*)(id, SEL, id, id, id, id))original)(receiver, selector, a, b, c, d);
                        };
                    }
                    IMP replacement = imp_implementationWithBlock(block);
                    install(cls, selector, replacement, &original);
                    [hooked addObject:key];
                    installed = YES;
                }
                [candidates addObject:@{
                    @"selector": name, @"owner": NSStringFromClass(current),
                    @"encoding": [NSString stringWithUTF8String:method_getTypeEncoding(methods[i])],
                    @"protocolDeclared": @(declared), @"signatureSupported": @(compatible),
                    @"hookInstalled": @(installed)
                }];
            }
            free(methods);
        }
        NSDictionary *snapshot = @{
            @"role": role, @"class": className, @"protocolsFound": @(visited.count),
            @"protocolCommandSelectors": [[names allObjects] sortedArrayUsingSelector:@selector(compare:)],
            @"methods": candidates
        };
        snapshots[identity] = snapshot;
        [[AxsAiSiriProbeManager shared] recordDelegateInventory:snapshot];
    }
}
