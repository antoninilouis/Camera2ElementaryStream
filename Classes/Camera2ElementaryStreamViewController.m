//
//  Camera2ElementaryStreamViewController.m
//  Camera2ElementaryStream (iOS)
//
//  Created by Antonini Louis on 2020-12-23.
//

#import "Camera2ElementaryStreamViewController.h"
#import "Camera2ElementaryStreamCapturePipeline.h"

@implementation Camera2ElementaryStreamViewController {
  Camera2ElementaryStreamCapturePipeline *_capturePipeline;
  BOOL _capturing;
}

NSString * const PREVIEW_LAYER_NAME = @"previewLayer";
NSString * const START_CAPTURE_BUTTON_TITLE = @"Stop Capture";
NSString * const STOP_CAPTURE_BUTTON_TITLE = @"Start Capture";

#pragma mark - View lifecycle

- (void)viewDidLoad
{
  [super viewDidLoad];
  _capturePipeline = [[Camera2ElementaryStreamCapturePipeline alloc] initWithDelegate:self callbackQueue:dispatch_get_main_queue()];
}

- (void)viewWillDisappear:(BOOL)animated
{
  // Not used for the moment
  NSLog( @"View will disappear" );
}

#pragma mark - UI

- (IBAction)toggleCapturing:(id)sender
{
  _capturing = !_capturing;
  
  if (_capturing) {
    [self.recordButton setTitle:START_CAPTURE_BUTTON_TITLE forState:UIControlStateNormal];
    [_capturePipeline start];
  } else {
    [self.recordButton setTitle:STOP_CAPTURE_BUTTON_TITLE forState:UIControlStateNormal];
    [_capturePipeline stop];
  }
}

#pragma mark - Camera2ElementaryStreamCapturePipelineDelegate

- (void)startRendering:(AVCaptureSession *)captureSession
{
  // Create preview layer with captureSession
  AVCaptureVideoPreviewLayer *previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:captureSession];
  [previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
  previewLayer.frame = self.view.bounds;
  previewLayer.name = PREVIEW_LAYER_NAME;
  previewLayer.zPosition = _recordButton.layer.zPosition - 1;

  NSLog(@"Preview layer bounds %@", NSStringFromCGSize( self.view.bounds.size ));
  
  // Add preview layer into the view's layer hierarchy.
  [self.view.layer addSublayer:previewLayer];
}

- (void)stopRendering
{
  NSArray *sublayers = [self.view.layer sublayers];
  for (__strong CALayer *layer in sublayers) {
    if ([[layer name] isEqualToString:PREVIEW_LAYER_NAME] == YES)
    {
      [layer setHidden:YES];
      [layer removeFromSuperlayer];
      layer = nil;
    }
  }
}

@end
