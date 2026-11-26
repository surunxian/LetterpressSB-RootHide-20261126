#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Minimal private Preferences ABI declarations used by the bundle principal class.
@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface LPSBRootListController : PSListController
@end

@implementation LPSBRootListController {
    NSArray *_cachedSpecifiers;
}
- (NSArray *)specifiers {
    if (!_cachedSpecifiers) _cachedSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _cachedSpecifiers ?: @[];
}
@end
