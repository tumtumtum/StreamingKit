//
//  AudioDownloader.m
//  Radio
//
//  Created by Trey Tartt on 8/9/14.
//  Copyright (c) 2014 Trey Tartt. All rights reserved.
//

#import "AudioDownloader.h"


#define numberOfOldUrls 15
#define defaultCallDelay 10

@implementation AudioDownloader

+ (id)AudioDownloaderItem {
	static AudioDownloader *sharedMyManager = nil;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		sharedMyManager = [[self alloc] init];
	});
	return sharedMyManager;
}

- (id)init {
	if (self = [super init]) {
	}
	return self;
}

- (void)dealloc {
	// Should never be called, but just here for clarity really.
}

- (void)clearData {
	if (!_addedAudioPackets)
		_addedAudioPackets = [[NSMutableArray alloc] init];

	[self.addedAudioPackets removeAllObjects];

	[_dataTask cancel];
}

/*
   get the url to stream from the m3u file
   and queue to audio player
 */
- (void)getM3uURLAndPlay:(NSString *)url {
	_dataTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url]
	                                        completionHandler : ^(NSData *data,
	                                                              NSURLResponse *response,
	                                                              NSError *error) {
	    if (error) {
	        NSLog(@"error %@", [error description]);
	        return;
		}
	    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	    NSArray *lines = [string componentsSeparatedByString:@"\r\n"];
	    NSMutableArray *newFiles = [[NSMutableArray alloc] init];

	    for (NSString *aLine in lines) {
	        if ([aLine rangeOfString:@"http"].location != NSNotFound && [aLine rangeOfString:@"EXTINF"].location == NSNotFound) {
	            [newFiles addObject:aLine];
			}
		}

	    /*
	       add the url returned from the m3u
	     */
	    if ([newFiles count] > 0) {
	        for (NSString *aFile in newFiles) {
	            if (![self.addedAudioPackets containsObject:aFile]) {
	                [[STKAudioPlayer Player] queue:aFile];
	                [self.addedAudioPackets insertObject:aFile atIndex:0];
				}
			}
		}
	}];
	[_dataTask resume];
}

/*
    creates session and fetches the aac files
    from that session url
 */
- (void)createM3u8Session:(NSString *)url {
	[[STKAudioPlayer Player] stop];
	[[STKAudioPlayer Player] clearQueue];

	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url]];

	[NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler: ^(NSURLResponse *response, NSData *data, NSError *error) {
	    if (data) {
	        NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	        NSArray *lines = [string componentsSeparatedByString:@"\r\n"];
	        NSString *url;
	        for (NSString *aLine in lines) {
	            if ([aLine rangeOfString:@"http"].location != NSNotFound) {
	                url = aLine;
	                break;
				}
			}

	        if (url) {
	            [self getAACFilesForm_m3u8:url];
			}
		}
	}];
}

/*
    fetch aac files from a m3u8 file
 */
- (void)getAACFilesForm_m3u8:(NSString *)urlStr {
	_dataTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlStr]
	                                        completionHandler : ^(NSData *data,
	                                                              NSURLResponse *response,
	                                                              NSError *error) {
	    if (error) {
	        NSLog(@"error %@", [error description]);
	        return;
		}
	    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	    [self parseFile:string:urlStr];
	}];

	[_dataTask resume];
}

/*
    parses return for http audio segments and
    queues next call to fetch audio segments
 */
- (void)parseFile:(NSString *)fileString:(NSString *)urlStr {
	NSArray *lines = [fileString componentsSeparatedByString:@"\r\n"];
	NSMutableArray *newFiles = [[NSMutableArray alloc] init];

	int nextCallDelay = defaultCallDelay;

	for (NSString *aLine in lines) {
		if ([aLine rangeOfString:@"http"].location != NSNotFound && [aLine rangeOfString:@"EXTINF"].location == NSNotFound) {
			[newFiles addObject:aLine];
		}
		else if ([aLine rangeOfString:@"TARGETDURATION"].location != NSNotFound) {
			NSString *delayStr = [aLine substringFromIndex:[aLine rangeOfString:@":"].location + 1];
			nextCallDelay = [delayStr intValue];
		}
	}

	/*
	    subtract 2 second from the next call to
	    take into account for network delay
	 */
	nextCallDelay = nextCallDelay - 2;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextCallDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self getAACFilesForm_m3u8:urlStr];
	});

	NSLog(@"added new files %lu", (unsigned long)newFiles.count);

	/*
	   add the audio pakcets if they're not in our addedAudioPackets cache
	 */
	if ([newFiles count] > 0) {
		for (NSString *aFile in newFiles) {
			if (![self.addedAudioPackets containsObject:aFile]) {
				[[STKAudioPlayer Player] queue:aFile];
				[self.addedAudioPackets insertObject:aFile atIndex:0];
			}
		}
	}

	/*
	   delete the oldes files if we're over our buffer size
	 */
	if ([self.addedAudioPackets count] > numberOfOldUrls) {
		int end = (int)[self.addedAudioPackets count] - numberOfOldUrls;
		int start = numberOfOldUrls;
		[self.addedAudioPackets removeObjectsInRange:NSMakeRange(start, end)];
	}
}

@end
