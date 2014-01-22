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

#import "AudioPlayerView.h"
#import "SampleQueueId.h"

///
/// This sample media player will play a local or an HTTP stream in repeat (gapless)
///

@interface AudioPlayerView()
-(void) setupTimer;
-(void) updateControls;
@end

@implementation AudioPlayerView
@synthesize audioPlayer, delegate;

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
	
    if (self)
	{
		CGSize size = CGSizeMake(180, 50);
		
		playFromHTTPButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		playFromHTTPButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.15, size.width, size.height);
		[playFromHTTPButton addTarget:self action:@selector(playFromHTTPButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[playFromHTTPButton setTitle:@"Play from HTTP" forState:UIControlStateNormal];

		playFromLocalFileButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		playFromLocalFileButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.15 + 50, size.width, size.height);
		[playFromLocalFileButton addTarget:self action:@selector(playFromLocalFileButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[playFromLocalFileButton setTitle:@"Play from Local File" forState:UIControlStateNormal];
        
        queueFromHttpButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		queueFromHttpButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.15 + 100, size.width, size.height);
		[queueFromHttpButton addTarget:self action:@selector(queueFromHTTPButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[queueFromHttpButton setTitle:@"Queue from HTTP" forState:UIControlStateNormal];
        
		playButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		playButton.frame = CGRectMake((320 - size.width) / 2, 350, size.width, size.height);
		[playButton addTarget:self action:@selector(playButtonPressed) forControlEvents:UIControlEventTouchUpInside];
		
		slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 290, 280, 20)];
		slider.continuous = YES;
		[slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
		
		[self addSubview:slider];
		[self addSubview:playButton];
		[self addSubview:playFromHTTPButton];
		[self addSubview:playFromLocalFileButton];
        [self addSubview:queueFromHttpButton];
		
		[self setupTimer];
		[self updateControls];
    }
	
    return self;
}

-(void) sliderChanged
{
	if (!audioPlayer)
	{
		return;
	}
	
	NSLog(@"Slider Changed: %f", slider.value);
	
	[audioPlayer seekToTime:slider.value];
}

-(void) setupTimer
{
	timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
	
	[[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

-(void) tick
{
	if (!audioPlayer || audioPlayer.duration == 0)
	{
		slider.value = 0;
		
		return;
	}
	
	slider.minimumValue = 0;
	slider.maximumValue = audioPlayer.duration;
	
	slider.value = audioPlayer.progress;
}

-(void) playFromHTTPButtonTouched
{
	[self.delegate audioPlayerViewPlayFromHTTPSelected:self];
}

-(void) playFromLocalFileButtonTouched
{
	[self.delegate audioPlayerViewPlayFromLocalFileSelected:self];
}

-(void) queueFromHTTPButtonTouched
{
	[self.delegate audioPlayerViewQueueFromHTTPSelected:self];
}


-(void) playButtonPressed
{
	if (!audioPlayer)
	{
		return;
	}
	
	if (audioPlayer.state == AudioPlayerStatePaused)
	{
		[audioPlayer resume];
	}
	else
	{
		[audioPlayer pause];
	}
}

-(void) updateControls
{
	if (audioPlayer == nil)
	{
		[playButton setTitle:@"Play" forState:UIControlStateNormal];
	}
	else if (audioPlayer.state == AudioPlayerStatePaused)
	{
		[playButton setTitle:@"Resume" forState:UIControlStateNormal];
	}
	else if (audioPlayer.state == AudioPlayerStatePlaying)
	{
		[playButton setTitle:@"Pause" forState:UIControlStateNormal];
	}
	else
	{
		[playButton setTitle:@"Play" forState:UIControlStateNormal];
	}
}

-(void) setAudioPlayer:(STKAudioPlayer*)value
{
	if (audioPlayer)
	{
		audioPlayer.delegate = nil;
	}

	audioPlayer = value;
	audioPlayer.delegate = self;
	
	[self updateControls];
}

-(STKAudioPlayer*) audioPlayer
{
	return audioPlayer;
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer stateChanged:(AudioPlayerState)state
{
	[self updateControls];
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didEncounterError:(AudioPlayerErrorCode)errorCode
{
	[self updateControls];
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didStartPlayingQueueItemId:(NSObject*)queueItemId
{
	SampleQueueId* queueId = (SampleQueueId*)queueItemId;
    
    NSLog(@"Started: %@", [queueId.url description]);
    
	[self updateControls];
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishBufferingSourceWithQueueItemId:(NSObject*)queueItemId
{
	[self updateControls];
    
    // This queues on the currently playing track to be buffered and played immediately after (gapless)
    
    SampleQueueId* queueId = (SampleQueueId*)queueItemId;

    NSLog(@"Requeuing: %@", [queueId.url description]);

    [self->audioPlayer queueDataSource:[self->audioPlayer dataSourceFromURL:queueId.url] withQueueItemId:[[SampleQueueId alloc] initWithUrl:queueId.url andCount:queueId.count + 1]];
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishPlayingQueueItemId:(NSObject*)queueItemId withReason:(AudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration
{
	[self updateControls];
 
    SampleQueueId* queueId = (SampleQueueId*)queueItemId;
    
    NSLog(@"Finished: %@", [queueId.url description]);
}

@end
