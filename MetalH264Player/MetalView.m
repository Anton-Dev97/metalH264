//
//  MetalView.m
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 25.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#import "MetalView.h"

#import <MetalKit/MetalKit.h>

@interface MetalView ()

@property (nonatomic) CAMetalLayer *metalLayer;

@end

@implementation MetalView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.metalLayer = [CAMetalLayer new];
        self.metalLayer.device = MTLCreateSystemDefaultDevice();
        self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        self.layer = _metalLayer;
        self.wantsLayer = YES;
    }
    return self;
}

@end
