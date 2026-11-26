#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Minimal Preferences declarations matching the public PSListController ABI.
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target;
@end

@interface LPSBRootListController : PSListController
@end

@implementation LPSBRootListController
- (NSMutableArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers ?: [NSMutableArray array];
}
@end
