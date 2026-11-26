#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

// Scoped declarations from theos/headers Preferences interfaces. Keeping these
// local avoids adding a new build dependency or changing the project file.
@interface PSSpecifier : NSObject
@property (nonatomic, retain) NSString *name;
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
@property (nonatomic, retain) UITableView *tableView;
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target;
- (NSInteger)indexOfGroup:(NSInteger)group;
- (BOOL)getGroup:(NSInteger *)group row:(NSInteger *)row ofSpecifier:(PSSpecifier *)specifier;
- (void)reloadSpecifiers;
@end

@interface LPSBRootListController : PSListController
@property (nonatomic, copy) NSDictionary<NSString *, PSSpecifier *> *sliderGroups;
@property (nonatomic, copy) NSDictionary<NSString *, PSSpecifier *> *preferenceSpecifiers;
@end

@implementation LPSBRootListController

- (NSString *)titleForSliderGroup:(PSSpecifier *)group value:(id)value {
    NSString *title = [group propertyForKey:@"lpSliderTitle"] ?: group.name ?: @"";
    NSString *format = [group propertyForKey:@"lpValueFormat"];
    if (![format isKindOfClass:NSString.class] || ![value respondsToSelector:@selector(doubleValue)]) {
        return title;
    }
    double scale = [[group propertyForKey:@"lpValueScale"] doubleValue];
    // Formats and units are copied from SheetView.swift, including the original
    // rounded count display. Values are never rounded or rescaled for storage.
    NSString *number = [NSString stringWithFormat:format, [value doubleValue] * scale];
    return [NSString stringWithFormat:@"%@ · %@", title, number];
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSMutableDictionary<NSString *, PSSpecifier *> *groups = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, PSSpecifier *> *sliders = [NSMutableDictionary dictionary];
        for (PSSpecifier *specifier in _specifiers) {
            NSString *sliderKey = [specifier propertyForKey:@"lpSliderKey"];
            if ([sliderKey isKindOfClass:NSString.class]) {
                [specifier setProperty:specifier.name ?: @"" forKey:@"lpSliderTitle"];
                groups[sliderKey] = specifier;
            }
            NSString *key = [specifier propertyForKey:@"key"];
            if ([key isKindOfClass:NSString.class]) sliders[key] = specifier;
        }
        self.sliderGroups = groups;
        self.preferenceSpecifiers = sliders;
        for (NSString *key in groups) {
            PSSpecifier *slider = sliders[key];
            if (!slider) continue;
            id value = [self readPreferenceValue:slider] ?: [slider propertyForKey:@"default"];
            groups[key].name = [self titleForSliderGroup:groups[key] value:value];
        }
    }
    return _specifiers ?: [NSMutableArray array];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger index = [self indexOfGroup:section];
    if (index >= 0 && index < (NSInteger)_specifiers.count) {
        PSSpecifier *group = _specifiers[(NSUInteger)index];
        if ([group propertyForKey:@"lpSliderKey"]) return group.name;
    }
    return [super tableView:tableView titleForHeaderInSection:section];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    // Preferences remains responsible for persistence and PostNotification.
    // Do not duplicate defaults domains, notification names, or renderer logic.
    [super setPreferenceValue:value specifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    PSSpecifier *group = key ? self.sliderGroups[key] : nil;
    if (!group) return;
    group.name = [self titleForSliderGroup:group value:value];
    NSInteger section = 0, row = 0;
    if ([self getGroup:&section row:&row ofSpecifier:specifier]) {
        UITableViewHeaderFooterView *header = [self.tableView headerViewForSection:section];
        header.textLabel.numberOfLines = 0;
        header.textLabel.text = group.name;
        [header setNeedsLayout];
    }
    // Never reload the table/section while dragging: that would replace the
    // active native PSSliderCell and interrupt continuous tracking.
}

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
        PSSpecifier *group = self.sliderGroups[key];
        if (group) group.name = [self titleForSliderGroup:group value:value];
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
    self.sliderGroups = nil;
    self.preferenceSpecifiers = nil;
    [self reloadSpecifiers];
}
@end
