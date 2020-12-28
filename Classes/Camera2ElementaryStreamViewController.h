//
//  Camera2ElementaryStreamViewController.h
//  Camera2ElementaryStream (iOS)
//
//  Created by Antonini Louis on 2020-12-23.
//

#ifndef Camera2ElementarySteamViewController_h
#define Camera2ElementarySteamViewController_h

#import <UIKit/UIKit.h>
#import "Camera2ElementaryStreamCapturePipeline.h"

@interface Camera2ElementaryStreamViewController : UIViewController <Camera2ElementaryStreamCapturePipelineDelegate>

@property (strong, nonatomic) IBOutlet UIButton *recordButton;

@end

#endif /* Camera2ElementaryStreamViewController_h */
