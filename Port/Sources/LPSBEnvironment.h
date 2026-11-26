#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface LPSBEnvironment : NSObject
+ (BOOL)isLocked;
+ (BOOL)isLockStateKnown;
+ (BOOL)isScreenBlanked;
+ (BOOL)isLandscape;
+ (BOOL)isScreenCaptured;
+ (nullable NSString *)resourceBundlePath;
@end

@interface LPSBPassThroughWindow : UIWindow
@end

@interface LPSBOverlayHost : NSObject
+ (void)startWithRootViewController:(nullable UIViewController *)controller;
+ (void)refreshVisibility;
@end
