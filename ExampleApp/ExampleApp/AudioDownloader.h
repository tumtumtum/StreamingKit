//
//  AudioDownloader.h
//  Radio
//
//  Created by Trey Tartt on 8/9/14.
//  Copyright (c) 2014 Trey Tartt. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "STKAudioPlayer.h"

@interface AudioDownloader : NSObject
@property (nonatomic, retain) NSMutableArray *addedAudioPackets;
@property (nonatomic, retain) NSURLSessionDataTask *dataTask;
@property (nonatomic, retain) STKAudioPlayer *audioPlayer;
@property (nonatomic, retain) NSString *currentStreamLocation;

- (void)clearData;

- (void)playLocation:(NSString *)streamLocation;

/*
   creates session and fetches the aac files
   from that session url
 */
- (void)createM3u8Session:(NSString *)url;

/*
   get the url to stream from the m3u file
   and queue to audio player
 */
- (void)getM3uURLAndPlay:(NSString *)url;
@end
