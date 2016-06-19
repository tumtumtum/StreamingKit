//
//  AppDelegate.m
//  ExampleAppMac
//
//  Created by Thong Nguyen on 02/02/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "AppDelegate.h"
#import "STKAudioPlayer.h"

@interface AppDelegate()
{
	NSView* meter;
	NSSlider* slider;
    NSTextField* metaDataTextField;
	STKAudioPlayer* audioPlayer;
}
@end

@implementation AppDelegate

-(void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
	CGRect frame = [self.window.contentView frame];
	
	NSButton* playFromHTTPButton = [[NSButton alloc] initWithFrame:CGRectMake(10, 10, frame.size.width - 20, 100)];
	
	[playFromHTTPButton setTitle:@"Play from HTTP"];
	[playFromHTTPButton setAction:@selector(playFromHTTP)];
	
	slider = [[NSSlider alloc] initWithFrame:CGRectMake(10, 140, frame.size.width - 20, 20)];
	[slider setAction:@selector(sliderChanged:)];
	
	meter = [[NSView alloc] initWithFrame:CGRectMake(10, 200, 0, 20)];
	[meter setLayer:[CALayer new]];
	[meter setWantsLayer:YES];
	meter.layer.backgroundColor = [NSColor greenColor].CGColor;
	
	metaDataTextField = [[NSTextField alloc] initWithFrame:CGRectMake(10, 270, frame.size.width - 20, 80)];
	metaDataTextField.alignment = NSCenterTextAlignment;
	metaDataTextField.stringValue = @"no meta data";
	
	[[self.window contentView] addSubview:slider];
	[[self.window contentView] addSubview:playFromHTTPButton];
	[[self.window contentView] addSubview:meter];
	[[self.window contentView] addSubview:metaDataTextField];
	
	audioPlayer = [[STKAudioPlayer alloc] initWithOptions:(STKAudioPlayerOptions){ .enableVolumeMixer = NO, .equalizerBandFrequencies = {50, 100, 200, 400, 800, 1600, 2600, 16000} } ];
	audioPlayer.delegate = self;
	audioPlayer.meteringEnabled = YES;
	audioPlayer.volume = 0.1;
    
    [self performSelector:@selector(test) withObject:nil afterDelay:4];
    [self performSelector:@selector(test) withObject:nil afterDelay:8];
    
	[NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

-(void) test
{
    audioPlayer.equalizerEnabled = !audioPlayer.equalizerEnabled;
}

-(void) playFromHTTP
{
    // Swiss Jazz stream
	[audioPlayer play:@"http://streaming.swisstxt.ch/m/rsj/mp3_128"];
}

-(void) tick:(NSTimer*)timer
{
	if (!audioPlayer)
	{
		slider.doubleValue = 0;
		
		return;
	}
	
	CGFloat meterWidth = 0;
	
    if (audioPlayer.currentlyPlayingQueueItemId != nil)
    {
        slider.minValue = 0;
        slider.maxValue = audioPlayer.duration;
        slider.doubleValue = audioPlayer.progress;
		
		meterWidth = [self.window.contentView frame].size.width - 20;
		meterWidth *= (([audioPlayer averagePowerInDecibelsForChannel:0] + 60) / 60);
    }
    else
    {
        slider.doubleValue = 0;
        slider.minValue = 0;
        slider.maxValue = 0;
		
		meterWidth = 0;
    }
	
	CGRect frame = meter.frame;
	
	frame.size.width = meterWidth;
	
	meter.frame = frame;
}

-(void) sliderChanged:(NSSlider*)sliderIn
{
	[audioPlayer seekToTime:sliderIn.doubleValue];
}

-(void) updateControls
{
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didStartPlayingQueueItemId:(NSObject*)queueItemId
{
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishBufferingSourceWithQueueItemId:(NSObject*)queueItemId
{
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer stateChanged:(STKAudioPlayerState)state previousState:(STKAudioPlayerState)previousState
{
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishPlayingQueueItemId:(NSObject*)queueItemId withReason:(STKAudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration
{
}

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer unexpectedError:(STKAudioPlayerErrorCode)errorCode
{
}

-(void) audioPlayer:(STKAudioPlayer *)audioPlayer didUpdateMetaData:(NSDictionary *)metaData
{
	metaDataTextField.stringValue = [metaData description];
}

@end
