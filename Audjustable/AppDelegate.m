//
//  AppDelegate.m
//  BlueCucumber-AudioPlayer
//
//  Created by Thong Nguyen on 01/06/2012.
//  Copyright (c) 2012 Thong Nguyen All rights reserved.
//

#import "AppDelegate.h"
#import "AudioPlayerView.h"

@implementation AppDelegate

@synthesize window = _window;

-(BOOL) application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
	self.window.backgroundColor = [UIColor whiteColor];

	audioPlayer = [[AudioPlayer alloc] init];
	AudioPlayerView* audioPlayerView = [[AudioPlayerView alloc] initWithFrame:self.window.bounds];

	audioPlayerView.delegate = self;
	audioPlayerView.audioPlayer = audioPlayer;
	
	[self.window addSubview:audioPlayerView];
	
    [self.window makeKeyAndVisible];
	
    return YES;
}

-(void) audioPlayerViewPlayFromHTTPSelected:(AudioPlayerView*)audioPlayerView
{	
	NSURL* url = [NSURL URLWithString:@"http://fs.bloom.fm/oss/audiosamples/sample.mp3"];
    
	[audioPlayer setDataSource:[audioPlayer dataSourceFromURL:url] withQueueItemId:url];
}

-(void) audioPlayerViewPlayFromLocalFileSelected:(AudioPlayerView*)audioPlayerView
{
	NSString * path = [[NSBundle mainBundle] pathForResource:@"sample" ofType:@"m4a"];
	NSURL* url = [NSURL fileURLWithPath:path];
	
	[audioPlayer setDataSource:[audioPlayer dataSourceFromURL:url] withQueueItemId:url];
}

@end
