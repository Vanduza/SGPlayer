//
//  SGAudioFrame.h
//  SGPlayer
//
//  Created by Single on 2018/1/19.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGFrame.h"
#import "SGAudioDescription.h"

NS_ASSUME_NONNULL_BEGIN

@interface SGAudioFrame : SGFrame

/**
 *
 */
@property (nonatomic, strong, readonly) SGAudioDescription *audioDescription;

/**
 *
 */
@property (nonatomic, readonly) int numberOfSamples;

/**
 *
 */
- (int *)linesize;

/**
 *
 */
- (uint8_t **)data;

@end

NS_ASSUME_NONNULL_END
