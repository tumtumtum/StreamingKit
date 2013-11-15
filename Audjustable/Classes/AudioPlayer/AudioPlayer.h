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
#import "DataSource.h"
#include <AudioToolbox/AudioToolbox.h>

#define AudioPlayerDefaultNumberOfAudioQueueBuffers (2 * 1024)

typedef enum
{
	AudioPlayerInternalStateInitialised = 0,
    AudioPlayerInternalStateRunning = 1,
    AudioPlayerInternalStatePlaying = (1 << 1) | AudioPlayerInternalStateRunning,
	AudioPlayerInternalStateStartingThread = (1 << 2) | AudioPlayerInternalStateRunning,
	AudioPlayerInternalStateWaitingForData = (1 << 3) | AudioPlayerInternalStateRunning,
    AudioPlayerInternalStateWaitingForQueueToStart = (1 << 4) | AudioPlayerInternalStateRunning,
    AudioPlayerInternalStatePaused = (1 << 5) | AudioPlayerInternalStateRunning,
    AudioPlayerInternalStateRebuffering = (1 << 6) | AudioPlayerInternalStateRunning,
    AudioPlayerInternalStateStopping = (1 << 7),
    AudioPlayerInternalStateStopped = (1 << 8),
    AudioPlayerInternalStateDisposed = (1 << 9),
    AudioPlayerInternalStateError = (1 << 10)
}
AudioPlayerInternalState;

typedef enum
{
    AudioPlayerStateReady,
    AudioPlayerStateRunning = 1,
    AudioPlayerStatePlaying = (1 << 1) | AudioPlayerStateRunning,
    AudioPlayerStatePaused = (1 << 2) | AudioPlayerStateRunning,
    AudioPlayerStateStopped = (1 << 3),
    AudioPlayerStateError = (1 << 4),
    AudioPlayerStateDisposed = (1 << 5)
}
AudioPlayerState;

typedef enum
{
	AudioPlayerStopReasonNoStop = 0,
	AudioPlayerStopReasonEof,
	AudioPlayerStopReasonUserAction,
    AudioPlayerStopReasonUserActionFlushStop
}
AudioPlayerStopReason;

typedef enum
{
	AudioPlayerErrorNone = 0,
	AudioPlayerErrorDataSource,
    AudioPlayerErrorStreamParseBytesFailed,
    AudioPlayerErrorDataNotFound,
    AudioPlayerErrorQueueStartFailed,
    AudioPlayerErrorQueuePauseFailed,
    AudioPlayerErrorUnknownBuffer,
    AudioPlayerErrorQueueStopFailed,
    AudioPlayerErrorOther
}
AudioPlayerErrorCode;

@class AudioPlayer;

@protocol AudioPlayerDelegate <NSObject>
-(void) audioPlayer:(AudioPlayer*)audioPlayer stateChanged:(AudioPlayerState)state;
-(void) audioPlayer:(AudioPlayer*)audioPlayer didEncounterError:(AudioPlayerErrorCode)errorCode;
-(void) audioPlayer:(AudioPlayer*)audioPlayer didStartPlayingQueueItemId:(NSObject*)queueItemId;
-(void) audioPlayer:(AudioPlayer*)audioPlayer didFinishBufferingSourceWithQueueItemId:(NSObject*)queueItemId;
-(void) audioPlayer:(AudioPlayer*)audioPlayer didFinishPlayingQueueItemId:(NSObject*)queueItemId withReason:(AudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration;
@optional
-(void) audioPlayer:(AudioPlayer*)audioPlayer logInfo:(NSString*)line;
-(void) audioPlayer:(AudioPlayer*)audioPlayer internalStateChanged:(AudioPlayerInternalState)state;
-(void) audioPlayer:(AudioPlayer*)audioPlayer didCancelQueuedItems:(NSArray*)queuedItems;
@end

@class QueueEntry;

typedef struct
{
    AudioQueueBufferRef ref;
    int bufferIndex;
}
AudioQueueBufferRefLookupEntry;

@interface AudioPlayer : NSObject<DataSourceDelegate>
{
@private
    UInt8* readBuffer;
    int readBufferSize;
	
    NSOperationQueue* fastApiQueue;
    
    QueueEntry* currentlyPlayingEntry;
    QueueEntry* currentlyReadingEntry;
    
    NSMutableArray* upcomingQueue;
    NSMutableArray* bufferingQueue;
    
    AudioQueueBufferRef* audioQueueBuffer;
    AudioQueueBufferRefLookupEntry* audioQueueBufferLookup;
    unsigned int audioQueueBufferRefLookupCount;
    unsigned int audioQueueBufferCount;
    AudioStreamPacketDescription* packetDescs;
    bool* bufferUsed;
    int numberOfBuffersUsed;
    
    AudioQueueRef audioQueue;
    AudioStreamBasicDescription currentAudioStreamBasicDescription;
    
    NSThread* playbackThread;
    NSRunLoop* playbackThreadRunLoop;
    NSConditionLock* threadFinishedCondLock;
    
    AudioFileStreamID audioFileStream;
    
    BOOL discontinuous;
    
    int bytesFilled;
	int packetsFilled;
    
    int fillBufferIndex;
    
	UIBackgroundTaskIdentifier backgroundTaskId;
	
    AudioPlayerErrorCode errorCode;
    AudioPlayerStopReason stopReason;
    
    int currentlyPlayingLock;
    pthread_mutex_t playerMutex;
    pthread_mutex_t queueBuffersMutex;
    pthread_cond_t queueBufferReadyCondition;
    
    volatile BOOL waiting;
    volatile BOOL disposeWasRequested;
    volatile BOOL seekToTimeWasRequested;
    volatile BOOL newFileToPlay;
    volatile double requestedSeekTime;
    volatile BOOL audioQueueFlushing;
    volatile SInt64 audioPacketsReadCount;
    volatile SInt64 audioPacketsPlayedCount;
    
    BOOL meteringEnabled;
    AudioQueueLevelMeterState* levelMeterState;
    NSInteger numberOfChannels;
}

@property (readonly) double duration;
@property (readonly) double progress;
@property (readwrite) AudioPlayerState state;
@property (readonly) AudioPlayerStopReason stopReason;
@property (readwrite, unsafe_unretained) id<AudioPlayerDelegate> delegate;
@property (readwrite) BOOL meteringEnabled;

-(id) init;
-(id) initWithNumberOfAudioQueueBuffers:(int)numberOfAudioQueueBuffers andReadBufferSize:(int)readBufferSizeIn;
-(DataSource*) dataSourceFromURL:(NSURL*)url;
-(void) play:(NSURL*)url;
-(void) queueDataSource:(DataSource*)dataSource withQueueItemId:(NSObject*)queueItemId;
-(void) setDataSource:(DataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId;
-(void) seekToTime:(double)value;
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
