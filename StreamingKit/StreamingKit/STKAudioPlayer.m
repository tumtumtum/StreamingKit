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

#import "STKAudioPlayer.h"
#import "AudioToolbox/AudioToolbox.h"
#import "STKHTTPDataSource.h"
#import "STKLocalFileDataSource.h"
#import "libkern/OSAtomic.h"

#define STK_BIT_RATE_ESTIMATION_MIN_PACKETS (64)
#define STK_BUFFERS_NEEDED_TO_START (32)
#define STK_BUFFERS_NEEDED_WHEN_UNDERUNNING (128)
#define STK_DEFAULT_READ_BUFFER_SIZE (2 * 1024)
#define STK_DEFAULT_PACKET_BUFFER_SIZE (2048)
#define STK_FRAMES_MISSED_BEFORE_CONSIDERED_UNDERRUN (1024)
#define STK_DEFAULT_NUMBER_OF_AUDIOQUEUE_BUFFERS (1024)

#define OSSTATUS_PARAM_ERROR (-50)

#define LOGINFO(x) [self logInfo:[NSString stringWithFormat:@"%s %@", sel_getName(_cmd), x]];

typedef struct
{
    AudioQueueBufferRef ref;
    int bufferIndex;
}
AudioQueueBufferRefLookupEntry;

@interface NSMutableArray(AudioPlayerExtensions)
-(void) enqueue:(id)obj;
-(id) dequeue;
-(id) peek;
@end

@implementation NSMutableArray(AudioPlayerExtensions)

-(void) enqueue:(id)obj
{
    [self insertObject:obj atIndex:0];
}

-(void) skipQueue:(id)obj
{
    [self addObject:obj];
}

-(id) dequeue
{
    if ([self count] == 0)
    {
        return nil;
    }
    
    id retval = [self lastObject];
    
    [self removeLastObject];
    
    return retval;
}

-(id) peek
{
    return [self lastObject];
}

-(id) peekRecent
{
    if (self.count == 0)
    {
        return nil;
    }
    
    return [self objectAtIndex:0];
}

@end

@interface STKQueueEntry : NSObject
{
@public
    BOOL parsedHeader;
    double sampleRate;
    double lastProgress;
    double packetDuration;
    UInt64 audioDataOffset;
    UInt64 audioDataByteCount;
    UInt32 packetBufferSize;
    volatile BOOL cancel;
    volatile int processedPacketsCount;
	volatile int processedPacketsSizeTotal;
    AudioStreamBasicDescription audioStreamBasicDescription;
}
@property (readwrite, retain) NSObject* queueItemId;
@property (readwrite, retain) STKDataSource* dataSource;
@property (readwrite) Float64 seekTime;
@property (readwrite) int bytesBuffered;
@property (readwrite) int lastByteIndex;
@property (readwrite) Float64 lastFrameIndex;
@property (readwrite) Float64 timeWhenLastBufferReturned;
@property (readwrite) Float64 firstFrameIndex;
@property (readonly) UInt64 audioDataLengthInBytes;

-(double) duration;
-(double) calculatedBitRate;

-(id) initWithDataSource:(STKDataSource*)dataSource andQueueItemId:(NSObject*)queueItemId;

@end

@implementation STKQueueEntry

-(id) initWithDataSource:(STKDataSource*)dataSourceIn andQueueItemId:(NSObject*)queueItemIdIn
{
    if (self = [super init])
    {
        self.dataSource = dataSourceIn;
        self.queueItemId = queueItemIdIn;
        self.lastFrameIndex = -1;
        self.lastByteIndex = -1;
    }
    
    return self;
}

-(double) calculatedBitRate
{
    double retval;
    
    if (packetDuration && processedPacketsCount > STK_BIT_RATE_ESTIMATION_MIN_PACKETS)
	{
		double averagePacketByteSize = processedPacketsSizeTotal / processedPacketsCount;
        
		retval = averagePacketByteSize / packetDuration * 8;
        
        return retval;
	}
	
    retval = (audioStreamBasicDescription.mBytesPerFrame * audioStreamBasicDescription.mSampleRate) * 8;
    
    return retval;
}

-(void) updateAudioDataSource
{
    if ([self.dataSource conformsToProtocol:@protocol(AudioDataSource)])
    {
        double calculatedBitrate = [self calculatedBitRate];
        
        id<AudioDataSource> audioDataSource = (id<AudioDataSource>)self.dataSource;
        
        audioDataSource.averageBitRate = calculatedBitrate;
        audioDataSource.audioDataOffset = audioDataOffset;
    }
}

-(Float64) calculateProgressWithTotalFramesPlayed:(Float64)framesPlayed
{
    return (Float64)self.seekTime + ((framesPlayed - self.firstFrameIndex) / (Float64)self->audioStreamBasicDescription.mSampleRate);
}

-(double) calculateProgressWithBytesPlayed:(Float64)bytesPlayed
{
    double retval = lastProgress;
    
    if (self->sampleRate > 0)
    {
        double calculatedBitrate = [self calculatedBitRate];
        
        retval = bytesPlayed / calculatedBitrate * 8;
        
        retval = self.seekTime + retval;
        
        [self updateAudioDataSource];
    }
    
	return retval;
}

-(double) duration
{
    if (self->sampleRate <= 0)
    {
        return 0;
    }
    
    UInt64 audioDataLengthInBytes = [self audioDataLengthInBytes];
    
    double calculatedBitRate = [self calculatedBitRate];
    
    if (calculatedBitRate < 1.0 || self.dataSource.length == 0)
    {
        return 0;
    }
    
    return audioDataLengthInBytes / (calculatedBitRate / 8);
}

-(UInt64) audioDataLengthInBytes
{
    if (audioDataByteCount)
    {
        return audioDataByteCount;
    }
    else
    {
        if (!self.dataSource.length)
        {
            return 0;
        }
        
        return self.dataSource.length - audioDataOffset;
    }
}

-(BOOL) isDefinitelyCompatible:(AudioStreamBasicDescription*)basicDescription
{
    if (self->audioStreamBasicDescription.mSampleRate == 0)
    {
        return NO;
    }
    
    return (memcmp(&(self->audioStreamBasicDescription), basicDescription, sizeof(*basicDescription)) == 0);
}

-(BOOL) isKnownToBeIncompatible:(AudioStreamBasicDescription*)basicDescription
{
    if (self->audioStreamBasicDescription.mSampleRate == 0)
    {
        return NO;
    }
    
    return (memcmp(&(self->audioStreamBasicDescription), basicDescription, sizeof(*basicDescription)) != 0);
}

-(BOOL) couldBeIncompatible:(AudioStreamBasicDescription*)basicDescription
{
    if (self->audioStreamBasicDescription.mSampleRate == 0)
    {
        return YES;
    }
    
    return memcmp(&(self->audioStreamBasicDescription), basicDescription, sizeof(*basicDescription)) != 0;
}

-(NSString*) description
{
    return [[self queueItemId] description];
}

@end

@interface STKAudioPlayer()
{
    UInt8* readBuffer;
    int readBufferSize;
	
    STKQueueEntry* currentlyPlayingEntry;
    STKQueueEntry* currentlyReadingEntry;
    
    NSMutableArray* upcomingQueue;
    NSMutableArray* bufferingQueue;
    
    bool* bufferUsed;
    AudioQueueBufferRef* audioQueueBuffer;
    AudioQueueBufferRefLookupEntry* audioQueueBufferLookup;
    unsigned int audioQueueBufferRefLookupCount;
    unsigned int audioQueueBufferCount;
    AudioStreamPacketDescription* packetDescs;
    UInt32 numberOfBuffersUsed;
    
    AudioQueueRef audioQueue;
    AudioStreamBasicDescription currentAudioStreamBasicDescription;
    
    NSThread* playbackThread;
    NSRunLoop* playbackThreadRunLoop;
    NSConditionLock* threadStartedLock;
    NSConditionLock* threadFinishedCondLock;
    Float64 averageHardwareDelay;
    
    AudioFileStreamID audioFileStream;
    
    BOOL discontinuous;
    
    int32_t bytesFilled;
	int32_t packetsFilled;
    int32_t framesFilled;
    int32_t fillBufferIndex;
    
    volatile Float64 framesQueued;
    volatile Float64 timelineAdjust;
    volatile Float64 rebufferingStartFrames;
    
#if TARGET_OS_IPHONE
	UIBackgroundTaskIdentifier backgroundTaskId;
#endif
    
    AudioPlayerErrorCode errorCode;
    AudioPlayerStopReason stopReason;
    
    int32_t seekVersion;
    OSSpinLock seekLock;
    OSSpinLock currentEntryReferencesLock;

    pthread_mutex_t playerMutex;
    pthread_mutex_t queueBuffersMutex;
    pthread_cond_t queueBufferReadyCondition;
    pthread_mutex_t mainThreadSyncCallMutex;
    pthread_cond_t mainThreadSyncCallReadyCondition;
    
    volatile BOOL waiting;
    volatile BOOL disposeWasRequested;
    volatile BOOL seekToTimeWasRequested;
    volatile BOOL newFileToPlay;
    volatile double requestedSeekTime;
    volatile BOOL audioQueueFlushing;
    volatile SInt64 audioPacketsReadCount;
    volatile SInt64 audioPacketsPlayedCount;
    
    BOOL meteringEnabled;
    UInt32 numberOfChannels;
    AudioQueueLevelMeterState* levelMeterState;
}

@property (readwrite) AudioPlayerInternalState internalState;
@property (readwrite) AudioPlayerInternalState stateBeforePaused;

-(void) logInfo:(NSString*)line;
-(void) createAudioQueue;
-(void) enqueueBuffer;
-(void) resetAudioQueueWithReason:(NSString*)reason;
-(BOOL) startAudioQueue;
-(void) stopAudioQueueWithReason:(NSString*)reason;
-(BOOL) processRunloop;
-(void) wakeupPlaybackThread;
-(void) audioQueueFinishedPlaying:(STKQueueEntry*)entry;
-(void) processSeekToTime;
-(void) didEncounterError:(AudioPlayerErrorCode)errorCode;
-(void) setInternalState:(AudioPlayerInternalState)value;
-(void) processFinishPlayingIfAnyAndPlayingNext:(STKQueueEntry*)entry withNext:(STKQueueEntry*)next;
-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)audioFileStreamIn fileStreamPropertyID:(AudioFileStreamPropertyID)propertyID ioFlags:(UInt32*)ioFlags;
-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptions;
-(void) handleAudioQueueOutput:(AudioQueueRef)audioQueue buffer:(AudioQueueBufferRef)buffer;
-(void) handlePropertyChangeForQueue:(AudioQueueRef)audioQueue propertyID:(AudioQueuePropertyID)propertyID;
@end

static void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{
	STKAudioPlayer* player = (__bridge STKAudioPlayer*)clientData;
    
	[player handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

static void AudioFileStreamPacketsProc(void* clientData, UInt32 numberBytes, UInt32 numberPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
	STKAudioPlayer* player = (__bridge STKAudioPlayer*)clientData;
    
	[player handleAudioPackets:inputData numberBytes:numberBytes numberPackets:numberPackets packetDescriptions:packetDescriptions];
}

static void AudioQueueOutputCallbackProc(void* clientData, AudioQueueRef audioQueue, AudioQueueBufferRef buffer)
{
	STKAudioPlayer* player = (__bridge STKAudioPlayer*)clientData;
    
	[player handleAudioQueueOutput:audioQueue buffer:buffer];
}

static void AudioQueueIsRunningCallbackProc(void* userData, AudioQueueRef audioQueue, AudioQueuePropertyID propertyId)
{
	STKAudioPlayer* player = (__bridge STKAudioPlayer*)userData;
    
	[player handlePropertyChangeForQueue:audioQueue propertyID:propertyId];
}

@implementation STKAudioPlayer
@synthesize delegate, internalState, state;

-(AudioPlayerInternalState) internalState
{
    return internalState;
}

-(void) setInternalState:(AudioPlayerInternalState)value
{
    if (value == internalState)
    {
        return;
    }
    
    internalState = value;
    
    if ([self.delegate respondsToSelector:@selector(audioPlayer:internalStateChanged:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.delegate audioPlayer:self internalStateChanged:internalState];
        });
    }
    
    AudioPlayerState newState;
    
    switch (internalState)
    {
        case AudioPlayerInternalStateInitialised:
            newState = AudioPlayerStateReady;
            break;
        case AudioPlayerInternalStateRunning:
        case AudioPlayerInternalStateStartingThread:
        case AudioPlayerInternalStatePlaying:
        case AudioPlayerInternalStateWaitingForDataAfterSeek:
        case AudioPlayerInternalStateFlushingAndStoppingButStillPlaying:
            newState = AudioPlayerStatePlaying;
            break;
        case AudioPlayerInternalStateRebuffering:
        case AudioPlayerInternalStateWaitingForData:
            newState = AudioPlayerStateBuffering;
            break;
        case AudioPlayerInternalStateStopping:
        case AudioPlayerInternalStateStopped:
            newState = AudioPlayerStateStopped;
            break;
        case AudioPlayerInternalStatePaused:
            newState = AudioPlayerStatePaused;
            break;
        case AudioPlayerInternalStateDisposed:
            newState = AudioPlayerStateDisposed;
            break;
        case AudioPlayerInternalStateError:
            newState = AudioPlayerStateError;
            break;
    }
    
    if (newState != self.state)
    {
        self.state = newState;
        
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.delegate audioPlayer:self stateChanged:self.state];
        });
    }
}

-(AudioPlayerStopReason) stopReason
{
    return stopReason;
}

-(BOOL) audioQueueIsRunning
{
    UInt32 isRunning;
    UInt32 isRunningSize = sizeof(isRunning);
    
    AudioQueueGetProperty(audioQueue, kAudioQueueProperty_IsRunning, &isRunning, &isRunningSize);
    
    return isRunning ? YES : NO;
}

-(void) logInfo:(NSString*)line
{
    if ([NSThread currentThread].isMainThread)
    {
        if ([self->delegate respondsToSelector:@selector(audioPlayer:logInfo:)])
        {
            [self->delegate audioPlayer:self logInfo:line];
        }
    }
    else
    {
        if ([self->delegate respondsToSelector:@selector(audioPlayer:logInfo:)])
        {
            [self->delegate audioPlayer:self logInfo:line];
        }
    }
}

-(id) init
{
    return [self initWithNumberOfAudioQueueBuffers:STK_DEFAULT_NUMBER_OF_AUDIOQUEUE_BUFFERS andReadBufferSize:STK_DEFAULT_READ_BUFFER_SIZE];
}

-(id) initWithNumberOfAudioQueueBuffers:(int)numberOfAudioQueueBuffers andReadBufferSize:(int)readBufferSizeIn
{
    if (self = [super init])
    {
        readBufferSize = readBufferSizeIn;
        readBuffer = calloc(sizeof(UInt8), readBufferSize);
        
        audioQueueBufferCount = numberOfAudioQueueBuffers;
        audioQueueBuffer = calloc(sizeof(AudioQueueBufferRef), audioQueueBufferCount);
        
        audioQueueBufferRefLookupCount = audioQueueBufferCount * 2;
        audioQueueBufferLookup = calloc(sizeof(AudioQueueBufferRefLookupEntry), audioQueueBufferRefLookupCount);
        
        packetDescs = calloc(sizeof(AudioStreamPacketDescription), audioQueueBufferCount);
        bufferUsed = calloc(sizeof(bool), audioQueueBufferCount);
        
        pthread_mutexattr_t attr;
        
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        
        pthread_mutex_init(&playerMutex, &attr);
        pthread_mutex_init(&queueBuffersMutex, NULL);
        pthread_cond_init(&queueBufferReadyCondition, NULL);

        pthread_mutex_init(&mainThreadSyncCallMutex, NULL);
        pthread_cond_init(&mainThreadSyncCallReadyCondition, NULL);
        
        threadStartedLock = [[NSConditionLock alloc] initWithCondition:0];
        threadFinishedCondLock = [[NSConditionLock alloc] initWithCondition:0];
        
        self.internalState = AudioPlayerInternalStateInitialised;
        
        upcomingQueue = [[NSMutableArray alloc] init];
        bufferingQueue = [[NSMutableArray alloc] init];
        
        [self createPlaybackThread];
    }
    
    return self;
}

-(void) dealloc
{
    if (currentlyReadingEntry)
    {
        currentlyReadingEntry.dataSource.delegate = nil;
    }
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry.dataSource.delegate = nil;
    }
    
    pthread_mutex_destroy(&playerMutex);
    pthread_mutex_destroy(&queueBuffersMutex);
    pthread_cond_destroy(&queueBufferReadyCondition);

    pthread_mutex_destroy(&mainThreadSyncCallMutex);
    pthread_cond_destroy(&mainThreadSyncCallReadyCondition);

    
    if (audioFileStream)
    {
        AudioFileStreamClose(audioFileStream);
    }
    
    if (audioQueue)
    {
        AudioQueueDispose(audioQueue, true);
    }
    
    free(bufferUsed);
    free(readBuffer);
    free(packetDescs);
    free(audioQueueBuffer);
    free(audioQueueBufferLookup);
    free(levelMeterState);
}

-(void) startSystemBackgroundTask
{
#if TARGET_OS_IPHONE
	pthread_mutex_lock(&playerMutex);
	{
		if (backgroundTaskId != UIBackgroundTaskInvalid)
		{
            pthread_mutex_unlock(&playerMutex);
            
			return;
		}
		
		backgroundTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^
        {
            [self stopSystemBackgroundTask];
        }];
	}
    pthread_mutex_unlock(&playerMutex);
#endif
}

-(void) stopSystemBackgroundTask
{
#if TARGET_OS_IPHONE
	pthread_mutex_lock(&playerMutex);
	{
		if (backgroundTaskId != UIBackgroundTaskInvalid)
		{
			[[UIApplication sharedApplication] endBackgroundTask:backgroundTaskId];
			
			backgroundTaskId = UIBackgroundTaskInvalid;
		}
	}
    pthread_mutex_unlock(&playerMutex);
#endif
}

-(STKDataSource*) dataSourceFromURL:(NSURL*)url
{
    STKDataSource* retval;
    
    if ([url.scheme isEqualToString:@"file"])
    {
        retval = [[STKLocalFileDataSource alloc] initWithFilePath:url.path];
    }
    else
    {
        retval = [[STKHTTPDataSource alloc] initWithURL:url];
    }
    
    return retval;
}

-(void) clearQueue
{
    [self clearQueueIncludingUpcoming:YES];
}

-(void) clearQueueIncludingUpcoming:(BOOL)includeUpcoming
{
    pthread_mutex_lock(&playerMutex);
    {
        pthread_mutex_lock(&queueBuffersMutex);
        
        NSMutableArray* array = [[NSMutableArray alloc] initWithCapacity:bufferingQueue.count + (includeUpcoming ? upcomingQueue.count : 0)];
        
        STKQueueEntry* entry = [bufferingQueue dequeue];
        
        if (entry && entry != currentlyPlayingEntry)
        {
            [array addObject:[entry queueItemId]];
        }
        
        while (bufferingQueue.count > 0)
        {
            id queueItemId = [[bufferingQueue dequeue] queueItemId];
            
            if (queueItemId != nil)
            {
                [array addObject:queueItemId];
            }
        }
        
        if (includeUpcoming)
        {
            for (STKQueueEntry* entry in upcomingQueue)
            {
                [array addObject:entry.queueItemId];
            }
            
            [upcomingQueue removeAllObjects];
        }
        
        if (array.count > 0)
        {
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
                if ([self.delegate respondsToSelector:@selector(audioPlayer:didCancelQueuedItems:)])
                {
                    [self.delegate audioPlayer:self didCancelQueuedItems:array];
                }
            }];
        }
        
        pthread_mutex_unlock(&queueBuffersMutex);
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) play:(NSString*)urlString
{
    NSURL* url = [NSURL URLWithString:urlString];
    
	[self setDataSource:[self dataSourceFromURL:url] withQueueItemId:urlString];
}

-(void) playWithURL:(NSURL*)url
{
	[self setDataSource:[self dataSourceFromURL:url] withQueueItemId:url];
}

-(void) playWithDataSource:(STKDataSource*)dataSource
{
	[self setDataSource:dataSource withQueueItemId:dataSource];
}

-(void) setDataSource:(STKDataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
	[self invokeOnPlaybackThread:^
    {
        pthread_mutex_lock(&playerMutex);
        {
            LOGINFO(([NSString stringWithFormat:@"Playing: %@", [queueItemId description]]));
            
            [self startSystemBackgroundTask];

            [self resetAudioQueueWithReason:@"from skipCurrent"];
            [self clearQueue];
            
            pthread_mutex_lock(&queueBuffersMutex);
            
            [upcomingQueue enqueue:[[STKQueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
            
            pthread_mutex_unlock(&queueBuffersMutex);
            
            self.internalState = AudioPlayerInternalStateRunning;
            
            newFileToPlay = YES;
        }
        pthread_mutex_unlock(&playerMutex);
    }];
    
    [self wakeupPlaybackThread];
}

-(void) queueDataSource:(STKDataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
	[self invokeOnPlaybackThread:^
    {
        pthread_mutex_lock(&playerMutex);
        {
            [upcomingQueue enqueue:[[STKQueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
        }
        pthread_mutex_unlock(&playerMutex);
    }];
    
    [self wakeupPlaybackThread];
}

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
	OSStatus error;
    
    if (!currentlyReadingEntry)
    {
        return;
    }
    
    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_DataOffset:
        {
            SInt64 offset;
            UInt32 offsetSize = sizeof(offset);
            
            AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
            
            currentlyReadingEntry->parsedHeader = YES;
            currentlyReadingEntry->audioDataOffset = offset;
            
            [currentlyReadingEntry updateAudioDataSource];
            
            break;
        }
        case kAudioFileStreamProperty_FileFormat:
        {
            char fileFormat[4];
			UInt32 fileFormatSize = sizeof(fileFormat);
            
			AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FileFormat, &fileFormatSize, &fileFormat);
            
            break;
        }
        case kAudioFileStreamProperty_DataFormat:
        {
            AudioStreamBasicDescription newBasicDescription;
            STKQueueEntry* entryToUpdate = currentlyReadingEntry;

            if (currentlyReadingEntry->audioStreamBasicDescription.mSampleRate == 0)
            {
                UInt32 size = sizeof(newBasicDescription);
                
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &newBasicDescription);

                pthread_mutex_lock(&playerMutex);
                pthread_mutex_lock(&queueBuffersMutex);
                                
                BOOL cancel = NO;
                
                AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
                
                if (currentlyReadingEntry->cancel)
                {
                    cancel = YES;
                }
                else
                {
                    if (currentlyReadingEntry != currentlyPlayingEntry && audioQueue && currentAudioStreamBasicDescription.mSampleRate != 0)
                    {
                        if (memcmp(&currentAudioStreamBasicDescription, &newBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
                        {
                            cancel = YES;
                        }
                    }
                }
                
                if (cancel)
                {
                    [currentlyReadingEntry.dataSource unregisterForEvents];
                    
                    if ([bufferingQueue objectAtIndex:0] == currentlyReadingEntry)
                    {
                        [bufferingQueue removeObjectAtIndex:0];
                    }
                    
                    STKQueueEntry* newEntry = [[STKQueueEntry alloc] initWithDataSource:currentlyReadingEntry.dataSource andQueueItemId:currentlyReadingEntry.queueItemId];
                    
                    entryToUpdate = newEntry;
                    
                    [upcomingQueue skipQueue:newEntry];
                    
                    OSSpinLockLock(&currentEntryReferencesLock);
                    currentlyReadingEntry = nil;
                    OSSpinLockUnlock(&currentEntryReferencesLock);
                }
                
                entryToUpdate->audioStreamBasicDescription = newBasicDescription;
                entryToUpdate->sampleRate = entryToUpdate->audioStreamBasicDescription.mSampleRate;
                entryToUpdate->packetDuration = entryToUpdate->audioStreamBasicDescription.mFramesPerPacket / entryToUpdate->sampleRate;

                UInt32 packetBufferSize = 0;
                UInt32 sizeOfPacketBufferSize = sizeof(packetBufferSize);
                
                error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfPacketBufferSize, &packetBufferSize);
                
                if (error || packetBufferSize == 0)
                {
                    error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfPacketBufferSize, &packetBufferSize);
                    
                    if (error || packetBufferSize == 0)
                    {
                        entryToUpdate->packetBufferSize = STK_DEFAULT_PACKET_BUFFER_SIZE;
                    }
                    else
                    {
                        entryToUpdate->packetBufferSize = packetBufferSize;
                    }
                }
                else
                {
                    entryToUpdate->packetBufferSize = packetBufferSize;
                }
                
                [entryToUpdate updateAudioDataSource];
                
                pthread_mutex_unlock(&queueBuffersMutex);
                pthread_mutex_unlock(&playerMutex);
            }
            
            break;
        }
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt64 audioDataByteCount;
            UInt32 byteCountSize = sizeof(audioDataByteCount);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
            
            currentlyReadingEntry->audioDataByteCount = audioDataByteCount;
            
            [currentlyReadingEntry updateAudioDataSource];
            
            break;
        }
		case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            discontinuous = YES;
            
            break;
        }
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            OSStatus err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            
            if (err)
            {
                break;
            }
            
            AudioFormatListItem* formatList = malloc(formatListSize);
            
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            
            if (err)
            {
                free(formatList);
                break;
            }
            
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
            {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
                {
                    //
                    // We've found HE-AAC, remember this to tell the audio queue
                    // when we construct it.
                    //
#if !TARGET_IPHONE_SIMULATOR
                    currentlyReadingEntry->audioStreamBasicDescription = pasbd;
#endif
                    break;
                }
            }
            
            free(formatList);
            
            break;
        }
        
    }
}

-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptionsIn
{
    if (currentlyReadingEntry == nil)
    {
        return;
    }
    
    if (seekToTimeWasRequested || disposeWasRequested)
    {
        return;
    }
    
	if (audioQueue == nil)
    {
        if (currentlyPlayingEntry == nil)
        {
            return;
        }
        
        [self createAudioQueue];
    
        if (audioQueue == nil)
        {
            return;
        }
        
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            if (stopReason == AudioPlayerStopReasonEof)
            {
                stopReason = AudioPlayerStopReasonNoStop;
                self.internalState = AudioPlayerInternalStateWaitingForData;
            }
            else
            {
                return;
            }
        }
    }
    else if (memcmp(&currentAudioStreamBasicDescription, &currentlyReadingEntry->audioStreamBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
    {
        if (currentlyReadingEntry == currentlyPlayingEntry && currentlyReadingEntry != nil)
        {
            [self createAudioQueue];
            
            if (audioQueue == nil)
            {
                return;
            }
        }
        else
        {
            return;
        }
    }
    
    if (discontinuous)
    {
        discontinuous = NO;
    }
    
    if (packetDescriptionsIn)
    {
        // VBR
        
        for (int i = 0; i < numberPackets; i++)
        {
            SInt64 packetOffset = packetDescriptionsIn[i].mStartOffset;
            SInt64 packetSize = packetDescriptionsIn[i].mDataByteSize;
            int bufSpaceRemaining;
            
            int framesPerPacket;
            
            if (packetDescriptionsIn[i].mVariableFramesInPacket > 0)
            {
                framesPerPacket = packetDescriptionsIn[i].mVariableFramesInPacket;
            }
            else
            {
                framesPerPacket = currentlyReadingEntry->audioStreamBasicDescription.mFramesPerPacket;
            }
            
            if (currentlyReadingEntry->processedPacketsCount * framesPerPacket < currentlyReadingEntry->audioStreamBasicDescription.mSampleRate * 15 * currentlyReadingEntry->audioStreamBasicDescription.mChannelsPerFrame)
            {
                OSAtomicAdd32((int32_t)packetSize, &currentlyReadingEntry->processedPacketsSizeTotal);
                OSAtomicIncrement32(&currentlyReadingEntry->processedPacketsCount);
            }
            
            if (packetSize > currentlyReadingEntry->packetBufferSize)
            {
                return;
            }
            
            bufSpaceRemaining = currentlyReadingEntry->packetBufferSize - bytesFilled;
            
            if (bufSpaceRemaining < packetSize)
            {
                [self enqueueBuffer];
                
                if (audioQueue == nil || disposeWasRequested || seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed)
                {
                    return;
                }
            }
            
            if (bytesFilled + packetSize > currentlyReadingEntry->packetBufferSize)
            {
                return;
            }
            
            AudioQueueBufferRef bufferToFill = audioQueueBuffer[fillBufferIndex];
            memcpy((char*)bufferToFill->mAudioData + bytesFilled, (const char*)inputData + packetOffset, (unsigned long)packetSize);
            
            framesFilled += framesPerPacket;
            
            packetDescs[packetsFilled] = packetDescriptionsIn[i];
            packetDescs[packetsFilled].mStartOffset = bytesFilled;
            
            bytesFilled += packetSize;
            packetsFilled++;
            
            int packetsDescRemaining = audioQueueBufferCount - packetsFilled;
            
            if (packetsDescRemaining <= 0)
            {
                [self enqueueBuffer];
                
                if (audioQueue == nil || disposeWasRequested || seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed)
                {
                    return;
                }
            }
        }
    }
    else
    {
        // CBR
        
    	int offset = 0;
        
		while (numberBytes)
		{
			int bytesLeft = currentlyReadingEntry->packetBufferSize - bytesFilled;
            
			if (bytesLeft < numberBytes)
			{
				[self enqueueBuffer];
                
                if (audioQueue == nil || disposeWasRequested || seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed)
                {
                    return;
                }
			}
			
            int copySize;
            bytesLeft = currentlyReadingEntry->packetBufferSize - bytesFilled;
            
            if (bytesLeft < numberBytes)
            {
                copySize = bytesLeft;
            }
            else
            {
                copySize = numberBytes;
            }
            
            if (bytesFilled > currentlyPlayingEntry->packetBufferSize)
            {
                pthread_mutex_unlock(&playerMutex);
                
                return;
            }
            
            AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
            memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inputData + offset), copySize);
            
            bytesFilled += copySize;
            packetsFilled = 0;
            numberBytes -= copySize;
            offset += copySize;
		}
    }
}


-(BOOL) moreFramesAreDefinitelyAvailableToPlay
{
	return [self moreFramesAreDefinitelyAvailableToPlayIgnoreExisting:NO];
}

-(BOOL) moreFramesAreDefinitelyAvailableToPlayIgnoreExisting:(BOOL)ignoreExisting
{
    if (numberOfBuffersUsed > 0 && !ignoreExisting)
    {
        return YES;
    }
    
    if (currentlyReadingEntry == currentlyPlayingEntry)
    {
        if (currentlyReadingEntry.dataSource.position == currentlyReadingEntry.dataSource.length)
        {
            return NO;
        }
        else
        {
            return YES;
        }
    }
    
    if (bufferingQueue.count > 1)
    {
        return YES;
    }
    
    if (bufferingQueue.count == 1 && [((STKQueueEntry*)[bufferingQueue peek]) couldBeIncompatible:&currentAudioStreamBasicDescription])
    {
        return NO;
    }
    
    if (upcomingQueue.count > 0)
    {
        if  ([((STKQueueEntry*)[upcomingQueue peek]) isDefinitelyCompatible:&currentAudioStreamBasicDescription])
        {
            return YES;
        }
    }
    
    return NO;
}

-(void) makeSureIncompatibleNextBufferingIsCancelled
{
    if (bufferingQueue.count == 1)
    {
        STKQueueEntry* nextBuffering = [bufferingQueue peek];
        
        if ([nextBuffering couldBeIncompatible:&currentAudioStreamBasicDescription])
        {
            nextBuffering->cancel = YES;
        }
    }
}

-(void) handleAudioQueueOutput:(AudioQueueRef)audioQueueIn buffer:(AudioQueueBufferRef)bufferIn
{
    int bufferIndex = -1;
    
    if (audioQueueIn != audioQueue)
    {
        return;
    }
    
    STKQueueEntry* entry = nil;
    
    if (currentlyPlayingEntry)
    {
        OSSpinLockLock(&currentEntryReferencesLock);
        {
            if (currentlyPlayingEntry)
            {
                entry = currentlyPlayingEntry;
                
                if (!audioQueueFlushing)
                {
                    entry.bytesBuffered += bufferIn->mAudioDataByteSize;
                }
            }
        }
        OSSpinLockUnlock(&currentEntryReferencesLock);
    }
    
    int index = (int)bufferIn % audioQueueBufferRefLookupCount;
    
    for (int i = 0; i < audioQueueBufferCount; i++)
    {
        if (audioQueueBufferLookup[index].ref == bufferIn)
        {
            bufferIndex = audioQueueBufferLookup[index].bufferIndex;
            
            break;
        }
        
        index = (index + 1) % audioQueueBufferRefLookupCount;
    }
    
    audioPacketsPlayedCount++;
	
	if (bufferIndex == -1)
	{
        [self playbackThreadQueueMainThreadSyncBlock:^
        {
            [self didEncounterError:AudioPlayerErrorUnknownBuffer];
        }];
        
		pthread_mutex_lock(&queueBuffersMutex);
		pthread_cond_signal(&queueBufferReadyCondition);
		pthread_mutex_unlock(&queueBuffersMutex);
        
		return;
	}
	
    pthread_mutex_lock(&queueBuffersMutex);
    
    BOOL signal = NO;
    
    if (bufferUsed[bufferIndex])
    {
        bufferUsed[bufferIndex] = false;
        numberOfBuffersUsed--;
    }
    else
    {
        // This should never happen
        
        signal = YES;
    }
    
    Float64 currentTime = [self currentTimeInFrames];
    
    if (entry != nil && !seekToTimeWasRequested)
    {
        if (entry.lastByteIndex == audioPacketsPlayedCount || ![self moreFramesAreDefinitelyAvailableToPlay])
        {
            LOGINFO(@"Final AudioBuffer returned");
            
            entry.timeWhenLastBufferReturned = currentTime;
            
            if (entry.lastFrameIndex < currentTime && entry.lastByteIndex == audioPacketsPlayedCount)
            {
                LOGINFO(@"Timeline drift");
                
                entry.lastFrameIndex = currentTime + 1;
            }
            
            if (![self moreFramesAreDefinitelyAvailableToPlay])
            {
                [self makeSureIncompatibleNextBufferingIsCancelled];
                
                if (self.internalState != AudioPlayerInternalStateFlushingAndStoppingButStillPlaying)
                {
                    if (audioQueue && [self audioQueueIsRunning])
                    {
                        self.internalState = AudioPlayerInternalStateFlushingAndStoppingButStillPlaying;
                        
                        LOGINFO(@"AudioQueueStop from handleAudioQueueOutput");
                        
                        [self invokeOnPlaybackThread:^
                        {
                            AudioQueueStop(audioQueue, NO);
                        }];
                    }
                }
            }
        }
        
        if (self.internalState != AudioPlayerInternalStateFlushingAndStoppingButStillPlaying)
        {
            if ((entry.lastFrameIndex != -1 && currentTime >= entry.lastFrameIndex && audioPacketsPlayedCount >= entry.lastByteIndex) || ![self moreFramesAreDefinitelyAvailableToPlay])
            {
                LOGINFO(@"Final frame played");
                
                Float64 hardwareDelay = currentTime - entry.timeWhenLastBufferReturned;
                
                if (averageHardwareDelay == 0)
                {
                    averageHardwareDelay = hardwareDelay;
                }
                else
                {
                    averageHardwareDelay = (averageHardwareDelay + hardwareDelay) / 2;
                }
                
                LOGINFO(([NSString stringWithFormat:@"Current Hardware Delay: %f", hardwareDelay]));
                LOGINFO(([NSString stringWithFormat:@"Average Hardware Delay: %f", averageHardwareDelay]));
                
                entry.lastFrameIndex = -1;

                [self invokeOnPlaybackThread:^
                {
                	[self audioQueueFinishedPlaying:entry];
                }];
                
                signal = YES;
            }
        }
    }
    
    if (!audioQueueFlushing)
    {
        if (numberOfBuffersUsed == 0
            && !seekToTimeWasRequested
            && !disposeWasRequested
            && self.internalState != AudioPlayerInternalStateFlushingAndStoppingButStillPlaying)
        {
            if (self->rebufferingStartFrames == 0)
            {
                if (self->numberOfBuffersUsed == 0
                    && !disposeWasRequested
                    && !seekToTimeWasRequested
                    && self->rebufferingStartFrames == 0
                    && self.internalState != AudioPlayerInternalStateWaitingForData
                    && self.internalState != AudioPlayerInternalStateFlushingAndStoppingButStillPlaying
                    && [self moreFramesAreDefinitelyAvailableToPlay])
                {
                    [self invokeOnPlaybackThread:^
                    {
                        self->rebufferingStartFrames = currentTime;
                        AudioQueuePause(audioQueue);
                    }];
                    
                    LOGINFO(([NSString stringWithFormat:@"Buffer underrun with time: %f", [self currentTimeInFrames]]));
                }
            }
            
            if (self.internalState != AudioPlayerInternalStateRebuffering && self.internalState != AudioPlayerInternalStatePaused)
            {
                Float64 interval = STK_FRAMES_MISSED_BEFORE_CONSIDERED_UNDERRUN / currentAudioStreamBasicDescription.mSampleRate;
                
                [self invokeOnPlaybackThreadAtInterval:interval withBlock:^
                {
                    [self setRebufferingStateIfApplicable];
                }];
            }
            
            signal = YES;
        }
        else
        {
            if (self.internalState == AudioPlayerInternalStateRebuffering && ([self readyToEndRebufferingState] || [self readyToEndWaitingForDataState]))
            {
                [self invokeOnPlaybackThread:^
                 {
                     self->rebufferingStartFrames = 0;
                     [self startAudioQueue];
                 }];
                
                signal = YES;
            }
        }
    }
    
    signal = signal || disposeWasRequested;
    
    if (self.internalState == AudioPlayerInternalStateStopped
        || self.internalState == AudioPlayerInternalStateStopping
        || self.internalState == AudioPlayerInternalStateDisposed
        || self.internalState == AudioPlayerInternalStateError)
    {
        signal = signal || waiting || numberOfBuffersUsed < (STK_BUFFERS_NEEDED_TO_START * 2);
    }
    else if (audioQueueFlushing)
    {
        signal = signal || (audioQueueFlushing && numberOfBuffersUsed < (STK_BUFFERS_NEEDED_TO_START * 2));
    }
    else
    {
        signal = signal || seekToTimeWasRequested || (numberOfBuffersUsed < self->audioQueueBufferCount / 2);
    }
    
    if (signal)
    {
        pthread_cond_signal(&queueBufferReadyCondition);
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) setRebufferingStateIfApplicable
{
    pthread_mutex_lock(&playerMutex);
    
    if (self->rebufferingStartFrames > 0)
    {
        if ([self currentTimeInFrames] > STK_FRAMES_MISSED_BEFORE_CONSIDERED_UNDERRUN
            && self.internalState != AudioPlayerInternalStateRebuffering
            && self.internalState != AudioPlayerInternalStatePaused)
        {
            self.internalState = AudioPlayerInternalStateRebuffering;
        }
        else
        {
            Float64 interval = STK_FRAMES_MISSED_BEFORE_CONSIDERED_UNDERRUN / currentAudioStreamBasicDescription.mSampleRate / 2;
            
            [self invokeOnPlaybackThreadAtInterval:interval withBlock:^
            {
                [self setRebufferingStateIfApplicable];
            }];
        }
    }
    
    pthread_mutex_unlock(&playerMutex);
}

-(Float64) currentTimeInFrames
{
    if (audioQueue == nil)
    {
        return 0;
    }
    
    AudioTimeStamp timeStamp;
    Boolean outTimelineDiscontinuity;
    
    AudioQueueGetCurrentTime(audioQueue, NULL, &timeStamp, &outTimelineDiscontinuity);
    
    return timeStamp.mSampleTime - timelineAdjust;
}

-(void) processFinishedPlayingViaAudioQueueStop
{
    if (currentlyPlayingEntry)
    {
        pthread_mutex_lock(&playerMutex);
        
        STKQueueEntry* entry = currentlyPlayingEntry;
        
        entry.lastFrameIndex = -1;
        
        pthread_mutex_unlock(&playerMutex);
        
        [self invokeOnPlaybackThread:^
        {
             self->stopReason = AudioPlayerStopReasonEof;
             self.internalState = AudioPlayerInternalStateStopped;
             
             if (audioQueue)
             {
                 [self stopAudioQueueWithReason:@"processFinishedPlayingViaAudioQueueStop"];
             }
             
             [self audioQueueFinishedPlaying:entry];
        }];
    }
    else
    {
        pthread_mutex_lock(&playerMutex);
        
        STKQueueEntry* entry = currentlyPlayingEntry;
        
        entry.lastFrameIndex = -1;
        
        pthread_mutex_unlock(&playerMutex);
        
        [self invokeOnPlaybackThread:^
        {
            if (audioQueue)
            {
                [self stopAudioQueueWithReason:@"processFinishedPlayingViaAudioQueueStop"];
            }
        
            [self audioQueueFinishedPlaying:entry];
        }];
    }
}

-(void) handlePropertyChangeForQueue:(AudioQueueRef)audioQueueIn propertyID:(AudioQueuePropertyID)propertyId
{
    if (audioQueueIn != audioQueue)
    {
        return;
    }
    
    if (propertyId == kAudioQueueProperty_IsRunning)
    {
        if (![self audioQueueIsRunning] && self.internalState == AudioPlayerInternalStateStopping)
        {
            self.internalState = AudioPlayerInternalStateStopped;
        }
        else if (![self audioQueueIsRunning] && self.internalState == AudioPlayerInternalStateFlushingAndStoppingButStillPlaying)
        {
            LOGINFO(@"AudioQueue not IsRunning")
            
            [self invokeOnPlaybackThread:^
            {
                [self processFinishedPlayingViaAudioQueueStop];
            }];
            
            pthread_mutex_lock(&queueBuffersMutex);
            
            if (signal)
            {
                pthread_cond_signal(&queueBufferReadyCondition);
            }
            
            pthread_mutex_unlock(&queueBuffersMutex);
        }
    }
}

-(BOOL) readyToEndRebufferingState
{
    BOOL tailEndOfBuffer = ![self moreFramesAreDefinitelyAvailableToPlayIgnoreExisting:YES];
    
    return self->rebufferingStartFrames > 0 && (numberOfBuffersUsed > STK_BUFFERS_NEEDED_WHEN_UNDERUNNING || tailEndOfBuffer);
}

-(BOOL) readyToEndWaitingForDataState
{
    BOOL tailEndOfBuffer = ![self moreFramesAreDefinitelyAvailableToPlayIgnoreExisting:YES];
    
    return (self.internalState == AudioPlayerInternalStateWaitingForData || self.internalState == AudioPlayerInternalStateWaitingForDataAfterSeek) && (numberOfBuffersUsed >= STK_BUFFERS_NEEDED_TO_START || tailEndOfBuffer);
}

-(void) enqueueBuffer
{
    BOOL queueBuffersMutexUnlocked = NO;
    
    pthread_mutex_lock(&playerMutex);
    {
		OSStatus error;
        
        if (audioFileStream == 0)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        if (audioQueueFlushing || newFileToPlay)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        pthread_mutex_lock(&queueBuffersMutex);
        
        if (audioQueue == nil)
        {
        	pthread_mutex_unlock(&queueBuffersMutex);
            
            return;
        }
        
        bufferUsed[fillBufferIndex] = true;
        numberOfBuffersUsed++;
        
        AudioQueueBufferRef buffer = audioQueueBuffer[fillBufferIndex];
        
        buffer->mAudioDataByteSize = bytesFilled;
        
        if (packetsFilled)
        {
            error = AudioQueueEnqueueBuffer(audioQueue, buffer, packetsFilled, packetDescs);
        }
        else
        {
            error = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, NULL);
        }
        
        audioPacketsReadCount++;
        framesQueued += framesFilled;
        
        if (error)
        {
            pthread_mutex_unlock(&queueBuffersMutex);
            pthread_mutex_unlock(&playerMutex);
            
            [self stopAudioQueueWithReason:@"enqueueBuffer critical error"];
            
            return;
        }
        
        if ([self readyToEndRebufferingState])
        {
            if (self.internalState != AudioPlayerInternalStatePaused)
            {
                self->rebufferingStartFrames = 0;
                
                pthread_mutex_unlock(&queueBuffersMutex);
                
                queueBuffersMutexUnlocked = YES;
                
                if (![self startAudioQueue] || audioQueue == nil)
                {
                    pthread_mutex_unlock(&playerMutex);
                    
                    return;
                }
            }
        }
        
        if ([self readyToEndWaitingForDataState])
        {
            if (self.internalState != AudioPlayerInternalStatePaused)
            {
                pthread_mutex_unlock(&queueBuffersMutex);
                
                queueBuffersMutexUnlocked = YES;
                
                if (![self startAudioQueue] || audioQueue == nil)
                {
                    pthread_mutex_unlock(&playerMutex);
                    
                    return;
                }
            }
        }
        
        if (++fillBufferIndex >= audioQueueBufferCount)
        {
            fillBufferIndex = 0;
        }
        
        bytesFilled = 0;
        framesFilled = 0;
        packetsFilled = 0;

        if (!queueBuffersMutexUnlocked)
        {
            pthread_mutex_unlock(&queueBuffersMutex);
        }
    }
    pthread_mutex_unlock(&playerMutex);
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    waiting = YES;
    
    while (bufferUsed[fillBufferIndex] && !(disposeWasRequested || seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed))
    {
        if (numberOfBuffersUsed == 0)
        {
            memset(&bufferUsed[0], 0, sizeof(bool) * audioQueueBufferCount);
            
            break;
        }
        
        pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex);
    }
    
    waiting = NO;
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) didEncounterError:(AudioPlayerErrorCode)errorCodeIn
{
    errorCode = errorCodeIn;
    self.internalState = AudioPlayerInternalStateError;
    
    [self playbackThreadQueueMainThreadSyncBlock:^
    {
        [self.delegate audioPlayer:self didEncounterError:errorCode];
    }];
}

-(void) createAudioQueue
{
	OSStatus error;
	
    LOGINFO(@"Called");
    
	[self startSystemBackgroundTask];
	
    pthread_mutex_lock(&playerMutex);
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (audioQueue)
    {
        LOGINFO(@"AudioQueueStop/1");

        pthread_mutex_unlock(&queueBuffersMutex);
        AudioQueueStop(audioQueue, YES);
        AudioQueueDispose(audioQueue, YES);
        
        memset(&currentAudioStreamBasicDescription, 0, sizeof(currentAudioStreamBasicDescription));
        
        audioQueue = nil;
    }
    
    if (currentlyPlayingEntry == nil)
    {
        LOGINFO(@"currentlyPlayingEntry == nil");
        
        pthread_mutex_unlock(&queueBuffersMutex);
	    pthread_mutex_unlock(&playerMutex);
        
        return;
    }
    
    currentAudioStreamBasicDescription = currentlyPlayingEntry->audioStreamBasicDescription;
    
    error = AudioQueueNewOutput(&currentAudioStreamBasicDescription, AudioQueueOutputCallbackProc, (__bridge void*)self, NULL, NULL, 0, &audioQueue);
    
    if (error)
    {
        [self playbackThreadQueueMainThreadSyncBlock:^
        {
            [self.delegate audioPlayer:self didEncounterError:AudioPlayerErrorQueueCreationFailed];
        }];

        pthread_mutex_unlock(&queueBuffersMutex);
        pthread_mutex_unlock(&playerMutex);
        
        return;
    }
    
    AudioQueuePause(audioQueue);
    
    error = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, AudioQueueIsRunningCallbackProc, (__bridge void*)self);
    
    if (error)
    {
        [self playbackThreadQueueMainThreadSyncBlock:^
        {
            [self.delegate audioPlayer:self didEncounterError:AudioPlayerErrorQueueCreationFailed];
        }];
        
        pthread_mutex_unlock(&queueBuffersMutex);
        pthread_mutex_unlock(&playerMutex);
        
        return;
    }
    
#if TARGET_OS_IPHONE
    UInt32 val = kAudioQueueHardwareCodecPolicy_PreferHardware;
    
    AudioQueueSetProperty(audioQueue, kAudioQueueProperty_HardwareCodecPolicy, &val, sizeof(UInt32));
    
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
#endif
    
    memset(audioQueueBufferLookup, 0, sizeof(AudioQueueBufferRefLookupEntry) * audioQueueBufferRefLookupCount);
    
    // Allocate AudioQueue buffers
    
    for (int i = 0; i < audioQueueBufferCount; i++)
    {
        error = AudioQueueAllocateBuffer(audioQueue, currentlyPlayingEntry->packetBufferSize, &audioQueueBuffer[i]);
        
        unsigned int hash = (unsigned int)audioQueueBuffer[i] % audioQueueBufferRefLookupCount;
        
        while (true)
        {
            if (audioQueueBufferLookup[hash].ref == 0)
            {
                audioQueueBufferLookup[hash].ref = audioQueueBuffer[i];
                audioQueueBufferLookup[hash].bufferIndex = i;
                
                break;
            }
            else
            {
                hash++;
                hash %= audioQueueBufferRefLookupCount;
            }
        }
        
        bufferUsed[i] = false;
        
        if (error)
        {
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
                [self.delegate audioPlayer:self didEncounterError:AudioPlayerErrorQueueCreationFailed];
            }];
            
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
    }
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    framesQueued = 0;
    timelineAdjust = 0;
    rebufferingStartFrames = 0;
    
    // Get file cookie/magic bytes information
    
	UInt32 cookieSize;
	Boolean writable;
    
	error = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
    
	if (!error)
	{
    	void* cookieData = calloc(1, cookieSize);
        
        error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        
        if (error)
        {
            free(cookieData);
            
            pthread_mutex_unlock(&queueBuffersMutex);
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        error = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
        
        if (error)
        {
            free(cookieData);
            
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
                [self.delegate audioPlayer:self didEncounterError:AudioPlayerErrorQueueCreationFailed];
            }];
            
            pthread_mutex_unlock(&queueBuffersMutex);
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        free(cookieData);
    }
    
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
    
    // Reset metering enabled in case the user set it before the queue was created
    
    [self setMeteringEnabled:meteringEnabled];
    
    pthread_mutex_unlock(&queueBuffersMutex);
    pthread_mutex_unlock(&playerMutex);
}

-(double) duration
{
    if (newFileToPlay)
    {
        return 0;
    }
    
    OSSpinLockLock(&currentEntryReferencesLock);
    
    STKQueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
		OSSpinLockUnlock(&currentEntryReferencesLock);
        
        return 0;
    }
    
    double retval = [entry duration];
    
	OSSpinLockUnlock(&currentEntryReferencesLock);
    
    double progress = [self progress];
    
    if (retval < progress && retval > 0)
    {
        return progress;
    }
    
    return retval;
}

-(double) progress
{
    if (seekToTimeWasRequested)
    {
        return requestedSeekTime;
    }
    
    if (newFileToPlay)
    {
        return 0;
    }
    
    OSSpinLockLock(&currentEntryReferencesLock);
    
    Float64 currentTime = [self currentTimeInFrames];
    STKQueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
    	OSSpinLockUnlock(&currentEntryReferencesLock);
        
        return 0;
    }
    
    Float64 time = currentTime;
    
    double retval = [entry calculateProgressWithTotalFramesPlayed:time];
    
    OSSpinLockUnlock(&currentEntryReferencesLock);
    
    return retval;
}

-(BOOL) invokeOnPlaybackThread:(void(^)())block
{
	NSRunLoop* runLoop = playbackThreadRunLoop;
	
    if (runLoop)
    {
        CFRunLoopPerformBlock([runLoop getCFRunLoop], NSRunLoopCommonModes, block);
        CFRunLoopWakeUp([runLoop getCFRunLoop]);
        
        return YES;
    }
    
    return NO;
}

-(void)invokeOnPlaybackThreadAtIntervalHelper:(NSTimer*)timer
{
    void(^block)() = (void(^)())timer.userInfo;
    
    block();
}

-(BOOL) invokeOnPlaybackThreadAtInterval:(NSTimeInterval)interval withBlock:(void(^)())block
{
	NSRunLoop* runLoop = playbackThreadRunLoop;
	
    if (runLoop)
    {
        NSTimer* timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(invokeOnPlaybackThreadAtIntervalHelper:) userInfo:[block copy] repeats:NO];
        
        [runLoop addTimer:timer forMode:NSRunLoopCommonModes];
        
        return YES;
    }
    
    return NO;
}

-(void) wakeupPlaybackThread
{
	[self invokeOnPlaybackThread:^
    {
        [self processRunloop];
    }];
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (waiting)
    {
        pthread_cond_signal(&queueBufferReadyCondition);
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) seekToTime:(double)value
{
    if (currentlyPlayingEntry == nil)
    {
        return;
    }
    
    OSSpinLockLock(&seekLock);
    
    BOOL seekAlreadyRequested = seekToTimeWasRequested;
    
    seekToTimeWasRequested = YES;
    requestedSeekTime = value;
    
    if (!seekAlreadyRequested)
    {
        OSAtomicIncrement32(&seekVersion);
        
        OSSpinLockUnlock(&seekLock);
        
        [self wakeupPlaybackThread];
        
        return;
    }
    
    OSSpinLockUnlock(&seekLock);
}

-(void) createPlaybackThread
{
    playbackThread = [[NSThread alloc] initWithTarget:self selector:@selector(startInternal) object:nil];
    
    [playbackThread start];
    
    [threadStartedLock lockWhenCondition:1];
    [threadStartedLock unlockWithCondition:0];
    
    NSAssert(playbackThreadRunLoop != nil, @"playbackThreadRunLoop != nil");
}

-(void) setCurrentlyReadingEntry:(STKQueueEntry*)entry andStartPlaying:(BOOL)startPlaying
{
    LOGINFO(([entry description]));
    
    NSAssert([NSThread currentThread] == playbackThread, @"[NSThread currentThread] == playbackThread");
    
    if (startPlaying)
    {
        if (audioQueue)
        {
            [self resetAudioQueueWithReason:@"from setCurrentlyReadingEntry" andPause:YES];
        }
    }
    
    if (audioFileStream)
    {
        AudioFileStreamClose(audioFileStream);
        
        audioFileStream = 0;
    }
    
    if (currentlyReadingEntry)
    {
        currentlyReadingEntry.dataSource.delegate = nil;
        [currentlyReadingEntry.dataSource unregisterForEvents];
        [currentlyReadingEntry.dataSource close];
    }
    
    OSSpinLockLock(&currentEntryReferencesLock);
    currentlyReadingEntry = entry;
    OSSpinLockUnlock(&currentEntryReferencesLock);
    
    currentlyReadingEntry.dataSource.delegate = self;
    
    [currentlyReadingEntry.dataSource registerForEvents:[NSRunLoop currentRunLoop]];
    [currentlyReadingEntry.dataSource seekToOffset:0];
    
    if (startPlaying)
    {
        [self clearQueueIncludingUpcoming:NO];
        
        [self processFinishPlayingIfAnyAndPlayingNext:currentlyPlayingEntry withNext:entry];
    }
    else
    {
        pthread_mutex_lock(&queueBuffersMutex);
        [bufferingQueue enqueue:entry];
        pthread_mutex_unlock(&queueBuffersMutex);
    }
}

-(void) audioQueueFinishedPlaying:(STKQueueEntry*)entry
{
    pthread_mutex_lock(&playerMutex);
    {
        pthread_mutex_lock(&queueBuffersMutex);
        
        STKQueueEntry* next = [bufferingQueue peek];
        
        pthread_mutex_unlock(&queueBuffersMutex);
        
        if (next == nil)
        {
            [self processRunloop];
        }
        
        pthread_mutex_lock(&queueBuffersMutex);
        next = [bufferingQueue dequeue];
        pthread_mutex_unlock(&queueBuffersMutex);
        
        [self processFinishPlayingIfAnyAndPlayingNext:entry withNext:next];

        [self processRunloop];
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) processFinishPlayingIfAnyAndPlayingNext:(STKQueueEntry*)entry withNext:(STKQueueEntry*)next
{
    if (entry != currentlyPlayingEntry)
    {
        return;
    }
    
    LOGINFO(([NSString stringWithFormat:@"Finished: %@, Next: %@, buffering.count=%d,upcoming.count=%d", entry ? [entry description] : @"nothing", [next description], (int)bufferingQueue.count, (int)upcomingQueue.count]));
    
    NSObject* queueItemId = entry.queueItemId;
    double progress = [entry calculateProgressWithTotalFramesPlayed:[self currentTimeInFrames]];
    double duration = [entry duration];
    
    BOOL isPlayingSameItemProbablySeek = currentlyPlayingEntry == next;
    
    if (next)
    {
        if (!isPlayingSameItemProbablySeek)
        {
            next.seekTime = 0;
            
            OSSpinLockLock(&seekLock);
            seekToTimeWasRequested = NO;
            OSSpinLockUnlock(&seekLock);
        }
        
        OSSpinLockLock(&currentEntryReferencesLock);
        currentlyPlayingEntry = next;
        currentlyPlayingEntry.bytesBuffered = 0;
        currentlyPlayingEntry.firstFrameIndex = [self currentTimeInFrames];
        NSObject* playingQueueItemId = playingQueueItemId = currentlyPlayingEntry.queueItemId;
        OSSpinLockUnlock(&currentEntryReferencesLock);
        
        if (!isPlayingSameItemProbablySeek && entry)
        {
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
                [self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
            }];
        }
        
        if (!isPlayingSameItemProbablySeek)
        {
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
                [self.delegate audioPlayer:self didStartPlayingQueueItemId:playingQueueItemId];
            }];
        }
    }
    else
    {
        OSSpinLockLock(&currentEntryReferencesLock);
		currentlyPlayingEntry = nil;
        OSSpinLockUnlock(&currentEntryReferencesLock);
        
        if (currentlyReadingEntry == nil)
        {
			if (upcomingQueue.count == 0)
			{
				stopReason = AudioPlayerStopReasonEof;
				self.internalState = AudioPlayerInternalStateStopping;
			}
        }
        
        if (!isPlayingSameItemProbablySeek && entry)
        {
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
				[self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
            }];
        }
    }
}

-(void) dispatchSyncOnMainThread:(void(^)())block
{
    __block BOOL finished = NO;
    
    if (disposeWasRequested)
    {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^
    {
        block();
        
        pthread_mutex_lock(&mainThreadSyncCallMutex);
        finished = YES;
        pthread_cond_signal(&mainThreadSyncCallReadyCondition);
        pthread_mutex_unlock(&mainThreadSyncCallMutex);
    });
    
    while (true)
    {
        if (disposeWasRequested)
        {
            break;
        }
        
        if (finished)
        {
            break;
        }
        
        pthread_mutex_lock(&mainThreadSyncCallMutex);
        pthread_cond_wait(&mainThreadSyncCallReadyCondition, &mainThreadSyncCallMutex);
        pthread_mutex_unlock(&mainThreadSyncCallMutex);
    }
}

-(void) playbackThreadQueueMainThreadSyncBlock:(void(^)())block
{
    block = [block copy];
    
    [self invokeOnPlaybackThread:^
    {
        if (disposeWasRequested)
        {
            return;
        }
        
        [self dispatchSyncOnMainThread:block];
    }];
}

-(BOOL) processRunloop
{
    BOOL dontPlayNew = NO;
    
    pthread_mutex_lock(&playerMutex);
    {
        dontPlayNew = self.internalState == AudioPlayerInternalStateFlushingAndStoppingButStillPlaying;
        
        if (self.internalState == AudioPlayerInternalStatePaused)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return YES;
        }
        else if (newFileToPlay)
        {
            STKQueueEntry* entry = [upcomingQueue dequeue];
            
            self.internalState = AudioPlayerInternalStateWaitingForData;
            
            [self setCurrentlyReadingEntry:entry andStartPlaying:YES];
            
            newFileToPlay = NO;
        }
        else if (seekToTimeWasRequested && currentlyPlayingEntry && currentlyPlayingEntry != currentlyReadingEntry)
        {
            currentlyPlayingEntry.lastFrameIndex = -1;
            currentlyPlayingEntry.lastByteIndex = -1;
            
            self.internalState = AudioPlayerInternalStateWaitingForDataAfterSeek;
            
            [self setCurrentlyReadingEntry:currentlyPlayingEntry andStartPlaying:YES];
            
            currentlyReadingEntry->parsedHeader = NO;
        }
        else if (self.internalState == AudioPlayerInternalStateStopped
                 && (stopReason == AudioPlayerStopReasonUserAction || stopReason == AudioPlayerStopReasonUserActionFlushStop))
        {
            [self stopAudioQueueWithReason:@"from processRunLoop/1"];
            
            currentlyReadingEntry.dataSource.delegate = nil;
            [currentlyReadingEntry.dataSource unregisterForEvents];
            [currentlyReadingEntry.dataSource close];
            
            if (currentlyPlayingEntry)
            {
                [self processFinishPlayingIfAnyAndPlayingNext:currentlyPlayingEntry withNext:nil];
            }
            
            pthread_mutex_lock(&queueBuffersMutex);
            
            if ([bufferingQueue peek] == currentlyPlayingEntry)
            {
                [bufferingQueue dequeue];
            }
            
            OSSpinLockLock(&currentEntryReferencesLock);
			currentlyPlayingEntry = nil;
            currentlyReadingEntry = nil;
            seekToTimeWasRequested = NO;
            OSSpinLockUnlock(&currentEntryReferencesLock);
            
            pthread_mutex_unlock(&queueBuffersMutex);
            
            if (stopReason == AudioPlayerStopReasonUserActionFlushStop)
            {
                [self resetAudioQueueWithReason:@"from processRunLoop"];
            }
        }
        else if (currentlyReadingEntry == nil && !dontPlayNew)
        {
            pthread_mutex_lock(&queueBuffersMutex);
            
            BOOL processNextToRead = YES;
            STKQueueEntry* next = [bufferingQueue peek];
            
            if (next != nil && next->audioStreamBasicDescription.mSampleRate == 0)
            {
                pthread_mutex_unlock(&queueBuffersMutex);
                
                processNextToRead = NO;
            }
            
            if (processNextToRead)
            {
                next = [upcomingQueue peek];
                
                if ([next isKnownToBeIncompatible:&currentAudioStreamBasicDescription] && currentlyPlayingEntry != nil)
                {
                    pthread_mutex_unlock(&queueBuffersMutex);
                    
                    processNextToRead = NO;
                }
            }
            
            if (processNextToRead)
            {
                if (upcomingQueue.count > 0)
                {
                    STKQueueEntry* entry = [upcomingQueue dequeue];
                    
                    BOOL startPlaying = currentlyPlayingEntry == nil;
                    BOOL wasCurrentlyPlayingNothing = currentlyPlayingEntry == nil;
                    
                    pthread_mutex_unlock(&queueBuffersMutex);
                    
                    [self setCurrentlyReadingEntry:entry andStartPlaying:startPlaying];
                    
                    if (wasCurrentlyPlayingNothing)
                    {
                        currentAudioStreamBasicDescription.mSampleRate = 0;
                        
                        [self setInternalState:AudioPlayerInternalStateWaitingForData];
                    }
                }
                else if (currentlyPlayingEntry == nil)
                {
                    pthread_mutex_unlock(&queueBuffersMutex);
                    
                    if (self.internalState != AudioPlayerInternalStateStopped)
                    {
                        [self stopAudioQueueWithReason:@"from processRunLoop/2"];
                        stopReason = AudioPlayerStopReasonEof;
                    }
                }
                else
                {
                    pthread_mutex_unlock(&queueBuffersMutex);
                }
            }
            else
            {
                pthread_mutex_unlock(&queueBuffersMutex);
            }
        }
        
        if (disposeWasRequested)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return NO;
        }
        
        if (currentlyPlayingEntry && currentlyPlayingEntry->parsedHeader)
        {
            int32_t originalSeekVersion;
            BOOL originalSeekToTimeRequested;

            OSSpinLockLock(&seekLock);
            originalSeekVersion = seekVersion;
            originalSeekToTimeRequested = seekToTimeWasRequested;
            OSSpinLockUnlock(&seekLock);
            
            if (originalSeekToTimeRequested && currentlyReadingEntry == currentlyPlayingEntry)
            {
                [self processSeekToTime];
                
                OSSpinLockLock(&seekLock);
                if (originalSeekVersion == seekVersion)
                {
                    seekToTimeWasRequested = NO;
                }
                OSSpinLockUnlock(&seekLock);
            }
        }
        else if (currentlyPlayingEntry == nil && seekToTimeWasRequested)
        {
            seekToTimeWasRequested = NO;
        }
    }
    pthread_mutex_unlock(&playerMutex);

    
    return YES;
}

-(void) startInternal
{
	@autoreleasepool
	{
		playbackThreadRunLoop = [NSRunLoop currentRunLoop];
		NSThread.currentThread.threadPriority = 1;
        
        [threadStartedLock lockWhenCondition:0];
        [threadStartedLock unlockWithCondition:1];
		
		bytesFilled = 0;
		packetsFilled = 0;
		
		[playbackThreadRunLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
        
		while (true)
		{
            @autoreleasepool
            {
                if (![self processRunloop])
                {
                    break;
                }
            }
            
            NSDate* date = [[NSDate alloc] initWithTimeIntervalSinceNow:10];
            [playbackThreadRunLoop runMode:NSDefaultRunLoopMode beforeDate:date];
		}
		
		disposeWasRequested = NO;
		seekToTimeWasRequested = NO;
		
		currentlyReadingEntry.dataSource.delegate = nil;
		currentlyPlayingEntry.dataSource.delegate = nil;
		
        pthread_mutex_lock(&playerMutex);
        OSSpinLockLock(&currentEntryReferencesLock);
		currentlyPlayingEntry = nil;
		currentlyReadingEntry = nil;
        OSSpinLockUnlock(&currentEntryReferencesLock);
        pthread_mutex_unlock(&playerMutex);
		
		self.internalState = AudioPlayerInternalStateDisposed;
		
		[threadFinishedCondLock lock];
		[threadFinishedCondLock unlockWithCondition:1];
	}
}

-(void) processSeekToTime
{
	OSStatus error;
    OSSpinLockLock(&currentEntryReferencesLock);
    STKQueueEntry* currentEntry = currentlyReadingEntry;
    OSSpinLockUnlock(&currentEntryReferencesLock);
    
    NSAssert(currentEntry == currentlyPlayingEntry, @"playing and reading must be the same");
    
    if (!currentEntry || ([currentEntry calculatedBitRate] == 0.0 || currentlyPlayingEntry.dataSource.length <= 0))
    {
        return;
    }
    
    long long seekByteOffset = currentEntry->audioDataOffset + (requestedSeekTime / self.duration) * (currentlyReadingEntry.audioDataLengthInBytes);
    
    if (seekByteOffset > currentEntry.dataSource.length - (2 * currentEntry->packetBufferSize))
    {
        seekByteOffset = currentEntry.dataSource.length - 2 * currentEntry->packetBufferSize;
    }
    
    currentEntry.seekTime = requestedSeekTime;
    currentEntry->lastProgress = requestedSeekTime;
    
    double calculatedBitRate = [currentEntry calculatedBitRate];
    
    if (currentEntry->packetDuration > 0 && calculatedBitRate > 0)
    {
        UInt32 ioFlags = 0;
        SInt64 packetAlignedByteOffset;
        SInt64 seekPacket = floor(requestedSeekTime / currentEntry->packetDuration);
        
        error = AudioFileStreamSeek(audioFileStream, seekPacket, &packetAlignedByteOffset, &ioFlags);
        
        if (!error && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated))
        {
            double delta = ((seekByteOffset - (SInt64)currentEntry->audioDataOffset) - packetAlignedByteOffset) / calculatedBitRate * 8;
            
            currentEntry.seekTime -= delta;
            
            seekByteOffset = packetAlignedByteOffset + currentEntry->audioDataOffset;
        }
    }
    
    currentEntry.lastFrameIndex = -1;
    [currentEntry updateAudioDataSource];
    [currentEntry.dataSource seekToOffset:seekByteOffset];
    
    if (self.internalState == AudioPlayerInternalStateFlushingAndStoppingButStillPlaying)
    {
        self.internalState = AudioPlayerInternalStatePlaying;
    }
    
    if (seekByteOffset > 0)
    {
        discontinuous = YES;
    }
    
    if (audioQueue)
    {
        [self resetAudioQueueWithReason:@"from seekToTime"];
    }
    
    currentEntry.bytesBuffered = 0;
    currentEntry.firstFrameIndex = [self currentTimeInFrames];
    
    [self clearQueue];
}

-(BOOL) startAudioQueue
{
	OSStatus error;
    
    LOGINFO(@"Called");
    
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
    
    error = AudioQueueStart(audioQueue, NULL);
    
    if (error)
    {
#if TARGET_OS_IPHONE
		if (backgroundTaskId == UIBackgroundTaskInvalid)
		{
			[self startSystemBackgroundTask];
		}
#endif
		
        [self stopAudioQueueWithReason:@"from startAudioQueue"];
        [self createAudioQueue];
        
        if (audioQueue != nil)
        {
            AudioQueueStart(audioQueue, NULL);
        }
    }
	
	[self stopSystemBackgroundTask];
    
    self.internalState = AudioPlayerInternalStatePlaying;
    
    return YES;
}

-(void) stopAudioQueueWithReason:(NSString*)reason
{
	OSStatus error;
	
    LOGINFO(([NSString stringWithFormat:@"With Reason: %@", reason]));
    
	if (!audioQueue)
    {
        LOGINFO(@"Already No AudioQueue");
        
        self.internalState = AudioPlayerInternalStateStopped;
        
        return;
    }
    else
    {
        LOGINFO(@"Stopping AudioQueue");
        
        audioQueueFlushing = YES;
        
        error = AudioQueueStop(audioQueue, YES);
        error = error | AudioQueueDispose(audioQueue, YES);
        
        memset(&currentAudioStreamBasicDescription, 0, sizeof(currentAudioStreamBasicDescription));
        
        audioQueue = nil;
    }
    
    if (error)
    {
        [self didEncounterError:AudioPlayerErrorQueueStopFailed];
    }
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (numberOfBuffersUsed != 0)
    {
        numberOfBuffersUsed = 0;
        
        memset(&bufferUsed[0], 0, sizeof(bool) * audioQueueBufferCount);
    }
    
    pthread_cond_signal(&queueBufferReadyCondition);
    pthread_mutex_unlock(&queueBuffersMutex);
    
    bytesFilled = 0;
    fillBufferIndex = 0;
    packetsFilled = 0;
    framesQueued = 0;
    timelineAdjust = 0;
    rebufferingStartFrames = 0;
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    audioQueueFlushing = NO;
    
    self.internalState = AudioPlayerInternalStateStopped;
}


-(void) resetAudioQueueWithReason:(NSString*)reason
{
    [self resetAudioQueueWithReason:reason andPause:NO];
}

-(void) resetAudioQueueWithReason:(NSString*)reason andPause:(BOOL)pause
{
	OSStatus error;
    
    LOGINFO(([NSString stringWithFormat:@"With Reason: %@", reason]));
    
    pthread_mutex_lock(&playerMutex);
    {
        audioQueueFlushing = YES;
        
        if (audioQueue)
        {
            AudioTimeStamp timeStamp;
            Boolean outTimelineDiscontinuity;
            
            error = AudioQueueReset(audioQueue);
            
            if (pause)
            {
                AudioQueuePause(audioQueue);
            }
            
            AudioQueueGetCurrentTime(audioQueue, NULL, &timeStamp, &outTimelineDiscontinuity);
            
            timelineAdjust = timeStamp.mSampleTime;
            
            BOOL startAudioQueue = NO;
            
            if (rebufferingStartFrames > 0)
            {
                startAudioQueue = YES;
                rebufferingStartFrames = 0;
            }
            
            if (!pause && startAudioQueue)
            {
                [self startAudioQueue];
            }
            
            if (error)
            {
                [self playbackThreadQueueMainThreadSyncBlock:^
                {
                    [self didEncounterError:AudioPlayerErrorQueueStopFailed];;
                }];
            }
        }
    }
    pthread_mutex_unlock(&playerMutex);
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (numberOfBuffersUsed != 0)
    {
        numberOfBuffersUsed = 0;
        
        memset(&bufferUsed[0], 0, sizeof(bool) * audioQueueBufferCount);
    }
    
    pthread_cond_signal(&queueBufferReadyCondition);
    
    
    bytesFilled = 0;
    fillBufferIndex = 0;
    packetsFilled = 0;
    framesQueued = 0;
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry->lastProgress = 0;
    }
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    audioQueueFlushing = NO;
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) dataSourceDataAvailable:(STKDataSource*)dataSourceIn
{
	OSStatus error;
    
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    if (!currentlyReadingEntry.dataSource.hasBytesAvailable)
    {
        return;
    }
    
    int read = [currentlyReadingEntry.dataSource readIntoBuffer:readBuffer withSize:readBufferSize];
    
    if (read == 0)
    {
        return;
    }
    
    if (audioFileStream == 0)
    {
        error = AudioFileStreamOpen((__bridge void*)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, dataSourceIn.audioFileTypeHint, &audioFileStream);
        
        if (error)
        {
            return;
        }
    }
    
    if (read < 0)
    {
        // iOS will shutdown network connections if the app is backgrounded (i.e. device is locked when player is paused)
        // We try to reopen -- should probably add a back-off protocol in the future
        
        long long position = currentlyReadingEntry.dataSource.position;
        
        [currentlyReadingEntry.dataSource seekToOffset:position];
        
        return;
    }
    
    int flags = 0;
    
    if (discontinuous)
    {
        flags = kAudioFileStreamParseFlag_Discontinuity;
    }
    
    if (audioFileStream)
    {
        error = AudioFileStreamParseBytes(audioFileStream, read, readBuffer, flags);
        
        if (error)
        {
            if (dataSourceIn == currentlyPlayingEntry.dataSource)
            {
                [self didEncounterError:AudioPlayerErrorStreamParseBytesFailed];
            }
            
            return;
        }
        
        OSSpinLockLock(&currentEntryReferencesLock);
        
        if (currentlyReadingEntry == nil)
        {
            [dataSourceIn unregisterForEvents];
            [dataSourceIn close];
        }
        
        OSSpinLockUnlock(&currentEntryReferencesLock);
    }
}

-(void) dataSourceErrorOccured:(STKDataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    [self didEncounterError:AudioPlayerErrorDataNotFound];
}

-(void) dataSourceEof:(STKDataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    LOGINFO(([NSString stringWithFormat:@"eof: %lld %lld", audioPacketsReadCount, audioPacketsPlayedCount]));
    
    if (bytesFilled > 0)
    {
        LOGINFO(([NSString stringWithFormat:@"eof: enqueueBuffer"]));
        
        [self enqueueBuffer];
    }
    
    LOGINFO(([NSString stringWithFormat:@" %@ (ptr:%d)", dataSourceIn, (int)dataSourceIn]));
    
    NSObject* queueItemId = currentlyReadingEntry.queueItemId;
    
    if (disposeWasRequested)
    {
        return;
    }
    
    [self dispatchSyncOnMainThread:^
    {
        [self.delegate audioPlayer:self didFinishBufferingSourceWithQueueItemId:queueItemId];
    }];
    
    if (disposeWasRequested)
    {
        return;
    }
    
    pthread_mutex_lock(&playerMutex);
    
    if (audioQueue)
    {
        currentlyReadingEntry.lastFrameIndex = self->framesQueued;
        currentlyReadingEntry.lastByteIndex = audioPacketsReadCount;
        
        LOGINFO(([NSString stringWithFormat:@"eof2: %lld %lld %d", audioPacketsReadCount, audioPacketsPlayedCount, numberOfBuffersUsed]));
        
        if (numberOfBuffersUsed == 0 && currentlyReadingEntry == currentlyPlayingEntry)
        {
            seekToTimeWasRequested = NO;
            
            if (audioQueue)
            {
                if ([self audioQueueIsRunning])
                {
                    self.internalState = AudioPlayerInternalStateFlushingAndStoppingButStillPlaying;

                    LOGINFO(@"Stopping AudioQueue asynchronously");
                    
                    if (AudioQueueStop(audioQueue, NO) != 0)
                    {
                        LOGINFO(@"Stopping AudioQueue asynchronously failed");
                        
                        [self processFinishedPlayingViaAudioQueueStop];
                    }
                }
                else
                {
                    LOGINFO(@"AudioQueue already stopped");
                    
                    [self processFinishedPlayingViaAudioQueueStop];
                }
            }
        }
    }
    else
    {
        stopReason = AudioPlayerStopReasonEof;
        self.internalState = AudioPlayerInternalStateStopped;
    }
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (self.internalState == AudioPlayerInternalStateRebuffering && ([self readyToEndRebufferingState] || [self readyToEndWaitingForDataState]))
    {
        self->rebufferingStartFrames = 0;
        [self startAudioQueue];
    }
    
    OSSpinLockLock(&currentEntryReferencesLock);
    currentlyReadingEntry = nil;
    OSSpinLockUnlock(&currentEntryReferencesLock);
    
    pthread_mutex_unlock(&queueBuffersMutex);
   
    pthread_mutex_unlock(&playerMutex);
}

-(void) pause
{
    pthread_mutex_lock(&playerMutex);
    {
		OSStatus error;
        
        if (self.internalState != AudioPlayerInternalStatePaused && (self.internalState & AudioPlayerInternalStateRunning))
        {
            self.stateBeforePaused = self.internalState;
            self.internalState = AudioPlayerInternalStatePaused;
            
            if (audioQueue)
            {
                error = AudioQueuePause(audioQueue);
                
                if (error)
                {
                    [self didEncounterError:AudioPlayerErrorQueuePauseFailed];
                    
                    pthread_mutex_unlock(&playerMutex);
                    
                    return;
                }
            }
            
            [self wakeupPlaybackThread];
        }
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) resume
{
    pthread_mutex_lock(&playerMutex);
    {
		OSStatus error;
		
        if (self.internalState == AudioPlayerInternalStatePaused)
        {
            self.internalState = self.stateBeforePaused;
            
            if (seekToTimeWasRequested)
            {
                [self resetAudioQueueWithReason:@"from resume"];
            }

            if (audioQueue != nil)
            {
                if(!((self.internalState == AudioPlayerInternalStateWaitingForData) || (self.internalState == AudioPlayerInternalStateRebuffering) || (self.internalState == AudioPlayerInternalStateWaitingForDataAfterSeek))
                    || [self readyToEndRebufferingState]
                    || [self readyToEndWaitingForDataState])
                {
                    error = AudioQueueStart(audioQueue, 0);
                    
                    if (error)
                    {
                        [self didEncounterError:AudioPlayerErrorQueueStartFailed];
                        
                        pthread_mutex_unlock(&playerMutex);
                        
                        return;
                    }
                }
            }
            
            [self wakeupPlaybackThread];
        }
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) stop
{
    pthread_mutex_lock(&playerMutex);
    {
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        stopReason = AudioPlayerStopReasonUserAction;
        self.internalState = AudioPlayerInternalStateStopped;
		
		[self wakeupPlaybackThread];
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) flushStop
{
    pthread_mutex_lock(&playerMutex);
    {
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        stopReason = AudioPlayerStopReasonUserActionFlushStop;
        self.internalState = AudioPlayerInternalStateStopped;
		
		[self wakeupPlaybackThread];
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) stopThread
{
    BOOL wait = NO;
    
    NSRunLoop* runLoop = playbackThreadRunLoop;
    
    if (runLoop != nil)
    {
        wait = YES;
        
        [self invokeOnPlaybackThread:^
        {
            pthread_mutex_lock(&queueBuffersMutex);
            disposeWasRequested = YES;
            pthread_mutex_unlock(&queueBuffersMutex);
        }];
        
        pthread_mutex_lock(&queueBuffersMutex);
        pthread_cond_signal(&queueBufferReadyCondition);
        pthread_mutex_unlock(&queueBuffersMutex);

        pthread_mutex_lock(&mainThreadSyncCallMutex);
        pthread_cond_signal(&mainThreadSyncCallReadyCondition);
        pthread_mutex_unlock(&mainThreadSyncCallMutex);

        
        CFRunLoopStop([runLoop getCFRunLoop]);
    }
    
    if (wait)
    {
        [threadFinishedCondLock lockWhenCondition:1];
        [threadFinishedCondLock unlockWithCondition:0];
    }
}

-(void) mute
{
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 0);
}

-(void) unmute
{
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
}

-(void) dispose
{
    [self stop];
    [self stopThread];
}

-(NSObject*) currentlyPlayingQueueItemId
{
    OSSpinLockLock(&currentEntryReferencesLock);
    
    STKQueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
        OSSpinLockUnlock(&currentEntryReferencesLock);
        
        return nil;
    }
    
    NSObject* retval = entry.queueItemId;
    
    OSSpinLockUnlock(&currentEntryReferencesLock);
    
    return retval;
}

#pragma mark Metering

-(void) setMeteringEnabled:(BOOL)value
{
    if (!audioQueue)
    {
        meteringEnabled = value;
        
        return;
    }
    
    UInt32 on = value ? 1 : 0;
    OSStatus error = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_EnableLevelMetering, &on, sizeof(on));
    
    if (error)
    {
        meteringEnabled = NO;
    }
    else
    {
        meteringEnabled = YES;
    }
}

-(BOOL) meteringEnabled
{
    return meteringEnabled;
}

-(void) updateMeters
{
    if (!meteringEnabled)
    {
        NSAssert(NO, @"Metering is not enabled. Make sure to set meteringEnabled = YES.");
    }
    
    UInt32 channels = currentAudioStreamBasicDescription.mChannelsPerFrame;
    
    if (numberOfChannels != channels)
    {
        numberOfChannels = channels;
        
        if (levelMeterState) free(levelMeterState);
        {
            levelMeterState = malloc(sizeof(AudioQueueLevelMeterState) * numberOfChannels);
        }
    }
    
    UInt32 sizeofMeters = (UInt32)(sizeof(AudioQueueLevelMeterState) * numberOfChannels);
    
    AudioQueueGetProperty(audioQueue, kAudioQueueProperty_CurrentLevelMeterDB, levelMeterState, &sizeofMeters);
}

-(float) peakPowerInDecibelsForChannel:(NSUInteger)channelNumber
{
    if (!meteringEnabled || !levelMeterState || (channelNumber > numberOfChannels))
    {
        return 0;
    }
    
    return levelMeterState[channelNumber].mPeakPower;
}

-(float) averagePowerInDecibelsForChannel:(NSUInteger)channelNumber
{
    if (!meteringEnabled || !levelMeterState || (channelNumber > numberOfChannels))
    {
        return 0;
    }
    
    return levelMeterState[channelNumber].mAveragePower;
}

@end
