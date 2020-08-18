//
//  MetalView.h
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 25.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import <Quartz/Quartz.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalView : NSView

@property (nonatomic, readonly) CAMetalLayer *metalLayer;

@end

NS_ASSUME_NONNULL_END
