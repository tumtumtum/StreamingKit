/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/StreamingKit
 
 Inspired by Matt Gallagher's AudioStreamer:
 https://github.com/mattgallagher/AudioStreamer
 
 Copyright (c) 2012-2014 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
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
 
 THIS SOFTWARE IS PROVIDED BY Thong Nguyen''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **********************************************************************************/

#import <Foundation/Foundation.h>
#import <pthread.h>
#import "STKDataSource.h"
#include <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_IPHONE
#include "UIKit/UIApplication.h"
#endif

typedef enum
{
    STKAudioPlayerStateReady,
    STKAudioPlayerStateRunning = 1,
    STKAudioPlayerStatePlaying = (1 << 1) | STKAudioPlayerStateRunning,
    STKAudioPlayerStateBuffering = (1 << 2) | STKAudioPlayerStateRunning,
    STKAudioPlayerStatePaused = (1 << 3) | STKAudioPlayerStateRunning,
    STKAudioPlayerStateStopped = (1 << 4),
    STKAudioPlayerStateError = (1 << 5),
    STKAudioPlayerStateDisposed = (1 << 6)
}
STKAudioPlayerState;

typedef enum
{
	STKAudioPlayerStopReasonNone = 0,
	STKAudioPlayerStopReasonEof,
	STKAudioPlayerStopReasonUserAction,
	STKAudioPlayerStopReasonError = 0xffff
}
STKAudioPlayerStopReason;

typedef enum
{
	STKAudioPlayerErrorNone = 0,
	STKAudioPlayerErrorDataSource,
    STKAudioPlayerErrorStreamParseBytesFailed,
    STKAudioPlayerErrorAudioSystemError,
    STKAudioPlayerErrorCodecError,
    STKAudioPlayerErrorDataNotFound,
    STKAudioPlayerErrorOther = 0xffff
}
STKAudioPlayerErrorCode;

typedef enum
{
	STKAudioPlayerOptionNone = 0,
	STKAudioPlayerOptionFlushQueueOnSeek = 1
}
STKAudioPlayerOptions;

typedef void(^STKFrameFilter)(UInt32 channelsPerFrame, UInt32 bytesPerFrame, UInt32 frameCount, void* frames);

@interface STKFrameFilterEntry : NSObject
@property (readonly) NSString* name;
@property (readonly) STKFrameFilter filter;
@end

@class STKAudioPlayer;

@protocol STKAudioPlayerDelegate <NSObject>

/// Raised when an item has started playing
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didStartPlayingQueueItemId:(NSObject*)queueItemId;
/// Raised when an item has finished buffering (may or may not be the currently playing item)
/// This event may be raised multiple times for the same item if seek is invoked on the player
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishBufferingSourceWithQueueItemId:(NSObject*)queueItemId;
/// Raised when the state of the player has changed
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer stateChanged:(STKAudioPlayerState)state previousState:(STKAudioPlayerState)previousState;
/// Raised when an item has finished playing
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishPlayingQueueItemId:(NSObject*)queueItemId withReason:(STKAudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration;
/// Raised when an unexpected and possibly unrecoverable error has occured (usually best to recreate the STKAudioPlauyer)
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer unexpectedError:(STKAudioPlayerErrorCode)errorCode;
@optional
/// Optionally implemented to get logging information from the STKAudioPlayer (used internally for debugging)
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer logInfo:(NSString*)line;
/// Raised when items queued items are cleared (usually because of a call to play, setDataSource or stop)
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didCancelQueuedItems:(NSArray*)queuedItems;

@end

@interface STKAudioPlayer : NSObject<STKDataSourceDelegate>

/// Gets or sets the player muted state
@property (readwrite) BOOL muted;
/// Gets the current item duration in seconds
@property (readonly) double duration;
/// Gets the current item progress in seconds
@property (readonly) double progress;
/// Enables or disables peak and average decibel meteting
@property (readwrite) BOOL meteringEnabled;
/// Returns an array of STKFrameFilterEntry objects representing the filters currently in use
@property (readonly) NSArray* frameFilters;
/// Returns the items pending to be played (includes buffering and upcoming items but does not include the current item)
@property (readonly) NSArray* pendingQueue;
/// The number of items pending to be played (includes buffering and upcoming items but does not include the current item)
@property (readonly) NSUInteger pendingQueueCount;
/// Gets the most recently queued item that is still pending to play
@property (readonly) NSObject* mostRecentlyQueuedStillPendingItem;
/// Gets the current state of the player
@property (readwrite) STKAudioPlayerState state;
/// Gets the options provided to the player on startup
@property (readonly) STKAudioPlayerOptions options;
/// Gets the reason why the player is stopped (if any)
@property (readonly) STKAudioPlayerStopReason stopReason;
/// Gets and sets the delegate used for receiving events from the STKAudioPlayer
@property (readwrite, unsafe_unretained) id<STKAudioPlayerDelegate> delegate;

/// Creates a datasource from a given URL.
/// URLs with FILE schemes will return an STKLocalFileDataSource.
/// URLs with HTTP schemes will return an STKHTTPDataSource wrapped within an STKAutoRecoveringHTTPDataSource.
/// URLs with unrecognised schemes will return nil.
+(STKDataSource*) dataSourceFromURL:(NSURL*)url;

/// Initializes a new STKAudioPlayer with the default options
-(id) init;

/// Initializes a new STKAudioPlayer with the given options
-(id) initWithOptions:(STKAudioPlayerOptions)optionsIn;

/// Plays an item from the given URL string (all pending queued items are removed).
/// The NSString is used as the queue item ID
-(void) play:(NSString*)urlString;

/// Plays an item from the given URL (all pending queued items are removed)
-(void) play:(NSString*)urlString withQueueItemID:(NSObject*)queueItemId;

/// Plays an item from the given URL (all pending queued items are removed)
/// The NSURL is used as the queue item ID
-(void) playURL:(NSURL*)url;

/// Plays an item from the given URL (all pending queued items are removed)
-(void) playURL:(NSURL*)url withQueueItemID:(NSObject*)queueItemId;

/// Plays the given item (all pending queued items are removed)
/// The STKDataSource is used as the queue item ID
-(void) playDataSource:(STKDataSource*)dataSource;

/// Plays the given item (all pending queued items are removed)
-(void) playDataSource:(STKDataSource*)dataSource withQueueItemID:(NSObject*)queueItemId;

/// Queues the URL string for playback and uses the NSString as the queueItemID
-(void) queue:(NSString*)urlString;

/// Queues the URL string for playback with the given queueItemID
-(void) queue:(NSString*)urlString withQueueItemId:(NSObject*)queueItemId;

/// Queues the URL for playback and uses the NSURL as the queueItemID
-(void) queueURL:(NSURL*)url;

/// Queues the URL for playback with the given queueItemID
-(void) queueURL:(NSURL*)url withQueueItemId:(NSObject*)queueItemId;

/// Queues a DataSource with the given queueItemId
-(void) queueDataSource:(STKDataSource*)dataSource withQueueItemId:(NSObject*)queueItemId;

/// Plays the given item (all pending queued items are removed)
-(void) setDataSource:(STKDataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId;

/// Seeks to a specific time (in seconds)
-(void) seekToTime:(double)value;

/// Clears any upcoming items already queued for playback (does not stop the current item).
/// The didCancelItems event will be raised for the items removed from the queue.
-(void) clearQueue;

/// Pauses playback
-(void) pause;

/// Resumes playback from pause
-(void) resume;

/// Stops playback of the current file, flushes all the buffers and removes any pending queued items
-(void) stop;

/// Mutes playback
-(void) mute;

/// Unmutes playback
-(void) unmute;

/// Disposes the STKAudioPlayer and frees up all resources before returning
-(void) dispose;

/// The QueueItemId of the currently playing item
-(NSObject*) currentlyPlayingQueueItemId;

/// Removes a frame filter with the given name
-(void) removeFrameFilterWithName:(NSString*)name;

/// Appends a frame filter with the given name and filter block to the end of the filter chain
-(void) appendFrameFilterWithName:(NSString*)name block:(STKFrameFilter)block;

/// Appends a frame filter with the given name and filter block just after the filter with the given name.
/// If the given name is nil, the filter will be inserted at the beginning of the filter change
-(void) addFrameFilterWithName:(NSString*)name afterFilterWithName:(NSString*)afterFilterWithName block:(STKFrameFilter)block;

/// Reads the peak power in decibals for the given channel (0 or 1).
/// Return values are between -60 (low) and 0 (high).
-(float) peakPowerInDecibelsForChannel:(NSUInteger)channelNumber;

/// Reads the average power in decibals for the given channel (0 or 1)
/// Return values are between -60 (low) and 0 (high).
-(float) averagePowerInDecibelsForChannel:(NSUInteger)channelNumber;

@end
