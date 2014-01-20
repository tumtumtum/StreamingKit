//
//  AppDelegate.h
//  ExampleApp
//
//  Created by Thong Nguyen on 20/01/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "STKAudioPlayer.h"
#import "AudioPlayerView.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate, AudioPlayerViewDelegate>

@property (strong, nonatomic) UIWindow *window;

@end
