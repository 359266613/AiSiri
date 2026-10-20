#import "AxsRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "AxsConfig.h"
#import "AxsDiagnostics.h"

@interface AxsRootListController ()
@property (strong) NSMutableDictionary *axsValues;
@property (strong) dispatch_queue_t axsQueue;
@end

@implementation AxsRootListController

#pragma mark - Panel lifecycle
- (instancetype)init {
    self = [super init];
    if (self) {
        _axsValues = [[AxsConfig defaults] mutableCopy];
        _axsQueue = dispatch_queue_create("com.axs.aisiri.panel", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.userInteractionEnabled = NO;
    dispatch_async(self.axsQueue, ^{
        BOOL success = [AxsConfig registerDefaults];
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *key in [AxsConfig defaults]) values[key] = [AxsConfig valueForKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.axsValues = values;
            [self reloadSpecifiers];
            self.tableView.userInteractionEnabled = YES;
            if (!success) [self axsShowMessage:@"\u65e0\u6cd5\u5199\u5165\u8bbe\u7f6e"];
        });
    });
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"\u5173\u4e8e\u6211\u4eec"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [self axsButton:@"Sileo \u8d8a\u72f1\u6e90" action:@selector(axsOpenSileo:) to:specs];
        [self axsButton:@"TG\u5206\u4eab\u9891\u9053" action:@selector(axsOpenTelegram:) to:specs];
        [self axsButton:@"QQ\u4ea4\u6d41\u7fa4\u7ec4" action:@selector(axsOpenQQ:) to:specs];
        _specifiers = specs;
    }
    return _specifiers;
}

#pragma mark - Serial persistence, main-thread UI snapshot
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return self.axsValues[[specifier propertyForKey:@"key"]] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![AxsConfig defaults][key] || !value) return;
    if ([value isKindOfClass:NSString.class] && [value length] > 512) {
        [self axsShowMessage:@"\u6587\u672c\u4e0d\u80fd\u8d85\u8fc7 512 \u4e2a\u5b57\u7b26"];
        [self reloadSpecifiers];
        return;
    }
    self.axsValues[key] = value;
    dispatch_async(self.axsQueue, ^{
        if (![AxsConfig setValue:value forPreferenceKey:key]) {
            id persisted = [AxsConfig valueForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.axsValues[key] = persisted;
                [self reloadSpecifiers];
                [self axsShowMessage:@"\u8bbe\u7f6e\u4fdd\u5b58\u5931\u8d25"];
            });
        }
    });
}

#pragma mark - Diagnostics
- (void)axsCopyDiagnostics {
    dispatch_async(self.axsQueue, ^{
        NSString *text = AxsReadDiagnostics();
        dispatch_async(dispatch_get_main_queue(), ^{
            UIPasteboard.generalPasteboard.string = text;
            [self axsShowMessage:@"\u8bca\u65ad\u5df2\u590d\u5236"];
        });
    });
}

- (void)axsShowMessage:(NSString *)message {
    if (!self.view.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AiSiri"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"\u597d" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Author links
- (void)axsButton:(NSString *)title action:(SEL)action to:(NSMutableArray *)specs {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title target:self
        set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    specifier.buttonAction = action;
    [specs addObject:specifier];
}

- (void)axsOpenURL:(NSURL *)url fallback:(NSURL *)fallback {
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success && fallback) {
            [UIApplication.sharedApplication openURL:fallback options:@{} completionHandler:nil];
        }
    }];
}

- (void)axsOpenSileo:(id)sender {
    NSString *source = @"https://axs66.github.io/pro";
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    [self axsOpenURL:[NSURL URLWithString:[@"sileo://source/" stringByAppendingString:encoded]]
           fallback:[NSURL URLWithString:source]];
}

- (void)axsOpenTelegram:(id)sender {
    [self axsOpenURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
           fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}

- (void)axsOpenQQ:(id)sender {
    [self axsOpenURL:[NSURL URLWithString:
        @"http://qm.qq.com/cgi-bin/qm/qr?_wv=1027&k=b9yIV3X8xKi3ZZUC7YXIr1YasKOzjYnm&authKey=ReN7wx79FV6Y4EIowsWSljNRUTSaGfgwWlmRzuvpWpBxl%2BCEKz%2BMNP3JePx1mMQ8&noverify=0&group_code=1001525693"]
           fallback:nil];
}
@end
