//
//  RenderingPipeline.m
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 25.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#import "RenderingPipeline.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <AVFoundation/AVFoundation.h>

@implementation RenderingPipeline
{
    CAMetalLayer *_layer;
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _state;
    id<MTLCommandQueue> _commandQueue;
    id<MTLBuffer> _vertexBuffer;
    CVMetalTextureCacheRef _textureCache;
}

- (instancetype)initWithLayer:(CAMetalLayer *)layer error:(NSError **)error {
    self = [super init];
    if (self) {
        _layer = layer;
        _device = layer.device;

        id<MTLLibrary> library = [_device newDefaultLibrary];
        if (library == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertex_shader"];
        if (vertexFunction == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragment_shader"];
        if (fragmentFunction == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        MTLVertexDescriptor *vertexDescriptor = [MTLVertexDescriptor new];
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2; // position
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2; // texCoords
        vertexDescriptor.attributes[1].offset = 2 * sizeof(simd_float1);
        vertexDescriptor.attributes[1].bufferIndex = 0;
        vertexDescriptor.layouts[0].stride = 4 * sizeof(simd_float1);
        vertexDescriptor.layouts[0].stepFunction = MTLStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;

        _state = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:error];
        if (_state == nil) {
            return nil;
        }

        _commandQueue = [_device newCommandQueue];
        if (_commandQueue == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        _vertexBuffer = [_device newBufferWithLength:16 * sizeof(simd_float1) options:0];

        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache) != kCVReturnSuccess) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }
    }
    return self;
}

- (void)render:(CVPixelBufferRef)frame {
    int width = (int)CVPixelBufferGetWidth(frame);
    int height = (int)CVPixelBufferGetHeight(frame);

    CVMetalTextureRef texture = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, NULL, MTLPixelFormatR8Unorm, width, height, 0, &texture);
    if (texture == NULL) {
        return;
    }

    id<MTLTexture> lumaTexture = CVMetalTextureGetTexture(texture);

    CFRelease(texture);
    texture = NULL;

    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &texture);
    if (texture == NULL) {
        return;
    }

    id<MTLTexture> chromaTexture = CVMetalTextureGetTexture(texture);

    CFRelease(texture);
    texture = NULL;

    id<CAMetalDrawable> drawable = _layer.nextDrawable;
    if (drawable == nil) {
        NSLog(@"Error: drawable is nil");
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (commandBuffer == nil) {
        return;
    }

    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor new];
    renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);

    id<MTLRenderCommandEncoder> commandEndoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    // Set up the quad vertices with respect to the orientation and aspect ratio of the video.
    CGSize aspectRatio = CGSizeMake(width, height);
    CGRect vertexSamplingRect = AVMakeRectWithAspectRatioInsideRect(aspectRatio, _layer.bounds);

    // Compute normalized quad coordinates to draw the frame into.
    CGSize normalizedSamplingSize = CGSizeMake(0.0, 0.0);
    CGSize cropScaleAmount = CGSizeMake(vertexSamplingRect.size.width / _layer.bounds.size.width,
                                        vertexSamplingRect.size.height / _layer.bounds.size.height);

    // Normalize the quad vertices.
    if (cropScaleAmount.width > cropScaleAmount.height) {
        normalizedSamplingSize.width = 1.0;
        normalizedSamplingSize.height = cropScaleAmount.height / cropScaleAmount.width;
    } else {
        normalizedSamplingSize.width = 1.0;
        normalizedSamplingSize.height = cropScaleAmount.width / cropScaleAmount.height;
    }

    CGRect textureSamplingRect = CGRectMake(0, 0, 1, 1);
    simd_float1 vertexData[] = {
        -1 * normalizedSamplingSize.width, -1 * normalizedSamplingSize.height, CGRectGetMinX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
        normalizedSamplingSize.width, -1 * normalizedSamplingSize.height, CGRectGetMaxX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
        -1 * normalizedSamplingSize.width, normalizedSamplingSize.height, CGRectGetMinX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
        normalizedSamplingSize.width, normalizedSamplingSize.height, CGRectGetMaxX(textureSamplingRect), CGRectGetMinY(textureSamplingRect)
    };
    memcpy(_vertexBuffer.contents, vertexData, 16 * sizeof(simd_float1));
    [commandEndoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];

    [commandEndoder setFragmentTexture:lumaTexture atIndex:0];
    [commandEndoder setFragmentTexture:chromaTexture atIndex:1];

    [commandEndoder setRenderPipelineState:_state];
    [commandEndoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [commandEndoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    [commandBuffer waitUntilCompleted];
}

@end
