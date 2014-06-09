//
//  STKMediaLibraryFileDataSource.m
//  StreamingKit
//
//  Created by Andrey Ryabov on 09.06.14.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKMediaLibraryFileDataSource.h"
#import <AVFoundation/AVFoundation.h>
@interface STKMediaLibraryFileDataSource()
{
    NSMutableData *_trackData;
    SInt64 position;
    SInt64 length;
//    AudioFileTypeID audioFileTypeHint;
}
@property (readwrite, copy) NSString* filePath;
-(void) open;
@end



@implementation STKMediaLibraryFileDataSource

@synthesize mediaURL;

-(id) initWithMediaURL:(NSURL *)url
{
    if (self = [super init])
    {
        self.mediaURL = url;
        _trackData = [NSMutableData new];
//        audioFileTypeHint = [STKMediaLibraryFileDataSource audioFileTypeHintFromFileExtension:filePathIn.pathExtension];
    }
    
    return self;
}

//+(AudioFileTypeID) audioFileTypeHintFromFileExtension:(NSString*)fileExtension
//{
//    static dispatch_once_t onceToken;
//    static NSDictionary* fileTypesByFileExtensions;
//    
//    dispatch_once(&onceToken, ^
//                  {
//                      fileTypesByFileExtensions =
//                      @{
//                        @"mp3": @(kAudioFileMP3Type),
//                        @"wav": @(kAudioFileWAVEType),
//                        @"aifc": @(kAudioFileAIFCType),
//                        @"aiff": @(kAudioFileAIFFType),
//                        @"m4a": @(kAudioFileM4AType),
//                        @"mp4": @(kAudioFileMPEG4Type),
//                        @"caf": @(kAudioFileCAFType),
//                        @"aac": @(kAudioFileAAC_ADTSType),
//                        @"ac3": @(kAudioFileAC3Type),
//                        @"3gp": @(kAudioFile3GPType)
//                        };
//                  });
//    
//    NSNumber* number = [fileTypesByFileExtensions objectForKey:fileExtension];
//    
//    if (!number)
//    {
//        return 0;
//    }
//    
//    return (AudioFileTypeID)number.intValue;
//}

-(AudioFileTypeID) audioFileTypeHint
{
    return 0;
}

-(void) dealloc
{
    [self close];
}

-(void) close
{
    if (stream)
    {
        [self unregisterForEvents];
        CFReadStreamClose(stream);
        _trackData = nil;
        stream = 0;
    }
}

-(void) open
{
    if (stream)
    {
        [self unregisterForEvents];
        
        CFReadStreamClose(stream);
        CFRelease(stream);
        
        stream = 0;
    }
    
    NSURL* url = self.mediaURL;
    
//    const uint32_t sampleRate = 16000; // 16k sample/sec
//    const uint16_t bitDepth = 16; // 16 bit/sample/channel
//    const uint16_t channels = 2; // 2 channel/sample (stereo)
    
//    NSDictionary *opts = [NSDictionary dictionary];
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:NULL];
//    NSDictionary *settings = [NSDictionary dictionaryWithObjectsAndKeys:
//                              [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
//                              [NSNumber numberWithFloat:(float)sampleRate], AVSampleRateKey,
//                              [NSNumber numberWithInt:bitDepth], AVLinearPCMBitDepthKey,
//                              [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
//                              [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
//                              [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey, settings];
    
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:[[asset tracks] objectAtIndex:0] outputSettings:nil];
    [reader addOutput:output];
    [reader startReading];
    _trackData = [NSMutableData new];
    // read the samples from the asset and append them subsequently
    while ([reader status] != AVAssetReaderStatusCompleted) {
        CMSampleBufferRef buffer = [output copyNextSampleBuffer];
        if (buffer == NULL) continue;
        
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(buffer);
        size_t size = CMBlockBufferGetDataLength(blockBuffer);
        uint8_t *outBytes = malloc(size);
        CMBlockBufferCopyDataBytes(blockBuffer, 0, size, outBytes);
        CMSampleBufferInvalidate(buffer);
        CFRelease(buffer);
        [_trackData appendBytes:outBytes length:size];
        free(outBytes);
    }

    
    const UInt8 *bytes = (const UInt8 *)[_trackData bytes];
    length = CMTimeGetSeconds(asset.duration);
    CFIndex len = [_trackData length];
    
    stream = CFReadStreamCreateWithBytesNoCopy(NULL, bytes, (CFIndex)len, kCFAllocatorNull);
    
//    NSError* fileError;
//    NSFileManager* manager = [[NSFileManager alloc] init];
////    NSDictionary* attributes = [manager attributesOfItemAtPath:filePath error:&fileError];
//    
//    if (fileError)
//    {
//        CFReadStreamClose(stream);
//        CFRelease(stream);
//        stream = 0;
//        return;
//    }
    
//    NSNumber* number = [attributes objectForKey:@"NSFileSize"];
    
//    if (number)
//    {
//        length = number.longLongValue;
//    }
    
    [self reregisterForEvents];
    
    CFReadStreamOpen(stream);
}

-(SInt64) position
{
    return position;
}

-(SInt64) length
{
    return length;
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    int retval = (int)CFReadStreamRead(stream, buffer, size);
    
    if (retval > 0)
    {
        position += retval;
    }
    else
    {
        NSNumber* property = (__bridge_transfer NSNumber*)CFReadStreamCopyProperty(stream, kCFStreamPropertyFileCurrentOffset);
        
        position = property.longLongValue;
    }
    
    return retval;
}

-(void) seekToOffset:(SInt64)offset
{
    CFStreamStatus status = kCFStreamStatusClosed;
    
    if (stream != 0)
    {
		status = CFReadStreamGetStatus(stream);
    }
    
    BOOL reopened = NO;
    
    if (status == kCFStreamStatusAtEnd || status == kCFStreamStatusClosed || status == kCFStreamStatusError)
    {
        reopened = YES;
        
        [self close];
        [self open];
    }
    
    if (stream == 0)
    {
        CFRunLoopPerformBlock(eventsRunLoop.getCFRunLoop, NSRunLoopCommonModes, ^
                              {
                                  [self errorOccured];
                              });
        
        CFRunLoopWakeUp(eventsRunLoop.getCFRunLoop);
        
        return;
    }
    
    if (CFReadStreamSetProperty(stream, kCFStreamPropertyFileCurrentOffset, (__bridge CFTypeRef)[NSNumber numberWithLongLong:offset]) != TRUE)
    {
        position = 0;
    }
    else
    {
        position = offset;
    }
    
    if (!reopened)
    {
        CFRunLoopPerformBlock(eventsRunLoop.getCFRunLoop, NSRunLoopCommonModes, ^
                              {
                                  if ([self hasBytesAvailable])
                                  {
                                      [self dataAvailable];
                                  }
                              });
        
        CFRunLoopWakeUp(eventsRunLoop.getCFRunLoop);
    }
}

-(NSString*) description
{
    return self->mediaURL.absoluteString;
}

@end
