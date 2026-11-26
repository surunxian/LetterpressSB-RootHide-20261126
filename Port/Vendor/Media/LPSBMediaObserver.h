//
//  LPSBMediaObserver.h
//  TRHud
//
//  Created by Rachel on 9/6/2025.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

OBJC_EXTERN NSNotificationName const LPSBMediaObserverDidChangeNotification;
OBJC_EXTERN NSNotificationName const LPSBMediaObserverArtworkDidChangeNotification;

@class UIImage;

@interface LPSBMediaObserver : NSObject

@property (nonatomic, strong, readonly) NSDictionary *_Nullable nowPlayingInfo;
@property (nonatomic, assign, readonly, getter=isNowPlaying) BOOL nowPlaying;

@property (nonatomic, copy, readonly) NSString *_Nullable nowPlayingApp;
@property (nonatomic, copy, readonly) NSString *_Nullable nowPlayingSubtitle;

@property (nonatomic, assign, getter=isArtworkDecodingRequired) BOOL artworkDecodingRequired;
@property (nonatomic, strong, readonly) UIImage *_Nullable nowPlayingArtwork;

@end

NS_ASSUME_NONNULL_END
