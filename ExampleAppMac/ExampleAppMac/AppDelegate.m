//
//  AppDelegate.m
//  ExampleAppMac
//
//  Created by Thong Nguyen on 02/02/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "AppDelegate.h"
#import "STKAudioPlayer.h"

@implementation AppDelegate

-(void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
	STKAudioPlayer* player = [[STKAudioPlayer alloc] init];
	
	[player play:@"http://fs.bloom.fm/oss/audiosamples/sample.mp3"];
}

@end
