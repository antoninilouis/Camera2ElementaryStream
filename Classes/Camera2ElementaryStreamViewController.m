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
  _capturePipeline = [[Camera2ElementaryStreamCapturePipeline alloc] initWithDelegate:self callbackQueue:dispatch_get_main_queue()];
  [super viewDidLoad];
}

#pragma mark - UI



@end
