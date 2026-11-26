#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

// Scoped declarations from theos/headers Preferences interfaces. Keeping these
// local avoids adding a new build dependency or changing the project file.
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSViewController : UIViewController
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface PSListController : PSViewController <UITableViewDelegate, UITableViewDataSource> {
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target;
- (void)reloadSpecifiers;
@end

@interface LPSBRootListController : PSListController
@property (nonatomic, copy) NSDictionary<NSString *, PSSpecifier *> *preferenceSpecifiers;
@end

@implementation LPSBRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSMutableDictionary<NSString *, PSSpecifier *> *preferences = [NSMutableDictionary dictionary];
        for (PSSpecifier *specifier in _specifiers) {
            NSString *key = [specifier propertyForKey:@"key"];
            if ([key isKindOfClass:NSString.class]) preferences[key] = specifier;
        }
        self.preferenceSpecifiers = preferences;
    }
    return _specifiers ?: [NSMutableArray array];
}

// Keep the inherited Preferences slider read/write implementation untouched.
// PSSliderCell.showValue owns the value label; static group titles and footers
// retain descriptions/units without mutating specifiers or table headers while
// the system slider is tracking. No private group lookup or table reload runs
// after a successful preference write.

- (void)confirmResetToDefaults {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认"
        message:@"确定要恢复效果、文字与颜色设置吗？已选应用将保持不变。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf resetPreferencesToDefaults]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetPreferencesToDefaults {
    // HudManager.resetDefaults(): retain selected apps, restore 24 effect/text
    // values plus the original four install-default colors in one notification.
    NSArray<NSString *> *keys = @[
        @"isEnabled", @"fontType", @"tokenizerMode", @"widthRatio", @"yOffset",
        @"ySlide", @"fontSize", @"birthRate", @"lifespan", @"speed", @"speedVariation",
        @"burstCount", @"burstCountVariation", @"attractionStrength", @"dampingFactor",
        @"initialSize", @"sizeMultiplier", @"opacity", @"isAdaptiveColorEnabled",
        @"shouldDisplayOnLockScreen", @"shouldDisplayWhenScreencast", @"isLabelEnabled",
        @"labelFontSize", @"yLabelOffset"
    ];
    [self specifiers];
    NSMutableSet<NSString *> *domains = [NSMutableSet set];
    NSMutableSet<NSString *> *notifications = [NSMutableSet set];
    // Validate the complete whitelist before writing any preference.
    for (NSString *key in keys) {
        PSSpecifier *specifier = self.preferenceSpecifiers[key];
        if (![specifier propertyForKey:@"default"] || ![specifier propertyForKey:@"defaults"]) return;
    }
    for (NSString *key in keys) {
        PSSpecifier *specifier = self.preferenceSpecifiers[key];
        NSString *domain = [specifier propertyForKey:@"defaults"];
        id value = [specifier propertyForKey:@"default"];
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)domain);
        [domains addObject:domain];
        NSString *notification = [specifier propertyForKey:@"PostNotification"];
        if (notification.length) [notifications addObject:notification];
    }
    NSString *colorDomain = [self.preferenceSpecifiers[@"isEnabled"] propertyForKey:@"defaults"];
    NSDictionary<NSString *, NSString *> *colorDefaults = @{
        @"color1": @"1.0,1.0,0.0,1.0", @"color2": @"1.0,0.0,0.0,1.0",
        @"color3": @"1.0,1.0,1.0,0.0", @"color4": @"1.0,1.0,1.0,0.0"
    };
    for (NSString *key in colorDefaults) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
            (__bridge CFPropertyListRef)colorDefaults[key], (__bridge CFStringRef)colorDomain);
    }
    // Synchronize the entire upstream reset before one reload, never publish
    // partially reset values or delete an applications selection.
    for (NSString *domain in domains) CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    for (NSString *notification in notifications) notify_post(notification.UTF8String);
    _specifiers = nil;
    self.preferenceSpecifiers = nil;
    [self reloadSpecifiers];
}
@end
