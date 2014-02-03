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
#import "STKAutoRecoveringHTTPDataSource.h"
#import "STKLocalFileDataSource.h"
#import "STKQueueEntry.h"
#import "NSMutableArray+STKAudioPlayer.h"
#import "libkern/OSAtomic.h"
#import <float.h>

#pragma mark Defines

#define kOutputBus 0
#define kInputBus 1

#define STK_DBMIN (-60)
#define STK_DBOFFSET (-74.0)
#define STK_LOWPASSFILTERTIMESLICE (0.0005)

#define STK_DEFAULT_PCM_BUFFER_SIZE_IN_SECONDS (10)
#define STK_DEFAULT_SECONDS_REQUIRED_TO_START_PLAYING (0.1)
#define STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION (2048)
#define STK_DEFAULT_READ_BUFFER_SIZE (64 * 1024)
#define STK_DEFAULT_PACKET_BUFFER_SIZE (2048)

#define LOGINFO(x) [self logInfo:[NSString stringWithFormat:@"%s %@", sel_getName(_cmd), x]];

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
    STKAudioPlayerInternalStateStopped = (1 << 9),
    STKAudioPlayerInternalStatePendingNext = (1 << 10),
    STKAudioPlayerInternalStateDisposed = (1 << 30),
    STKAudioPlayerInternalStateError = (1 << 31)
}
STKAudioPlayerInternalState;

#pragma mark STKFrameFilterEntry

@interface STKFrameFilterEntry()
{
@public
	NSString* name;
	STKFrameFilter filter;
}
@end

@implementation STKFrameFilterEntry
-(id) initWithFilter:(STKFrameFilter)filterIn andName:(NSString*)nameIn
{
	if (self = [super init])
	{
		self->filter = [filterIn copy];
		self->name = nameIn;
	}
	
	return self;
}

-(NSString*) name
{
	return self->name;
}

-(STKFrameFilter) filter
{
	return self->filter;
}
@end

#pragma mark STKAudioPlayer

@interface STKAudioPlayer()
{
	BOOL muted;
	
    UInt8* readBuffer;
    int readBufferSize;
    STKAudioPlayerInternalState internalState;
	
	Float32 peakPowerDb[2];
	Float32 averagePowerDb[2];
	
	BOOL meteringEnabled;
    STKAudioPlayerOptions options;
    AudioComponentInstance audioUnit;
    
    UInt32 framesRequiredToStartPlaying;
    UInt32 framesRequiredToPlayAfterRebuffering;
    
    STKQueueEntry* volatile currentlyPlayingEntry;
    STKQueueEntry* volatile currentlyReadingEntry;
    
    NSMutableArray* upcomingQueue;
    NSMutableArray* bufferingQueue;
    
    OSSpinLock pcmBufferSpinLock;
    volatile UInt32 pcmBufferTotalFrameCount;
    volatile UInt32 pcmBufferFrameStartIndex;
    volatile UInt32 pcmBufferUsedFrameCount;
    volatile UInt32 pcmBufferFrameSizeInBytes;
    
    AudioBuffer* pcmAudioBuffer;
    AudioBufferList pcmAudioBufferList;
    AudioConverterRef audioConverterRef;

    AudioStreamBasicDescription canonicalAudioStreamBasicDescription;
    AudioStreamBasicDescription audioConverterAudioStreamBasicDescription;
    
    BOOL discontinuous;
	NSArray* frameFilters;
    NSThread* playbackThread;
    NSRunLoop* playbackThreadRunLoop;
    AudioFileStreamID audioFileStream;
    NSConditionLock* threadStartedLock;
    NSConditionLock* threadFinishedCondLock;
    
#if TARGET_OS_IPHONE
	UIBackgroundTaskIdentifier backgroundTaskId;
#endif
    
    int32_t seekVersion;
    OSSpinLock seekLock;
    OSSpinLock currentEntryReferencesLock;

    pthread_mutex_t playerMutex;
    pthread_cond_t playerThreadReadyCondition;
    pthread_mutex_t mainThreadSyncCallMutex;
    pthread_cond_t mainThreadSyncCallReadyCondition;
    
    volatile BOOL waiting;
    volatile double requestedSeekTime;
    volatile BOOL disposeWasRequested;
    volatile BOOL seekToTimeWasRequested;
    volatile STKAudioPlayerStopReason stopReason;
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

-(STKAudioPlayerOptions) options
{
    return options;
}

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
    
    STKAudioPlayerState newState;
    
    switch (internalState)
    {
        case STKAudioPlayerInternalStateInitialised:
            newState = STKAudioPlayerStateReady;
			stopReason = STKAudioPlayerStopReasonNone;
            break;
        case STKAudioPlayerInternalStateRunning:
        case STKAudioPlayerInternalStatePendingNext:
        case STKAudioPlayerInternalStateStartingThread:
        case STKAudioPlayerInternalStatePlaying:
        case STKAudioPlayerInternalStateWaitingForDataAfterSeek:
            newState = STKAudioPlayerStatePlaying;
			stopReason = STKAudioPlayerStopReasonNone;
            break;
        case STKAudioPlayerInternalStateRebuffering:
        case STKAudioPlayerInternalStateWaitingForData:
            newState = STKAudioPlayerStateBuffering;
			stopReason = STKAudioPlayerStopReasonNone;
            break;
        case STKAudioPlayerInternalStateStopped:
            newState = STKAudioPlayerStateStopped;
            break;
        case STKAudioPlayerInternalStatePaused:
            newState = STKAudioPlayerStatePaused;
			stopReason = STKAudioPlayerStopReasonNone;
            break;
        case STKAudioPlayerInternalStateDisposed:
            newState = STKAudioPlayerStateDisposed;
			stopReason = STKAudioPlayerStopReasonUserAction;
            break;
        case STKAudioPlayerInternalStateError:
            newState = STKAudioPlayerStateError;
			stopReason = STKAudioPlayerStopReasonError;
            break;
    }
    
	STKAudioPlayerState previousState = self.state;
	
    if (newState != previousState)
    {
        self.state = newState;
        
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.delegate audioPlayer:self stateChanged:self.state previousState:previousState];
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
        if ([self.delegate respondsToSelector:@selector(audioPlayer:logInfo:)])
        {
            [self.delegate audioPlayer:self logInfo:line];
        }
    }
    else
    {
        if ([self.delegate respondsToSelector:@selector(audioPlayer:logInfo:)])
        {
            [self.delegate audioPlayer:self logInfo:line];
        }
    }
}

-(id) init
{
    return [self initWithReadBufferSize:STK_DEFAULT_READ_BUFFER_SIZE andOptions:STKAudioPlayerOptionNone];
}

-(id) initWithOptions:(STKAudioPlayerOptions)optionsIn
{
	return [self initWithReadBufferSize:STK_DEFAULT_READ_BUFFER_SIZE andOptions:optionsIn];
}

-(id) initWithReadBufferSize:(int)readBufferSizeIn andOptions:(STKAudioPlayerOptions)optionsIn
{
    if (self = [super init])
    {
        options = optionsIn;

        const int bytesPerSample = sizeof(AudioSampleType);
		
        canonicalAudioStreamBasicDescription.mSampleRate = 44100.00;
        canonicalAudioStreamBasicDescription.mFormatID = kAudioFormatLinearPCM;
        canonicalAudioStreamBasicDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        canonicalAudioStreamBasicDescription.mFramesPerPacket = 1;
        canonicalAudioStreamBasicDescription.mChannelsPerFrame = 2;
        canonicalAudioStreamBasicDescription.mBytesPerFrame = bytesPerSample * canonicalAudioStreamBasicDescription.mChannelsPerFrame;
        canonicalAudioStreamBasicDescription.mBitsPerChannel = 8 * bytesPerSample;
        canonicalAudioStreamBasicDescription.mBytesPerPacket = canonicalAudioStreamBasicDescription.mBytesPerFrame * canonicalAudioStreamBasicDescription.mFramesPerPacket;
        
        framesRequiredToStartPlaying = canonicalAudioStreamBasicDescription.mSampleRate * STK_DEFAULT_SECONDS_REQUIRED_TO_START_PLAYING;
        framesRequiredToPlayAfterRebuffering = canonicalAudioStreamBasicDescription.mSampleRate * STK_DEFAULT_PCM_BUFFER_SIZE_IN_SECONDS;
        
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

		[self resetPcmBuffers];
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
        [currentlyReadingEntry.dataSource unregisterForEvents];
    }
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry.dataSource.delegate = nil;
        [currentlyReadingEntry.dataSource unregisterForEvents];
    }
    
    [self stopAudioUnitWithReason:STKAudioPlayerStopReasonEof];

    if (audioFileStream)
    {
        AudioFileStreamClose(audioFileStream);
    }
    
    if (audioConverterRef)
    {
        AudioConverterDispose(audioConverterRef);
    }
    
    if (audioUnit)
    {
        AudioComponentInstanceDispose(audioUnit);
    }
    
    pthread_mutex_destroy(&playerMutex);
    pthread_mutex_destroy(&mainThreadSyncCallMutex);
    pthread_cond_destroy(&playerThreadReadyCondition);
    pthread_cond_destroy(&mainThreadSyncCallReadyCondition);
    
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

+(STKDataSource*) dataSourceFromURL:(NSURL*)url
{
    STKDataSource* retval = nil;
    
    if ([url.scheme isEqualToString:@"file"])
    {
        retval = [[STKLocalFileDataSource alloc] initWithFilePath:url.path];
    }
    else if ([url.scheme caseInsensitiveCompare:@"http"] == NSOrderedSame || [url.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame)
    {
        retval = [[STKAutoRecoveringHTTPDataSource alloc] initWithHTTPDataSource:[[STKHTTPDataSource alloc] initWithURL:url]];
    }
    
    return retval;
}

-(void) clearQueue
{
    pthread_mutex_lock(&playerMutex);
    {
        if ([self.delegate respondsToSelector:@selector(audioPlayer:didCancelQueuedItems:)])
        {
            NSMutableArray* array = [[NSMutableArray alloc] initWithCapacity:bufferingQueue.count + upcomingQueue.count];
            
            for (STKQueueEntry* entry in upcomingQueue)
            {
                [array addObject:entry.queueItemId];
            }
			
			for (STKQueueEntry* entry in bufferingQueue)
            {
                [array addObject:entry.queueItemId];
            }
            
            [upcomingQueue removeAllObjects];
			[bufferingQueue removeAllObjects];
            
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
        else
        {
            [bufferingQueue removeAllObjects];
            [upcomingQueue removeAllObjects];
        }
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) play:(NSString*)urlString
{
	[self play:urlString withQueueItemID:urlString];
}

-(void) play:(NSString*)urlString withQueueItemID:(NSObject*)queueItemId
{
    NSURL* url = [NSURL URLWithString:urlString];
    
	[self setDataSource:[STKAudioPlayer dataSourceFromURL:url] withQueueItemId:queueItemId];
}

-(void) playURL:(NSURL*)url
{
	[self playURL:url withQueueItemID:url];
}

-(void) playURL:(NSURL*)url withQueueItemID:(NSObject*)queueItemId
{
	[self setDataSource:[STKAudioPlayer dataSourceFromURL:url] withQueueItemId:queueItemId];
}

-(void) playDataSource:(STKDataSource*)dataSource
{
	[self playDataSource:dataSource withQueueItemID:dataSource];
}

-(void) playDataSource:(STKDataSource*)dataSource withQueueItemID:(NSObject *)queueItemId
{
	[self setDataSource:dataSource withQueueItemId:queueItemId];
}

-(void) setDataSource:(STKDataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
    pthread_mutex_lock(&playerMutex);
    {
        LOGINFO(([NSString stringWithFormat:@"Playing: %@", [queueItemId description]]));
        
        [self startSystemBackgroundTask];
        
        [self clearQueue];

        [upcomingQueue enqueue:[[STKQueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
        
        self.internalState = STKAudioPlayerInternalStatePendingNext;
    }
    pthread_mutex_unlock(&playerMutex);
    
    [self wakeupPlaybackThread];
}

-(void) queue:(NSString*)urlString
{
	return [self queueURL:[NSURL URLWithString:urlString] withQueueItemId:urlString];
}

-(void) queue:(NSString*)urlString withQueueItemId:(NSObject*)queueItemId
{
	[self queueURL:[NSURL URLWithString:urlString] withQueueItemId:queueItemId];
}

-(void) queueURL:(NSURL*)url
{
	[self queueURL:url withQueueItemId:url];
}

-(void) queueURL:(NSURL*)url withQueueItemId:(NSObject*)queueItemId
{
	[self queueDataSource:[STKAudioPlayer dataSourceFromURL:url] withQueueItemId:queueItemId];
}

-(void) queueDataSource:(STKDataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
    pthread_mutex_lock(&playerMutex);
    {
		[self startSystemBackgroundTask];
        
        [upcomingQueue enqueue:[[STKQueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
    }
    pthread_mutex_unlock(&playerMutex);
    
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

            if (!currentlyReadingEntry->parsedHeader)
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
                
                [self createAudioConverter:&currentlyReadingEntry->audioStreamBasicDescription];
                
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
			if (!audioConverterAudioStreamBasicDescription.mFormatID == kAudioFormatLinearPCM)
			{
				discontinuous = YES;
			}
            
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

-(Float64) currentTimeInFrames
{
    if (audioUnit == nil)
    {
        return 0;
    }
    
    return 0;
}

-(void) unexpectedError:(STKAudioPlayerErrorCode)errorCodeIn
{
    self.internalState = STKAudioPlayerInternalStateError;
    
    [self playbackThreadQueueMainThreadSyncBlock:^
    {
        [self.delegate audioPlayer:self unexpectedError:errorCodeIn];
    }];
}

-(double) duration
{
    if (self.internalState == STKAudioPlayerInternalStatePendingNext)
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
    
    if (self.internalState == STKAudioPlayerInternalStatePendingNext)
    {
        return 0;
    }
    
    STKQueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
        return 0;
    }
    
    OSSpinLockLock(&entry->spinLock);
    double retval = entry->seekTime + (entry->framesPlayed / canonicalAudioStreamBasicDescription.mSampleRate);
    OSSpinLockUnlock(&entry->spinLock);
    
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

-(void) audioQueueFinishedPlaying:(STKQueueEntry*)entry
{
    STKQueueEntry* next = [bufferingQueue dequeue];
    
    [self processFinishPlayingIfAnyAndPlayingNext:entry withNext:next];
    [self processRunloop];
}

-(void) setCurrentlyReadingEntry:(STKQueueEntry*)entry andStartPlaying:(BOOL)startPlaying
{
    [self setCurrentlyReadingEntry:entry andStartPlaying:startPlaying clearQueue:YES];
}

-(void) setCurrentlyReadingEntry:(STKQueueEntry*)entry andStartPlaying:(BOOL)startPlaying clearQueue:(BOOL)clearQueue
{
    LOGINFO(([entry description]));

    if (startPlaying)
    {
        memset(&pcmAudioBuffer->mData[0], 0, pcmBufferTotalFrameCount * pcmBufferFrameSizeInBytes);
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
        if (clearQueue)
        {
            [self clearQueue];
        }
        
        [self processFinishPlayingIfAnyAndPlayingNext:currentlyPlayingEntry withNext:entry];
        [self startAudioUnit];
    }
    else
    {
        [bufferingQueue enqueue:entry];
    }
}

-(void) processFinishPlayingIfAnyAndPlayingNext:(STKQueueEntry*)entry withNext:(STKQueueEntry*)next
{
    if (entry != currentlyPlayingEntry)
    {
        return;
    }
    
    LOGINFO(([NSString stringWithFormat:@"Finished: %@, Next: %@, buffering.count=%d,upcoming.count=%d", entry ? [entry description] : @"nothing", [next description], (int)bufferingQueue.count, (int)upcomingQueue.count]));
    
    NSObject* queueItemId = entry.queueItemId;
    double progress = [entry progressInFrames] / canonicalAudioStreamBasicDescription.mSampleRate;
    double duration = [entry duration];
    
    BOOL isPlayingSameItemProbablySeek = currentlyPlayingEntry == next;
    
    if (next)
    {
        if (!isPlayingSameItemProbablySeek)
        {
            OSSpinLockLock(&next->spinLock);
            next->seekTime = 0;
            OSSpinLockUnlock(&next->spinLock);
            
            OSSpinLockLock(&seekLock);
            seekToTimeWasRequested = NO;
            OSSpinLockUnlock(&seekLock);
        }
        
        OSSpinLockLock(&currentEntryReferencesLock);
        currentlyPlayingEntry = next;
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
            [self setInternalState:STKAudioPlayerInternalStateWaitingForData];
            
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
        
        if (!isPlayingSameItemProbablySeek && entry)
        {
            [self playbackThreadQueueMainThreadSyncBlock:^
            {
				[self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
            }];
        }
    }
    
    [self wakeupPlaybackThread];
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
		if (!disposeWasRequested)
		{
			block();
		}

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

-(void) requeueBufferingEntries
{
    if (bufferingQueue.count > 0)
    {
        for (STKQueueEntry* queueEntry in bufferingQueue)
        {
            queueEntry->parsedHeader = NO;
            
            [queueEntry reset];
        }

        [upcomingQueue skipQueueWithQueue:bufferingQueue];
        
        [bufferingQueue removeAllObjects];
    }
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
        else if (self.internalState == STKAudioPlayerInternalStatePendingNext)
        {
            STKQueueEntry* entry = [upcomingQueue dequeue];
            
            self.internalState = STKAudioPlayerInternalStateWaitingForData;
            
            [self setCurrentlyReadingEntry:entry andStartPlaying:YES];
            [self resetPcmBuffers];
        }
        else if (seekToTimeWasRequested && currentlyPlayingEntry && currentlyPlayingEntry != currentlyReadingEntry)
        {
            currentlyPlayingEntry->parsedHeader = NO;
            [currentlyPlayingEntry reset];
            
            if (currentlyReadingEntry != nil)
            {
                currentlyReadingEntry.dataSource.delegate = nil;
                [currentlyReadingEntry.dataSource unregisterForEvents];
            }
            
            if (self->options & STKAudioPlayerOptionFlushQueueOnSeek)
            {
                self.internalState = STKAudioPlayerInternalStateWaitingForDataAfterSeek;
                [self setCurrentlyReadingEntry:currentlyPlayingEntry andStartPlaying:YES clearQueue:YES];
            }
            else
            {
                [self requeueBufferingEntries];
                
                self.internalState = STKAudioPlayerInternalStateWaitingForDataAfterSeek;
                [self setCurrentlyReadingEntry:currentlyPlayingEntry andStartPlaying:YES clearQueue:NO];
            }
        }
        else if (currentlyReadingEntry == nil)
        {
            if (upcomingQueue.count > 0)
            {
                STKQueueEntry* entry = [upcomingQueue dequeue];
                
                BOOL startPlaying = currentlyPlayingEntry == nil;
                
                self.internalState = STKAudioPlayerInternalStateWaitingForData;
                [self setCurrentlyReadingEntry:entry andStartPlaying:startPlaying];
            }
            else if (currentlyPlayingEntry == nil)
            {
                if (self.internalState != STKAudioPlayerInternalStateStopped)
                {
                    [self stopAudioUnitWithReason:STKAudioPlayerStopReasonEof];
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
    STKQueueEntry* currentEntry = currentlyReadingEntry;
    
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
    
    OSSpinLockLock(&currentEntry->spinLock);
    currentEntry->seekTime = requestedSeekTime;
    OSSpinLockUnlock(&currentEntry->spinLock);
    
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
            
            OSSpinLockLock(&currentEntry->spinLock);
            currentEntry->seekTime -= delta;
            OSSpinLockUnlock(&currentEntry->spinLock);
            
            seekByteOffset = packetAlignedByteOffset + currentEntry->audioDataOffset;
        }
    }
    
    if (audioConverterRef)
    {
        AudioConverterReset(audioConverterRef);
    }
    
    [currentEntry updateAudioDataSource];
    [currentEntry reset];
    [currentEntry.dataSource seekToOffset:seekByteOffset];
    
    self.internalState = STKAudioPlayerInternalStateWaitingForDataAfterSeek;
    
    if (audioUnit)
    {
        [self resetPcmBuffers];
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
            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            
            return;
        }
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
                [self unexpectedError:STKAudioPlayerErrorStreamParseBytesFailed];
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
    
    [self unexpectedError:STKAudioPlayerErrorDataNotFound];
}

-(void) dataSourceEof:(STKDataSource*)dataSourceIn
{
    if (currentlyReadingEntry == nil || currentlyReadingEntry.dataSource != dataSourceIn)
    {
        dataSourceIn.delegate = nil;
        [dataSourceIn unregisterForEvents];
        [dataSourceIn close];

        return;
    }
    
    if (disposeWasRequested)
    {
        return;
    }
    
    NSObject* queueItemId = currentlyReadingEntry.queueItemId;

    [self dispatchSyncOnMainThread:^
    {
        [self.delegate audioPlayer:self didFinishBufferingSourceWithQueueItemId:queueItemId];
    }];

    pthread_mutex_lock(&playerMutex);
    
    if (currentlyReadingEntry == nil)
    {
        dataSourceIn.delegate = nil;
        [dataSourceIn unregisterForEvents];
        [dataSourceIn close];
        
        return;
    }
    
    OSSpinLockLock(&currentlyReadingEntry->spinLock);
    currentlyReadingEntry->lastFrameQueued = currentlyReadingEntry->framesQueued;
    OSSpinLockUnlock(&currentlyReadingEntry->spinLock);
    
    currentlyReadingEntry.dataSource.delegate = nil;
    [currentlyReadingEntry.dataSource unregisterForEvents];
    [currentlyReadingEntry.dataSource close];
    
    OSSpinLockLock(&currentEntryReferencesLock);
    currentlyReadingEntry = nil;
    OSSpinLockUnlock(&currentEntryReferencesLock);
    
    pthread_mutex_unlock(&playerMutex);
    
    [self processRunloop];
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
                    [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
                    
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
                [self resetPcmBuffers];
            }

            if (audioUnit != nil)
            {
                error = AudioOutputUnitStart(audioUnit);
                
                if (error)
                {
                    [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
                    
                    pthread_mutex_unlock(&playerMutex);
                    
                    return;
                }
            }
            
            [self wakeupPlaybackThread];
        }
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) resetPcmBuffers
{
    OSSpinLockLock(&pcmBufferSpinLock);
    
    self->pcmBufferFrameStartIndex = 0;
    self->pcmBufferUsedFrameCount = 0;
	self->peakPowerDb[0] = STK_DBMIN;
	self->peakPowerDb[1] = STK_DBMIN;
	self->averagePowerDb[0] = STK_DBMIN;
	self->averagePowerDb[1] = STK_DBMIN;
    
    OSSpinLockUnlock(&pcmBufferSpinLock);
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
        
        [self stopAudioUnitWithReason:STKAudioPlayerStopReasonUserAction];

        [self resetPcmBuffers];
		
        [self invokeOnPlaybackThread:^
        {
            pthread_mutex_lock(&playerMutex);
            {
                currentlyReadingEntry.dataSource.delegate = nil;
                [currentlyReadingEntry.dataSource unregisterForEvents];
                [currentlyReadingEntry.dataSource close];
                
                if (currentlyPlayingEntry)
                {
                    [self processFinishPlayingIfAnyAndPlayingNext:currentlyPlayingEntry withNext:nil];
                }
                
                [self clearQueue];
                
                OSSpinLockLock(&currentEntryReferencesLock);
                currentlyPlayingEntry = nil;
                currentlyReadingEntry = nil;
                seekToTimeWasRequested = NO;
                OSSpinLockUnlock(&currentEntryReferencesLock);
            }
            pthread_mutex_unlock(&playerMutex);
        }];
        
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

-(BOOL) muted
{
	return self->muted;
}

-(void) setMuted:(BOOL)value
{
	self->muted = value;
}

-(void) mute
{
    self.muted = YES;
}

-(void) unmute
{
    self.muted = NO;
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

static BOOL GetHardwareCodecClassDesc(UInt32 formatId, AudioClassDescription* classDesc)
{
#if TARGET_OS_IPHONE
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
#endif
    
    return NO;
}

-(void) destroyAudioConverter
{
    if (audioConverterRef)
    {
        AudioConverterDispose(audioConverterRef);
        
        audioConverterRef = nil;
    }
}

-(void) createAudioConverter:(AudioStreamBasicDescription*)asbd
{
    OSStatus status;
    Boolean writable;
	UInt32 cookieSize;
    
    if (memcmp(asbd, &audioConverterAudioStreamBasicDescription, sizeof(AudioStreamBasicDescription)) == 0)
    {
        AudioConverterReset(audioConverterRef);
        
        return;
    }

    [self destroyAudioConverter];
    
    AudioClassDescription classDesc;
    
    if (GetHardwareCodecClassDesc(asbd->mFormatID, &classDesc))
    {
        AudioConverterNewSpecific(asbd, &canonicalAudioStreamBasicDescription, 1,  &classDesc, &audioConverterRef);
    }
    
    if (!audioConverterRef)
    {
        status = AudioConverterNew(asbd, &canonicalAudioStreamBasicDescription, &audioConverterRef);
        
        if (status)
        {
            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            
            return;
        }
    }

    audioConverterAudioStreamBasicDescription = *asbd;
    
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
#if TARGET_OS_IPHONE
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
	desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    
    status = AudioComponentInstanceNew(component, &audioUnit);
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return;
    }
    
#if TARGET_OS_IPHONE
    UInt32 flag = 1;
	status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &flag, sizeof(flag));
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return;
    }
#endif
    
    status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &canonicalAudioStreamBasicDescription, sizeof(canonicalAudioStreamBasicDescription));
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return;
    }
    
    AURenderCallbackStruct callbackStruct;
    
    callbackStruct.inputProc = OutputRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)self;

    status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &callbackStruct, sizeof(callbackStruct));
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return;
    }
 
    status = AudioUnitInitialize(audioUnit);
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return;
    }
    
    pthread_mutex_unlock(&playerMutex);
}

-(BOOL) startAudioUnit
{
    OSStatus status;
    
	[self resetPcmBuffers];
	
    status = AudioOutputUnitStart(audioUnit);
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return NO;
    }
    
    return YES;
}

-(void) stopAudioUnitWithReason:(STKAudioPlayerStopReason)stopReasonIn
{
	OSStatus status;
	
	if (!audioUnit)
    {
        stopReason = stopReasonIn;
        self.internalState = STKAudioPlayerInternalStateStopped;
        
        return;
    }
    
    status = AudioOutputUnitStop(audioUnit);
	
	[self resetPcmBuffers];
    
    if (status)
    {
        [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
        
        return;
    }
    
    stopReason = stopReasonIn;
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
    
    if (!currentlyReadingEntry->parsedHeader)
    {
        return;
    }
    
    if (seekToTimeWasRequested || disposeWasRequested)
    {
        return;
    }
    
    if (audioConverterRef == nil)
    {
        return;
    }
    
	discontinuous = NO;
    
    OSStatus status;
    
    AudioConvertInfo convertInfo;

    convertInfo.done = NO;
    convertInfo.numberOfPackets = numberPackets;
    convertInfo.packetDescriptions = packetDescriptionsIn;
    convertInfo.audioBuffer.mData = (void *)inputData;
    convertInfo.audioBuffer.mDataByteSize = numberBytes;
    convertInfo.audioBuffer.mNumberChannels = audioConverterAudioStreamBasicDescription.mChannelsPerFrame;

    if (packetDescriptionsIn && currentlyReadingEntry->processedPacketsCount < STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION)
    {
        int count = MIN(numberPackets, STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION - currentlyReadingEntry->processedPacketsCount);
        
        for (int i = 0; i < count; i++)
        {
			SInt64 packetSize;
			
			packetSize = packetDescriptionsIn[i].mDataByteSize;
			
            OSAtomicAdd32((int32_t)packetSize, &currentlyReadingEntry->processedPacketsSizeTotal);
            OSAtomicIncrement32(&currentlyReadingEntry->processedPacketsCount);
        }
    }
    
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
                
                if  (disposeWasRequested
                     || seekToTimeWasRequested
                     || self.internalState == STKAudioPlayerInternalStateStopped
                     || self.internalState == STKAudioPlayerInternalStateDisposed
                     || self.internalState == STKAudioPlayerInternalStatePendingNext)
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
                OSSpinLockUnlock(&pcmBufferSpinLock);

                OSSpinLockLock(&currentlyReadingEntry->spinLock);
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&currentlyReadingEntry->spinLock);
                
                return;
            }
            else if (status != 0)
            {
                [self unexpectedError:STKAudioPlayerErrorCodecError];
                
                return;
            }
            
            framesToDecode = start;
            
            if (framesToDecode == 0)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                OSSpinLockLock(&currentlyReadingEntry->spinLock);
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&currentlyReadingEntry->spinLock);
                
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
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                OSSpinLockLock(&currentlyReadingEntry->spinLock);
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&currentlyReadingEntry->spinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                OSSpinLockLock(&currentlyReadingEntry->spinLock);
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&currentlyReadingEntry->spinLock);
                
                continue;
            }
            else if (status != 0)
            {
                [self unexpectedError:STKAudioPlayerErrorCodecError];
                
                return;
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
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                OSSpinLockLock(&currentlyReadingEntry->spinLock);
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&currentlyReadingEntry->spinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&pcmBufferSpinLock);
                pcmBufferUsedFrameCount += framesAdded;
                OSSpinLockUnlock(&pcmBufferSpinLock);
                
                OSSpinLockLock(&currentlyReadingEntry->spinLock);
                currentlyReadingEntry->framesQueued += framesAdded;
                OSSpinLockUnlock(&currentlyReadingEntry->spinLock);

                continue;
            }
            else if (status != 0)
            {
                [self unexpectedError:STKAudioPlayerErrorCodecError];
                
                return;
            }
        }
    }
}

static OSStatus OutputRenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData)
{
    STKAudioPlayer* audioPlayer = (__bridge STKAudioPlayer*)inRefCon;

    OSSpinLockLock(&audioPlayer->pcmBufferSpinLock);
    
    BOOL waitForBuffer = NO;
	BOOL muted = audioPlayer->muted;
	STKQueueEntry* entry = audioPlayer->currentlyPlayingEntry;
    AudioBuffer* audioBuffer = audioPlayer->pcmAudioBuffer;
    UInt32 frameSizeInBytes = audioPlayer->pcmBufferFrameSizeInBytes;
    UInt32 used = audioPlayer->pcmBufferUsedFrameCount;
    UInt32 start = audioPlayer->pcmBufferFrameStartIndex;
    UInt32 end = (audioPlayer->pcmBufferFrameStartIndex + audioPlayer->pcmBufferUsedFrameCount) % audioPlayer->pcmBufferTotalFrameCount;
    BOOL signal = audioPlayer->waiting && used < audioPlayer->pcmBufferTotalFrameCount / 2;
	NSArray* frameFilters = audioPlayer->frameFilters;
    
    STKAudioPlayerInternalState state = audioPlayer.internalState;
    
	if (state == STKAudioPlayerInternalStatePendingNext)
    {
        OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
        
        return 0;
    }

	if (entry)
	{
		if (state == STKAudioPlayerInternalStateWaitingForData)
		{
			int64_t framesRequiredToStartPlaying = audioPlayer->framesRequiredToStartPlaying;
			
			if (entry->lastFrameQueued >= 0)
			{
				framesRequiredToStartPlaying = MIN(framesRequiredToStartPlaying, audioPlayer->currentlyPlayingEntry->lastFrameQueued);
			}
			
			if (entry && audioPlayer->currentlyReadingEntry == entry
				&& entry->framesQueued < framesRequiredToStartPlaying)
			{
				waitForBuffer = YES;
			}
		}
		else if (state == STKAudioPlayerInternalStateRebuffering)
		{
			int64_t framesRequiredToStartPlaying = audioPlayer->framesRequiredToStartPlaying;
			
			if (audioPlayer->currentlyPlayingEntry->lastFrameQueued >= 0)
			{
				framesRequiredToStartPlaying = MIN(framesRequiredToStartPlaying, entry->lastFrameQueued - entry->framesQueued);
			}
			
			if (used < framesRequiredToStartPlaying)
			{
				waitForBuffer = YES;
			}
		}
	}
    
    OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
    
    UInt32 totalFramesCopied = 0;
    
    if (used > 0 && !waitForBuffer && entry != nil)
    {
        if (state == STKAudioPlayerInternalStateWaitingForData)
        {
            // Starting
        }
        else if (state == STKAudioPlayerInternalStateRebuffering)
        {
            // Resuming from buffering
        }
        
        if (end > start)
        {
            UInt32 framesToCopy = MIN(inNumberFrames, used);
            
            ioData->mBuffers[0].mNumberChannels = 2;
            ioData->mBuffers[0].mDataByteSize = frameSizeInBytes * framesToCopy;
			
			if (muted)
			{
				memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
			}
			else
			{
				memcpy(ioData->mBuffers[0].mData, audioBuffer->mData + (start * frameSizeInBytes), ioData->mBuffers[0].mDataByteSize);
			}
            
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
			
			if (muted)
			{
				memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
			}
			else
			{
				memcpy(ioData->mBuffers[0].mData, audioBuffer->mData + (start * frameSizeInBytes), ioData->mBuffers[0].mDataByteSize);
			}
            
            UInt32 moreFramesToCopy = 0;
            UInt32 delta = inNumberFrames - framesToCopy;
            
            if (delta > 0)
            {
                moreFramesToCopy = MIN(delta, end);
                
                ioData->mBuffers[0].mNumberChannels = 2;
                ioData->mBuffers[0].mDataByteSize += frameSizeInBytes * moreFramesToCopy;
				
				if (muted)
				{
					memset(ioData->mBuffers[0].mData + (framesToCopy * frameSizeInBytes), 0, frameSizeInBytes * moreFramesToCopy);
				}
				else
				{
					memcpy(ioData->mBuffers[0].mData + (framesToCopy * frameSizeInBytes), audioBuffer->mData, frameSizeInBytes * moreFramesToCopy);
				}
            }
            
            totalFramesCopied = framesToCopy + moreFramesToCopy;
            
            OSSpinLockLock(&audioPlayer->pcmBufferSpinLock);
            audioPlayer->pcmBufferFrameStartIndex = (audioPlayer->pcmBufferFrameStartIndex + totalFramesCopied) % audioPlayer->pcmBufferTotalFrameCount;
            audioPlayer->pcmBufferUsedFrameCount -= totalFramesCopied;
            OSSpinLockUnlock(&audioPlayer->pcmBufferSpinLock);
        }
        
        audioPlayer.internalState = STKAudioPlayerInternalStatePlaying;
    }
    
    if (totalFramesCopied < inNumberFrames)
    {
        UInt32 delta = inNumberFrames - totalFramesCopied;
        
        memset(ioData->mBuffers[0].mData + (totalFramesCopied * frameSizeInBytes), 0, delta * frameSizeInBytes);
        
        if (!(entry == nil || state == STKAudioPlayerInternalStateWaitingForDataAfterSeek || state == STKAudioPlayerInternalStateWaitingForData || state == STKAudioPlayerInternalStateRebuffering))
        {
            // Buffering
            
            audioPlayer.internalState = STKAudioPlayerInternalStateRebuffering;
        }
    }

	if (frameFilters)
	{
		NSUInteger count = frameFilters.count;
		AudioStreamBasicDescription asbd = audioPlayer->canonicalAudioStreamBasicDescription;
		
		for (int i = 0; i < count; i++)
		{
			STKFrameFilterEntry* entry = [frameFilters objectAtIndex:i];
			
			entry->filter(asbd.mChannelsPerFrame, asbd.mBytesPerFrame, inNumberFrames, ioData->mBuffers[0].mData);
		}
	}
	
    if (entry == nil)
    {
        return 0;
    }
    
    OSSpinLockLock(&entry->spinLock);
	
    int64_t extraFramesPlayedNotAssigned = 0;
    int64_t framesPlayedForCurrent = totalFramesCopied;

    if (entry->lastFrameQueued >= 0)
    {
        framesPlayedForCurrent = MIN(entry->lastFrameQueued - entry->framesPlayed, framesPlayedForCurrent);
    }
    
    entry->framesPlayed += framesPlayedForCurrent;
    extraFramesPlayedNotAssigned = totalFramesCopied - framesPlayedForCurrent;
    
    BOOL lastFramePlayed = entry->framesPlayed == entry->lastFrameQueued;

    OSSpinLockUnlock(&entry->spinLock);
    
    if (signal || lastFramePlayed)
    {
        pthread_mutex_lock(&audioPlayer->playerMutex);
        
        if (lastFramePlayed && entry == audioPlayer->currentlyPlayingEntry)
        {
            [audioPlayer audioQueueFinishedPlaying:entry];
            
            while (extraFramesPlayedNotAssigned > 0)
            {
                STKQueueEntry* newEntry = audioPlayer->currentlyPlayingEntry;
                
                if (newEntry != nil)
                {
                    int64_t framesPlayedForCurrent = extraFramesPlayedNotAssigned;
                    
                    OSSpinLockLock(&newEntry->spinLock);
                    
                    if (newEntry->lastFrameQueued > 0)
                    {
                        framesPlayedForCurrent = MIN(newEntry->lastFrameQueued - newEntry->framesPlayed, framesPlayedForCurrent);
                    }
                    
                    newEntry->framesPlayed += framesPlayedForCurrent;
                    
                    if (newEntry->framesPlayed == newEntry->lastFrameQueued)
                    {
                        OSSpinLockUnlock(&newEntry->spinLock);
                        
                        [audioPlayer audioQueueFinishedPlaying:newEntry];
                    }
                    else
                    {
                        OSSpinLockUnlock(&newEntry->spinLock);
                    }
                    
                    extraFramesPlayedNotAssigned -= framesPlayedForCurrent;
                }
				else
				{
					break;
				}
            }
        }

        pthread_cond_signal(&audioPlayer->playerThreadReadyCondition);
        pthread_mutex_unlock(&audioPlayer->playerMutex);
    }
    
    return 0;
}

-(NSArray*) pendingQueue
{
	pthread_mutex_lock(&playerMutex);
	
	NSArray* retval;
	NSMutableArray* mutableArray = [[NSMutableArray alloc] initWithCapacity:upcomingQueue.count + bufferingQueue.count];
	
	[mutableArray skipQueueWithQueue:upcomingQueue];
	[mutableArray skipQueueWithQueue:bufferingQueue];
	
	retval = [NSArray arrayWithArray:mutableArray];
	
	pthread_mutex_unlock(&playerMutex);
	
	return retval;
}

-(NSUInteger) pendingQueueCount
{
	pthread_mutex_lock(&playerMutex);
	
	NSUInteger retval = upcomingQueue.count + bufferingQueue.count;
	
	pthread_mutex_unlock(&playerMutex);
	
	return retval;
}

-(NSObject*) mostRecentlyQueuedStillPendingItem
{
	pthread_mutex_lock(&playerMutex);
	
	if (upcomingQueue.count > 0)
	{
		NSObject* retval = [upcomingQueue objectAtIndex:0];
		
		pthread_mutex_unlock(&playerMutex);
		
		return retval;
	}
	
	if (bufferingQueue.count > 0)
	{
		NSObject* retval = [bufferingQueue objectAtIndex:0];
		
		pthread_mutex_unlock(&playerMutex);
		
		return retval;
	}
	
	pthread_mutex_unlock(&playerMutex);
	
	return nil;
}

-(float) peakPowerInDecibelsForChannel:(NSUInteger)channelNumber
{
	if (channelNumber >= canonicalAudioStreamBasicDescription.mChannelsPerFrame)
	{
		return 0;
	}
	
	return peakPowerDb[channelNumber];
}

-(float) averagePowerInDecibelsForChannel:(NSUInteger)channelNumber
{
	if (channelNumber >= canonicalAudioStreamBasicDescription.mChannelsPerFrame)
	{
		return 0;
	}
	
	return averagePowerDb[channelNumber];
}

-(BOOL) meteringEnabled
{
	return self->meteringEnabled;
}

#define CALCULATE_METER(channel) \
	Float32 currentFilteredValueOfSampleAmplitude##channel = STK_LOWPASSFILTERTIMESLICE * absoluteValueOfSampleAmplitude##channel + (1.0 - STK_LOWPASSFILTERTIMESLICE) * previousFilteredValueOfSampleAmplitude##channel; \
	previousFilteredValueOfSampleAmplitude##channel = currentFilteredValueOfSampleAmplitude##channel; \
	Float32 sampleDB##channel = 20.0 * log10(currentFilteredValueOfSampleAmplitude##channel) + STK_DBOFFSET; \
	if ((sampleDB##channel == sampleDB##channel) && (sampleDB##channel != -DBL_MAX)) \
	{ \
		if(sampleDB##channel > peakValue##channel) \
		{ \
			peakValue##channel = sampleDB##channel; \
		} \
		if (sampleDB##channel > -DBL_MAX) \
		{ \
			count##channel++; \
			totalValue##channel += sampleDB##channel; \
		} \
		decibels##channel = peakValue##channel; \
	};

-(void) setMeteringEnabled:(BOOL)value
{
	if (self->meteringEnabled == value)
	{
		return;
	}
	
	if (!value)
	{
		[self removeFrameFilterWithName:@"STKMeteringFilter"];
		self->meteringEnabled = NO;
	}
	else
	{
		[self appendFrameFilterWithName:@"STKMeteringFilter" block:^(UInt32 channelsPerFrame, UInt32 bytesPerFrame, UInt32 frameCount, void* frames)
		{
			SInt16* samples16 = (SInt16*)frames;
			SInt32* samples32 = (SInt32*)frames;
			UInt32 countLeft = 0;
			UInt32 countRight = 0;
			Float32 decibelsLeft = STK_DBMIN;
			Float32 peakValueLeft = STK_DBMIN;
			Float64 totalValueLeft = 0;
			Float32 previousFilteredValueOfSampleAmplitudeLeft = 0;
			Float32 decibelsRight = STK_DBMIN;
			Float32 peakValueRight = STK_DBMIN;
			Float64 totalValueRight = 0;
			Float32 previousFilteredValueOfSampleAmplitudeRight = 0;
			
			if (bytesPerFrame / channelsPerFrame == 2)
			{
				for (int i = 0; i < frameCount * channelsPerFrame; i += channelsPerFrame)
				{
					Float32 absoluteValueOfSampleAmplitudeLeft = abs(samples16[i]);
					Float32 absoluteValueOfSampleAmplitudeRight = abs(samples16[i + 1]);
					
					CALCULATE_METER(Left);
					CALCULATE_METER(Right);
				}
			}
			else if (bytesPerFrame / channelsPerFrame == 4)
			{
				for (int i = 0; i < frameCount * channelsPerFrame; i += channelsPerFrame)
				{
					Float32 absoluteValueOfSampleAmplitudeLeft = abs(samples32[i]) / 32768.0;
					Float32 absoluteValueOfSampleAmplitudeRight = abs(samples32[i + 1]) / 32768.0;
					
					CALCULATE_METER(Left);
					CALCULATE_METER(Right);
				}
			}
			else
			{
				return;
			}
			
			peakPowerDb[0] = MIN(MAX(decibelsLeft, -60), 0);
			peakPowerDb[1] = MIN(MAX(decibelsRight, -60), 0);
			
			if (countLeft > 0)
			{
				averagePowerDb[0] = MIN(MAX(totalValueLeft / frameCount, -60), 0);
			}
			
			if (countRight != 0)
			{
				averagePowerDb[1] = MIN(MAX(totalValueRight / frameCount, -60), 0);
			}
		}];
	}
}

#pragma mark Frame Filters

-(NSArray*) frameFilters
{
	return frameFilters;
}

-(void) appendFrameFilterWithName:(NSString*)name block:(STKFrameFilter)block
{
	[self addFrameFilterWithName:name afterFilterWithName:nil block:block];
}

-(void) removeFrameFilterWithName:(NSString*)name
{
	pthread_mutex_lock(&self->playerMutex);
	
	NSMutableArray* newFrameFilters = [[NSMutableArray alloc] initWithCapacity:frameFilters.count + 1];
	
	for (STKFrameFilterEntry* filterEntry in frameFilters)
	{
		if (![filterEntry->name isEqualToString:name])
		{
			[newFrameFilters addObject:filterEntry];
		}
	}
	
	NSArray* replacement = [NSArray arrayWithArray:newFrameFilters];
	
	OSSpinLockLock(&pcmBufferSpinLock);
	if (newFrameFilters.count > 0)
	{
		frameFilters = replacement;
	}
	else
	{
		frameFilters = nil;
	}
	OSSpinLockUnlock(&pcmBufferSpinLock);
	
	pthread_mutex_unlock(&self->playerMutex);
}

-(void) addFrameFilterWithName:(NSString*)name afterFilterWithName:(NSString*)afterFilterWithName block:(STKFrameFilter)block
{
	pthread_mutex_lock(&self->playerMutex);
	
	NSMutableArray* newFrameFilters = [[NSMutableArray alloc] initWithCapacity:frameFilters.count + 1];
	
	if (afterFilterWithName == nil)
	{
		[newFrameFilters addObject:[[STKFrameFilterEntry alloc] initWithFilter:block andName:name]];
		[newFrameFilters addObjectsFromArray:frameFilters];
	}
	else
	{
		for (STKFrameFilterEntry* filterEntry in frameFilters)
		{
			if (afterFilterWithName != nil && [filterEntry->name isEqualToString:afterFilterWithName])
			{
				[newFrameFilters addObject:[[STKFrameFilterEntry alloc] initWithFilter:block andName:name]];
			}
			
			[newFrameFilters addObject:filterEntry];
		}
	}
	
	NSArray* replacement = [NSArray arrayWithArray:newFrameFilters];
	
	OSSpinLockLock(&pcmBufferSpinLock);
	frameFilters = replacement;
	OSSpinLockUnlock(&pcmBufferSpinLock);
	
	pthread_mutex_unlock(&self->playerMutex);
}

-(void) addFrameFilter:(STKFrameFilter)frameFilter withName:(NSString*)name afterFilterWithName:(NSString*)afterFilterWithName
{
	pthread_mutex_lock(&self->playerMutex);
	
	NSMutableArray* newFrameFilters = [[NSMutableArray alloc] initWithCapacity:frameFilters.count + 1];
	
	if (afterFilterWithName == nil)
	{
		[newFrameFilters addObjectsFromArray:frameFilters];
		[newFrameFilters addObject:[[STKFrameFilterEntry alloc] initWithFilter:frameFilter andName:name]];
	}
	else
	{
		for (STKFrameFilterEntry* filterEntry in frameFilters)
		{
			[newFrameFilters addObject:filterEntry];
			
			if (afterFilterWithName != nil && [filterEntry->name isEqualToString:afterFilterWithName])
			{
				[newFrameFilters addObject:[[STKFrameFilterEntry alloc] initWithFilter:frameFilter andName:name]];
			}
		}
	}
	
	NSArray* replacement = [NSArray arrayWithArray:newFrameFilters];
	
	OSSpinLockLock(&pcmBufferSpinLock);
	frameFilters = replacement;
	OSSpinLockUnlock(&pcmBufferSpinLock);
	
	pthread_mutex_unlock(&self->playerMutex);
}

@end
