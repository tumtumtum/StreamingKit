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

#import "AudioPlayer.h"
#import "AudioToolbox/AudioToolbox.h"
#import "HttpDataSource.h"
#import "LocalFileDataSource.h"
#import "libkern/OSAtomic.h"

#define BitRateEstimationMinPackets (64)
#define AudioPlayerBuffersNeededToStart (16)
#define AudioPlayerDefaultReadBufferSize (16 * 1024)
#define AudioPlayerDefaultPacketBufferSize (2048)

#define OSSTATUS_PARAM_ERROR (-50)

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

@interface QueueEntry : NSObject
{
@public
    BOOL parsedHeader;
    double sampleRate;
    double lastProgress;
    double packetDuration;
    UInt64 audioDataOffset;
    UInt64 audioDataByteCount;
    UInt32 packetBufferSize;
    volatile double seekTime;
    volatile int bytesPlayed;
    volatile int processedPacketsCount;
	volatile int processedPacketsSizeTotal;
    AudioStreamBasicDescription audioStreamBasicDescription;
}
@property (readwrite, retain) NSObject* queueItemId;
@property (readwrite, retain) DataSource* dataSource;
@property (readwrite) int bufferIndex;
@property (readonly) UInt64 audioDataLengthInBytes;

-(double) duration;
-(double) calculatedBitRate;
-(double) progress;

-(id) initWithDataSource:(DataSource*)dataSource andQueueItemId:(NSObject*)queueItemId;
-(id) initWithDataSource:(DataSource*)dataSource andQueueItemId:(NSObject*)queueItemId andBufferIndex:(int)bufferIndex;

@end

@implementation QueueEntry
@synthesize dataSource, queueItemId, bufferIndex;

-(id) initWithDataSource:(DataSource*)dataSourceIn andQueueItemId:(NSObject*)queueItemIdIn
{
    return [self initWithDataSource:dataSourceIn andQueueItemId:queueItemIdIn andBufferIndex:-1];
}

-(id) initWithDataSource:(DataSource*)dataSourceIn andQueueItemId:(NSObject*)queueItemIdIn andBufferIndex:(int)bufferIndexIn
{
    if (self = [super init])
    {
        self.dataSource = dataSourceIn;
        self.queueItemId = queueItemIdIn;
        self.bufferIndex = bufferIndexIn;
    }
    
    return self;
}

-(double) calculatedBitRate
{
    double retval;
    
    if (packetDuration && processedPacketsCount > BitRateEstimationMinPackets)
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
    if ([self->dataSource conformsToProtocol:@protocol(AudioDataSource)])
    {
        double calculatedBitrate = [self calculatedBitRate];
        
        id<AudioDataSource> audioDataSource = (id<AudioDataSource>)self->dataSource;
        
        audioDataSource.averageBitRate = calculatedBitrate;
        audioDataSource.audioDataOffset = audioDataOffset;
    }
}

-(double) progress
{
    double retval = lastProgress;
    double duration = [self duration];
    
    if (self->sampleRate > 0)
    {
        double calculatedBitrate = [self calculatedBitRate];
        
        retval = self->bytesPlayed / calculatedBitrate * 8;
        
        retval = seekTime + retval;
        
        [self updateAudioDataSource];
    }
    
    if (retval > duration)
    {
        retval = duration;
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
    
    if (calculatedBitRate == 0 || dataSource.length == 0)
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
        if (!dataSource.length)
        {
            return 0;
        }
        
        return dataSource.length - audioDataOffset;
    }
}

-(NSString*) description
{
    return [[self queueItemId] description];
}

@end

@interface AudioPlayer()
@property (readwrite) AudioPlayerInternalState internalState;

-(void) logInfo:(NSString*)line;
-(void) processQueue:(BOOL)skipCurrent;
-(void) createAudioQueue;
-(void) enqueueBuffer;
-(void) resetAudioQueueWithReason:(NSString*)reason;
-(BOOL) startAudioQueue;
-(void) stopAudioQueueWithReason:(NSString*)reason;
-(BOOL) processRunloop;
-(void) wakeupPlaybackThread;
-(void) audioQueueFinishedPlaying:(QueueEntry*)entry;
-(void) processSeekToTime;
-(void) didEncounterError:(AudioPlayerErrorCode)errorCode;
-(void) setInternalState:(AudioPlayerInternalState)value;
-(void) processDidFinishPlaying:(QueueEntry*)entry withNext:(QueueEntry*)next;
-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)audioFileStreamIn fileStreamPropertyID:(AudioFileStreamPropertyID)propertyID ioFlags:(UInt32*)ioFlags;
-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptions;
-(void) handleAudioQueueOutput:(AudioQueueRef)audioQueue buffer:(AudioQueueBufferRef)buffer;
-(void) handlePropertyChangeForQueue:(AudioQueueRef)audioQueue propertyID:(AudioQueuePropertyID)propertyID;
@end

static void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{
	AudioPlayer* player = (__bridge AudioPlayer*)clientData;
    
	[player handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

static void AudioFileStreamPacketsProc(void* clientData, UInt32 numberBytes, UInt32 numberPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
	AudioPlayer* player = (__bridge AudioPlayer*)clientData;
    
	[player handleAudioPackets:inputData numberBytes:numberBytes numberPackets:numberPackets packetDescriptions:packetDescriptions];
}

static void AudioQueueOutputCallbackProc(void* clientData, AudioQueueRef audioQueue, AudioQueueBufferRef buffer)
{
	AudioPlayer* player = (__bridge AudioPlayer*)clientData;
    
	[player handleAudioQueueOutput:audioQueue buffer:buffer];
}

static void AudioQueueIsRunningCallbackProc(void* userData, AudioQueueRef audioQueue, AudioQueuePropertyID propertyId)
{
	AudioPlayer* player = (__bridge AudioPlayer*)userData;
    
	[player handlePropertyChangeForQueue:audioQueue propertyID:propertyId];
}

@implementation AudioPlayer
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
        case AudioPlayerInternalStateWaitingForData:
        case AudioPlayerInternalStateWaitingForQueueToStart:
        case AudioPlayerInternalStatePlaying:
        case AudioPlayerInternalStateRebuffering:
            newState = AudioPlayerStatePlaying;
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
    if ([self->delegate respondsToSelector:@selector(audioPlayer:logInfo:)])
    {
        [self->delegate audioPlayer:self logInfo:line];
    }
}

-(id) init
{
    return [self initWithNumberOfAudioQueueBuffers:AudioPlayerDefaultNumberOfAudioQueueBuffers andReadBufferSize:AudioPlayerDefaultReadBufferSize];
}

-(id) initWithNumberOfAudioQueueBuffers:(int)numberOfAudioQueueBuffers andReadBufferSize:(int)readBufferSizeIn
{
    if (self = [super init])
    {
        fastApiQueue = [[NSOperationQueue alloc] init];
        [fastApiQueue setMaxConcurrentOperationCount:1];
        
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
        
        threadFinishedCondLock = [[NSConditionLock alloc] initWithCondition:0];
        
        self.internalState = AudioPlayerInternalStateInitialised;
        
        upcomingQueue = [[NSMutableArray alloc] init];
        bufferingQueue = [[NSMutableArray alloc] init];
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
}

-(void) stopSystemBackgroundTask
{
	pthread_mutex_lock(&playerMutex);
	{
		if (backgroundTaskId != UIBackgroundTaskInvalid)
		{
			[[UIApplication sharedApplication] endBackgroundTask:backgroundTaskId];
			
			backgroundTaskId = UIBackgroundTaskInvalid;
		}
	}
    pthread_mutex_unlock(&playerMutex);
}

-(DataSource*) dataSourceFromURL:(NSURL*)url
{
    DataSource* retval;
    
    if ([url.scheme isEqualToString:@"file"])
    {
        retval = [[LocalFileDataSource alloc] initWithFilePath:url.path];
    }
    else
    {
        retval = [[HttpDataSource alloc] initWithURL:url];
    }
    
    return retval;
}

-(void) clearQueue
{
    pthread_mutex_lock(&playerMutex);
    {
        NSMutableArray* array = [[NSMutableArray alloc] initWithCapacity:bufferingQueue.count + upcomingQueue.count];
        
        QueueEntry* entry = [bufferingQueue dequeue];
        
        if (entry && entry != currentlyPlayingEntry)
        {
            [array addObject:[entry queueItemId]];
        }
        
        while (bufferingQueue.count > 0)
        {
            [array addObject:[[bufferingQueue dequeue] queueItemId]];
        }
        
        for (QueueEntry* entry in upcomingQueue)
        {
            [array addObject:entry.queueItemId];
        }
        
        [upcomingQueue removeAllObjects];
        
        dispatch_async(dispatch_get_main_queue(), ^
                       {
                           if ([self.delegate respondsToSelector:@selector(audioPlayer:didCancelQueuedItems:)])
                           {
                               [self.delegate audioPlayer:self didCancelQueuedItems:array];
                           }
                       });
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) play:(NSURL*)url
{
	[self setDataSource:[self dataSourceFromURL:url] withQueueItemId:url];
}

-(void) setDataSource:(DataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
    [fastApiQueue cancelAllOperations];
    
	[fastApiQueue addOperationWithBlock:^
     {
         pthread_mutex_lock(&playerMutex);
         {
             [self startSystemBackgroundTask];
             
             [self clearQueue];
             
             [upcomingQueue enqueue:[[QueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
             
             self.internalState = AudioPlayerInternalStateRunning;
             [self processQueue:YES];
         }
         pthread_mutex_unlock(&playerMutex);
     }];
}

-(void) queueDataSource:(DataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
	[fastApiQueue addOperationWithBlock:^
     {
         pthread_mutex_lock(&playerMutex);
         {
             [upcomingQueue enqueue:[[QueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
             
             [self processQueue:NO];
         }
         pthread_mutex_unlock(&playerMutex);
     }];
}

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
	OSStatus error;
    
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
        }
            break;
        case kAudioFileStreamProperty_DataFormat:
        {
            if (currentlyReadingEntry->audioStreamBasicDescription.mSampleRate == 0) {
                AudioStreamBasicDescription newBasicDescription;
                UInt32 size = sizeof(newBasicDescription);
                
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &newBasicDescription);
                currentlyReadingEntry->audioStreamBasicDescription = newBasicDescription;
            }
            
            currentlyReadingEntry->sampleRate = currentlyReadingEntry->audioStreamBasicDescription.mSampleRate;
            currentlyReadingEntry->packetDuration = currentlyReadingEntry->audioStreamBasicDescription.mFramesPerPacket / currentlyReadingEntry->sampleRate;
            
            UInt32 packetBufferSize = 0;
            UInt32 sizeOfPacketBufferSize = sizeof(packetBufferSize);
            
            error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfPacketBufferSize, &packetBufferSize);
            
            if (error || packetBufferSize == 0)
            {
                error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfPacketBufferSize, &packetBufferSize);
                
                if (error || packetBufferSize == 0)
                {
                    currentlyReadingEntry->packetBufferSize = AudioPlayerDefaultPacketBufferSize;
                }
            }
            
            [currentlyReadingEntry updateAudioDataSource];
            
            AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
        }
            break;
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt64 audioDataByteCount;
            UInt32 byteCountSize = sizeof(audioDataByteCount);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
            
            currentlyReadingEntry->audioDataByteCount = audioDataByteCount;
            
            [currentlyReadingEntry updateAudioDataSource];
        }
            break;
		case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            discontinuous = YES;
        }
            break;
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            OSStatus err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            if (err)
            {
                break;
            }
            
            AudioFormatListItem *formatList = malloc(formatListSize);
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            if (err)
            {
                free(formatList);
                break;
            }
            
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
            {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE ||
                    pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
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
        }
            break;
    }
}

-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptionsIn
{
    if (currentlyReadingEntry == nil)
    {
        return;
    }
    
    if (seekToTimeWasRequested)
    {
        return;
    }
    
	if (audioQueue == nil)
    {
        [self createAudioQueue];
    }
    else if (memcmp(&currentAudioStreamBasicDescription, &currentlyReadingEntry->audioStreamBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
    {
        if (currentlyReadingEntry == currentlyPlayingEntry)
        {
            [self createAudioQueue];
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
            
            if (currentlyReadingEntry->processedPacketsSizeTotal < 0xfffff)
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
                
                if (seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed)
                {
                    return;
                }
            }
            
            if (bytesFilled + packetSize > currentlyReadingEntry->packetBufferSize)
            {
                return;
            }
            
            AudioQueueBufferRef bufferToFill = audioQueueBuffer[fillBufferIndex];
            memcpy((char*)bufferToFill->mAudioData + bytesFilled, (const char*)inputData + packetOffset, packetSize);
            
            packetDescs[packetsFilled] = packetDescriptionsIn[i];
            packetDescs[packetsFilled].mStartOffset = bytesFilled;
            
            bytesFilled += packetSize;
            packetsFilled++;
            
            int packetsDescRemaining = audioQueueBufferCount - packetsFilled;
            
            if (packetsDescRemaining <= 0)
            {
                [self enqueueBuffer];
                
                if (seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed)
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
			int bytesLeft = AudioPlayerDefaultPacketBufferSize - bytesFilled;
            
			if (bytesLeft < numberBytes)
			{
				[self enqueueBuffer];
                
                if (seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed)
                {
                    return;
                }
			}
			
			pthread_mutex_lock(&playerMutex);
			{
				int copySize;
				bytesLeft = AudioPlayerDefaultPacketBufferSize - bytesFilled;
                
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
            pthread_mutex_unlock(&playerMutex);
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
    
    QueueEntry* entry = nil;
    
    if (currentlyPlayingEntry)
    {
        OSSpinLockLock(&currentlyPlayingLock);
        {
            if (currentlyPlayingEntry)
            {
                entry = currentlyPlayingEntry;
                
                if (!audioQueueFlushing)
                {
                    currentlyPlayingEntry->bytesPlayed += bufferIn->mAudioDataByteSize;
                }
            }
        }
        OSSpinLockUnlock(&currentlyPlayingLock);
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
		[self didEncounterError:AudioPlayerErrorUnknownBuffer];
        
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
    
    if (!audioQueueFlushing && [self progress] > 4.0 && numberOfBuffersUsed == 0 ) {
        self.internalState = AudioPlayerInternalStateRebuffering;
    }
    
    
    if (!audioQueueFlushing)
    {
        if (entry != nil)
        {
            if (entry.bufferIndex == audioPacketsPlayedCount && entry.bufferIndex != -1)
            {
                entry.bufferIndex = -1;
                
                if (playbackThread)
                {
                    CFRunLoopPerformBlock([playbackThreadRunLoop getCFRunLoop], NSDefaultRunLoopMode, ^
                                          {
                                              [self audioQueueFinishedPlaying:entry];
                                          });
                    
                    CFRunLoopWakeUp([playbackThreadRunLoop getCFRunLoop]);
                    
                    signal = YES;
                }
            }
        }
    }
    
    if (self.internalState == AudioPlayerInternalStateStopped
        || self.internalState == AudioPlayerInternalStateStopping
        || self.internalState == AudioPlayerInternalStateDisposed
        || self.internalState == AudioPlayerInternalStateError
        || self.internalState == AudioPlayerInternalStateWaitingForQueueToStart)
    {
        signal = waiting || numberOfBuffersUsed < 8;
    }
    else if (audioQueueFlushing)
    {
        signal = signal || (audioQueueFlushing && numberOfBuffersUsed < 8);
    }
    else
    {
        if (seekToTimeWasRequested)
        {
            signal = YES;
        }
        else
        {
            if ((waiting && numberOfBuffersUsed < audioQueueBufferCount / 2) || (numberOfBuffersUsed < 8))
            {
                signal = YES;
            }
        }
    }
    
    if (signal)
    {
        pthread_cond_signal(&queueBufferReadyCondition);
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
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
        else if (self.internalState == AudioPlayerInternalStateWaitingForQueueToStart)
        {
            [NSRunLoop currentRunLoop];
            
            self.internalState = AudioPlayerInternalStatePlaying;
        }
    }
}

-(void) enqueueBuffer
{
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
        
        bufferUsed[fillBufferIndex] = true;
        numberOfBuffersUsed++;
        
        pthread_mutex_unlock(&queueBuffersMutex);
        
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
        
        if (error)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return;
        }
        
        if (self.internalState == AudioPlayerInternalStateWaitingForData && numberOfBuffersUsed >= AudioPlayerBuffersNeededToStart)
        {
            if (![self startAudioQueue])
            {
                pthread_mutex_unlock(&playerMutex);
                
                return;
            }
        }
        
        if (self.internalState == AudioPlayerInternalStateRebuffering && numberOfBuffersUsed >= AudioPlayerBuffersNeededToStart)
        {
            self.internalState = AudioPlayerInternalStatePlaying;
        }
        
        if (++fillBufferIndex >= audioQueueBufferCount)
        {
            fillBufferIndex = 0;
        }
        
        bytesFilled = 0;
        packetsFilled = 0;
    }
    pthread_mutex_unlock(&playerMutex);
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    waiting = YES;
    
    while (bufferUsed[fillBufferIndex] && !(seekToTimeWasRequested || self.internalState == AudioPlayerInternalStateStopped || self.internalState == AudioPlayerInternalStateStopping || self.internalState == AudioPlayerInternalStateDisposed))
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
    
    dispatch_async(dispatch_get_main_queue(), ^
                   {
                       [self.delegate audioPlayer:self didEncounterError:errorCode];
                   });
}

-(void) createAudioQueue
{
	OSStatus error;
	
	[self startSystemBackgroundTask];
	
    if (audioQueue)
    {
        AudioQueueStop(audioQueue, YES);
        AudioQueueDispose(audioQueue, YES);
        
        audioQueue = nil;
    }
    
    OSSpinLockLock(&currentlyPlayingLock);
    currentAudioStreamBasicDescription = currentlyPlayingEntry->audioStreamBasicDescription;
    OSSpinLockUnlock(&currentlyPlayingLock);
    
    error = AudioQueueNewOutput(&currentlyPlayingEntry->audioStreamBasicDescription, AudioQueueOutputCallbackProc, (__bridge void*)self, NULL, NULL, 0, &audioQueue);
    
    if (error)
    {
        return;
    }
    
    error = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, AudioQueueIsRunningCallbackProc, (__bridge void*)self);
    
    if (error)
    {
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
            return;
        }
    }
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    
    // Get file cookie/magic bytes information
    
	UInt32 cookieSize;
	Boolean writable;
    
	error = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
    
	if (error)
	{
		return;
	}
    
	void* cookieData = calloc(1, cookieSize);
    
	error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
    
	if (error)
	{
        free(cookieData);
        
		return;
	}
    
	error = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
    
	if (error)
	{
        free(cookieData);
        
		return;
	}
    
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
    
    // Reset metering enabled in case the user set it before the queue was created
    
    [self setMeteringEnabled:meteringEnabled];
    
    free(cookieData);
}

-(double) duration
{
    if (newFileToPlay)
    {
        return 0;
    }
    
    OSSpinLockLock(&currentlyPlayingLock);
    
    QueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
		OSSpinLockUnlock(&currentlyPlayingLock);
        
        return 0;
    }
    
    double retval = [entry duration];
    
	OSSpinLockUnlock(&currentlyPlayingLock);
    
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
    
    OSSpinLockLock(&currentlyPlayingLock);
    
    QueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
    	OSSpinLockUnlock(&currentlyPlayingLock);
        
        return 0;
    }
    
    double retval = [entry progress];
    
    OSSpinLockUnlock(&currentlyPlayingLock);
    
    return retval;
}

-(void) wakeupPlaybackThread
{
	NSRunLoop* runLoop = playbackThreadRunLoop;
	
    if (runLoop)
    {
        CFRunLoopPerformBlock([runLoop getCFRunLoop], NSDefaultRunLoopMode, ^
                              {
                                  [self processRunloop];
                              });
        
        CFRunLoopWakeUp([runLoop getCFRunLoop]);
    }
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (waiting)
    {
        pthread_cond_signal(&queueBufferReadyCondition);
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
    
}

-(void) seekToTime:(double)value
{
    pthread_mutex_lock(&playerMutex);
    {
		BOOL seekAlreadyRequested = seekToTimeWasRequested;
		
        seekToTimeWasRequested = YES;
        requestedSeekTime = value;
        
        if (!seekAlreadyRequested)
        {
            [self wakeupPlaybackThread];
        }
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) processQueue:(BOOL)skipCurrent
{
	if (playbackThread == nil)
	{
		newFileToPlay = YES;
		
		playbackThread = [[NSThread alloc] initWithTarget:self selector:@selector(startInternal) object:nil];
		
		[playbackThread start];
		
		[self wakeupPlaybackThread];
	}
	else
	{
		if (skipCurrent)
		{
			newFileToPlay = YES;
			
			[self resetAudioQueueWithReason:@"from skipCurrent"];
		}
		
		[self wakeupPlaybackThread];
	}
}

-(void) setCurrentlyReadingEntry:(QueueEntry*)entry andStartPlaying:(BOOL)startPlaying
{
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (startPlaying)
    {
        if (audioQueue)
        {
            pthread_mutex_unlock(&queueBuffersMutex);
            
            [self resetAudioQueueWithReason:@"from setCurrentlyReadingEntry"];
            
            pthread_mutex_lock(&queueBuffersMutex);
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
    
    currentlyReadingEntry = entry;
    currentlyReadingEntry.dataSource.delegate = self;
    
    if (currentlyReadingEntry.dataSource.position != 0)
    {
        [currentlyReadingEntry.dataSource seekToOffset:0];
    }
    
    [currentlyReadingEntry.dataSource registerForEvents:[NSRunLoop currentRunLoop]];
    
    if (startPlaying)
    {
        [bufferingQueue removeAllObjects];
        
        [self processDidFinishPlaying:currentlyPlayingEntry withNext:entry];
    }
    else
    {
        [bufferingQueue enqueue:entry];
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) audioQueueFinishedPlaying:(QueueEntry*)entry
{
    pthread_mutex_lock(&playerMutex);
    {
        pthread_mutex_lock(&queueBuffersMutex);
        {
            QueueEntry* next = [bufferingQueue dequeue];
            
            [self processDidFinishPlaying:entry withNext:next];
        }
        pthread_mutex_unlock(&queueBuffersMutex);
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) processDidFinishPlaying:(QueueEntry*)entry withNext:(QueueEntry*)next
{
    if (entry != currentlyPlayingEntry)
    {
        return;
    }
    
    NSObject* queueItemId = entry.queueItemId;
    double progress = [entry progress];
    double duration = [entry duration];
    
    BOOL nextIsDifferent = currentlyPlayingEntry != next;
    
    if (next)
    {
        if (nextIsDifferent)
        {
            next->seekTime = 0;
            
            seekToTimeWasRequested = NO;
        }
        
        OSSpinLockLock(&currentlyPlayingLock);
        currentlyPlayingEntry = next;
        currentlyPlayingEntry->bytesPlayed = 0;
        NSObject* playingQueueItemId = playingQueueItemId = currentlyPlayingEntry.queueItemId;
        OSSpinLockUnlock(&currentlyPlayingLock);
        
        if (nextIsDifferent && entry)
        {
            dispatch_async(dispatch_get_main_queue(), ^
                           {
                               [self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
                           });
        }
        
        if (nextIsDifferent)
        {
            dispatch_async(dispatch_get_main_queue(), ^
                           {
                               [self.delegate audioPlayer:self didStartPlayingQueueItemId:playingQueueItemId];
                           });
        }
    }
    else
    {
        OSSpinLockLock(&currentlyPlayingLock);
		currentlyPlayingEntry = nil;
        OSSpinLockUnlock(&currentlyPlayingLock);
        
        if (currentlyReadingEntry == nil)
        {
			if (upcomingQueue.count == 0)
			{
				stopReason = AudioPlayerStopReasonNoStop;
				self.internalState = AudioPlayerInternalStateStopping;
			}
        }
        
        if (nextIsDifferent && entry)
        {
            dispatch_async(dispatch_get_main_queue(), ^
                           {
                               [self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
                           });
        }
    }
}

-(BOOL) processRunloop
{
    pthread_mutex_lock(&playerMutex);
    {
        if (self.internalState == AudioPlayerInternalStatePaused)
        {
            pthread_mutex_unlock(&playerMutex);
            
            return YES;
        }
        else if (newFileToPlay)
        {
            QueueEntry* entry = [upcomingQueue dequeue];
            
            self.internalState = AudioPlayerInternalStateWaitingForData;
            
            [self setCurrentlyReadingEntry:entry andStartPlaying:YES];
            
            newFileToPlay = NO;
        }
        else if (seekToTimeWasRequested && currentlyPlayingEntry && currentlyPlayingEntry != currentlyReadingEntry)
        {
            currentlyPlayingEntry.bufferIndex = -1;
            [self setCurrentlyReadingEntry:currentlyPlayingEntry andStartPlaying:YES];
            
            currentlyReadingEntry->parsedHeader = NO;
            [currentlyReadingEntry.dataSource seekToOffset:0];
        }
        else if (self.internalState == AudioPlayerInternalStateStopped && stopReason == AudioPlayerStopReasonUserAction)
        {
            [self stopAudioQueueWithReason:@"from processRunLoop/1"];
            
            currentlyReadingEntry.dataSource.delegate = nil;
            [currentlyReadingEntry.dataSource unregisterForEvents];
            [currentlyReadingEntry.dataSource close];
            
            if (currentlyPlayingEntry)
            {
                [self processDidFinishPlaying:currentlyPlayingEntry withNext:nil];
            }
            
            pthread_mutex_lock(&queueBuffersMutex);
            
            if ([bufferingQueue peek] == currentlyPlayingEntry)
            {
                [bufferingQueue dequeue];
            }
            
            OSSpinLockLock(&currentlyPlayingLock);
			currentlyPlayingEntry = nil;
            OSSpinLockUnlock(&currentlyPlayingLock);
            
            currentlyReadingEntry = nil;
            seekToTimeWasRequested = NO;
            
            pthread_mutex_unlock(&queueBuffersMutex);
        }
        else if (self.internalState == AudioPlayerInternalStateStopped && stopReason == AudioPlayerStopReasonUserActionFlushStop)
        {
            currentlyReadingEntry.dataSource.delegate = nil;
            [currentlyReadingEntry.dataSource unregisterForEvents];
            [currentlyReadingEntry.dataSource close];
            
            if (currentlyPlayingEntry)
            {
                [self processDidFinishPlaying:currentlyPlayingEntry withNext:nil];
            }
            
            pthread_mutex_lock(&queueBuffersMutex);
            
            if ([bufferingQueue peek] == currentlyPlayingEntry)
            {
                [bufferingQueue dequeue];
            }
            
            OSSpinLockLock(&currentlyPlayingLock);
			currentlyPlayingEntry = nil;
            OSSpinLockUnlock(&currentlyPlayingLock);
            
            currentlyReadingEntry = nil;
            pthread_mutex_unlock(&queueBuffersMutex);
            
            [self resetAudioQueueWithReason:@"from processRunLoop"];
        }
        else if (currentlyReadingEntry == nil)
        {
            BOOL nextIsIncompatible = NO;
            
            QueueEntry* next = [bufferingQueue peek];
            
            if (next == nil)
            {
                next = [upcomingQueue peek];
                
                if (next)
                {
                    if (next->audioStreamBasicDescription.mSampleRate != 0)
                    {
                        if (memcmp(&next->audioStreamBasicDescription, &currentAudioStreamBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
                        {
                            nextIsIncompatible = YES;
                        }
                    }
                }
            }
            
            if (nextIsIncompatible && currentlyPlayingEntry != nil)
            {
                // Holding off cause next is incompatible
            }
            else
            {
                if (upcomingQueue.count > 0)
                {
                    QueueEntry* entry = [upcomingQueue dequeue];
                    
                    BOOL startPlaying = currentlyPlayingEntry == nil;
                    BOOL wasCurrentlyPlayingNothing = currentlyPlayingEntry == nil;
                    
                    [self setCurrentlyReadingEntry:entry andStartPlaying:startPlaying];
                    
                    if (wasCurrentlyPlayingNothing)
                    {
                        [self setInternalState:AudioPlayerInternalStateWaitingForData];
                    }
                }
                else if (currentlyPlayingEntry == nil)
                {
                    if (self.internalState != AudioPlayerInternalStateStopped)
                    {
                        [self stopAudioQueueWithReason:@"from processRunLoop/2"];
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
    }
    pthread_mutex_unlock(&playerMutex);
    
    if (currentlyReadingEntry && currentlyReadingEntry->parsedHeader && currentlyReadingEntry != currentlyPlayingEntry)
    {
        if (currentAudioStreamBasicDescription.mSampleRate != 0)
        {
            if (memcmp(&currentAudioStreamBasicDescription, &currentlyReadingEntry->audioStreamBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
            {
                [currentlyReadingEntry.dataSource unregisterForEvents];
                
                if ([bufferingQueue peek] == currentlyReadingEntry)
                {
                    [bufferingQueue dequeue];
                }
                
                QueueEntry* newEntry = [[QueueEntry alloc] initWithDataSource:currentlyReadingEntry.dataSource andQueueItemId:currentlyReadingEntry.queueItemId];
                
                newEntry->audioStreamBasicDescription = currentlyReadingEntry->audioStreamBasicDescription;
                
                [upcomingQueue skipQueue:newEntry];
                
                OSSpinLockLock(&currentlyPlayingLock);
                currentlyReadingEntry = nil;
                OSSpinLockUnlock(&currentlyPlayingLock);
            }
        }
    }
    
    if (currentlyPlayingEntry && currentlyPlayingEntry->parsedHeader)
    {
        if (seekToTimeWasRequested && currentlyReadingEntry == currentlyPlayingEntry)
        {
            [self processSeekToTime];
			
            seekToTimeWasRequested = NO;
        }
    }
    
    return YES;
}

-(void) startInternal
{
	@autoreleasepool
	{
		playbackThreadRunLoop = [NSRunLoop currentRunLoop];
		
		NSThread.currentThread.threadPriority = 1;
		
		bytesFilled = 0;
		packetsFilled = 0;
		
		[playbackThreadRunLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
        
		while (true)
		{
			if (![self processRunloop])
			{
				break;
			}
            
			NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:10];
			[playbackThreadRunLoop runMode:NSDefaultRunLoopMode beforeDate:date];
		}
		
		disposeWasRequested = NO;
		seekToTimeWasRequested = NO;
		
		currentlyReadingEntry.dataSource.delegate = nil;
		currentlyPlayingEntry.dataSource.delegate = nil;
		
		currentlyReadingEntry = nil;
        
        pthread_mutex_lock(&playerMutex);
        OSSpinLockLock(&currentlyPlayingLock);
		currentlyPlayingEntry = nil;
        OSSpinLockUnlock(&currentlyPlayingLock);
        pthread_mutex_unlock(&playerMutex);
		
		self.internalState = AudioPlayerInternalStateDisposed;
		
		[threadFinishedCondLock lock];
		[threadFinishedCondLock unlockWithCondition:1];
	}
}

-(void) processSeekToTime
{
	OSStatus error;
    OSSpinLockLock(&currentlyPlayingLock);
    QueueEntry* currentEntry = currentlyReadingEntry;
    OSSpinLockUnlock(&currentlyPlayingLock);
    
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
    
    currentEntry->seekTime = requestedSeekTime;
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
            
            currentEntry->seekTime -= delta;
            
            seekByteOffset = packetAlignedByteOffset + currentEntry->audioDataOffset;
        }
    }
    
    [currentEntry updateAudioDataSource];
    [currentEntry.dataSource seekToOffset:seekByteOffset];
    
    if (seekByteOffset > 0)
    {
        discontinuous = YES;
    }
    
    if (audioQueue)
    {
        [self resetAudioQueueWithReason:@"from seekToTime"];
    }
    
    if (currentEntry)
    {
        currentEntry->bytesPlayed = 0;
    }
}

-(BOOL) startAudioQueue
{
	OSStatus error;
    
    self.internalState = AudioPlayerInternalStateWaitingForQueueToStart;
    
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1);
    
    error = AudioQueueStart(audioQueue, NULL);
    
    if (error)
    {
		if (backgroundTaskId == UIBackgroundTaskInvalid)
		{
			[self startSystemBackgroundTask];
		}
		
        [self stopAudioQueueWithReason:@"from startAudioQueue"];
        [self createAudioQueue];
        
        self.internalState = AudioPlayerInternalStateWaitingForQueueToStart;
        
        AudioQueueStart(audioQueue, NULL);
    }
	
	[self stopSystemBackgroundTask];
    
    return YES;
}

-(void) stopAudioQueueWithReason:(NSString*)reason
{
	OSStatus error;
	
	if (!audioQueue)
    {
        [self logInfo:[@"stopAudioQueue/1 " stringByAppendingString:reason]];
        
        self.internalState = AudioPlayerInternalStateStopped;
        
        return;
    }
    else
    {
        [self logInfo:[@"stopAudioQueue/2 " stringByAppendingString:reason]];
        
        audioQueueFlushing = YES;
        
        error = AudioQueueStop(audioQueue, true);
        error = error | AudioQueueDispose(audioQueue, true);
        
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
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    audioQueueFlushing = NO;
    
    self.internalState = AudioPlayerInternalStateStopped;
}

-(void) resetAudioQueueWithReason:(NSString*)reason
{
	OSStatus error;
    
    [self logInfo:[@"resetAudioQueue/1 " stringByAppendingString:reason]];
    
    pthread_mutex_lock(&playerMutex);
    {
        audioQueueFlushing = YES;
        
        if (audioQueue)
        {
            error = AudioQueueReset(audioQueue);
            
            if (error)
            {
                dispatch_async(dispatch_get_main_queue(), ^
                               {
                                   [self didEncounterError:AudioPlayerErrorQueueStopFailed];;
                               });
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
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry->lastProgress = 0;
    }
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    audioQueueFlushing = NO;
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) dataSourceDataAvailable:(DataSource*)dataSourceIn
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
    
    error = AudioFileStreamParseBytes(audioFileStream, read, readBuffer, flags);
    
    if (error)
    {
        if (dataSourceIn == currentlyPlayingEntry.dataSource)
        {
            [self didEncounterError:AudioPlayerErrorStreamParseBytesFailed];
        }
        
        return;
    }
}

-(void) dataSourceErrorOccured:(DataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    [self didEncounterError:AudioPlayerErrorDataNotFound];
}

-(void) dataSourceEof:(DataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    if (bytesFilled)
    {
        [self enqueueBuffer];
    }
    
    [self logInfo:[NSString stringWithFormat:@"dataSourceEof for dataSource: %@", dataSourceIn]];
    
    NSObject* queueItemId = currentlyReadingEntry.queueItemId;
    
    dispatch_async(dispatch_get_main_queue(), ^
                   {
                       [self.delegate audioPlayer:self didFinishBufferingSourceWithQueueItemId:queueItemId];
                   });
    
    pthread_mutex_lock(&playerMutex);
    {
        if (audioQueue)
        {
            currentlyReadingEntry.bufferIndex = audioPacketsReadCount;
            currentlyReadingEntry = nil;
            
            if (self.internalState == AudioPlayerInternalStatePlaying)
            {
                if (audioQueue)
                {
                    if (![self audioQueueIsRunning])
                    {
                        [self logInfo:@"startAudioQueue from dataSourceEof"];
                        
                        [self startAudioQueue];
                    }
                }
            }
        }
        else
        {
            stopReason = AudioPlayerStopReasonEof;
            self.internalState = AudioPlayerInternalStateStopped;
        }
    }
    pthread_mutex_unlock(&playerMutex);
}

-(void) pause
{
    pthread_mutex_lock(&playerMutex);
    {
		OSStatus error;
        
        if (self.internalState != AudioPlayerInternalStatePaused)
        {
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
            self.internalState = AudioPlayerInternalStatePlaying;
            
            if (seekToTimeWasRequested)
            {
                [self resetAudioQueueWithReason:@"from resume"];
            }
            
            error = AudioQueueStart(audioQueue, 0);
            
            if (error)
            {
                [self didEncounterError:AudioPlayerErrorQueueStartFailed];
                
                pthread_mutex_unlock(&playerMutex);
                
                return;
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
    
    pthread_mutex_lock(&playerMutex);
    {
        disposeWasRequested = YES;
        
        if (playbackThread && playbackThreadRunLoop)
        {
            wait = YES;
            
            CFRunLoopStop([playbackThreadRunLoop getCFRunLoop]);
        }
    }
    pthread_mutex_unlock(&playerMutex);
    
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
    OSSpinLockLock(&currentlyPlayingLock);
    
    QueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
        OSSpinLockUnlock(&currentlyPlayingLock);
        
        return nil;
    }
    
    NSObject* retval = entry.queueItemId;
    
    OSSpinLockUnlock(&currentlyPlayingLock);
    
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
    
    NSInteger channels = currentAudioStreamBasicDescription.mChannelsPerFrame;
    
    if (numberOfChannels != channels)
    {
        numberOfChannels = channels;
        
        if (levelMeterState) free(levelMeterState);
        {
            levelMeterState = malloc(sizeof(AudioQueueLevelMeterState) * numberOfChannels);
        }
    }
    
    UInt32 sizeofMeters = sizeof(AudioQueueLevelMeterState) * numberOfChannels;
    
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
