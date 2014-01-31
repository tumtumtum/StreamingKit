//
//  STKQueueEntry.h
//  StreamingKit
//
//  Created by Thong Nguyen on 30/01/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKDataSource.h"
#import "libkern/OSAtomic.h"
#import "AudioToolbox/AudioToolbox.h"

@interface STKQueueEntry : NSObject
{
@public
    OSSpinLock spinLock;
    
    BOOL parsedHeader;
    Float64 sampleRate;
    double packetDuration;
    UInt64 audioDataOffset;
    UInt64 audioDataByteCount;
    UInt32 packetBufferSize;
    volatile Float64 seekTime;
    volatile int64_t framesQueued;
    volatile int64_t framesPlayed;
    volatile int64_t lastFrameQueued;
    volatile int processedPacketsCount;
	volatile int processedPacketsSizeTotal;
    AudioStreamBasicDescription audioStreamBasicDescription;
}

@property (readonly) UInt64 audioDataLengthInBytes;
@property (readwrite, retain) NSObject* queueItemId;
@property (readwrite, retain) STKDataSource* dataSource;

-(id) initWithDataSource:(STKDataSource*)dataSource andQueueItemId:(NSObject*)queueItemId;

-(void) reset;
-(double) duration;
-(Float64) progressInFrames;
-(double) calculatedBitRate;
-(void) updateAudioDataSource;
-(BOOL) isDefinitelyCompatible:(AudioStreamBasicDescription*)basicDescription;

@end