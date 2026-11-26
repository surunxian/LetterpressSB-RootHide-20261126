#import <Foundation/Foundation.h>
#import <notify.h>

@interface LPSBNotifyCenter : NSObject
+ (int32_t)registerName:(NSString *)name handler:(void (^)(void))handler;
+ (void)cancel:(int32_t)token;
+ (void)postName:(NSString *)name;
@end
