//
//  AppDelegate.h
//  BlueCucumber-AudioPlayer
//
//  Created by Thong Nguyen on 01/06/2012.
//  Copyright (c) 2012 Thong Nguyen All rights reserved.
//

#import <UIKit/UIKit.h>
#import "AudioPlayerView.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate, AudioPlayerViewDelegate>
{
@private
	AudioPlayer* audioPlayer;
}

@property (strong, nonatomic) UIWindow *window;

@end
