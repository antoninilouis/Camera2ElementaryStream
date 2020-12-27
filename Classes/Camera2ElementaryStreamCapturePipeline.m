//
//  Camera2ElementaryStreamCapturePipeline.m
//  Camera2ElementaryStream
//
//  Created by Antonini Louis on 2020-12-25.
//

#import <AVFoundation/AVFoundation.h>
#import "Camera2ElementaryStreamCapturePipeline.h"

/*
  Manages the capture session
  Uses formal delegation for capture session lifecycle
 */
@implementation Camera2ElementaryStreamCapturePipeline {
  AVCaptureSession *_captureSession;
  AVCaptureDevice *_videoDevice;
  AVCaptureConnection *_videoConnection;
  BOOL _running;
  BOOL _rendering;

  dispatch_queue_t _sessionQueue;
  dispatch_queue_t _videoDataOutputQueue;
  __weak id<Camera2ElementaryStreamCapturePipelineDelegate> _delegate;
  dispatch_queue_t _delegateCallbackQueue;
}

- (instancetype)initWithDelegate:(id<Camera2ElementaryStreamCapturePipelineDelegate>)delegate callbackQueue:(dispatch_queue_t)queue {
  self = [ super init ];

  _sessionQueue = dispatch_queue_create( "camera2elementarystream.capturepipeline.session", DISPATCH_QUEUE_SERIAL );

  _videoDataOutputQueue = dispatch_queue_create( "camera2elementarystream.capturepipeline.video", DISPATCH_QUEUE_SERIAL );
  dispatch_set_target_queue( _videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0 ) );

  _delegate = delegate;
  _delegateCallbackQueue = queue;

  return self;
}

- (void)startRunning
{
  dispatch_sync( _sessionQueue, ^{
    [self setupCaptureSession];
    
    if ( _captureSession ) {
      [_captureSession startRunning];
      _running = YES;
    }
  } );
}

#pragma mark - Capture Session

- (void)setupCaptureSession
{
  if ( _captureSession ) {
    return;
  }
  
  _captureSession = [[AVCaptureSession alloc] init];
  
  // Setup the capture session input
  AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  NSError *videoDeviceError = nil;
  AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:&videoDeviceError];
  [_captureSession addInput:videoIn];
  _videoDevice = videoDevice;

  // Setup the capture session output
  AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
//  videoOut.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(_renderer.inputPixelFormat) };
  [videoOut setSampleBufferDelegate:self queue:_videoDataOutputQueue];
  videoOut.alwaysDiscardsLateVideoFrames = NO;
  [_captureSession addOutput:videoOut];
  _videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];

  // Setup the capture session quality level or bitrate
  _captureSession.sessionPreset = AVCaptureSessionPresetHigh;

  // Use fixed frame rate
  CMTime frameDuration = CMTimeMake( 1, 30 );
  NSError *error = nil;
  if ( [videoDevice lockForConfiguration:&error] ) {
    videoDevice.activeVideoMaxFrameDuration = frameDuration;
    videoDevice.activeVideoMinFrameDuration = frameDuration;
    [videoDevice unlockForConfiguration];
  }
  else {
    NSLog( @"videoDevice lockForConfiguration returned error %@", error );
  }
  
  return;
}

#pragma mark - Capture Pipeline

- (void)setupVideoPipelineWithInputFormatDescription:(CMFormatDescriptionRef)inputFormatDescription
{
  NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
  self.outputVideoFormatDescription = inputFormatDescription;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
  CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription( sampleBuffer );
  
  if ( connection == _videoConnection )
  {
    if ( self.outputVideoFormatDescription == NULL ) {
      // Don't render the first sample buffer.
      // This gives us one frame interval (33ms at 30fps) for setupVideoPipelineWithInputFormatDescription: to complete.
      // Ideally this would be done asynchronously to ensure frames don't back up on slower devices.
      [self setupVideoPipelineWithInputFormatDescription:formatDescription];
    }
  }
}

- (void)startRendering
{
  if ( _rendering == YES ) {
    return;
  }
  // Create preview layer with captureSession
  AVCaptureVideoPreviewLayer *previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_captureSession];
  [previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
  [_delegate startRendering:previewLayer];
  _rendering = YES;
}

@end
