//
//  AudioPlayerView.h
//  BlueCucumber-AudioPlayer
//
//  Created by Thong Nguyen on 01/06/2012.
//  Copyright (c) 2012 Thong Nguyen All rights reserved.
//

#import <UIKit/UIKit.h>
#import "AudioPlayer.h"

@class AudioPlayerView;

@protocol AudioPlayerViewDelegate<NSObject>
-(void) audioPlayerViewPlayFromHTTPSelected:(AudioPlayerView*)audioPlayerView;
-(void) audioPlayerViewPlayFromLocalFileSelected:(AudioPlayerView*)audioPlayerView;
@end

@interface AudioPlayerView : UIView<AudioPlayerDelegate>
{
@private
	NSTimer* timer;
	UISlider* slider;
	UIButton* playButton;
	UIButton* playFromHTTPButton;
	UIButton* playFromLocalFileButton;
}

@property (readwrite, retain) AudioPlayer* audioPlayer;
@property (readwrite, unsafe_unretained) id<AudioPlayerViewDelegate> delegate;

@end
