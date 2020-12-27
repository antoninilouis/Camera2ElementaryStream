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
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
  [super viewDidLoad];
  _capturePipeline = [[Camera2ElementaryStreamCapturePipeline alloc] initWithDelegate:self callbackQueue:dispatch_get_main_queue()];
}

#pragma mark - UI

- (IBAction)toggleRendering:(id)sender
{
  [self.recordButton setTitle:@"Stop" forState:UIControlStateNormal];
  [_capturePipeline startRunning];
  [_capturePipeline startRendering];
}

#pragma mark - Camera2ElementaryStreamCapturePipelineDelegate

- (void)startRendering:(AVCaptureVideoPreviewLayer *)previewLayer
{
  // Add preview layer into the view's layer hierarchy.
  previewLayer.frame = self.view.bounds;
  [self.view.layer addSublayer:previewLayer];
}

@end
