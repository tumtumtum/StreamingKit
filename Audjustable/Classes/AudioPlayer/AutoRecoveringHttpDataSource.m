/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 16/10/2012.
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

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "AutoRecoveringHttpDataSource.h"

#define MAX_IMMEDIATE_RECONNECT_ATTEMPTS (8)
#define MAX_ATTEMPTS_WITH_SERVER_ERROR (MAX_IMMEDIATE_RECONNECT_ATTEMPTS + 2)

@interface AutoRecoveringHttpDataSource()
{
	int reconnectAttempts;
    BOOL waitingForNetwork;
    SCNetworkReachabilityRef reachabilityRef;
}

-(void) reachabilityChanged;

@end

static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info)
{
    @autoreleasepool
    {
        AutoRecoveringHttpDataSource* dataSource = (__bridge AutoRecoveringHttpDataSource*)info;
        
        [dataSource reachabilityChanged];
    }
}

@implementation AutoRecoveringHttpDataSource

-(HttpDataSource*) innerHttpDataSource
{
    return (HttpDataSource*)self.innerDataSource;
}

-(id) initWithHttpDataSource:(HttpDataSource*)innerDataSourceIn
{
    if (self = [super initWithDataSource:innerDataSourceIn])
    {
        self.innerDataSource.delegate = self;
        
        struct sockaddr_in zeroAddress;
        
        bzero(&zeroAddress, sizeof(zeroAddress));
        zeroAddress.sin_len = sizeof(zeroAddress);
        zeroAddress.sin_family = AF_INET;
        
        reachabilityRef = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr*)&zeroAddress);
    }
    
    return self;
}

-(BOOL) startNotifierOnRunLoop:(NSRunLoop*)runLoop
{
    BOOL retVal = NO;
    SCNetworkReachabilityContext context = { 0, (__bridge void*)self, NULL, NULL, NULL };
    
    if (SCNetworkReachabilitySetCallback(reachabilityRef, ReachabilityCallback, &context))
    {
		if(SCNetworkReachabilityScheduleWithRunLoop(reachabilityRef, runLoop.getCFRunLoop, kCFRunLoopDefaultMode))
        {
            retVal = YES;
        }
    }
    
    return retVal;
}

-(BOOL) registerForEvents:(NSRunLoop*)runLoop
{
    [super registerForEvents:runLoop];
    [self startNotifierOnRunLoop:runLoop];
    
    return YES;
}

-(void) unregisterForEvents
{
    [self stopNotifier];
}

-(void) stopNotifier
{
    if (reachabilityRef != NULL)
    {
        SCNetworkReachabilitySetCallback(reachabilityRef, NULL, NULL);
        SCNetworkReachabilityUnscheduleFromRunLoop(reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    }
}

-(BOOL) hasGotNetworkConnection
{
    SCNetworkReachabilityFlags flags;
    
    if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags))
    {
        return ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    }
    
    return NO;
}

-(void) dealloc
{
    self.innerDataSource.delegate = nil;
    
    [self stopNotifier];
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
    if (reachabilityRef!= NULL)
    {
        CFRelease(reachabilityRef);
    }
}

-(void) reachabilityChanged
{
    if (waitingForNetwork)
    {
        waitingForNetwork = NO;
        
        [self attemptReconnect];
    }
}

-(void) dataSourceDataAvailable:(DataSource*)dataSource
{
    reconnectAttempts = 0;
    
    [super dataSourceDataAvailable:dataSource];
}

-(void) attemptReconnect
{
    reconnectAttempts++;
    
    [self seekToOffset:self.position];
}

-(void) processRetryOnError
{
    if (![self hasGotNetworkConnection])
    {
        waitingForNetwork = YES;
        
        return;
    }
    
    if (!(self.innerDataSource.httpStatusCode >= 200 && self.innerDataSource.httpStatusCode <= 299) && reconnectAttempts >= MAX_ATTEMPTS_WITH_SERVER_ERROR)
    {
        [super dataSourceErrorOccured:self];
    }
    else if (reconnectAttempts > MAX_IMMEDIATE_RECONNECT_ATTEMPTS)
    {
        [self performSelector:@selector(attemptReconnect) withObject:nil afterDelay:5];
    }
    else
    {
        [self attemptReconnect];
    }
}

-(void) dataSourceEof:(DataSource*)dataSource
{
    if ([self position] != [self length])
    {
        [self processRetryOnError];
        
        return;
    }
    
    [self.delegate dataSourceEof:self];
}

-(void) dataSourceErrorOccured:(DataSource*)dataSource
{
    if (self.innerDataSource.httpStatusCode == 416 /* Range out of bounds */)
    {
        [super dataSourceEof:dataSource];
    }
    else
    {
        [self processRetryOnError];
    }
    
}

-(NSString*) description
{
    return [NSString stringWithFormat:@"Auto-recovering HTTP data source with file length: %lld and position: %lld", self.length, self.position];
    
}

@end
