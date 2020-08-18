//
//  ViewController.m
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 25.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#import "ViewController.h"

#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <vector>
#include <mutex>
#include <optional>

#import "MetalView.h"
#import "RenderingPipeline.h"

struct PlayerFrame {
    CVImageBufferRef imageBuffer;
    CMTime time;
};

struct PlayerFrameQueue {
    std::vector<PlayerFrame> buffer;
    std::mutex mutex;

    dispatch_semaphore_t bufferSemaphore;

    std::optional<PlayerFrame> getFrame() {
        std::lock_guard<std::mutex> guard(mutex);

        if (!buffer.empty()) {
            return buffer.front();
        }
        return std::nullopt;
    }

    void addFrame(CVImageBufferRef imageBuffer, CMTime time) {
        std::lock_guard<std::mutex> guard(mutex);

        CFRetain(imageBuffer);

        for (size_t i = 0; i < buffer.size(); i++) {
            size_t p = buffer.size() - i - 1;
            if (CMTimeGetSeconds(buffer[p].time) <= CMTimeGetSeconds(time)) {
                buffer.insert(buffer.begin() + p + 1, {imageBuffer, time});
                return;
            }
        }

        buffer.insert(buffer.begin(), {imageBuffer, time});
    }

    void removeFrame() {
        std::lock_guard<std::mutex> guard(mutex);

        if (!buffer.empty()) {
            CFRelease(buffer.front().imageBuffer);
            buffer.erase(buffer.begin());
        }

        if (buffer.size() == 3) {
            dispatch_semaphore_signal(bufferSemaphore);
        }
    }

    size_t size() const {
        return buffer.size();
    }
};

@interface ViewController ()

@property (nonatomic) RenderingPipeline *pipeline;

@property (nonatomic) AVAssetReader *assetReader;
@property (nonatomic) VTDecompressionSessionRef decompressionSession;
@property (nonatomic) dispatch_queue_t backgroundQueue;
@property (nonatomic) CFTimeInterval startTime;
@property (nonatomic) CGAffineTransform videoPreferredTransform;
@property (nonatomic) NSArray *videoTracks;

@end

@implementation ViewController
{
    NSButton *_button;
    MetalView *_metalView;
    RenderingPipeline *_pipeline;
    CVDisplayLinkRef _displayLink;

    PlayerFrameQueue _queue;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.backgroundQueue = dispatch_queue_create("com.lunarkey.backgroundqueue", NULL);
    self.startTime = 0.0;
    _queue.bufferSemaphore = dispatch_semaphore_create(0);

    _button = [NSButton buttonWithTitle:@"Open" target:self action:@selector(showOpenFile)];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_button];

    [NSLayoutConstraint activateConstraints:@[
        [_button.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:5],
        [_button.leftAnchor constraintEqualToAnchor:self.view.leftAnchor constant:5],
        [_button.widthAnchor constraintEqualToConstant:100],
        [_button.heightAnchor constraintEqualToConstant:30]
    ]];

    _metalView = [MetalView new];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_metalView];

    [NSLayoutConstraint activateConstraints:@[
        [_metalView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_metalView.leftAnchor constraintEqualToAnchor:self.view.leftAnchor],
        [_metalView.rightAnchor constraintEqualToAnchor:self.view.rightAnchor]
    ]];

    NSError *error;
    _pipeline = [[RenderingPipeline alloc] initWithLayer:_metalView.metalLayer error:&error];
    if (_pipeline == nil) {
        NSLog(@"Error: %@", error);
        return;
    }

    CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);

    __weak ViewController *weakSelf = self;
    CVDisplayLinkSetOutputHandler(_displayLink, ^CVReturn(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut) {
        [weakSelf render:inOutputTime->hostTime / 1000000000.0];
        return kCVReturnSuccess;
    });
}

- (void)viewWillDisappear {
    [super viewWillDisappear];

    CVDisplayLinkStop(_displayLink);
}

#pragma mark - Private

- (void)showOpenFile {
    NSOpenPanel *panel = [NSOpenPanel new];

    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;

    __weak ViewController *weakSelf = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        NSURL *url = panel.URLs.firstObject;
        if (url != nil) {
            [weakSelf playFile:url];
        }
    }];
}

- (void)playFile:(NSURL *)url {
    NSDictionary *inputOptions = @{AVURLAssetPreferPreciseDurationAndTimingKey: @(YES)};
    AVAsset *avAsset = [[AVURLAsset alloc] initWithURL:url options:inputOptions];

    NSError *error = nil;
    self.assetReader = [AVAssetReader assetReaderWithAsset:avAsset error:&error];
    if (error) {
        NSLog(@"Error creating Asset Reader: %@", error);
        return;
    }

    _button.hidden = YES;
    CVDisplayLinkStart(_displayLink);

    self.videoTracks = [avAsset tracksWithMediaType:AVMediaTypeVideo];

    dispatch_async(self.backgroundQueue, ^{
        [self readSampleBuffersFromAsset:avAsset];
    });
}

- (void)stopPlay {
    CVDisplayLinkStop(_displayLink);

    VTDecompressionSessionInvalidate(_decompressionSession);
    CFRelease(_decompressionSession);
    _decompressionSession = NULL;
}

- (void)readSampleBuffersFromAsset:(AVAsset *)asset {
    AVAssetTrack *videoTrack = (AVAssetTrack *)self.videoTracks.firstObject;

    [self createDecompressionSessionFromAssetTrack:videoTrack];
    AVAssetReaderTrackOutput *videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:nil];

    if ([self.assetReader canAddOutput:videoTrackOutput]) {
        [self.assetReader addOutput:videoTrackOutput];
    }

    BOOL didStart = [self.assetReader startReading];
    if (!didStart) {
        return;
    }

    while (self.assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
        if (sampleBuffer) {
            VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
            VTDecodeInfoFlags flagOut;
            VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, flags, NULL, &flagOut);

            CFRelease(sampleBuffer);
            // if we have 5 or more unprocessed frames then wait for processing
            if (_queue.size() >= 5) {
                dispatch_semaphore_wait(_queue.bufferSemaphore, DISPATCH_TIME_FOREVER);
            }
        } else if (self.assetReader.status == AVAssetReaderStatusFailed) {
            NSLog(@"Asset Reader failed with error: %@", self.assetReader.error);
        } else if (self.assetReader.status == AVAssetReaderStatusCompleted) {
            NSLog(@"Reached the end of the video.");
        }
    }
}

- (void)createDecompressionSessionFromAssetTrack:(AVAssetTrack *)track {
    id formatDescription = track.formatDescriptions.firstObject;

    NSDictionary *decoderSpecification = @{
        (NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @(YES)
    };

    self.videoPreferredTransform = track.preferredTransform;
    _decompressionSession = NULL;

    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @(YES),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionOutputCallbackRecord callBackRecord;
    callBackRecord.decompressionOutputCallback = didDecompress;
    callBackRecord.decompressionOutputRefCon = (__bridge void *)self;
    VTDecompressionSessionCreate(kCFAllocatorDefault,
                                 (__bridge CMVideoFormatDescriptionRef)formatDescription,
                                 (__bridge CFDictionaryRef)decoderSpecification,
                                 (__bridge CFDictionaryRef)attributes,
                                 &callBackRecord,
                                 &_decompressionSession);
}

- (void)render:(CFTimeInterval)time {
    if (self.startTime == 0.0f) {
        self.startTime = time;
    }
    CFTimeInterval timeSinceLastCallback = time - self.startTime;

    if (auto frame = _queue.getFrame()) {
        // check if the current time is greater than or equal to the presentation time of the sample buffer
        if (timeSinceLastCallback >= CMTimeGetSeconds(frame->time)) {
            [_pipeline render:frame->imageBuffer];
            _queue.removeFrame();
        } else {
            [_pipeline render:frame->imageBuffer];
        }
    }
}

#pragma mark - VideoToolBox Decompress Frame CallBack
/*
 This callback gets called everytime the decompresssion session decodes a frame
 */
void didDecompress(void *decompressionOutputRefCon,
                   void *sourceFrameRefCon,
                   OSStatus status,
                   VTDecodeInfoFlags infoFlags,
                   CVImageBufferRef imageBuffer,
                   CMTime presentationTimeStamp,
                   CMTime presentationDuration) {
    if (status != noErr) {
        NSLog(@"Error decompressing frame at time: %.3f error: %d infoFlags: %u",
              (float)presentationTimeStamp.value / presentationTimeStamp.timescale,
              (int)status,
              (unsigned int)infoFlags);
        return;
    }

    if (imageBuffer == NULL) {
        return;
    }

    if (!CMTIME_IS_VALID(presentationTimeStamp)) {
        NSLog(@"Not a valid time for image buffer: %@", imageBuffer);
        return;
    }

    ViewController *controller = (__bridge ViewController *)decompressionOutputRefCon;
    controller->_queue.addFrame(imageBuffer, presentationTimeStamp);
}

@end
