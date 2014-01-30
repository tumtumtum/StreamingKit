//
//  STKQueueEntry.m
//  StreamingKit
//
//  Created by Thong Nguyen on 30/01/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKQueueEntry.h"
#import "STKDataSource.h"

#define STK_BIT_RATE_ESTIMATION_MIN_PACKETS (64)

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

-(Float64) calculateProgressWithTotalFramesPlayed:(Float64)framesPlayedIn
{
    return (Float64)self.seekTime + ((framesPlayedIn - self.firstFrameIndex) / (Float64)self->audioStreamBasicDescription.mSampleRate);
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