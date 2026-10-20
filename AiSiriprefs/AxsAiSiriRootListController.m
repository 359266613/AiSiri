#import "AxsAiSiriRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "AxsAiSiriConfig.h"
#import "AxsAiSiriDiagnostics.h"

@interface AxsAiSiriRootListController ()
@property (strong) NSMutableDictionary *axsAiSiriValues;
@property (strong) dispatch_queue_t axsAiSiriQueue;
@end

@implementation AxsAiSiriRootListController

#pragma mark - Panel lifecycle
- (instancetype)init {
    self = [super init];
    if (self) {
        _axsAiSiriValues = [[AxsAiSiriConfig defaults] mutableCopy];
        _axsAiSiriQueue = dispatch_queue_create("com.axs.aisiri.panel", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Avoid private PSListController table/tableView accessors on iOS 16.5.
    self.view.userInteractionEnabled = NO;
    dispatch_async(self.axsAiSiriQueue, ^{
        BOOL success = [AxsAiSiriConfig registerDefaults];
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *key in [AxsAiSiriConfig defaults]) values[key] = [AxsAiSiriConfig valueForKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.axsAiSiriValues = values;
            [self reloadSpecifiers];
            self.view.userInteractionEnabled = YES;
            if (!success) [self axsAiSiriShowMessage:@"\u65e0\u6cd5\u5199\u5165\u8bbe\u7f6e"];
        });
    });
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"AiSiriRoot" target:self] mutableCopy];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"\u5173\u4e8e\u6211\u4eec"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [self axsAiSiriButton:@"Sileo \u8d8a\u72f1\u6e90" action:@selector(axsAiSiriOpenSileo:) to:specs];
        [self axsAiSiriButton:@"TG\u5206\u4eab\u9891\u9053" action:@selector(axsAiSiriOpenTelegram:) to:specs];
        [self axsAiSiriButton:@"QQ\u4ea4\u6d41\u7fa4\u7ec4" action:@selector(axsAiSiriOpenQQ:) to:specs];
        _specifiers = specs;
    }
    return _specifiers;
}

#pragma mark - Serial persistence, main-thread UI snapshot
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return self.axsAiSiriValues[[specifier propertyForKey:@"key"]] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![AxsAiSiriConfig defaults][key] || !value) return;
    if ([value isKindOfClass:NSString.class] && [value length] > 512) {
        [self axsAiSiriShowMessage:@"\u6587\u672c\u4e0d\u80fd\u8d85\u8fc7 512 \u4e2a\u5b57\u7b26"];
        [self reloadSpecifiers];
        return;
    }
    self.axsAiSiriValues[key] = value;
    dispatch_async(self.axsAiSiriQueue, ^{
        if (![AxsAiSiriConfig setValue:value forPreferenceKey:key]) {
            id persisted = [AxsAiSiriConfig valueForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.axsAiSiriValues[key] = persisted;
                [self reloadSpecifiers];
                [self axsAiSiriShowMessage:@"\u8bbe\u7f6e\u4fdd\u5b58\u5931\u8d25"];
            });
        }
    });
}

#pragma mark - Diagnostics
- (void)axsAiSiriCopyDiagnostics {
    dispatch_async(self.axsAiSiriQueue, ^{
        NSString *text = AxsAiSiriReadDiagnostics();
        dispatch_async(dispatch_get_main_queue(), ^{
            UIPasteboard.generalPasteboard.string = text;
            [self axsAiSiriShowMessage:@"\u8bca\u65ad\u5df2\u590d\u5236"];
        });
    });
}

- (void)axsAiSiriShowMessage:(NSString *)message {
    if (!self.view.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AiSiri"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"\u597d" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Author links
- (void)axsAiSiriButton:(NSString *)title action:(SEL)action to:(NSMutableArray *)specs {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title target:self
        set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    specifier.buttonAction = action;
    [specs addObject:specifier];
}

- (void)axsAiSiriOpenURL:(NSURL *)url fallback:(NSURL *)fallback {
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success && fallback) {
            [UIApplication.sharedApplication openURL:fallback options:@{} completionHandler:nil];
        }
    }];
}

- (void)axsAiSiriOpenSileo:(id)sender {
    NSString *source = @"https://axs66.github.io/pro";
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    [self axsAiSiriOpenURL:[NSURL URLWithString:[@"sileo://source/" stringByAppendingString:encoded]]
           fallback:[NSURL URLWithString:source]];
}

- (void)axsAiSiriOpenTelegram:(id)sender {
    [self axsAiSiriOpenURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
           fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}

- (void)axsAiSiriOpenQQ:(id)sender {
    [self axsAiSiriOpenURL:[NSURL URLWithString:
        @"mqqapi://card/show_pslcard?src_type=internal&version=1&uin=678055716&card_type=group&source=qrcode"]
           fallback:nil];
}
@end
