//
//  NSData+XXHash.h
//  xxHash-ObjC
//
//  Created by Matthew Smith on 3/24/16.
//  Copyright © 2016 Latte, Jed?. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSData (LPSBXXHash)

- (NSString *)lp_xxh32;
- (NSString *)lp_xxh64;

@end
