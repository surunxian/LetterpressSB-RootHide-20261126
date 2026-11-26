#import "LPSBEnvironment.h"
#import <objc/message.h>
#import <notify.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

static void LPSBImageMarker(void) {}

static BOOL gLocked = YES;
static BOOL gLockKnown = NO;
static BOOL gBlanked = YES;
static int32_t gBlankToken = -1;
static int32_t gLockToken = -1;
static LPSBPassThroughWindow *gWindow;
static id gWindowHostingController;
static unsigned int gWindowContextID;
static BOOL gRefreshingVisibility = NO;
static BOOL gStartingWindow = NO;
static __weak UIScene *gDisconnectedScene;

@implementation LPSBEnvironment
+ (BOOL)isLocked {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    id manager = nil;
    if (cls && [cls respondsToSelector:sharedSelector]) {
        manager = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSelector);
    }
    for (NSString *name in @[@"isUILocked", @"isUILockedForUI", @"isLocked"]) {
        SEL selector = NSSelectorFromString(name);
        if (manager && [manager respondsToSelector:selector]) {
            gLocked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, selector);
            gLockKnown = YES;
            return gLocked;
        }
    }
    // Unknown lock state is fail-closed; never expose the overlay by guessing.
    gLocked = YES;
    gLockKnown = NO;
    return YES;
}
+ (BOOL)isLockStateKnown { return gLockKnown; }
+ (BOOL)isScreenBlanked { return gBlanked; }
+ (BOOL)isLandscape {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIInterfaceOrientation orientation = ((UIWindowScene *)scene).interfaceOrientation;
        if (UIInterfaceOrientationIsLandscape(orientation)) return YES;
    }
    return NO;
}
+ (BOOL)isScreenCaptured { return UIScreen.mainScreen.isCaptured; }
+ (NSString *)resourceBundlePath {
    // Resolve the actual loaded image rather than assuming /var/jb or a stable jbroot.
    Dl_info info = {};
    if (dladdr((const void *)&LPSBImageMarker, &info) && info.dli_fname) {
        NSURL *image = [NSURL fileURLWithPath:[NSString stringWithUTF8String:info.dli_fname]];
        NSURL *directory = image.URLByDeletingLastPathComponent;
        NSURL *substrate = directory.URLByDeletingLastPathComponent;
        NSURL *library = substrate.URLByDeletingLastPathComponent;
        if ([directory.lastPathComponent isEqualToString:@"DynamicLibraries"] &&
            [substrate.lastPathComponent isEqualToString:@"MobileSubstrate"] &&
            [library.lastPathComponent isEqualToString:@"Library"]) {
            NSString *path = [library URLByAppendingPathComponent:@"Application Support/LetterpressSB.bundle"].path;
            if ([NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Info.plist"]]) return path;
        }
    }
    return nil;
}
@end

@implementation LPSBPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)_ignoresHitTest { return YES; }
+ (BOOL)_isSecure { return YES; }
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
@end

static UIWindowScene *LPOverlayScene(void) {
    UIWindowScene *candidate = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene == gDisconnectedScene) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.screen != UIScreen.mainScreen) continue;
        UISceneActivationState state = scene.activationState;
        if (state != UISceneActivationStateForegroundActive &&
            state != UISceneActivationStateForegroundInactive && state != UISceneActivationStateBackground) continue;
        // A SpringBoard system overlay must not track the foreground app's scene state.
        // Keep a connected hosting scene stable; lock/blank/capture policy still gates visibility.
        if (gWindow.windowScene == windowScene) return windowScene;
        if (!candidate || state == UISceneActivationStateForegroundActive ||
            (state == UISceneActivationStateForegroundInactive &&
             candidate.activationState == UISceneActivationStateBackground)) candidate = windowScene;
    }
    return candidate;
}

static BOOL LPRegisterOverlayWindow(LPSBPassThroughWindow *window) {
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    if (![window respondsToSelector:contextSelector]) return NO;
    unsigned int contextID = ((unsigned int (*)(id, SEL))objc_msgSend)(window, contextSelector);
    if (!contextID) return NO;
    SEL boundSelector = NSSelectorFromString(@"_boundContext");
    id context = [window respondsToSelector:boundSelector] ? ((id (*)(id, SEL))objc_msgSend)(window, boundSelector) : nil;
    SEL secureSelector = NSSelectorFromString(@"setSecure:");
    if (context && [context respondsToSelector:secureSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(context, secureSelector, YES);
    }
    Class hostClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    id host = hostClass ? [[hostClass alloc] init] : nil;
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (!host || ![host respondsToSelector:registerSelector]) return NO;
    NSMethodSignature *signature = [host methodSignatureForSelector:registerSelector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    double level = window.windowLevel;
    invocation.target = host;
    invocation.selector = registerSelector;
    [invocation setArgument:&contextID atIndex:2];
    [invocation setArgument:&level atIndex:3];
    [invocation invoke];
    gWindowHostingController = host;
    gWindowContextID = contextID;
    return YES;
}

static void LPUnregisterOverlayWindow(void) {
    gWindow.hidden = YES;
    SEL selector = NSSelectorFromString(@"unregisterWindowWithContextID:");
    if (gWindowHostingController && gWindowContextID &&
        [gWindowHostingController respondsToSelector:selector]) {
        NSMethodSignature *signature = [gWindowHostingController methodSignatureForSelector:selector];
        if (signature.numberOfArguments == 3) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = gWindowHostingController;
            invocation.selector = selector;
            unsigned int contextID = gWindowContextID;
            [invocation setArgument:&contextID atIndex:2];
            [invocation invoke];
        }
    }
    gWindow.rootViewController = nil;
    gWindow = nil;
    gWindowHostingController = nil;
    gWindowContextID = 0;
}

@implementation LPSBOverlayHost
+ (void)installObservers {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &gBlankToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 1;
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) gBlanked = (state != 0);
        [self refreshVisibility];
    });
    notify_register_dispatch("com.apple.springboard.lockstate", &gLockToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        [LPSBEnvironment isLocked];
        [self refreshVisibility];
    });
    uint64_t blankState = 1;
    if (gBlankToken >= 0 && notify_get_state(gBlankToken, &blankState) == NOTIFY_STATUS_OK) gBlanked = (blankState != 0);
    [LPSBEnvironment isLocked];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshVisibility)
        name:UIScreenCapturedDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:)
        name:UISceneDidActivateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:)
        name:UISceneWillDeactivateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:)
        name:UISceneDidDisconnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:)
        name:UISceneWillConnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:)
        name:UISceneWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:)
        name:UISceneDidEnterBackgroundNotification object:nil];
    });
}
+ (void)sceneChanged:(NSNotification *)note {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self sceneChanged:note]; }); return; }
    if ([note.name isEqualToString:UISceneDidDisconnectNotification]) {
        gDisconnectedScene = note.object;
        if (note.object == gWindow.windowScene) LPUnregisterOverlayWindow();
    } else if (note.object == gDisconnectedScene &&
               ([note.name isEqualToString:UISceneWillConnectNotification] ||
                [note.name isEqualToString:UISceneDidActivateNotification] ||
                [note.name isEqualToString:UISceneWillEnterForegroundNotification])) {
        gDisconnectedScene = nil;
    }
    // Deactivation is not a screen-lock signal in SpringBoard.
    [self refreshVisibility];
}
+ (void)startWithRootViewController:(UIViewController *)controller {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self startWithRootViewController:controller]; }); return; }
    [self installObservers];
    if (gWindow || !controller || gStartingWindow) return;
    UIWindowScene *scene = LPOverlayScene();
    if (!scene) return;
    gStartingWindow = YES;
    @try {
    LPSBPassThroughWindow *window = [[LPSBPassThroughWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.clipsToBounds = YES;
    window.windowLevel = 10000001.0;
    window.rootViewController = controller;
    gWindow = window;
    if (!LPRegisterOverlayWindow(window)) {
        window.hidden = YES;
        window.rootViewController = nil;
        gWindow = nil;
        return;
    }
    window.hidden = YES; // Fail closed until lock/blank/capture policy is checked.
    } @finally {
        gStartingWindow = NO;
    }
    [self refreshVisibility];
}
+ (void)refreshVisibility {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshVisibility]; }); return; }
    [self installObservers];
    if (gRefreshingVisibility || gStartingWindow) return;
    gRefreshingVisibility = YES;
    @try {
    UIWindowScene *scene = LPOverlayScene();
    if (gWindow && (!scene || gWindow.windowScene != scene)) LPUnregisterOverlayWindow();
    if (!scene) return;
    Class plugin = NSClassFromString(@"LPSBPlugin");
    if (!gWindow) {
        SEL makeSelector = NSSelectorFromString(@"makeRootViewController");
        UIViewController *root = [plugin respondsToSelector:makeSelector] ? ((id (*)(id, SEL))objc_msgSend)(plugin, makeSelector) : nil;
        if (root) [self startWithRootViewController:root];
    }
    if (!gWindow) return;
    gWindow.frame = scene.coordinateSpace.bounds;
    SEL refreshSelector = NSSelectorFromString(@"refresh");
    SEL visibleSelector = NSSelectorFromString(@"shouldShowOverlay");
    if (!plugin || ![plugin respondsToSelector:refreshSelector] || ![plugin respondsToSelector:visibleSelector]) {
        gWindow.hidden = YES;
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(plugin, refreshSelector);
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(plugin, visibleSelector);
    gWindow.hidden = !visible;
    } @finally {
        gRefreshingVisibility = NO;
    }
}
@end

static void LPSBBootstrap(NSUInteger attemptsRemaining) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    // Register observers before asking Swift for a root, even if Swift/scenes are not ready.
    [LPSBOverlayHost refreshVisibility];
    if (gWindow || attemptsRemaining <= 1) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        LPSBBootstrap(attemptsRemaining - 1);
    });
}

__attribute__((constructor)) static void LPSBConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LPSBBootstrap(30); // Bounded launch retries; later events can also recreate the window.
    });
}
