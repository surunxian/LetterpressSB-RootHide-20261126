#import "LPSBNotifyCenter.h"

@implementation LPSBNotifyCenter
+ (int32_t)registerName:(NSString *)name handler:(void (^)(void))handler {
    if (name.length == 0 || !handler) return -1;
    __block int32_t token = -1;
    int status = notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(int received) {
        handler();
    });
    return status == NOTIFY_STATUS_OK ? token : -1;
}
+ (void)cancel:(int32_t)token {
    if (token >= 0) notify_cancel(token);
}
+ (void)postName:(NSString *)name {
    if (name.length) notify_post(name.UTF8String);
}
@end
