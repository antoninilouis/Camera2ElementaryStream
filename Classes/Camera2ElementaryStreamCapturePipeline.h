//
//  Camera2ElementaryStreamCapturePipeline.h
//  Camera2ElementaryStream (iOS)
//
//  Created by Antonini Louis on 2020-12-25.
//

#ifndef Camera2ElementaryStreamCapturePipeline_h
#define Camera2ElementaryStreamCapturePipeline_h

#import <AVFoundation/AVFoundation.h>

@protocol Camera2ElementaryStreamCapturePipelineDelegate
@required
- (void)startRendering:(AVCaptureVideoPreviewLayer *)previewLayer;

@end

@interface Camera2ElementaryStreamCapturePipeline : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

- (instancetype)initWithDelegate:(id<Camera2ElementaryStreamCapturePipelineDelegate>)delegate callbackQueue:(dispatch_queue_t)queue;

- (void)startRunning;

- (void)startRendering;

@property(nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;

@end

#endif /* Camera2ElementaryStreamCapturePipeline_h */
