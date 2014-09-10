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

- (id)initWithFrame:(CGRect)frame andAudioPlayer:(STKAudioPlayer*)audioPlayerIn
{
    self = [super initWithFrame:frame];
	
    if (self)
	{
        self.audioPlayer = audioPlayerIn;
        
		CGSize size = CGSizeMake(220, 50);
		
		playFromHTTPButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		playFromHTTPButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.10, size.width, size.height);
		[playFromHTTPButton addTarget:self action:@selector(playFromHTTPButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[playFromHTTPButton setTitle:@"Play from HTTP" forState:UIControlStateNormal];

		playFromLocalFileButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		playFromLocalFileButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.10 + 50, size.width, size.height);
		[playFromLocalFileButton addTarget:self action:@selector(playFromLocalFileButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[playFromLocalFileButton setTitle:@"Play from Local File" forState:UIControlStateNormal];
        
        queueShortFileButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		queueShortFileButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.10 + 100, size.width, size.height);
		[queueShortFileButton addTarget:self action:@selector(queueShortFileButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[queueShortFileButton setTitle:@"Queue short file" forState:UIControlStateNormal];
		
		queuePcmWaveFileFromHTTPButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		queuePcmWaveFileFromHTTPButton.frame = CGRectMake((320 - size.width) / 2, frame.size.height * 0.10 + 150, size.width, size.height);
		[queuePcmWaveFileFromHTTPButton addTarget:self action:@selector(queuePcmWaveFileButtonTouched) forControlEvents:UIControlEventTouchUpInside];
		[queuePcmWaveFileFromHTTPButton setTitle:@"Queue PCM/WAVE from HTTP" forState:UIControlStateNormal];
        
        size = CGSizeMake(90, 40);
        
		playButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		playButton.frame = CGRectMake(30, 380, size.width, size.height);
		[playButton addTarget:self action:@selector(playButtonPressed) forControlEvents:UIControlEventTouchUpInside];
        
        stopButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		stopButton.frame = CGRectMake((320 - size.width) - 30, 380, size.width, size.height);
		[stopButton addTarget:self action:@selector(stopButtonPressed) forControlEvents:UIControlEventTouchUpInside];
        [stopButton setTitle:@"Stop" forState:UIControlStateNormal];
		
		muteButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
		muteButton.frame = CGRectMake((320 - size.width) - 30, 410, size.width, size.height);
		[muteButton addTarget:self action:@selector(muteButtonPressed) forControlEvents:UIControlEventTouchUpInside];
		[muteButton setTitle:@"Mute" forState:UIControlStateNormal];
		
		slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 320, 280, 20)];
		slider.continuous = YES;
		[slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
        
        size = CGSizeMake(80, 50);
        
        repeatSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(30, frame.size.height * 0.15 + 180, size.width, size.height)];
        
        enableEqSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(320 - size.width - 30, frame.size.height * 0.15 + 180, size.width, size.height)];
        enableEqSwitch.on = audioPlayer.equalizerEnabled;
        
        [enableEqSwitch addTarget:self action:@selector(onEnableEqSwitch) forControlEvents:UIControlEventAllTouchEvents];

        label = [[UILabel alloc] initWithFrame:CGRectMake(0, slider.frame.origin.y + slider.frame.size.height + 10, frame.size.width, 25)];
		
        label.textAlignment = NSTextAlignmentCenter;
        
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, slider.frame.origin.y + slider.frame.size.height + label.frame.size.height + 8, frame.size.width, 50)];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        
        metaDataLabel = [[UILabel alloc] initWithFrame:
                         CGRectMake(
                                    0,
                                    statusLabel.frame.origin.y - 20,
                                    frame.size.width,
                                    15
                                    )];
        metaDataLabel.font = [UIFont systemFontOfSize:12];
        metaDataLabel.textAlignment = NSTextAlignmentCenter;
        
		meter = [[UIView alloc] initWithFrame:CGRectMake(0, 450, 0, 20)];
		
		meter.backgroundColor = [UIColor greenColor];
		
		[self addSubview:slider];
		[self addSubview:playButton];
		[self addSubview:playFromHTTPButton];
		[self addSubview:playFromLocalFileButton];
        [self addSubview:queueShortFileButton];
		[self addSubview:queuePcmWaveFileFromHTTPButton];
        [self addSubview:repeatSwitch];
        [self addSubview:label];
        [self addSubview:statusLabel];
        [self addSubview:metaDataLabel];
        [self addSubview:stopButton];
		[self addSubview:meter];
		[self addSubview:muteButton];
        [self addSubview:enableEqSwitch];
        
		[self setupTimer];
		[self updateControls];
    }
	
    return self;
}

-(void) onEnableEqSwitch
{
    audioPlayer.equalizerEnabled = self->enableEqSwitch.on;
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
	timer = [NSTimer timerWithTimeInterval:0.001 target:self selector:@selector(tick) userInfo:nil repeats:YES];
	
	[[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

-(void) tick
{
	if (!audioPlayer)
	{
		slider.value = 0;
        label.text = @"";
        statusLabel.text = @"";
		
		return;
	}
	
    if (audioPlayer.duration != 0)
    {
        slider.minimumValue = 0;
        slider.maximumValue = audioPlayer.duration;
        slider.value = audioPlayer.progress;
        
        label.text = [NSString stringWithFormat:@"%@ - %@", [self formatTimeFromSeconds:audioPlayer.progress], [self formatTimeFromSeconds:audioPlayer.duration]];
    }
    else
    {
        slider.value = 0;
        slider.minimumValue = 0;
        slider.maximumValue = 0;
        
        label.text =  @"";
    }
    
    statusLabel.text = audioPlayer.state == STKAudioPlayerStateBuffering ? @"buffering" : @"";
	
	CGFloat newWidth = 320 * (([audioPlayer averagePowerInDecibelsForChannel:1] + 60) / 60);
	
	meter.frame = CGRectMake(0, 460, newWidth, 20);
}

-(void) playFromHTTPButtonTouched
{
	[self.delegate audioPlayerViewPlayFromHTTPSelected:self];
}

-(void) playFromLocalFileButtonTouched
{
	[self.delegate audioPlayerViewPlayFromLocalFileSelected:self];
}

-(void) queueShortFileButtonTouched
{
	[self.delegate audioPlayerViewQueueShortFileSelected:self];
}

-(void) queuePcmWaveFileButtonTouched
{
	[self.delegate audioPlayerViewQueuePcmWaveFileSelected:self];
}

-(void) muteButtonPressed
{
	audioPlayer.muted = !audioPlayer.muted;
	
	if (audioPlayer.muted)
	{
		[muteButton setTitle:@"Unmute" forState:UIControlStateNormal];
	}
	else
	{
		[muteButton setTitle:@"Mute" forState:UIControlStateNormal];
	}
}

-(void) stopButtonPressed
{
    [audioPlayer stop];
}

-(void) playButtonPressed
{
	if (!audioPlayer)
	{
		return;
	}
    
	if (audioPlayer.state == STKAudioPlayerStatePaused)
	{
		[audioPlayer resume];
	}
	else
	{
		[audioPlayer pause];
	}
}

-(NSString*) formatTimeFromSeconds:(int)totalSeconds
{
    
    int seconds = totalSeconds % 60;
    int minutes = (totalSeconds / 60) % 60;
    int hours = totalSeconds / 3600;
    
    return [NSString stringWithFormat:@"%02d:%02d:%02d", hours, minutes, seconds];
}

-(void) updateControls
{
	if (audioPlayer == nil)
	{
		[playButton setTitle:@"" forState:UIControlStateNormal];
	}
	else if (audioPlayer.state == STKAudioPlayerStatePaused)
	{
		[playButton setTitle:@"Resume" forState:UIControlStateNormal];
	}
	else if (audioPlayer.state & STKAudioPlayerStatePlaying)
	{
		[playButton setTitle:@"Pause" forState:UIControlStateNormal];
	}
	else
	{
		[playButton setTitle:@"" forState:UIControlStateNormal];
	}
    
    [self tick];
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

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer stateChanged:(STKAudioPlayerState)state previousState:(STKAudioPlayerState)previousState
{
	[self updateControls];
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer unexpectedError:(STKAudioPlayerErrorCode)errorCode
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
    
    if (repeatSwitch.on)
    {
        SampleQueueId* queueId = (SampleQueueId*)queueItemId;

        NSLog(@"Requeuing: %@", [queueId.url description]);

        [self->audioPlayer queueDataSource:[STKAudioPlayer dataSourceFromURL:queueId.url] withQueueItemId:[[SampleQueueId alloc] initWithUrl:queueId.url andCount:queueId.count + 1]];
    }
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishPlayingQueueItemId:(NSObject*)queueItemId withReason:(STKAudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration
{
	[self updateControls];
 
    SampleQueueId* queueId = (SampleQueueId*)queueItemId;
    
    NSLog(@"Finished: %@", [queueId.url description]);
}

-(void) audioPlayer:(STKAudioPlayer *)audioPlayer logInfo:(NSString *)line
{
    NSLog(@"%@", line);
}

-(void) audioPlayer:(STKAudioPlayer *)audioPlayer didUpdateMetaData:(NSDictionary *)metaData
{
    metaDataLabel.text = metaData[@"StreamTitle"];
}

@end
