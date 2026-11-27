#import "LPSBEnvironment.h"
#import "LPSBWakeDiagnostics.h"
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
static BOOL gKeychainLocked = YES;
static int32_t gKeychainToken = -1;
static int (*gGetDeviceLockState)(CFDictionaryRef);
static id gOrientationObserver;
static UIInterfaceOrientation gWindowOrientation = UIInterfaceOrientationUnknown;

// The original HUD reads MobileKeyBag only at startup and lock-status events.
// Resolve its existing API here without linking the injected dylib to a new
// private-framework install name. Missing state is fail-closed, not unlocked.
static void LPRefreshKeychainLockState(void) {
    if (!gGetDeviceLockState) { gKeychainLocked = YES; return; }
    int state = gGetDeviceLockState(NULL);
    gKeychainLocked = state < 0 || state == 1 || state == 2;
}

static void LPInstallOriginalPolicyInputs(void) {
    void *keybag = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_LAZY | RTLD_LOCAL);
    void *symbols = keybag ? keybag : RTLD_DEFAULT;
    gGetDeviceLockState = (int (*)(CFDictionaryRef))dlsym(symbols, "MKBGetDeviceLockState");
    CFStringRef *notification = (CFStringRef *)dlsym(symbols, "kMobileKeyBagLockStatusNotification");
    if (gGetDeviceLockState && notification && *notification) {
        uint32_t status = notify_register_dispatch([(__bridge NSString *)*notification UTF8String], &gKeychainToken,
                                                  dispatch_get_main_queue(), ^(int token) {
            (void)token;
            LPSBWakeDiagnosticMark(LPWakeStageKeybagCallback, 0, 0);
            LPRefreshKeychainLockState();
            [LPSBOverlayHost refreshVisibility];
        });
        if (status == NOTIFY_STATUS_OK) {
            LPRefreshKeychainLockState();
        } else {
            // Do not treat a one-off query as a live, subscribed lock state.
            // Leave policy fail-closed without wake-time polling or re-registering.
            gKeychainToken = -1;
            gGetDeviceLockState = NULL;
            gKeychainLocked = YES;
            NSLog(@"[Letterpress] keychain notification registration failed (%u)", (unsigned int)status);
        }
    } else {
        gGetDeviceLockState = NULL;
    }

    // Same FBSOrientationObserver input as upstream; never set SpringBoard's
    // device orientation or replace its UIApplication/delegate/run loop.
    Class cls = NSClassFromString(@"FBSOrientationObserver");
    id observer = cls ? [[cls alloc] init] : nil;
    SEL handlerSelector = NSSelectorFromString(@"setHandler:");
    if (observer && [observer respondsToSelector:handlerSelector]) {
        void (^handler)(id) = ^(id update) {
            SEL selector = NSSelectorFromString(@"orientation");
            if (![update respondsToSelector:selector]) return;
            NSInteger orientation = ((NSInteger (*)(id, SEL))objc_msgSend)(update, selector);
            dispatch_async(dispatch_get_main_queue(), ^{
                gWindowOrientation = (UIInterfaceOrientation)orientation;
                [LPSBOverlayHost refreshVisibility];
            });
        };
        ((void (*)(id, SEL, id))objc_msgSend)(observer, handlerSelector, handler);
        gOrientationObserver = observer;
    }
}

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
+ (BOOL)isKeychainLocked { return gKeychainLocked; }
+ (BOOL)isLandscape {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    if (gOrientationObserver) return UIInterfaceOrientationIsLandscape(gWindowOrientation);
    // Compatibility fallback when the original private observer is unavailable;
    // do not let an unrelated external-display scene hide the main-screen HUD.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.screen != UIScreen.mainScreen) continue;
        UIInterfaceOrientation orientation = windowScene.interfaceOrientation;
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
    LPSBWakeDiagnosticMark(LPWakeStageWindowRegisterBegin, contextID, 0);
    [invocation invoke];
    LPSBWakeDiagnosticMark(LPWakeStageWindowRegisterEnd, contextID, 0);
    gWindowHostingController = host;
    gWindowContextID = contextID;
    return YES;
}

static void LPUnregisterOverlayWindow(void) {
    LPSBWakeDiagnosticMark(LPWakeStageWindowUnregister, gWindowContextID, 0);
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
    LPInstallOriginalPolicyInputs();
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &gBlankToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 1;
        gBlanked = notify_get_state(token, &state) == NOTIFY_STATUS_OK ? (state != 0) : YES;
        LPSBWakeDiagnosticMark(LPWakeStageBlankCallback, gBlanked, 0);
        [self refreshVisibility];
    });
    notify_register_dispatch("com.apple.springboard.lockstate", &gLockToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        // refreshVisibility re-queries the live lock manager before any show.
        LPSBWakeDiagnosticMark(LPWakeStageLockCallback, 0, 0);
        [self refreshVisibility];
    });
    uint64_t blankState = 1;
    if (gBlankToken >= 0 && notify_get_state(gBlankToken, &blankState) == NOTIFY_STATUS_OK) gBlanked = (blankState != 0);
    [LPSBEnvironment isLocked];
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
    LPSBWakeDiagnosticMark(LPWakeStageSceneChanged, (uint64_t)(__bridge void *)note.object, 0);
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
    // As upstream, retain a visible secure window and gate the root view.
    // Initialise the entire original containment chain while still hidden.
    controller.view.hidden = YES;
    window.rootViewController = controller;
    gWindow = window;
    if (!LPRegisterOverlayWindow(window)) {
        window.hidden = YES;
        window.rootViewController = nil;
        gWindow = nil;
        return;
    }
    window.hidden = NO; // Root is already hidden; never make SpringBoard's overlay key.
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
    LPSBWakeDiagnosticMark(LPWakeStageRefreshBegin, gWindowContextID, gBlanked);
    @try {
    Class plugin = NSClassFromString(@"LPSBPlugin");
    SEL refreshSelector = NSSelectorFromString(@"refresh");
    // Blank is hide-only, never an inference about lock state. Keep an existing
    // window idle; initial bootstrap still prewarms the root (not on first wake).
    if (gBlanked && gWindow) {
        if (!gWindow.rootViewController.view.hidden) gWindow.rootViewController.view.hidden = YES;
        if ([plugin respondsToSelector:refreshSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(plugin, refreshSelector);
        }
        return;
    }
    UIWindowScene *scene = LPOverlayScene();
    if (gWindow && (!scene || gWindow.windowScene != scene)) LPUnregisterOverlayWindow();
    if (!scene) return;
    if (!gWindow) {
        SEL makeSelector = NSSelectorFromString(@"makeRootViewController");
        LPSBWakeDiagnosticMark(LPWakeStageRootCreateBegin, 0, 0);
        UIViewController *root = [plugin respondsToSelector:makeSelector] ? ((id (*)(id, SEL))objc_msgSend)(plugin, makeSelector) : nil;
        LPSBWakeDiagnosticMark(LPWakeStageRootCreateEnd, root != nil, 0);
        if (root) [self startWithRootViewController:root];
    }
    if (!gWindow) return;
    CGRect bounds = scene.coordinateSpace.bounds;
    if (!CGRectEqualToRect(gWindow.frame, bounds)) gWindow.frame = bounds;
    SEL visibleSelector = NSSelectorFromString(@"shouldShowOverlay");
    if (!plugin || ![plugin respondsToSelector:refreshSelector] || ![plugin respondsToSelector:visibleSelector]) {
        gWindow.rootViewController.view.hidden = YES;
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(plugin, refreshSelector);
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(plugin, visibleSelector);
    if (gWindow.rootViewController.view.hidden != !visible) gWindow.rootViewController.view.hidden = !visible;
    } @finally {
        uint64_t diagnosticFlags = (gBlanked ? 1u : 0u) | (gLocked ? 2u : 0u) | (gLockKnown ? 4u : 0u);
        LPSBWakeDiagnosticWindow(gWindowContextID, (uint64_t)(__bridge void *)gWindow.windowScene, diagnosticFlags);
        LPSBWakeDiagnosticMark(LPWakeStageRefreshEnd, gWindowContextID, diagnosticFlags);
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
        LPSBWakeDiagnosticsInstall();
        LPSBBootstrap(30); // Bounded launch retries; later events can also recreate the window.
    });
}
