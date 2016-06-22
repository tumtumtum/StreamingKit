//
//  STKQueueEntry.m
//  StreamingKit
//
//  Created by Thong Nguyen on 30/01/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKQueueEntry.h"
#import "STKDataSource.h"

#define STK_BIT_RATE_ESTIMATION_MIN_PACKETS_MIN (2)
#define STK_BIT_RATE_ESTIMATION_MIN_PACKETS_PREFERRED (64)

///
/// Metadata that is associated with a given frame within a STKQueueEntry.
///
@interface STKQueueEntryMetadataItem : NSObject

@property (readonly) SInt64 frame;
@property (readonly, copy) NSDictionary *metadata;

-(instancetype) initWithFrame:(SInt64)frame metadata:(NSDictionary *)metadata;

@end

@interface STKQueueEntry()

@property (readwrite, assign) OSSpinLock metadataSpinLock;
@property (readwrite, strong) NSMutableArray *sortedMetadataItems;
// Working data structures to avoid allocations during -removeMetadataDictionariesStartingAtFrame:length:
@property (readwrite, strong) NSMutableArray *workingMetadataBuffer;
@property (readwrite, strong) NSMutableIndexSet *workingMetadataIndexes;

@end

@implementation STKQueueEntry

-(instancetype) initWithDataSource:(STKDataSource*)dataSourceIn andQueueItemId:(NSObject*)queueItemIdIn
{
    if (self = [super init])
    {
        self->spinLock = OS_SPINLOCK_INIT;
        self.metadataSpinLock = OS_SPINLOCK_INIT;
        
        self.dataSource = dataSourceIn;
        self.queueItemId = queueItemIdIn;
        self->lastFrameQueued = -1;
        self->durationHint = dataSourceIn.durationHint;
        self.sortedMetadataItems = [[NSMutableArray alloc] init];
        self.workingMetadataBuffer = [[NSMutableArray alloc] init];
        self.workingMetadataIndexes = [[NSMutableIndexSet alloc] init];
    }
    
    return self;
}

-(void) reset
{
    OSSpinLockLock(&self->spinLock);
    self->framesQueued = 0;
    self->framesPlayed = 0;
    self->lastFrameQueued = -1;
    OSSpinLockUnlock(&self->spinLock);
    
    OSSpinLockLock(&self->_metadataSpinLock);
    
    [self.sortedMetadataItems removeAllObjects];
    [self.workingMetadataBuffer removeAllObjects];
    [self.workingMetadataIndexes removeAllIndexes];
    
    OSSpinLockUnlock(&self->_metadataSpinLock);
}

-(double) calculatedBitRate
{
    double retval;
    
    if (packetDuration > 0)
	{
		if (processedPacketsCount > STK_BIT_RATE_ESTIMATION_MIN_PACKETS_PREFERRED || (audioStreamBasicDescription.mBytesPerFrame == 0 && processedPacketsCount > STK_BIT_RATE_ESTIMATION_MIN_PACKETS_MIN))
		{
			double averagePacketByteSize = (double)processedPacketsSizeTotal / (double)processedPacketsCount;
			
			retval = averagePacketByteSize / packetDuration * 8;
			
			return retval;
		}
	}
	
    retval = (audioStreamBasicDescription.mBytesPerFrame * audioStreamBasicDescription.mSampleRate) * 8;
    
    return retval;
}

-(double) duration
{
    if (durationHint > 0.0) return durationHint;
    
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

-(Float64) progressInFrames
{
    OSSpinLockLock(&self->spinLock);
    Float64 retval = (self->seekTime * self->audioStreamBasicDescription.mSampleRate) + self->framesPlayed;
    OSSpinLockUnlock(&self->spinLock);
    
    return retval;
}

- (NSArray *)sortedMetadata
{
    NSArray *sortedMetadata = nil;
    
    OSSpinLockLock(&self->_metadataSpinLock);
    sortedMetadata = [self.sortedMetadataItems copy];
    OSSpinLockUnlock(&self->_metadataSpinLock);
    
    return sortedMetadata;
}

-(void) addMetadataDictionaryFor:(NSDictionary *)metadata forFrame:(SInt64)frame
{
    OSSpinLockLock(&self->_metadataSpinLock);
    
    STKQueueEntryMetadataItem *queuedMetadata = [[STKQueueEntryMetadataItem alloc] initWithFrame:frame metadata:metadata];
    [self.sortedMetadataItems addObject:queuedMetadata];
    [self.sortedMetadataItems sortUsingComparator:^NSComparisonResult(STKQueueEntryMetadataItem  *lhs, STKQueueEntryMetadataItem *rhs) {
        if (lhs.frame < rhs.frame) {
            return NSOrderedAscending;
        } else if (lhs.frame > rhs.frame) {
            return NSOrderedDescending;
        } else {
            return NSOrderedSame;
        }
    }];
    
    OSSpinLockUnlock(&self->_metadataSpinLock);
}

-(NSArray *) removeMetadataDictionariesStartingAtFrame:(SInt64)frame length:(SInt64)length
{
    NSArray *result = nil;
    OSSpinLockLock(&self->_metadataSpinLock);
    
    NSInteger count = self.sortedMetadataItems.count;
    for (int i = 0; i < count; ++i)
    {
        STKQueueEntryMetadataItem *metadataItem = self.sortedMetadataItems[i];
        
        if (metadataItem.frame < frame)
        {
            continue;
        }
        else if (metadataItem.frame >= (frame + length))
        {
            // Array is sorted, so no more frames will fall in the range.
            break;
        }
        
        [self.workingMetadataIndexes addIndex:i];
        [self.workingMetadataBuffer addObject:metadataItem.metadata];
    }
    
    if (self.workingMetadataIndexes.count > 0) {
        [self.sortedMetadataItems removeObjectsAtIndexes:self.workingMetadataIndexes];
        result = [self.workingMetadataBuffer copy];
        [self.workingMetadataBuffer removeAllObjects];
        [self.workingMetadataIndexes removeAllIndexes];
    }
    
    OSSpinLockUnlock(&self->_metadataSpinLock);
    
    return result;
}

-(NSString*) description
{
    return [[self queueItemId] description];
}

@end

@implementation STKQueueEntryMetadataItem

- (instancetype) initWithFrame:(SInt64)frame metadata:(NSDictionary *)metadata
{
    if (self = [super init])
    {
        self->_frame = frame;
        self->_metadata = [metadata copy];
    }
    
    return self;
}

@end
