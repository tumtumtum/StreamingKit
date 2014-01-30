//
//  STKQueueEntry.h
//  StreamingKit
//
//  Created by Thong Nguyen on 30/01/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKDataSource.h"
#import "AudioToolbox/AudioToolbox.h"

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
-(void) updateAudioDataSource;
-(BOOL) isDefinitelyCompatible:(AudioStreamBasicDescription*)basicDescription;
-(BOOL) isKnownToBeIncompatible:(AudioStreamBasicDescription*)basicDescription;
-(BOOL) couldBeIncompatible:(AudioStreamBasicDescription*)basicDescription;
-(Float64) calculateProgressWithTotalFramesPlayed:(Float64)framesPlayed;

-(id) initWithDataSource:(STKDataSource*)dataSource andQueueItemId:(NSObject*)queueItemId;

@end