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
	STKAudioPlayer* audioPlayer;
    NSTextField* textField;
}
@end

@implementation AppDelegate

-(void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
	NSButton* playFromHTTPButton = [[NSButton alloc] init];
	[playFromHTTPButton setTitle:@"Play from HTTP"];
	[playFromHTTPButton setAction:@selector(playFromHTTP)];

    NSButton* stopButton = [[NSButton alloc] init];
    [stopButton setTitle:@"Stop"];
    [stopButton setAction:@selector(stopPlaying)];

    NSStackView *buttonStackView = [[NSStackView alloc] initWithFrame:self.window.contentView.frame];
    [buttonStackView setDistribution:NSStackViewDistributionFillEqually];
    [buttonStackView setSpacing:8];
    [buttonStackView setOrientation:NSUserInterfaceLayoutOrientationHorizontal];

    [buttonStackView addArrangedSubview:playFromHTTPButton];
    [buttonStackView addArrangedSubview:stopButton];
	
	slider = [[NSSlider alloc] init];
    [slider setTranslatesAutoresizingMaskIntoConstraints:false];
	[slider setAction:@selector(sliderChanged:)];
	
	meter = [[NSView alloc] init];
    [meter setTranslatesAutoresizingMaskIntoConstraints:false];
	[meter setLayer:[CALayer new]];
	[meter setWantsLayer:YES];
	meter.layer.backgroundColor = [NSColor greenColor].CGColor;

    NSView *meterWrapper = [[NSView alloc] init];
    [meterWrapper setTranslatesAutoresizingMaskIntoConstraints:false];
    [meterWrapper addSubview:meter];

    textField = [[NSTextField alloc] init];
    [textField setTranslatesAutoresizingMaskIntoConstraints:false];
    textField.stringValue = @"http://www.abstractpath.com/files/audiosamples/sample.mp3";

    NSStackView *stackView = [[NSStackView alloc] initWithFrame:self.window.contentView.frame];
    [stackView setTranslatesAutoresizingMaskIntoConstraints:false];
    [stackView setDistribution:NSStackViewDistributionEqualSpacing];
    [stackView setSpacing:8];
    [stackView setOrientation:NSUserInterfaceLayoutOrientationVertical];

    [stackView addArrangedSubview:textField];
    [stackView addArrangedSubview:meterWrapper];
    [stackView addArrangedSubview:slider];
    [stackView addArrangedSubview:buttonStackView];

    [[self.window contentView] addSubview:stackView];

    [stackView.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:16].active = true;
    [stackView.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor constant:-16].active = true;
    [stackView.rightAnchor constraintEqualToAnchor:self.window.contentView.rightAnchor constant:-16].active = true;
    [stackView.leftAnchor constraintEqualToAnchor:self.window.contentView.leftAnchor constant:16].active = true;

    [meter.topAnchor constraintEqualToAnchor:meterWrapper.topAnchor].active = true;
    [meter.bottomAnchor constraintEqualToAnchor:meterWrapper.bottomAnchor].active = true;
    [meter.leadingAnchor constraintEqualToAnchor:meterWrapper.leadingAnchor].active = true;

	audioPlayer = [[STKAudioPlayer alloc] initWithOptions:(STKAudioPlayerOptions)
    {
        .enableVolumeMixer = NO,
        .equalizerBandFrequencies = {50, 100, 200, 400, 800, 1600, 2600, 16000}
    }];
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
	[audioPlayer play:textField.stringValue];
    audioPlayer.rate = 2;
}

- (void) stopPlaying
{
    [audioPlayer stop];
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

@end
