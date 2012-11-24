//
//  AutoRecoveringHttpDataSource.m
//  bloom
//
//  Created by Thong Nguyen on 16/10/2012.
//  Copyright (c) 2012 DDN Ltd. All rights reserved.
//

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

-(void) dataSourceErrorOccured:(DataSource*)dataSource
{
    if (![self hasGotNetworkConnection])
    {
        waitingForNetwork = YES;
        
        return;
    }
    
    if (reconnectAttempts > MAX_IMMEDIATE_RECONNECT_ATTEMPTS)
    {
        [self performSelector:@selector(attemptReconnect) withObject:nil afterDelay:5];
    }
    else
    {
        [self attemptReconnect];
    }
}

@end
