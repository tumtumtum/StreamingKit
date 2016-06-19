/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/audjustable
 
 Copyright (c) 2012 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
 must display the following acknowledgement:
 This product includes software developed by Thong Nguyen (tumtumtum@gmail.com)
 4. Neither the name of Thong Nguyen nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY Thong Nguyen ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THONG NGUYEN BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **********************************************************************************/

#import <UIKit/UIKit.h>
#import "STKAudioPlayer.h"

@class AudioPlayerView;

@protocol AudioPlayerViewDelegate<NSObject>
-(void) audioPlayerViewPlayFromHTTPSelected:(AudioPlayerView*)audioPlayerView;
-(void) audioPlayerViewPlayFromIcecastSelected:(AudioPlayerView*)audioPlayerView;
-(void) audioPlayerViewQueueShortFileSelected:(AudioPlayerView*)audioPlayerView;
-(void) audioPlayerViewPlayFromLocalFileSelected:(AudioPlayerView*)audioPlayerView;
-(void) audioPlayerViewQueuePcmWaveFileSelected:(AudioPlayerView*)audioPlayerView;
@end

@interface AudioPlayerView : UIView<STKAudioPlayerDelegate>
{
@private
	NSTimer* timer;
    UILabel* label;
    UILabel* statusLabel;
    UILabel* metaDataLabel;
	UISlider* slider;
    UISwitch* enableEqSwitch;
    UISwitch* repeatSwitch;
	UIButton* muteButton;
	UIButton* playButton;
    UIButton* stopButton;
	UIButton* playFromHTTPButton;
    UIButton* playFromIcecastButton;
    UIButton* queueShortFileButton;
	UIButton* queuePcmWaveFileFromHTTPButton;
	UIButton* playFromLocalFileButton;
	UIView* meter;
}

@property (readwrite, retain) STKAudioPlayer* audioPlayer;
@property (readwrite, unsafe_unretained) id<AudioPlayerViewDelegate> delegate;

- (id)initWithFrame:(CGRect)frame andAudioPlayer:(STKAudioPlayer*)audioPlayer;

@end
