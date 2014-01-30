/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/StreamingKit
 
 Copyright (c) 2014 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
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
#import "STKQueueEntry.h"
#import "NSMutableArray+STKAudioPlayer.h"
#import "libkern/OSAtomic.h"

#define STK_DEFAULT_PCM_BUFFER_SIZE_IN_SECONDS (5)
#define STK_DEFAULT_SECONDS_REQUIRED_TO_START_PLAYING (0.75)

#define STK_BUFFERS_NEEDED_TO_START (32)
#define STK_BUFFERS_NEEDED_WHEN_UNDERUNNING (128)
#define STK_DEFAULT_READ_BUFFER_SIZE (64 * 1024)
#define STK_DEFAULT_PACKET_BUFFER_SIZE (2048)
#define STK_FRAMES_MISSED_BEFORE_CONSIDERED_UNDERRUN (1024)

#define LOGINFO(x) [self logInfo:[NSString stringWithFormat:@"%s %@", sel_getName(_cmd), x]];

@interface STKAudioPlayer()
{
    UInt8* readBuffer;
    int readBufferSize;
    
    UInt32 framesRequiredToStartPlaying;
    UInt32 framesRequiredToPlayAfterRebuffering;
    
    AudioComponentInstance audioUnit;
	
    STKQueueEntry* currentlyPlayingEntry;
    STKQueueEntry* currentlyReadingEntry;
    
    NSMutableArray* upcomingQueue;
    NSMutableArray* bufferingQueue;
    
    volatile BOOL buffering;
    OSSpinLock pcmBufferSpinLock;
    int32_t rebufferingStartFrames;
    volatile UInt32 pcmBufferTotalFrameCount;
    volatile UInt32 pcmBufferFrameStartIndex;
    volatile UInt32 pcmBufferUsedFrameCount;
    volatile UInt32 pcmBufferFrameSizeInBytes;
    
    AudioBuffer* pcmAudioBuffer;
    AudioBufferList pcmAudioBufferList;
    
    AudioConverterRef audioConverterRef;

    AudioStreamBasicDescription currentAudioStreamBasicDescription;
    AudioStreamBasicDescription canonicalAudioStreamBasicDescription;
    
    NSThread* playbackThread;
    NSRunLoop* playbackThreadRunLoop;
    NSConditionLock* threadStartedLock;
    NSConditionLock* threadFinishedCondLock;
    Float64 averageHardwareDelay;
    
    AudioFileStreamID audioFileStream;
    
    BOOL discontinuous;
    
#if TARGET_OS_IPHONE
	UIBackgroundTaskIdentifier backgroundTaskId;
#endif
    
    STKAudioPlayerErrorCode errorCode;
    STKAudioPlayerStopReason stopReason;
    
    int32_t seekVersion;
    OSSpinLock seekLock;
    OSSpinLock currentEntryReferencesLock;

    pthread_mutex_t playerMutex;
    pthread_cond_t playerThreadReadyCondition;
    pthread_mutex_t mainThreadSyncCallMutex;
    pthread_cond_t mainThreadSyncCallReadyCondition;
    
    volatile BOOL waiting;
    volatile BOOL disposeWasRequested;
    volatile BOOL seekToTimeWasRequested;
    volatile BOOL newFileToPlay;
    volatile double requestedSeekTime;
}

@property (readwrite) STKAudioPlayerInternalState internalState;
@property (readwrite) STKAudioPlayerInternalState stateBeforePaused;

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)audioFileStreamIn fileStreamPropertyID:(AudioFileStreamPropertyID)propertyID ioFlags:(UInt32*)ioFlags;
-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptions;
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

@implementation STKAudioPlayer
@synthesize delegate, internalState, state;

-(STKAudioPlayerInternalState) internalState
{
    return internalState;
}

-(void) setInternalState:(STKAudioPlayerInternalState)value
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
    
    STKAudioPlayerState newState;
    
    switch (internalState)
    {
        case STKAudioPlayerInternalStateInitialised:
            newState = STKAudioPlayerStateReady;
            break;
        case STKAudioPlayerInternalStateRunning:
        case STKAudioPlayerInternalStateStartingThread:
        case STKAudioPlayerInternalStatePlaying:
        case STKAudioPlayerInternalStateWaitingForDataAfterSeek:
        case STKAudioPlayerInternalStateFlushingAndStoppingButStillPlaying:
            newState = STKAudioPlayerStatePlaying;
            break;
        case STKAudioPlayerInternalStateRebuffering:
        case STKAudioPlayerInternalStateWaitingForData:
            newState = STKAudioPlayerStateBuffering;
            break;
        case STKAudioPlayerInternalStateStopping:
        case STKAudioPlayerInternalStateStopped:
            newState = STKAudioPlayerStateStopped;
            break;
        case STKAudioPlayerInternalStatePaused:
            newState = STKAudioPlayerStatePaused;
            break;
        case STKAudioPlayerInternalStateDisposed:
            newState = STKAudioPlayerStateDisposed;
            break;
        case STKAudioPlayerInternalStateError:
            newState = STKAudioPlayerStateError;
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

-(STKAudioPlayerStopReason) stopReason
{
    return stopReason;
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
    return [self initWithReadBufferSize:STK_DEFAULT_READ_BUFFER_SIZE];
}

-(id) initWithReadBufferSize:(int)readBufferSizeIn
{
    if (self = [super init])
    {
        canonicalAudioStreamBasicDescription.mSampleRate = 44100.00;
        canonicalAudioStreamBasicDescription.mFormatID = kAudioFormatLinearPCM;
        canonicalAudioStreamBasicDescription.mFormatFlags = kAudioFormatFlagsCanonical;
        canonicalAudioStreamBasicDescription.mFramesPerPacket = 1;
        canonicalAudioStreamBasicDescription.mChannelsPerFrame = 2;
        canonicalAudioStreamBasicDescription.mBytesPerFrame = sizeof(AudioSampleType) * canonicalAudioStreamBasicDescription.mChannelsPerFrame;
        canonicalAudioStreamBasicDescription.mBitsPerChannel = 8 * sizeof(AudioSampleType);
        canonicalAudioStreamBasicDescription.mBytesPerPacket = canonicalAudioStreamBasicDescription.mBytesPerFrame * canonicalAudioStreamBasicDescription.mFramesPerPacket;
        
        framesRequiredToStartPlaying = canonicalAudioStreamBasicDescription.mSampleRate * STK_DEFAULT_SECONDS_REQUIRED_TO_START_PLAYING;
        
        pcmAudioBuffer = &pcmAudioBufferList.mBuffers[0];
        pcmAudioBufferList.mNumberBuffers = 1;
        pcmAudioBufferList.mBuffers[0].mDataByteSize = (canonicalAudioStreamBasicDescription.mSampleRate * STK_DEFAULT_PCM_BUFFER_SIZE_IN_SECONDS) * canonicalAudioStreamBasicDescription.mBytesPerFrame;
        pcmAudioBufferList.mBuffers[0].mData = (void*)calloc(pcmAudioBuffer->mDataByteSize, 1);
        pcmAudioBufferList.mBuffers[0].mNumberChannels = 2;
        
        pcmBufferFrameSizeInBytes = canonicalAudioStreamBasicDescription.mBytesPerFrame;
        pcmBufferTotalFrameCount = pcmAudioBuffer->mDataByteSize / pcmBufferFrameSizeInBytes;
        
        readBufferSize = readBufferSizeIn;
        readBuffer = calloc(sizeof(UInt8), readBufferSize);
        
        pthread_mutexattr_t attr;
        
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        
        pthread_mutex_init(&playerMutex, &attr);
        pthread_mutex_init(&mainThreadSyncCallMutex, NULL);
        pthread_cond_init(&playerThreadReadyCondition, NULL);
        pthread_cond_init(&mainThreadSyncCallReadyCondition, NULL);

        threadStartedLock = [[NSConditionLock alloc] initWithCondition:0];
        threadFinishedCondLock = [[NSConditionLock alloc] initWithCondition:0];
        
        self.internalState = STKAudioPlayerInternalStateInitialised;
        
        upcomingQueue = [[NSMutableArray alloc] init];
        bufferingQueue = [[NSMutableArray alloc] init];
        
        [self createAudioUnit];
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
    pthread_mutex_destroy(&mainThreadSyncCallMutex);
    pthread_cond_destroy(&playerThreadReadyCondition);
    pthread_cond_destroy(&mainThreadSyncCallReadyCondition);

    
    if (audioFileStream)
    {
        AudioFileStreamClose(audioFileStream);
    }
    
    if (audioUnit)
    {
        AudioComponentInstanceDispose(audioUnit);
    }
    
    free(readBuffer);
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
            
            [upcomingQueue enqueue:[[STKQueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
            
            self.internalState = STKAudioPlayerInternalStateRunning;
            
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
                currentAudioStreamBasicDescription = currentlyReadingEntry->audioStreamBasicDescription;
                
                [self createAudioConverter];
                
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

-(void) setRebufferingStateIfApplicable
{
    pthread_mutex_lock(&playerMutex);
    
    if (self->rebufferingStartFrames > 0)
    {
        if ([self currentTimeInFrames] > STK_FRAMES_MISSED_BEFORE_CONSIDERED_UNDERRUN
            && self.internalState != STKAudioPlayerInternalStateRebuffering
            && self.internalState != STKAudioPlayerInternalStatePaused)
        {
            self.internalState = STKAudioPlayerInternalStateRebuffering;
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
    if (audioUnit == nil)
    {
        return 0;
    }
    
    return 0;
}

-(void) didEncounterError:(STKAudioPlayerErrorCode)errorCodeIn
{
    errorCode = errorCodeIn;
    self.internalState = STKAudioPlayerInternalStateError;
    
    [self playbackThreadQueueMainThreadSyncBlock:^
    {
        [self.delegate audioPlayer:self didEncounterError:errorCode];
    }];
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
    
    pthread_mutex_lock(&playerMutex);
    
    if (waiting)
    {
        pthread_cond_signal(&playerThreadReadyCondition);
    }
    
    pthread_mutex_unlock(&playerMutex);
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
        // TODO: RESET AUDIOUNIT
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
        
        [self startAudioUnit];
    }
    else
    {
        [bufferingQueue enqueue:entry];
    }
}

-(void) audioQueueFinishedPlaying:(STKQueueEntry*)entry
{
    STKQueueEntry* next = [bufferingQueue peek];
    
    if (next == nil)
    {
        [self processRunloop];
    }
    
    next = [bufferingQueue dequeue];
    
    [self processFinishPlayingIfAnyAndPlayingNext:entry withNext:next];
    [self processRunloop];
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
				self.internalState = STKAudioPlayerInternalStateStopping;
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
    pthread_mutex_lock(&playerMutex);
    {
        if (self.internalState == STKAudioPlayerInternalStatePaused)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return YES;
        }
        else if (newFileToPlay)
        {
            STKQueueEntry* entry = [upcomingQueue dequeue];
            
            self.internalState = STKAudioPlayerInternalStateWaitingForData;
            
            [self setCurrentlyReadingEntry:entry andStartPlaying:YES];
            
            newFileToPlay = NO;
        }
        else if (seekToTimeWasRequested && currentlyPlayingEntry && currentlyPlayingEntry != currentlyReadingEntry)
        {
            currentlyPlayingEntry.lastFrameIndex = -1;
            currentlyPlayingEntry.lastByteIndex = -1;
            
            self.internalState = STKAudioPlayerInternalStateWaitingForDataAfterSeek;
            
            [self setCurrentlyReadingEntry:currentlyPlayingEntry andStartPlaying:YES];
            
            currentlyReadingEntry->parsedHeader = NO;
        }
        else if (self.internalState == STKAudioPlayerInternalStateStopped
                 && (stopReason == AudioPlayerStopReasonUserAction || stopReason == AudioPlayerStopReasonUserActionFlushStop))
        {
            [self stopAudioUnitWithReason:@"from processRunLoop/1"];
            
            currentlyReadingEntry.dataSource.delegate = nil;
            [currentlyReadingEntry.dataSource unregisterForEvents];
            [currentlyReadingEntry.dataSource close];
            
            if (currentlyPlayingEntry)
            {
                [self processFinishPlayingIfAnyAndPlayingNext:currentlyPlayingEntry withNext:nil];
            }
            
            if ([bufferingQueue peek] == currentlyPlayingEntry)
            {
                [bufferingQueue dequeue];
            }
            
            OSSpinLockLock(&currentEntryReferencesLock);
			currentlyPlayingEntry = nil;
            currentlyReadingEntry = nil;
            seekToTimeWasRequested = NO;
            OSSpinLockUnlock(&currentEntryReferencesLock);
            
            if (stopReason == AudioPlayerStopReasonUserActionFlushStop)
            {
                [self resetAudioQueueWithReason:@"from processRunLoop"];
            }
        }
        else if (currentlyReadingEntry == nil)
        {
            BOOL processNextToRead = YES;
            STKQueueEntry* next = [bufferingQueue peek];
            
            if (next != nil && next->audioStreamBasicDescription.mSampleRate == 0)
            {
                processNextToRead = NO;
            }
            
            if (processNextToRead)
            {
                next = [upcomingQueue peek];
                
                if ([next isKnownToBeIncompatible:&currentAudioStreamBasicDescription] && currentlyPlayingEntry != nil)
                {
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
                    
                    [self setCurrentlyReadingEntry:entry andStartPlaying:startPlaying];
                    
                    if (wasCurrentlyPlayingNothing)
                    {
                        currentAudioStreamBasicDescription.mSampleRate = 0;
                        
                        [self setInternalState:STKAudioPlayerInternalStateWaitingForData];
                    }
                }
                else if (currentlyPlayingEntry == nil)
                {
                    if (self.internalState != STKAudioPlayerInternalStateStopped)
                    {
                        [self stopAudioUnitWithReason:@"from processRunLoop/2"];
                        stopReason = AudioPlayerStopReasonEof;
                    }
                }
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
		
		self.internalState = STKAudioPlayerInternalStateDisposed;
		
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
    
    if (self.internalState == STKAudioPlayerInternalStateFlushingAndStoppingButStillPlaying)
    {
        self.internalState = STKAudioPlayerInternalStatePlaying;
    }
    
    if (seekByteOffset > 0)
    {
        discontinuous = YES;
    }
    
    if (audioUnit)
    {
        // TODO: RESET AUDIO UNIT
    }
    
    currentEntry.bytesBuffered = 0;
    currentEntry.firstFrameIndex = [self currentTimeInFrames];
    
    [self clearQueue];
}


-(void) resetAudioQueueWithReason:(NSString*)reason
{
    [self resetAudioQueueWithReason:reason andPause:NO];
}

-(void) resetAudioQueueWithReason:(NSString*)reason andPause:(BOOL)pause
{
//	OSStatus error;
    
    LOGINFO(([NSString stringWithFormat:@"With Reason: %@", reason]));
    
    /*
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
                    [self didEncounterError:STKAudioPlayerErrorQueueStopFailed];;
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
    */
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry->lastProgress = 0;
    }
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
                [self didEncounterError:STKAudioPlayerErrorStreamParseBytesFailed];
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
    
    [self didEncounterError:STKAudioPlayerErrorDataNotFound];
}

-(void) dataSourceEof:(STKDataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    NSObject* queueItemId = currentlyReadingEntry.queueItemId;
    
    if (disposeWasRequested)
    {
        return;
    }
    
    [self dispatchSyncOnMainThread:^
    {
        [self.delegate audioPlayer:self didFinishBufferingSourceWithQueueItemId:queueItemId];
    }];
    
    currentlyReadingEntry = nil;
}

-(void) pause
{
    pthread_mutex_lock(&playerMutex);
    {
		OSStatus error;
        
        if (self.internalState != STKAudioPlayerInternalStatePaused && (self.internalState & STKAudioPlayerInternalStateRunning))
        {
            self.stateBeforePaused = self.internalState;
            self.internalState = STKAudioPlayerInternalStatePaused;
            
            if (audioUnit)
            {
                error = AudioOutputUnitStop(audioUnit);
                
                if (error)
                {
                    [self didEncounterError:STKAudioPlayerErrorQueuePauseFailed];
                    
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
		
        if (self.internalState == STKAudioPlayerInternalStatePaused)
        {
            self.internalState = self.stateBeforePaused;
            
            if (seekToTimeWasRequested)
            {
                [self resetAudioQueueWithReason:@"from resume"];
            }

            if (audioUnit != nil)
            {
                if(!((self.internalState == STKAudioPlayerInternalStateWaitingForData) || (self.internalState == STKAudioPlayerInternalStateRebuffering) || (self.internalState == STKAudioPlayerInternalStateWaitingForDataAfterSeek)))
                {
                    error = AudioOutputUnitStop(audioUnit);
                    
                    if (error)
                    {
                        [self didEncounterError:STKAudioPlayerErrorQueueStartFailed];
                        
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
        if (self.internalState == STKAudioPlayerInternalStateStopped)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        stopReason = AudioPlayerStopReasonUserAction;
        self.internalState = STKAudioPlayerInternalStateStopped;
		
		[self wakeupPlaybackThread];
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) flushStop
{
    pthread_mutex_lock(&playerMutex);
    {
        if (self.internalState == STKAudioPlayerInternalStateStopped)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        stopReason = AudioPlayerStopReasonUserActionFlushStop;
        self.internalState = STKAudioPlayerInternalStateStopped;
		
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
            disposeWasRequested = YES;
        }];
        
        pthread_mutex_lock(&playerMutex);
        pthread_cond_signal(&playerThreadReadyCondition);
        pthread_mutex_unlock(&playerMutex);

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
    // TODO
}

-(void) unmute
{
    // TODO
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

#define kOutputBus 0
#define kInputBus 1

BOOL GetHardwareCodecClassDesc(UInt32 formatId, AudioClassDescription* classDesc)
{
    UInt32 size;
    
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size) != 0)
    {
        return NO;
    }

    UInt32 decoderCount = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[decoderCount];
    
    if (AudioFormatGetProperty(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size, encoderDescriptions) != 0)
    {
        return NO;
    }
    
    for (UInt32 i = 0; i < decoderCount; ++i)
    {
        if (encoderDescriptions[i].mManufacturer == kAppleHardwareAudioCodecManufacturer)
        {
            *classDesc = encoderDescriptions[i];
            
            return YES;
        }
    }
    
    return NO;
}

-(void) createAudioConverter
{
    OSStatus status;
    AudioClassDescription classDesc;
    
    if (GetHardwareCodecClassDesc(currentAudioStreamBasicDescription.mFormatID, &classDesc))
    {
        status = AudioConverterNewSpecific(&currentAudioStreamBasicDescription, &canonicalAudioStreamBasicDescription, 1,  &classDesc, &audioConverterRef);
    }
    
    if (!audioConverterRef)
    {
        status = AudioConverterNew(&currentAudioStreamBasicDescription, &canonicalAudioStreamBasicDescription, &audioConverterRef);
    }
    
	Boolean writable;
	UInt32 cookieSize;
    
	status = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
    
	if (!status)
	{
    	void* cookieData = alloca(cookieSize);
        
        status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        
        if (status)
        {
            return;
        }
        
        status = AudioConverterSetProperty(audioConverterRef, kAudioConverterDecompressionMagicCookie, cookieSize, &cookieData);
        
        if (status)
        {
            return;
        }
    }
}

-(void) createAudioUnit
{
    pthread_mutex_lock(&playerMutex);
    
    OSStatus status;
    AudioComponentDescription desc;
    
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    
    status = AudioComponentInstanceNew(component, &audioUnit);
    
    UInt32 flag = 1;

	status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &flag, sizeof(flag));
    status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &canonicalAudioStreamBasicDescription, sizeof(canonicalAudioStreamBasicDescription));
    
    AURenderCallbackStruct callbackStruct;
    
    callbackStruct.inputProc = playbackCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)self;

    status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &callbackStruct, sizeof(callbackStruct));
 
    status = AudioUnitInitialize(audioUnit);
    
    pthread_mutex_unlock(&playerMutex);
}

-(BOOL) startAudioUnit
{
    OSStatus status;
    
    status = AudioOutputUnitStart(audioUnit);
    
    return YES;
}

-(void) stopAudioUnitWithReason:(NSString*)reason
{
	OSStatus status;
	
    LOGINFO(([NSString stringWithFormat:@"With Reason: %@", reason]));
    
	if (!audioUnit)
    {
        LOGINFO(@"No AudioUnit");
        
        self.internalState = STKAudioPlayerInternalStateStopped;
        
        return;
    }
    else
    {
        LOGINFO(@"Stopping AudioUnit");
    }
    
    status = AudioOutputUnitStop(audioUnit);
    
    rebufferingStartFrames = 0;
    
    self.internalState = STKAudioPlayerInternalStateStopped;
}

typedef struct
{
    BOOL done;
    UInt32 numberOfPackets;
    AudioBuffer audioBuffer;
    AudioStreamPacketDescription* packetDescriptions;
}
AudioConvertInfo;

OSStatus AudioConverterCallback(AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription **outDataPacketDescription, void* inUserData)
{
    AudioConvertInfo* convertInfo = (AudioConvertInfo*)inUserData;
    
    if (convertInfo->done)
    {
        ioNumberDataPackets = 0;
        
    	return 100;
    }
    
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0] = convertInfo->audioBuffer;

    if (outDataPacketDescription)
    {
        *outDataPacketDescription = convertInfo->packetDescriptions;
    }
    
    *ioNumberDataPackets = convertInfo->numberOfPackets;
    convertInfo->done = YES;
    
    return 0;
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
    
    if (discontinuous)
    {
        discontinuous = NO;
    }

    OSStatus status;
    
    AudioConvertInfo convertInfo;

    convertInfo.done = NO;
    convertInfo.numberOfPackets = numberPackets;
    convertInfo.packetDescriptions = packetDescriptionsIn;
    convertInfo.audioBuffer.mData = (void *)inputData;
    convertInfo.audioBuffer.mDataByteSize = numberBytes;
    convertInfo.audioBuffer.mNumberChannels = currentAudioStreamBasicDescription.mChannelsPerFrame;

    while (true)
    {
        OSSpinLockLock(&pcmBufferSpinLock);
        UInt32 used = pcmBufferUsedFrameCount;
        UInt32 start = pcmBufferFrameStartIndex;
        UInt32 end = (pcmBufferFrameStartIndex + pcmBufferUsedFrameCount) % pcmBufferTotalFrameCount;
        UInt32 framesLeftInsideBuffer = pcmBufferTotalFrameCount - used;
        OSSpinLockUnlock(&pcmBufferSpinLock);
        
        if (framesLeftInsideBuffer == 0)
        {
            pthread_mutex_lock(&playerMutex);
            
            while (true)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                used = pcmBufferUsedFrameCount;
                start = pcmBufferFrameStartIndex;
                end = (pcmBufferFrameStartIndex + pcmBufferUsedFrameCount) % pcmBufferTotalFrameCount;
                framesLeftInsideBuffer = pcmBufferTotalFrameCount - used;
                OSSpinLockUnlock(&pcmBufferSpinLock);

                if (framesLeftInsideBuffer > 0)
                {
                    break;
                }
                
                if  (disposeWasRequested || seekToTimeWasRequested || self.internalState == STKAudioPlayerInternalStateStopped || self.internalState == STKAudioPlayerInternalStateStopping || self.internalState == STKAudioPlayerInternalStateDisposed)
                {
                    pthread_mutex_unlock(&playerMutex);
                    
                    return;
                }
                
                waiting = YES;

                pthread_cond_wait(&playerThreadReadyCondition, &playerMutex);
                
                waiting = NO;
            }
            
            pthread_mutex_unlock(&playerMutex);
        }
        
        AudioBuffer* localPcmAudioBuffer;
        AudioBufferList localPcmBufferList;
        
        localPcmBufferList.mNumberBuffers = 1;
        localPcmAudioBuffer = &localPcmBufferList.mBuffers[0];
        
        if (start == end)
        {
            NSLog(@"");
        }
        
        if (end >= start)
        {
            UInt32 framesAdded = 0;
            UInt32 framesToDecode = pcmBufferTotalFrameCount - end;
            
            localPcmAudioBuffer->mData = pcmAudioBuffer->mData + (end * pcmBufferFrameSizeInBytes);
            localPcmAudioBuffer->mDataByteSize = framesToDecode * pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(audioConverterRef, AudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded = framesToDecode;

            if (status == 100)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                
                return;
            }
            else if (status != 0)
            {
                NSLog(@"");
            }
            
            framesToDecode = start;
            
            if (framesToDecode == 0)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                continue;
            }
            
            localPcmAudioBuffer->mData = pcmAudioBuffer->mData;
            localPcmAudioBuffer->mDataByteSize = framesToDecode * pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(audioConverterRef, AudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded += framesToDecode;
            
            if (status == 100)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                continue;
            }
            else if (status != 0)
            {
                NSLog(@"");
            }
        }
        else
        {
            UInt32 framesAdded = 0;
            UInt32 framesToDecode = start - end;
            
            localPcmAudioBuffer->mData = pcmAudioBuffer->mData + (end * pcmBufferFrameSizeInBytes);
            localPcmAudioBuffer->mDataByteSize = framesToDecode * pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(audioConverterRef, AudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded = framesToDecode;
            
            if (status == 100)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                continue;
            }
            else if (status != 0)
            {
                NSLog(@"");
            }
        }
    }
}

static OSStatus playbackCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData)
{
    STKAudioPlayer* audioPlayer = (__bridge STKAudioPlayer*)inRefCon;

    OSSpinLockLock(&audioPlayer->pcmBufferSpinLock);
    AudioBuffer* audioBuffer = audioPlayer->pcmAudioBuffer;
    UInt32 frameSizeInBytes = audioPlayer->pcmBufferFrameSizeInBytes;
    UInt32 used = audioPlayer->pcmBufferUsedFrameCount;
    UInt32 start = audioPlayer->pcmBufferFrameStartIndex;
    UInt32 end = (audioPlayer->pcmBufferFrameStartIndex + audioPlayer->pcmBufferUsedFrameCount) % audioPlayer->pcmBufferTotalFrameCount;
    BOOL signal = audioPlayer->waiting && used < audioPlayer->pcmBufferTotalFrameCount / 2;
    BOOL waitForBuffer = NO;
    
    if (audioPlayer.internalState == STKAudioPlayerInternalStateWaitingForData)
    {
        if (audioPlayer->currentlyReadingEntry == audioPlayer->currentlyPlayingEntry && audioPlayer->currentlyPlayingEntry->framesQueued < audioPlayer->framesRequiredToStartPlaying)
        {
            waitForBuffer = YES;
        }
        else
        {
            audioPlayer.internalState = STKAudioPlayerInternalStatePlaying;
        }
    }
    
    OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
    
    UInt32 totalFramesCopied = 0;
    
    if (used > 0 && !waitForBuffer)
    {
        if (!(audioPlayer->buffering && used < audioPlayer->pcmBufferTotalFrameCount))
        {
            if (audioPlayer->buffering)
            {
                NSLog(@"Buffering resuming");
                
                audioPlayer->buffering = NO;
            }
            
            if (end > start)
            {
                UInt32 framesToCopy = MIN(inNumberFrames, used);
                
                ioData->mBuffers[0].mNumberChannels = 2;
                ioData->mBuffers[0].mDataByteSize = frameSizeInBytes * framesToCopy;
                memcpy(ioData->mBuffers[0].mData, audioBuffer->mData + (start * frameSizeInBytes), ioData->mBuffers[0].mDataByteSize);
                
                totalFramesCopied = framesToCopy;
                
                OSSpinLockLock(&audioPlayer->pcmBufferSpinLock);
                audioPlayer->pcmBufferFrameStartIndex = (audioPlayer->pcmBufferFrameStartIndex + totalFramesCopied) % audioPlayer->pcmBufferTotalFrameCount;
                audioPlayer->pcmBufferUsedFrameCount -= totalFramesCopied;
                OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
            }
            else
            {
                UInt32 framesToCopy = MIN(inNumberFrames, audioPlayer->pcmBufferTotalFrameCount - start);
                
                ioData->mBuffers[0].mNumberChannels = 2;
                ioData->mBuffers[0].mDataByteSize = frameSizeInBytes * framesToCopy;
                memcpy(ioData->mBuffers[0].mData, audioBuffer->mData + (start * frameSizeInBytes), ioData->mBuffers[0].mDataByteSize);
                
                UInt32 moreFramesToCopy = 0;
                UInt32 delta = inNumberFrames - framesToCopy;
                
                if (delta > 0)
                {
                    moreFramesToCopy = MIN(delta, end);
                    
                    ioData->mBuffers[0].mNumberChannels = 2;
                    ioData->mBuffers[0].mDataByteSize += frameSizeInBytes * moreFramesToCopy;
                    memcpy(ioData->mBuffers[0].mData + (framesToCopy * frameSizeInBytes), audioBuffer->mData, frameSizeInBytes * moreFramesToCopy);
                }
                
                totalFramesCopied = framesToCopy + moreFramesToCopy;
                
                OSSpinLockLock(&audioPlayer->pcmBufferSpinLock);
                audioPlayer->pcmBufferFrameStartIndex = (audioPlayer->pcmBufferFrameStartIndex + totalFramesCopied) % audioPlayer->pcmBufferTotalFrameCount;
                audioPlayer->pcmBufferUsedFrameCount -= totalFramesCopied;
                OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
            }
        }
    }
    
    OSSpinLockLock(&audioPlayer->pcmBufferSpinLock);
    audioPlayer->currentlyPlayingEntry->framesPlayed += totalFramesCopied;
    OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
    
    if (totalFramesCopied < inNumberFrames)
    {
        UInt32 delta = inNumberFrames - totalFramesCopied;
        
        memset(ioData->mBuffers[0].mData + (totalFramesCopied * frameSizeInBytes), 0, delta * frameSizeInBytes);

        if (!audioPlayer->buffering)
        {
            NSLog(@"Buffering");
        }
        
        audioPlayer->buffering = YES;
    }
    
    if (signal)
    {
        pthread_mutex_lock(&audioPlayer->playerMutex);
        pthread_cond_signal(&audioPlayer->playerThreadReadyCondition);
        pthread_mutex_unlock(&audioPlayer->playerMutex);
    }
    
    return 0;
}

@end

