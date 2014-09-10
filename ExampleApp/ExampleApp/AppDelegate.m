//
//  AppDelegate.m
//  ExampleApp
//
//  Created by Thong Nguyen on 20/01/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "AppDelegate.h"
#import "STKAudioPlayer.h"
#import "AudioPlayerView.h"
#import "STKAutoRecoveringHTTPDataSource.h"
#import "SampleQueueId.h"
#import <AVFoundation/AVFoundation.h>

@interface AppDelegate()
{
    STKAudioPlayer* audioPlayer;
}
@end

@implementation AppDelegate

-(BOOL) application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    NSError* error;
    
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
	[[AVAudioSession sharedInstance] setActive:YES error:&error];
    
    Float32 bufferLength = 0.1;
    AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(bufferLength), &bufferLength);
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
	self.window.backgroundColor = [UIColor whiteColor];
    
	audioPlayer = [[STKAudioPlayer alloc] initWithOptions:(STKAudioPlayerOptions){ .flushQueueOnSeek = YES, .enableVolumeMixer = NO, .equalizerBandFrequencies = {50, 100, 200, 400, 800, 1600, 2600, 16000} }];
	audioPlayer.meteringEnabled = YES;
	audioPlayer.volume = 1;
    
	
	AudioPlayerView* audioPlayerView = [[AudioPlayerView alloc] initWithFrame:self.window.bounds andAudioPlayer:audioPlayer];
    
	audioPlayerView.delegate = self;
    
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];
	
	[self.window addSubview:audioPlayerView];
	
    [self.window makeKeyAndVisible];
	
    return YES;
}

-(BOOL) canBecomeFirstResponder
{
    return YES;
}

-(void) audioPlayerViewPlayFromHTTPSelected:(AudioPlayerView*)audioPlayerView
{
    NSURL* url = [NSURL URLWithString:@"http://streaming.swisstxt.ch/m/rsj/mp3_128"];
    
    STKDataSource* dataSource = [STKAudioPlayer dataSourceFromURL:url];
    
	[audioPlayer setDataSource:dataSource withQueueItemId:[[SampleQueueId alloc] initWithUrl:url andCount:0]];
}

-(void) audioPlayerViewQueueShortFileSelected:(AudioPlayerView*)audioPlayerView
{
    NSString* path = [[NSBundle mainBundle] pathForResource:@"airplane" ofType:@"aac"];
	NSURL* url = [NSURL fileURLWithPath:path];
	
	STKDataSource* dataSource = [STKAudioPlayer dataSourceFromURL:url];
    
	[audioPlayer queueDataSource:dataSource withQueueItemId:[[SampleQueueId alloc] initWithUrl:url andCount:0]];
}

-(void) audioPlayerViewPlayFromLocalFileSelected:(AudioPlayerView*)audioPlayerView
{
	NSString* path = [[NSBundle mainBundle] pathForResource:@"sample" ofType:@"m4a"];
	NSURL* url = [NSURL fileURLWithPath:path];
	
	STKDataSource* dataSource = [STKAudioPlayer dataSourceFromURL:url];
	
	[audioPlayer setDataSource:dataSource withQueueItemId:[[SampleQueueId alloc] initWithUrl:url andCount:0]];
}

-(void) audioPlayerViewQueuePcmWaveFileSelected:(AudioPlayerView*)audioPlayerView
{
	NSURL* url = [NSURL URLWithString:@"http://www.abstractpath.com/files/audiosamples/perfectly.wav"];
    
    STKDataSource* dataSource = [STKAudioPlayer dataSourceFromURL:url];
    
	[audioPlayer queueDataSource:dataSource withQueueItemId:[[SampleQueueId alloc] initWithUrl:url andCount:0]];
}

@end
