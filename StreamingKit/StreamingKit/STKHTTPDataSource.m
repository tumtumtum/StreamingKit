/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/audjustable
 
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
 
 THIS SOFTWARE IS PROVIDED BY Thong Nguyen ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THONG NGUYEN BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **********************************************************************************/

#import "STKHTTPDataSource.h"
#import "STKLocalFileDataSource.h"

@interface STKHTTPDataSource()
{
@private
    UInt32 httpStatusCode;
    SInt64 seekStart;
    SInt64 relativePosition;
    SInt64 fileLength;
    int discontinuous;
	int requestSerialNumber;

    NSURL* currentUrl;
    STKAsyncURLProvider asyncUrlProvider;
    NSDictionary* httpHeaders;
    AudioFileTypeID audioFileTypeHint;
    NSDictionary* requestHeaders;
    
    // Meta data
    BOOL metaDataPresent;
    unsigned int metaDataInterval;        // how many data bytes between meta data
    unsigned int metaDataBytesRemaining;  // how many bytes of metadata remain to be read
    unsigned int dataBytesRead;           // how many bytes of data have been read
    BOOL foundIcyStart;
    BOOL foundIcyEnd;
    NSMutableString *metaDataString;      //  meta data string
}
-(void) open;

@end

@implementation STKHTTPDataSource

-(id) initWithURL:(NSURL*)urlIn
{
    return [self initWithURLProvider:^NSURL* { return urlIn; }];
}

-(id) initWithURL:(NSURL *)urlIn httpRequestHeaders:(NSDictionary *)httpRequestHeaders
{
    self = [self initWithURLProvider:^NSURL* { return urlIn; }];
    self->requestHeaders = httpRequestHeaders;
    return self;
}

-(id) initWithURLProvider:(STKURLProvider)urlProviderIn
{
	urlProviderIn = [urlProviderIn copy];
    
    return [self initWithAsyncURLProvider:^(STKHTTPDataSource* dataSource, BOOL forSeek, STKURLBlock block)
    {
        block(urlProviderIn());
    }];
}

-(id) initWithAsyncURLProvider:(STKAsyncURLProvider)asyncUrlProviderIn
{
    if (self = [super init])
    {
        seekStart = 0;
        relativePosition = 0;
        fileLength = -1;
        
        self->asyncUrlProvider = [asyncUrlProviderIn copy];
        
        audioFileTypeHint = [STKLocalFileDataSource audioFileTypeHintFromFileExtension:self->currentUrl.pathExtension];
        
        metaDataString = [NSMutableString new];
    }
    
    return self;
}

-(void) dealloc
{
    NSLog(@"STKHTTPDataSource dealloc");
}

-(NSURL*) url
{
    return self->currentUrl;
}

+(AudioFileTypeID) audioFileTypeHintFromMimeType:(NSString*)mimeType
{
    static dispatch_once_t onceToken;
    static NSDictionary* fileTypesByMimeType;
    
    dispatch_once(&onceToken, ^
    {
        fileTypesByMimeType =
        @{
            @"audio/mp3": @(kAudioFileMP3Type),
            @"audio/mpg": @(kAudioFileMP3Type),
            @"audio/mpeg": @(kAudioFileMP3Type),
            @"audio/wav": @(kAudioFileWAVEType),
            @"audio/aifc": @(kAudioFileAIFCType),
            @"audio/aiff": @(kAudioFileAIFFType),
            @"audio/x-m4a": @(kAudioFileM4AType),
            @"audio/x-mp4": @(kAudioFileMPEG4Type),
            @"audio/aacp": @(kAudioFileAAC_ADTSType),
            @"audio/m4a": @(kAudioFileM4AType),
            @"audio/mp4": @(kAudioFileMPEG4Type),
            @"audio/caf": @(kAudioFileCAFType),
            @"audio/aac": @(kAudioFileAAC_ADTSType),
            @"audio/ac3": @(kAudioFileAC3Type),
            @"audio/3gp": @(kAudioFile3GPType)
        };
    });
    
    NSNumber* number = [fileTypesByMimeType objectForKey:mimeType];
    
    if (!number)
    {
        return 0;
    }
    
    return (AudioFileTypeID)number.intValue;
}

-(AudioFileTypeID) audioFileTypeHint
{
    return audioFileTypeHint;
}

-(void) dataAvailable
{
    if (stream == NULL) {
        return;
    }
    
	if (self.httpStatusCode == 0)
	{
		CFTypeRef response = CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
        
        if (response)
        {
            httpHeaders = (__bridge_transfer NSDictionary*)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)response);
            
            self->httpStatusCode = (UInt32)CFHTTPMessageGetResponseStatusCode((CFHTTPMessageRef)response);
            
            CFRelease(response);
        }
		
		if (self.httpStatusCode == 200)
		{
			if (seekStart == 0)
			{
				fileLength = (SInt64)[[httpHeaders objectForKey:@"Content-Length"] longLongValue];
			}
			
			NSString* contentType = [httpHeaders objectForKey:@"Content-Type"];
			AudioFileTypeID typeIdFromMimeType = [STKHTTPDataSource audioFileTypeHintFromMimeType:contentType];
			
			if (typeIdFromMimeType != 0)
			{
				audioFileTypeHint = typeIdFromMimeType;
			}
		}
		else if (self.httpStatusCode == 206)
		{
			NSString* contentRange = [httpHeaders objectForKey:@"Content-Range"];
			NSArray* components = [contentRange componentsSeparatedByString:@"/"];
			
			if (components.count == 2)
			{
				fileLength = [[components objectAtIndex:1] integerValue];
			}
		}
		else if (self.httpStatusCode == 416)
		{
			if (self.length >= 0)
			{
				seekStart = self.length;
			}
			
			[self eof];
			
			return;
		}
		else if (self.httpStatusCode >= 300)
		{
			[self errorOccured];
			
			return;
		}
	}
	
	[super dataAvailable];
}

-(SInt64) position
{
    return seekStart + relativePosition;
}

-(SInt64) length
{
    return fileLength >= 0 ? fileLength : 0;
}

-(void) reconnect
{
    NSRunLoop* savedEventsRunLoop = eventsRunLoop;
    
    [self close];
    
    eventsRunLoop = savedEventsRunLoop;
	
    [self seekToOffset:self.position];
}

-(void) seekToOffset:(SInt64)offset
{
    NSRunLoop* savedEventsRunLoop = eventsRunLoop;
    
    [self close];
    
    eventsRunLoop = savedEventsRunLoop;
	
    NSAssert([NSRunLoop currentRunLoop] == eventsRunLoop, @"Seek called on wrong thread");
    
    stream = 0;
    relativePosition = 0;
    seekStart = offset;
    
    self->isInErrorState = NO;
    
    [self openForSeek:YES];
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    if (size == 0)
    {
        return 0;
    }
    
    int read = (int)CFReadStreamRead(stream, buffer, size);
    
    if (read < 0)
    {
        return read;
    }
    
    // method will move audio bytes to the beginning of the buffer,
    // and return their number
    read = [self checkForMetaDataInfoWithBuffer:buffer andLength:read];
    
    relativePosition += read;
    
    return read;
}

-(void) open
{
    return [self openForSeek:NO];
}

-(void) openForSeek:(BOOL)forSeek
{
	int localRequestSerialNumber;
	
	requestSerialNumber++;
	localRequestSerialNumber = requestSerialNumber;
	
    asyncUrlProvider(self, forSeek, ^(NSURL* url)
    {
		if (localRequestSerialNumber != self->requestSerialNumber)
		{
			return;
		}
		
        self->currentUrl = url;

        if (url == nil)
        {
            return;
        }

        CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)self->currentUrl, kCFHTTPVersion1_1);

        if (seekStart > 0)
        {
            CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Range"), (__bridge CFStringRef)[NSString stringWithFormat:@"bytes=%lld-", seekStart]);

            discontinuous = YES;
        }

        for (NSString* key in self->requestHeaders)
        {
            NSString* value = [self->requestHeaders objectForKey:key];
            CFHTTPMessageSetHeaderFieldValue(message, (__bridge CFStringRef)key, (__bridge CFStringRef)value);
        }

        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Icy-MetaData"), CFSTR("1"));
        
        stream = CFReadStreamCreateForHTTPRequest(NULL, message);

        if (stream == nil)
        {
            CFRelease(message);

            [self errorOccured];

            return;
        }

        if (!CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue))
        {
            CFRelease(message);

            [self errorOccured];

            return;
        }

        // Proxy support

        CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
        CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
        CFRelease(proxySettings);

        // SSL support

        if ([self->currentUrl.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame)
        {
            NSDictionary* sslSettings = [NSDictionary dictionaryWithObjectsAndKeys:
            (NSString*)kCFStreamSocketSecurityLevelNegotiatedSSL, kCFStreamSSLLevel,
            [NSNumber numberWithBool:YES], kCFStreamSSLAllowsExpiredCertificates,
            [NSNumber numberWithBool:YES], kCFStreamSSLAllowsExpiredRoots,
            [NSNumber numberWithBool:YES], kCFStreamSSLAllowsAnyRoot,
            [NSNumber numberWithBool:NO], kCFStreamSSLValidatesCertificateChain,
            [NSNull null], kCFStreamSSLPeerName,
            nil];

            CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings, (__bridge CFTypeRef)sslSettings);
        }

        [self reregisterForEvents];
        
		self->httpStatusCode = 0;
		
        // Open

        if (!CFReadStreamOpen(stream))
        {
            CFRelease(stream);
            CFRelease(message);
            
            stream = 0;

            [self errorOccured];

            return;
        }
        
        self->isInErrorState = NO;
        
        CFRelease(message);
    });
}

-(UInt32) httpStatusCode
{
    return self->httpStatusCode;
}

-(NSRunLoop*) eventsRunLoop
{
    return self->eventsRunLoop;
}

-(NSString*) description
{
    return [NSString stringWithFormat:@"HTTP data source with file length: %lld and position: %lld", self.length, self.position];
}

#pragma mark - Meta data

// This code was mostly taken from the link below
// https://code.google.com/p/audiostreamer-meta/

// Returns new length: the number of bytes from buffer that contain audio data.
// Other bytes are meta data bytes and this method "consumes" them.
-(int) checkForMetaDataInfoWithBuffer:(UInt8 *)buffer andLength:(int)length
{
    CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
    
    if (foundIcyStart == NO && metaDataPresent == NO) {
        // check if this is a ICY 200 OK response
        NSString *icyCheck = [[NSString alloc] initWithBytes:buffer length:10 encoding:NSUTF8StringEncoding];
        if (icyCheck != nil && [icyCheck caseInsensitiveCompare:@"ICY 200 OK"] == NSOrderedSame) {
            foundIcyStart = YES;
        } else {
            NSString *metaInt = (__bridge NSString *) CFHTTPMessageCopyHeaderFieldValue(response, CFSTR("Icy-Metaint"));
            
            if (metaInt) {
                metaDataPresent = YES;
                metaDataInterval = [metaInt intValue];
            }
        }
    }
    
    int streamStart = 0;
    
    if (foundIcyStart == YES && foundIcyEnd == NO) {
        char c[4] = {};
        
        for (int lineStart = 0; streamStart + 3 < length; ++streamStart) {
            
            memcpy(c, buffer + streamStart, 4);
            
            if (c[0] == '\r' && c[1] == '\n') {
                NSString *fullString = [[NSString alloc] initWithBytes:buffer length:streamStart encoding:NSUTF8StringEncoding];
                
                NSString *line = [fullString substringWithRange:NSMakeRange(lineStart, streamStart - lineStart)];
                
                NSArray *lineItems = [line componentsSeparatedByString:@":"];
                if (lineItems.count > 1) {
                    if ([lineItems[0] caseInsensitiveCompare:@"icy-metaint"] == NSOrderedSame) {
                        metaDataInterval = [lineItems[1] intValue];
                    } else if ([lineItems[0] caseInsensitiveCompare:@"content-type"] == NSOrderedSame) {
                        AudioFileTypeID idFromMime = [STKHTTPDataSource audioFileTypeHintFromMimeType:lineItems[1]];
                        if (idFromMime != 0) {
                            audioFileTypeHint = idFromMime;
                        }
                    }
                }
                
                // this is the end of a line, the new line starts in 2
                lineStart = streamStart + 2;
                
                if (c[2] == '\r' && c[3] == '\n') {
                    foundIcyEnd = YES;
                    metaDataPresent = YES;
                    streamStart += 4; // skip double new line
                    break;
                }
            }
        }
    }
    
    if (metaDataPresent == YES) {
        int audioDataByteCount = 0;
        
        for (int i = streamStart; i < length; ++i) {
            // is this a metadata byte?
            if (metaDataBytesRemaining > 0) {
                
                [metaDataString appendFormat:@"%c", buffer[i]];
                
                if (--metaDataBytesRemaining == 0) {
                    dataBytesRead = 0;
                    
                    NSDictionary *metaDataDictionary = [self dictionaryFromMetaData:metaDataString];
                    [self.delegate dataSource:self didUpdateMetaData:metaDataDictionary];
                }
                
                continue;
            }
            
            // is this the interval byte?
            if (metaDataInterval > 0 && dataBytesRead == metaDataInterval) {
                
                metaDataBytesRemaining = buffer[i] * 16;
                
                metaDataString.string = @"";
                
                if (metaDataBytesRemaining == 0) {
                    dataBytesRead = 0;
                }
                
                continue;
            }
            
            // this is a data byte
            ++dataBytesRead;
            
            // overwrite beginning of the buffer with the real audio data
            // we don't need those bytes any more, since we already examined them
            buffer[audioDataByteCount++] = buffer[i];
        }
        
        return audioDataByteCount;
        
    } else if (foundIcyStart == YES) { // still parsing icy response
        
        return 0;
        
    } else { // no meta data in stream
        
        return length;
        
    }
}

-(NSDictionary *) dictionaryFromMetaData:(NSString *)metaData
{
    NSArray *components = [metaData componentsSeparatedByString:@";"];
    
    NSMutableDictionary *dictionary = [NSMutableDictionary new];
    
    for (NSString *entry in components) {
        NSInteger equalitySignPosition = [entry rangeOfString:@"="].location;
        if (equalitySignPosition != NSNotFound) {
            NSString *key = [entry substringToIndex:equalitySignPosition];
            NSString *value = [entry substringFromIndex:equalitySignPosition + 1];
            NSString *valueWithoutQuotes = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            
            dictionary[key] = valueWithoutQuotes;
        }
    }
    
    return dictionary;
}

@end
