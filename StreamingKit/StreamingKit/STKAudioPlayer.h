/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/audjustable
 
 Inspired by Matt Gallagher's AudioStreamer:
 https://github.com/mattgallagher/AudioStreamer
 
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
	STKAudioPlayerInternalStateInitialised = 0,
    STKAudioPlayerInternalStateRunning = 1,
    STKAudioPlayerInternalStatePlaying = (1 << 1) | STKAudioPlayerInternalStateRunning,
    STKAudioPlayerInternalStateRebuffering = (1 << 2) | STKAudioPlayerInternalStateRunning,
	STKAudioPlayerInternalStateStartingThread = (1 << 3) | STKAudioPlayerInternalStateRunning,
	STKAudioPlayerInternalStateWaitingForData = (1 << 4) | STKAudioPlayerInternalStateRunning,
    /* Same as STKAudioPlayerInternalStateWaitingForData but isn't immediately raised as a buffering event */
    STKAudioPlayerInternalStateWaitingForDataAfterSeek = (1 << 5) | STKAudioPlayerInternalStateRunning,
    STKAudioPlayerInternalStatePaused = (1 << 6) | STKAudioPlayerInternalStateRunning,
    STKAudioPlayerInternalStateFlushingAndStoppingButStillPlaying = (1 << 7) | STKAudioPlayerInternalStateRunning,
    STKAudioPlayerInternalStateStopping = (1 << 8),
    STKAudioPlayerInternalStateStopped = (1 << 9),
    STKAudioPlayerInternalStateDisposed = (1 << 10),
    STKAudioPlayerInternalStateError = (1 << 31)
}
STKAudioPlayerInternalState;

typedef enum
{
    STKAudioPlayerStateReady,
    STKAudioPlayerStateRunning = 1,
    STKAudioPlayerStatePlaying = (1 << 1) | STKAudioPlayerStateRunning,
    STKAudioPlayerStateBuffering = (1 << 2) | STKAudioPlayerStatePlaying,
    STKAudioPlayerStatePaused = (1 << 3) | STKAudioPlayerStateRunning,
    STKAudioPlayerStateStopped = (1 << 4),
    STKAudioPlayerStateError = (1 << 5),
    STKAudioPlayerStateDisposed = (1 << 6)
}
STKAudioPlayerState;

typedef enum
{
	AudioPlayerStopReasonNoStop = 0,
	AudioPlayerStopReasonEof,
	AudioPlayerStopReasonUserAction,
    AudioPlayerStopReasonUserActionFlushStop
}
STKAudioPlayerStopReason;

typedef enum
{
	STKAudioPlayerErrorNone = 0,
	STKAudioPlayerErrorDataSource,
    STKAudioPlayerErrorStreamParseBytesFailed,
    STKAudioPlayerErrorDataNotFound,
    STKAudioPlayerErrorQueueStartFailed,
    STKAudioPlayerErrorQueuePauseFailed,
    STKAudioPlayerErrorUnknownBuffer,
    STKAudioPlayerErrorQueueStopFailed,
    STKAudioPlayerErrorQueueCreationFailed,
    STKAudioPlayerErrorOther = -1
}
STKAudioPlayerErrorCode;

@class STKAudioPlayer;

@protocol STKAudioPlayerDelegate <NSObject>

-(void) audioPlayer:(STKAudioPlayer*)audioPlayer stateChanged:(STKAudioPlayerState)state;
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didEncounterError:(STKAudioPlayerErrorCode)errorCode;
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didStartPlayingQueueItemId:(NSObject*)queueItemId;
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishBufferingSourceWithQueueItemId:(NSObject*)queueItemId;
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishPlayingQueueItemId:(NSObject*)queueItemId withReason:(STKAudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration;
@optional
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer logInfo:(NSString*)line;
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer internalStateChanged:(STKAudioPlayerInternalState)state;
-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didCancelQueuedItems:(NSArray*)queuedItems;

@end

@interface STKAudioPlayer : NSObject<STKDataSourceDelegate>

@property (readonly) double duration;
@property (readonly) double progress;
@property (readwrite) STKAudioPlayerState state;
@property (readonly) STKAudioPlayerStopReason stopReason;
@property (readwrite, unsafe_unretained) id<STKAudioPlayerDelegate> delegate;
@property (readwrite) BOOL meteringEnabled;

-(id) init;
-(id) initWithNumberOfAudioQueueBuffers:(int)numberOfAudioQueueBuffers andReadBufferSize:(int)readBufferSizeIn;
-(STKDataSource*) dataSourceFromURL:(NSURL*)url;
-(void) play:(NSString*)urlString;
-(void) playWithURL:(NSURL*)url;
-(void) playWithDataSource:(STKDataSource*)dataSource;
-(void) queueDataSource:(STKDataSource*)dataSource withQueueItemId:(NSObject*)queueItemId;
-(void) setDataSource:(STKDataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId;
-(void) seekToTime:(double)value;
-(void) clearQueue;
-(void) pause;
-(void) resume;
-(void) stop;
-(void) flushStop;
-(void) mute;
-(void) unmute;
-(void) dispose;
-(NSObject*) currentlyPlayingQueueItemId;
-(void) updateMeters;
-(float) peakPowerInDecibelsForChannel:(NSUInteger)channelNumber;
-(float) averagePowerInDecibelsForChannel:(NSUInteger)channelNumber;

@end
