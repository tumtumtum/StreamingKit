//
//  AppDelegate.h
//  ExampleAppMac
//
//  Created by Thong Nguyen on 02/02/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "STKAudioPlayer.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, STKAudioPlayerDelegate>

@property (assign) IBOutlet NSWindow *window;

@end
