#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

// Settings supplies Preferences.framework. No AltList or extra linked framework.
@interface PSViewController : UIViewController
@end

static NSString *const LPNativeDomain = @"com.82flex.letterpress";
static const char *const LPNativeReload = "LetterpressNotificationNameNeedsReload";
static NSUserDefaults *LPNativeDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:LPNativeDomain];
}
static void LPNativeNotify(NSUserDefaults *defaults) {
    [defaults synchronize];
    notify_post(LPNativeReload);
}
static const char *LPUnqualifiedType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) ++type;
    return type;
}
// Never cast an unverified private objc_msgSend ABI. Only zero-argument object
// getters are invoked; callers also validate the returned Foundation type.
static id LPObjectGetter(id target, NSString *name) {
    @try {
        SEL sel = NSSelectorFromString(name);
        if (!target || ![target respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        const char *type = LPUnqualifiedType(sig.methodReturnType);
        if (!sig || sig.numberOfArguments != 2 || !type || *type != '@' ||
            sig.methodReturnLength != sizeof(id)) return nil;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = target;
        call.selector = sel;
        [call invoke];
        __unsafe_unretained id result = nil;
        [call getReturnValue:&result];
        return result;
    } @catch (__unused NSException *error) { return nil; }
}
static BOOL LPBooleanGetter(id target, NSString *name, BOOL fallback) {
    @try {
        SEL sel = NSSelectorFromString(name);
        if (!target || ![target respondsToSelector:sel]) return fallback;
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        const char *type = LPUnqualifiedType(sig.methodReturnType);
        if (!sig || sig.numberOfArguments != 2 || !type ||
            !(*type == 'B' || *type == 'c' || *type == 'C') ||
            sig.methodReturnLength != sizeof(unsigned char)) return fallback;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = target;
        call.selector = sel;
        [call invoke];
        unsigned char value = 0;
        [call getReturnValue:&value];
        return value != 0;
    } @catch (__unused NSException *error) { return fallback; }
}

// PSLinkCell detail controllers receive these selectors on different iOS
// versions. Keep our own prefixed storage, not PSListController's table/ivars.
@interface LPSBNativeOptionsController : PSViewController <UITableViewDataSource, UITableViewDelegate> {
    id _lpSpecifier;
    __weak id _lpParentController;
    __weak id _lpRootController;
}
@property (nonatomic, strong) UITableView *lpTable;
@property (nonatomic, strong) NSUserDefaults *lpDefaults;
- (instancetype)initForContentSize:(CGSize)size;
- (instancetype)initWithSpecifier:(id)specifier;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (void)setParentController:(id)controller;
- (id)parentController;
- (void)setRootController:(id)controller;
- (id)rootController;
@end
@implementation LPSBNativeOptionsController
- (instancetype)initForContentSize:(CGSize)size {
    (void)size;
    return [self initWithNibName:nil bundle:nil];
}
- (instancetype)initWithSpecifier:(id)specifier {
    self = [self initWithNibName:nil bundle:nil];
    if (self) _lpSpecifier = specifier;
    return self;
}
- (void)setSpecifier:(id)specifier { _lpSpecifier = specifier; }
- (id)specifier { return _lpSpecifier; }
- (void)setPreferenceSpecifier:(id)specifier { _lpSpecifier = specifier; }
- (void)setParentController:(id)controller { _lpParentController = controller; }
- (id)parentController { return _lpParentController; }
- (void)setRootController:(id)controller { _lpRootController = controller; }
- (id)rootController { return _lpRootController; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.lpDefaults = LPNativeDefaults();
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.lpTable = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.lpTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.lpTable.dataSource = self;
    self.lpTable.delegate = self;
    self.lpTable.rowHeight = UITableViewAutomaticDimension;
    self.lpTable.estimatedRowHeight = 64;
    [self.view addSubview:self.lpTable];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 0;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}
@end

static NSArray<NSString *> *LPDefaultApplications(void) {
    // No built-in preselection. Explicit current/legacy selections still win.
    return @[];
}
static NSMutableSet<NSString *> *LPReadApplications(NSUserDefaults *defaults) {
    NSDictionary *domain = [defaults persistentDomainForName:LPNativeDomain] ?: @{};
    // New-domain values win over old-domain values, including an explicit [].
    if (!domain[@"selectedApplicationsCSV"] && !domain[@"selectedApplications"]) {
        domain = [defaults persistentDomainForName:@"wiki.qaq.letterpress"] ?: @{};
    }
    id csv = domain[@"selectedApplicationsCSV"];
    id array = domain[@"selectedApplications"];
    NSArray *values = [csv isKindOfClass:NSString.class] ? [csv componentsSeparatedByString:@","] :
        ([array isKindOfClass:NSArray.class] ? array : LPDefaultApplications());
    NSMutableSet *selection = [NSMutableSet set];
    for (id value in values) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *identifier = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (identifier.length) [selection addObject:identifier];
    }
    return selection;
}

@interface LPSBApplicationsController : LPSBNativeOptionsController <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<NSDictionary *> *lpApplications;
@property (nonatomic, copy) NSArray<NSDictionary *> *lpFiltered;
@property (nonatomic, strong) NSMutableSet<NSString *> *lpSelected;
@property (nonatomic, strong) UISearchController *lpSearch;
@property (nonatomic, copy) NSString *lpLoadMessage;
@end
@implementation LPSBApplicationsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"指定应用程序启用";
    self.lpSelected = LPReadApplications(self.lpDefaults);
    self.lpApplications = @[];
    self.lpFiltered = @[];
    self.lpLoadMessage = @"正在读取可见应用…";
    self.lpSearch = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.lpSearch.searchResultsUpdater = self;
    self.lpSearch.obscuresBackgroundDuringPresentation = NO;
    self.lpSearch.searchBar.placeholder = @"搜索应用名称或标识符";
    self.navigationItem.searchController = self.lpSearch;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(lpSaveAndClose)];
    [self lpUpdatePrompt];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static dispatch_once_t token;
        dispatch_once(&token, ^{
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
        });
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = LPObjectGetter(workspaceClass, @"defaultWorkspace");
        id proxies = LPObjectGetter(workspace, @"allInstalledApplications");
        if (![proxies isKindOfClass:NSArray.class]) proxies = LPObjectGetter(workspace, @"allApplications");
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        BOOL available = [proxies isKindOfClass:NSArray.class] && proxyClass != Nil;
        NSMutableDictionary<NSString *, NSDictionary *> *unique = [NSMutableDictionary dictionary];
        for (id proxy in available ? proxies : @[]) {
            if (![proxy isKindOfClass:proxyClass]) continue;
            id identifier = LPObjectGetter(proxy, @"bundleIdentifier");
            if (![identifier isKindOfClass:NSString.class] || ![identifier length]) continue;
            id kind = LPObjectGetter(proxy, @"applicationType");
            if ([kind isKindOfClass:NSString.class] && ![kind isEqualToString:@"User"] &&
                ![kind isEqualToString:@"System"]) continue;
            id tags = LPObjectGetter(proxy, @"appTags");
            if ([tags isKindOfClass:NSArray.class] && [tags containsObject:@"hidden"]) continue;
            if (LPBooleanGetter(proxy, @"isHidden", NO) ||
                LPBooleanGetter(proxy, @"isLaunchProhibited", NO) ||
                !LPBooleanGetter(proxy, @"isInstalled", YES)) continue;
            id name = LPObjectGetter(proxy, @"localizedName");
            if (![name isKindOfClass:NSString.class] || ![name length]) name = identifier;
            unique[identifier] = @{@"identifier": identifier, @"name": name};
        }
        NSArray *apps = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult result = [a[@"name"] localizedStandardCompare:b[@"name"]];
            return result == NSOrderedSame ? [a[@"identifier"] compare:b[@"identifier"]] : result;
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.lpApplications = apps;
            self.lpLoadMessage = available ? @"未找到可见应用。原有选择已保留。" :
                @"当前系统无法读取应用列表（接口不可用或签名不兼容）。原有选择已保留。";
            [self updateSearchResultsForSearchController:self.lpSearch];
        });
    });
}
- (void)lpUpdatePrompt {
    self.navigationItem.prompt = [NSString stringWithFormat:@"已选 %lu 项；不选择任何应用则不显示效果", (unsigned long)self.lpSelected.count];
}
- (void)lpPersistSelection {
    [self.lpDefaults setObject:[self.lpSelected.allObjects sortedArrayUsingSelector:@selector(compare:)]
                       forKey:@"selectedApplications"];
    [self.lpDefaults removeObjectForKey:@"selectedApplicationsCSV"];
    LPNativeNotify(self.lpDefaults);
    [self lpUpdatePrompt];
}
- (void)lpSaveAndClose {
    [self lpPersistSelection];
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) self.lpFiltered = self.lpApplications;
    else self.lpFiltered = [self.lpApplications filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
        (void)bindings;
        return [app[@"name"] localizedStandardContainsString:query] ||
               [app[@"identifier"] localizedStandardContainsString:query];
    }]];
    [self.lpTable reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.lpFiltered.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.lpFiltered.count ? @"仅显示可见应用，点击勾选后立即保存。未安装或隐藏应用的已有选择不会被删除。" :
        (self.lpSearch.searchBar.text.length ? @"没有匹配的应用。" : self.lpLoadMessage);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LPApplication"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LPApplication"];
    NSDictionary *app = self.lpFiltered[(NSUInteger)indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = app[@"identifier"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = [self.lpSelected containsObject:app[@"identifier"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityValue = cell.accessoryType == UITableViewCellAccessoryCheckmark ? @"已选择" : @"未选择";
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *identifier = self.lpFiltered[(NSUInteger)indexPath.row][@"identifier"];
    if ([self.lpSelected containsObject:identifier]) [self.lpSelected removeObject:identifier];
    else [self.lpSelected addObject:identifier];
    [self lpPersistSelection];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}
@end

static NSArray<NSString *> *LPDefaultColorStrings(void) {
    return @[@"1.0,1.0,0.0,1.0", @"1.0,0.0,0.0,1.0",
             @"1.0,1.0,1.0,0.0", @"1.0,1.0,1.0,0.0"];
}
static UIColor *LPColorFromRGBA(NSString *rgba) {
    if (![rgba isKindOfClass:NSString.class]) return UIColor.clearColor;
    // Match split + compactMap(Double.init): require four parsed values,
    // without imposing a finite-value check or a 0...1 storage restriction.
    double values[4];
    NSUInteger count = 0;
    for (NSString *part in [rgba componentsSeparatedByString:@","]) {
        if (!part.length || [part rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) continue;
        const char *start = part.UTF8String;
        char *end = NULL;
        double value = strtod(start, &end);
        if (end == start || *end != '\0') continue;
        if (count == 4) return UIColor.clearColor;
        values[count++] = value;
    }
    if (count != 4) return UIColor.clearColor;
    return [UIColor colorWithRed:values[0] green:values[1] blue:values[2] alpha:values[3]];
}
static NSString *LPRGBAFromColor(UIColor *color) {
    CGColorRef cgColor = color.CGColor;
    const CGFloat *components = cgColor ? CGColorGetComponents(cgColor) : NULL;
    size_t count = cgColor ? CGColorGetNumberOfComponents(cgColor) : 0;
    if (components && count == 2) {
        return [NSString stringWithFormat:@"%.17g,%.17g,%.17g,%.17g",
                (double)components[0], (double)components[0], (double)components[0], (double)components[1]];
    }
    if (components && count == 4) {
        return [NSString stringWithFormat:@"%.17g,%.17g,%.17g,%.17g",
                (double)components[0], (double)components[1], (double)components[2], (double)components[3]];
    }
    return @"0,0,0,0";
}

@interface LPSBColorsController : LPSBNativeOptionsController <UIColorPickerViewControllerDelegate>
@property (nonatomic) NSInteger lpColorIndex;
@property (nonatomic, weak) UIColorPickerViewController *lpActivePicker;
@property (nonatomic, strong) NSMutableArray<UIColor *> *lpDraftColors;
@end
@implementation LPSBColorsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"颜色";
    self.lpColorIndex = NSNotFound;
    self.lpDraftColors = [NSMutableArray arrayWithCapacity:4];
    for (NSUInteger index = 0; index < 4; index++) {
        NSString *key = [NSString stringWithFormat:@"color%lu", (unsigned long)index + 1];
        id value = [self.lpDefaults objectForKey:key];
        [self.lpDraftColors addObject:LPColorFromRGBA(value ?: LPDefaultColorStrings()[index])];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"应用" style:UIBarButtonItemStyleDone target:self action:@selector(lpApplyColors)];
}
- (void)lpCommitColors {
    for (NSUInteger index = 0; index < self.lpDraftColors.count; index++) {
        [self.lpDefaults setObject:LPRGBAFromColor(self.lpDraftColors[index])
                           forKey:[NSString stringWithFormat:@"color%lu", (unsigned long)index + 1]];
    }
    LPNativeNotify(self.lpDefaults);
}
- (void)lpApplyColors {
    [self lpCommitColors];
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Presenting the picker or reset alert is not leaving the colors page.
    // A cancelled interactive pop also must not submit the draft.
    if (!self.presentedViewController) [self lpCommitColors];
}
- (NSString *)lpStoredColorAtIndex:(NSUInteger)index {
    return LPRGBAFromColor(self.lpDraftColors[index]);
}
- (UIColor *)lpColorAtIndex:(NSUInteger)index {
    return self.lpDraftColors[index];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? 4 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? @"选择颜色" : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"支持透明度，点击应用或离开颜色页时保存。关闭自适应颜色后使用这些自定义颜色。" :
        @"重置颜色将恢复为白色、透明、透明、透明（与原版“重置颜色”一致）。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (indexPath.section == 1) {
        cell.textLabel.text = @"重置颜色";
        cell.textLabel.textColor = UIColor.systemRedColor;
        return cell;
    }
    NSUInteger index = (NSUInteger)indexPath.row;
    cell.textLabel.text = [NSString stringWithFormat:@"颜色 #%lu", (unsigned long)index + 1];
    cell.detailTextLabel.text = [self lpStoredColorAtIndex:index];
    cell.detailTextLabel.numberOfLines = 2;
    UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
    swatch.backgroundColor = [self lpColorAtIndex:index];
    swatch.layer.cornerRadius = 8;
    swatch.layer.borderWidth = 1;
    swatch.layer.borderColor = UIColor.separatorColor.CGColor;
    cell.accessoryView = swatch;
    cell.accessibilityHint = @"打开原生颜色选择器，可调整透明度";
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) { [self lpConfirmReset]; return; }
    self.lpColorIndex = indexPath.row;
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.supportsAlpha = YES;
    picker.selectedColor = [self lpColorAtIndex:(NSUInteger)indexPath.row];
    picker.delegate = self;
    picker.title = [NSString stringWithFormat:@"颜色 #%ld", (long)indexPath.row + 1];
    self.lpActivePicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)lpUpdateDraftColor:(UIColor *)color picker:(UIColorPickerViewController *)picker {
    if (picker != self.lpActivePicker || self.lpColorIndex < 0 || self.lpColorIndex >= 4) return;
    self.lpDraftColors[(NSUInteger)self.lpColorIndex] = color;
    [self.lpTable reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:self.lpColorIndex inSection:0]]
                       withRowAnimation:UITableViewRowAnimationNone];
}
- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                 didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    (void)continuously;
    [self lpUpdateDraftColor:color picker:viewController];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self lpUpdateDraftColor:viewController.selectedColor picker:viewController];
    self.lpActivePicker = nil;
    self.lpColorIndex = NSNotFound;
}
- (void)lpConfirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置颜色"
        message:@"确定将颜色重置为白色、透明、透明、透明吗？" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        typeof(self) self = weakSelf;
        if (!self) return;
        self.lpDraftColors = [@[UIColor.whiteColor, UIColor.clearColor, UIColor.clearColor, UIColor.clearColor] mutableCopy];
        [self.lpTable reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
