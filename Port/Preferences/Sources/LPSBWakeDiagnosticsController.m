#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <math.h>

static NSString *const LPWakeDomain = @"com.82flex.letterpress.diagnostics";
static NSString *const LPWakeBuild = @"0.1.0~test8+diag1";
static const NSUInteger LPWakeReportLimit = 384 * 1024;
static const char *const LPWakeCommandNotification = "com.82flex.letterpress.diagnostics.command";

// Bound dictionary compatibility input before serialization, including JSON escaping.
static BOOL LPWakeBudget(id object, NSUInteger *budget, NSUInteger depth) {
    if (depth > 32 || *budget < 2) return NO;
    if ([object isKindOfClass:NSString.class]) {
        NSString *string = object;
        NSUInteger bytes = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (bytes > *budget - 2) return NO;
        bytes += 2;
        for (NSUInteger i = 0; i < string.length; i++) {
            unichar c = [string characterAtIndex:i];
            NSUInteger extra = (c == '"' || c == '\\') ? 1 :
                (c < 0x20 ? ((c == '\n' || c == '\r' || c == '\t' || c == '\b' || c == '\f') ? 1 : 5) : 0);
            if (extra > *budget - bytes) return NO;
            bytes += extra;
        }
        *budget -= bytes;
        return YES;
    }
    if (object == NSNull.null || [object isKindOfClass:NSNumber.class]) {
        if (object != NSNull.null && !isfinite([object doubleValue])) return NO;
        NSUInteger cost = object == NSNull.null ? 4 : MAX((NSUInteger)5, [[object stringValue] length] + 8);
        if (cost > *budget) return NO;
        *budget -= cost;
        return YES;
    }
    BOOL dictionary = [object isKindOfClass:NSDictionary.class];
    if (!dictionary && ![object isKindOfClass:NSArray.class]) return NO;
    *budget -= 2;
    for (id item in object) {
        if (*budget < 2) return NO;
        *budget -= 2; // Conservative comma/colon allowance.
        if (dictionary) {
            if (![item isKindOfClass:NSString.class] || !LPWakeBudget(item, budget, depth + 1) ||
                !LPWakeBudget(object[item], budget, depth + 1)) return NO;
        } else if (!LPWakeBudget(item, budget, depth + 1)) return NO;
    }
    return YES;
}
static BOOL LPWakeNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= 0;
}
static BOOL LPWakeUUID(id value) {
    return [value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static BOOL LPWakeSameUUID(id a, id b) {
    if (!LPWakeUUID(a) || !LPWakeUUID(b)) return NO;
    return [[[NSUUID alloc] initWithUUIDString:a] isEqual:[[NSUUID alloc] initWithUUIDString:b]];
}
static NSDictionary *LPWakeReadReport(id raw, NSData **dataOut, NSString **problem) {
    *dataOut = nil;
    *problem = nil;
    if (!raw) { *problem = @"尚无诊断报告；未确认 SpringBoard 诊断模块是否已启动。"; return nil; }
    NSData *data = nil;
    if ([raw isKindOfClass:NSString.class]) {
        // Check UTF-8 length BEFORE creating NSData or asking the JSON parser to read it.
        if ([(NSString *)raw lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > LPWakeReportLimit) {
            *problem = @"报告超过 384 KB 上限，拒绝读取或导出。"; return nil;
        }
        data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([raw isKindOfClass:NSDictionary.class]) {
        NSUInteger budget = LPWakeReportLimit;
        if (!LPWakeBudget(raw, &budget, 0) || ![NSJSONSerialization isValidJSONObject:raw]) {
            *problem = @"兼容报告超出大小/深度限制，或不是合法 JSON 字典。"; return nil;
        }
        data = [NSJSONSerialization dataWithJSONObject:raw options:0 error:NULL];
    }
    if (!data || data.length > LPWakeReportLimit) {
        *problem = @"诊断报告类型错误、无法编码或超过 384 KB；未确认采样成功。"; return nil;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        *problem = @"诊断报告不是合法 JSON 对象。"; return nil;
    }
    NSDictionary *report = parsed;
    if (!LPWakeNumber(report[@"schema"]) || [report[@"schema"] doubleValue] != 1 ||
        ![report[@"build"] isKindOfClass:NSString.class] || ![report[@"build"] isEqualToString:LPWakeBuild]) {
        *problem = @"这是旧版或不兼容的诊断报告（需要 schema 1 / 0.1.0~test8+diag1），不能作为本次结果。"; return nil;
    }
    NSString *status = report[@"status"];
    if (![status isKindOfClass:NSString.class] ||
        ![@[@"recording", @"completed", @"cleared", @"error"] containsObject:status] || !LPWakeUUID(report[@"requestID"])) {
        *problem = @"报告的状态或 requestID 无效；未确认采样成功。"; return nil;
    }
    // A completed report must carry the full payload. Partial acknowledgements cannot be exported.
    if ([status isEqualToString:@"completed"] &&
        (!LPWakeNumber(report[@"startedAtUnix"]) || !LPWakeNumber(report[@"endedAtUnix"]) ||
         !LPWakeNumber(report[@"duration"]) || [report[@"endedAtUnix"] doubleValue] < [report[@"startedAtUnix"] doubleValue] ||
         ![report[@"events"] isKindOfClass:NSArray.class] || ![report[@"samples"] isKindOfClass:NSArray.class] ||
         ![report[@"images"] isKindOfClass:NSArray.class] || ![report[@"limits"] isKindOfClass:NSDictionary.class])) {
        *problem = @"completed 报告缺少完整时间、events、samples、images 或 limits，不能完整导出。"; return nil;
    }
    *dataOut = data;
    return report;
}

// Match the existing native options controllers hosted by Preferences.
@interface PSViewController : UIViewController
@end
@interface LPSBWakeDiagnosticsController : PSViewController <UITableViewDataSource, UITableViewDelegate> {
    id _lpSpecifier;
    __weak id _lpParentController;
    __weak id _lpRootController;
}
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSDictionary *lpReport;
@property (nonatomic, strong) NSData *lpReportData;
@property (nonatomic, copy) NSString *lpProblem;
@property (nonatomic, copy) NSString *lpFeedback;
@property (nonatomic, copy) NSString *lpStoredRequestID;
@property (nonatomic, copy) NSString *lpCommandID;
@property (nonatomic, copy) NSString *lpCommand;
@property (nonatomic) BOOL lpAckHandled;
@property (nonatomic) BOOL lpVisible;
@property (nonatomic) BOOL lpPolling;
@property (nonatomic) NSUInteger lpGeneration;
@end

@implementation LPSBWakeDiagnosticsController
- (instancetype)init { return [super initWithNibName:nil bundle:nil]; }
- (instancetype)initForContentSize:(CGSize)size { (void)size; return [self init]; }
- (instancetype)initWithSpecifier:(id)specifier {
    self = [self init]; if (self) _lpSpecifier = specifier; return self;
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
    self.title = @"唤醒诊断（非修复版）";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(lpBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(lpResignedActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lpVisible = YES;
    [self lpReload]; // Always synchronize cross-process preferences on return.
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self lpHandleAcknowledgement];
}
- (void)viewWillDisappear:(BOOL)animated {
    self.lpVisible = NO;
    [self lpCancelPolling];
    [super viewWillDisappear:animated];
}
- (void)lpCancelPolling {
    if (self.lpPolling) self.lpFeedback = @"短时应答核验已结束或取消；返回本页会重新同步，不会在后台永久轮询。";
    self.lpGeneration++; self.lpPolling = NO;
}
- (void)lpResignedActive:(NSNotification *)notification {
    (void)notification;
    [self lpCancelPolling];
}
- (void)lpBecameActive:(NSNotification *)notification {
    (void)notification;
    if (self.lpVisible) { [self lpReload]; [self lpHandleAcknowledgement]; }
}
- (void)lpAlert:(NSString *)title message:(NSString *)message {
    if (!self.lpVisible || !self.view.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)lpReload {
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)LPWakeDomain)) {
        self.lpReport = nil; self.lpReportData = nil; self.lpStoredRequestID = nil;
        self.lpProblem = @"无法同步本地诊断域；未确认 SpringBoard 应答，不能使用缓存报告。";
    } else {
        id raw = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("report"), (__bridge CFStringRef)LPWakeDomain));
        NSData *data = nil; NSString *problem = nil;
        self.lpReport = LPWakeReadReport(raw, &data, &problem);
        self.lpReportData = data; self.lpProblem = problem;
        id request = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("request"), (__bridge CFStringRef)LPWakeDomain));
        id requestID = [request isKindOfClass:NSDictionary.class] ? request[@"requestID"] : nil;
        self.lpStoredRequestID = LPWakeUUID(requestID) ? requestID : nil;
    }
    if (self.lpAckHandled && [self lpReportMatchesLatestRequest] &&
        [self.lpReport[@"status"] isEqualToString:@"completed"]) {
        self.lpFeedback = @"重新同步已确认 completed 完整报告；可手动导出，不表示问题已修复。";
    }
    [self.tableView reloadData];
}
- (NSDictionary *)lpLastCommandForLatestRequest {
    NSString *requestID = self.lpCommandID ?: self.lpStoredRequestID;
    if (self.lpStoredRequestID && !LPWakeSameUUID(requestID, self.lpStoredRequestID)) return nil;
    id ack = self.lpReport[@"lastCommand"];
    if (![ack isKindOfClass:NSDictionary.class] || !LPWakeSameUUID(ack[@"requestID"], requestID) ||
        ![ack[@"status"] isKindOfClass:NSString.class] ||
        ![@[@"accepted", @"rejected"] containsObject:ack[@"status"]]) return nil;
    return ack;
}
- (BOOL)lpReportMatchesLatestRequest {
    NSString *requestID = self.lpCommandID ?: self.lpStoredRequestID;
    if (self.lpStoredRequestID && !LPWakeSameUUID(requestID, self.lpStoredRequestID)) return NO;
    NSDictionary *ack = [self lpLastCommandForLatestRequest];
    if ([ack[@"status"] isEqualToString:@"rejected"]) return NO;
    // SB preserves the sampling requestID; stop acknowledgements may be in lastCommand.
    return LPWakeSameUUID(self.lpReport[@"requestID"], requestID) || [ack[@"status"] isEqualToString:@"accepted"];
}
- (NSString *)lpSummary {
    if (!self.lpReport) return self.lpProblem ?: @"尚无报告。";
    NSDictionary *ack = [self lpLastCommandForLatestRequest];
    if ([ack[@"status"] isEqualToString:@"rejected"]) return @"SpringBoard 已明确拒绝最新命令（busy / rejected 或不在采样中）；原报告身份保留，不把它当作新采样成功。";
    if (![self lpReportMatchesLatestRequest]) return @"现有报告未确认最新命令（可能是旧报告）；不可作为本次采样结果导出。";
    NSString *status = self.lpReport[@"status"];
    if ([status isEqualToString:@"recording"]) return @"SpringBoard 已接受采样（recording），尚非完整报告；最多观察 90 秒，请按步骤复现后返回停止。";
    if ([status isEqualToString:@"completed"]) return @"SpringBoard 报告已完成（completed），可导出完整 JSON；不代表已找到或修复问题。";
    if ([status isEqualToString:@"cleared"]) return @"SpringBoard 已确认清除诊断报告；未恢复或更改任何偏好。";
    return @"SpringBoard 返回 error（可能 busy / rejected）；未确认本次操作成功。";
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return 4; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section; return @"仅诊断 · 非修复版 · 手动开始";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [NSString stringWithFormat:@"只有手动点开始后才请求 SpringBoard 进行最多 90 秒观察；本页不自行采样或改变设备。\n操作：开始 → 去播放器放歌 → 锁屏 30 秒 → 亮屏后回本页 → 停止并保存 → 导出。\n\n状态：%@%@\n\n仅收集诊断元数据，不采集歌词或账号。不自动复制到剪贴板、不自动联网或公开上传；分享由你选择目的地。采样会产生少量额外开销，不保证捕获根因，请避免连续长开。",
        [self lpSummary], self.lpFeedback.length ? [@"\n" stringByAppendingString:self.lpFeedback] : @""];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LPWakeAction"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LPWakeAction"];
    cell.textLabel.text = @[@"开始 90 秒采样", @"停止并保存", @"导出诊断", @"清除本次诊断"][indexPath.row];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.textColor = self.lpPolling ? UIColor.secondaryLabelColor :
        (indexPath.row == 3 ? UIColor.systemRedColor : self.view.tintColor);
    cell.accessibilityTraits = UIAccessibilityTraitButton | (self.lpPolling ? UIAccessibilityTraitNotEnabled : 0);
    cell.selectionStyle = self.lpPolling ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.lpPolling) return;
    if (indexPath.row == 0) [self lpSendCommand:@"start"];
    else if (indexPath.row == 1) [self lpSendCommand:@"stop"];
    else if (indexPath.row == 2) [self lpExportFromIndexPath:indexPath];
    else [self lpConfirmClear];
}
- (void)lpSendCommand:(NSString *)command {
    [self lpCancelPolling];
    NSString *requestID = NSUUID.UUID.UUIDString.lowercaseString;
    self.lpCommandID = requestID; self.lpCommand = command; self.lpAckHandled = NO;
    NSDictionary *request = @{@"command": command, @"requestID": requestID,
        @"issuedAtUnix": @([NSDate date].timeIntervalSince1970)};
    // NSUUID is encoded as UUIDString because CFPreferences values must be property-list types.
    // Never write, remove, or synthesize the SB-owned report value.
    CFPreferencesSetAppValue(CFSTR("request"), (__bridge CFPropertyListRef)request, (__bridge CFStringRef)LPWakeDomain);
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)LPWakeDomain)) {
        self.lpFeedback = @"命令未能同步；没有确认任何采样或保存成功。";
        [self lpReload];
        [self lpAlert:@"命令未确认" message:self.lpFeedback];
        return;
    }
    uint32_t result = notify_post(LPWakeCommandNotification);
    if (result != NOTIFY_STATUS_OK) {
        self.lpFeedback = @"命令已写入，但通知发送失败；没有确认 SpringBoard 接受。";
        [self lpReload];
        [self lpAlert:@"通知未确认" message:self.lpFeedback];
        return;
    }
    self.lpFeedback = @"命令已发送，正在核验相同 requestID 的 SpringBoard 应答；通知成功不等于采样成功。";
    self.lpPolling = YES;
    NSUInteger generation = self.lpGeneration;
    [self.tableView reloadData];
    [self lpPollGeneration:generation attempt:1];
}
- (void)lpPollGeneration:(NSUInteger)generation attempt:(NSUInteger)attempt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.lpGeneration || !self.lpVisible || !self.lpPolling) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            [self lpCancelPolling]; return;
        }
        [self lpReload];
        if ([self lpHandleAcknowledgement]) return;
        if (attempt < 10) { [self lpPollGeneration:generation attempt:attempt + 1]; return; }
        [self lpCancelPolling];
        self.lpFeedback = @"约 4 秒内未收到与本次命令 requestID 相同的有效应答；未确认采样、停止或清除成功。可能诊断注入未启动，或 SpringBoard 未响应。返回本页可重新读取，旧报告不会冒充本次结果。";
        [self.tableView reloadData];
        [self lpAlert:@"SpringBoard 未确认" message:[NSString stringWithFormat:@"%@\n%@", self.lpFeedback, self.lpProblem ?: @""]];
    });
}
- (BOOL)lpHandleAcknowledgement {
    if (!self.lpCommandID || self.lpAckHandled || !self.lpReport) return NO;
    NSDictionary *ack = [self lpLastCommandForLatestRequest];
    BOOL rejected = [ack[@"status"] isEqualToString:@"rejected"];
    if (!rejected && ![self lpReportMatchesLatestRequest]) return NO;
    NSString *status = self.lpReport[@"status"];
    self.lpAckHandled = YES;
    [self lpCancelPolling];
    if (rejected) {
        id code = ack[@"reasonCode"];
        BOOL busy = [code isKindOfClass:NSNumber.class] && [code integerValue] == 37;
        self.lpFeedback = busy ? @"SpringBoard 已应答本次 requestID：busy，重复开始被拒绝；没有开始新采样，原采样/报告保留。请按原流程返回停止。" :
            @"SpringBoard 已应答本次 requestID：rejected，命令未执行（例如当前未在采样）。原报告未被设置页清空或覆盖，不能把旧报告视为新命令成功。";
        [self lpAlert:busy ? @"正在采样，拒绝重复开始" : @"诊断命令被拒绝" message:self.lpFeedback];
    } else if ([status isEqualToString:@"error"]) {
        // Treat any SB error as rejection. Explicitly cover busy/rejected without exposing arbitrary report text.
        self.lpFeedback = @"SpringBoard 返回 error / 拒绝命令；若为重复开始或 busy / rejected，未开始新的采样。不会由设置页清空或覆盖旧报告。";
        [self lpAlert:@"诊断命令被拒绝" message:self.lpFeedback];
    } else if ([self.lpCommand isEqualToString:@"start"] && [status isEqualToString:@"recording"]) {
        self.lpFeedback = @"已核验本次 requestID：SpringBoard 已接受开始；recording 不是完整导出。请去播放器放歌、锁屏 30 秒，亮屏后返回停止。";
    } else if (([self.lpCommand isEqualToString:@"start"] || [self.lpCommand isEqualToString:@"stop"]) &&
               [status isEqualToString:@"completed"]) {
        self.lpFeedback = @"已核验本次 requestID 和 completed 完整报告，可手动导出；这不表示问题已修复。";
    } else if ([self.lpCommand isEqualToString:@"clear"] && [status isEqualToString:@"cleared"]) {
        self.lpFeedback = @"已核验本次 requestID：仅诊断报告已清除，没有恢复默认或修改设置。";
    } else {
        self.lpFeedback = @"收到相同 requestID，但报告状态不是该命令预期的完成状态；未确认操作成功。请返回重读，或稍后停止并保存。";
        [self lpAlert:@"状态尚未完成" message:self.lpFeedback];
    }
    [self.tableView reloadData];
    return YES;
}
- (void)lpConfirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"仅清除诊断报告？"
        message:@"此操作请求 SpringBoard 清除本次诊断报告；若仍在采样，将结束本次诊断。不是恢复默认，不修改任何 Letterpress 设置。取消不会发送命令。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清除诊断报告" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf lpSendCommand:@"clear"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)lpExportFromIndexPath:(NSIndexPath *)indexPath {
    [self lpReload];
    if (!self.lpReport) {
        [self lpAlert:@"无法导出诊断" message:self.lpProblem ?: @"尚无有效报告；未确认诊断模块已启动。"];
        return;
    }
    if (![self lpReportMatchesLatestRequest]) {
        NSDictionary *ack = [self lpLastCommandForLatestRequest];
        id reason = ack[@"reasonCode"];
        if ([ack[@"status"] isEqualToString:@"rejected"] && [reason isKindOfClass:NSNumber.class] &&
            [reason integerValue] == 38 && [self.lpReport[@"status"] isEqualToString:@"completed"]) {
            NSData *snapshot = self.lpReportData;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"停止未执行；已有完成报告"
                message:@"SpringBoard 已应答此停止命令为 rejected / 当前未采样（可能已满 90 秒自动结束）。现存的是原 requestID 的 completed 报告，不是本次停止成功或新采样结果。是否明确导出这个已有报告？"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            __weak typeof(self) weakSelf = self;
            [alert addAction:[UIAlertAction actionWithTitle:@"导出已有完成报告" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf lpShareData:snapshot fromIndexPath:indexPath]; }];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [self lpAlert:@"不是本次命令的报告" message:@"现有报告未应答最新 requestID，可能是旧报告或诊断注入未启动。不会把它当成本次采样成功；请确认 SpringBoard 诊断模块后手动重新开始。"];
        return;
    }
    if (![self.lpReport[@"status"] isEqualToString:@"completed"]) {
        [self lpAlert:@"尚无完整报告" message:[self lpSummary]];
        return;
    }
    [self lpShareData:self.lpReportData fromIndexPath:indexPath];
}
- (void)lpShareData:(NSData *)data fromIndexPath:(NSIndexPath *)indexPath {
    if (!self.lpVisible || self.presentedViewController) return;
    if (!data || data.length > LPWakeReportLimit) {
        [self lpAlert:@"无法导出诊断" message:@"报告为空或超出 384 KB 上限。"];
        return;
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *name = [@"Letterpress-Diagnostics-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:name isDirectory:YES];
    NSURL *file = [directory URLByAppendingPathComponent:@"Letterpress-diagnostics.json" isDirectory:NO];
    NSError *error = nil;
    // A unique 0700 directory prevents access during atomic-file creation; the final file is 0600.
    BOOL madeDirectory = [manager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:@{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication, NSFilePosixPermissions: @0700
    } error:&error];
    BOOL written = madeDirectory && [data writeToURL:file
        options:(NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication) error:&error];
    BOOL secured = written && [manager setAttributes:@{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication, NSFilePosixPermissions: @0600
    } ofItemAtPath:file.path error:&error];
    if (!secured) {
        // No activity sheet owns a failed staging file; remove only our own newly created directory.
        if (madeDirectory) { [manager removeItemAtURL:file error:NULL]; [manager removeItemAtURL:directory error:NULL]; }
        [self lpAlert:@"无法准备分享文件" message:@"写入临时 JSON 或设置文件保护/0600 权限失败，未打开分享页、未导出或上传。"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    // Keep the file alive through the share sheet, even if this settings controller is released.
    activity.completionWithItemsHandler = ^(__unused UIActivityType type, __unused BOOL completed,
                                            __unused NSArray *items, __unused NSError *activityError) {
        NSFileManager *cleanup = NSFileManager.defaultManager;
        [cleanup removeItemAtURL:file error:NULL];
        [cleanup removeItemAtURL:directory error:NULL];
    };
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.tableView;
        popover.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:activity animated:YES completion:nil];
}
@end
