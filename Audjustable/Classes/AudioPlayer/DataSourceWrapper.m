//
//  DataSourceWrapper.m
//  bloom
//
//  Created by Thong Nguyen on 16/10/2012.
//  Copyright (c) 2012 DDN Ltd. All rights reserved.
//

#import "DataSourceWrapper.h"

@interface DataSourceWrapper()
@property (readwrite) DataSource* innerDataSource;
@end

@implementation DataSourceWrapper

-(id) initWithDataSource:(DataSource*)innerDataSourceIn
{
    if (self = [super init])
    {
        self.innerDataSource = innerDataSourceIn;
        
        self.innerDataSource.delegate = self;
    }
    
    return self;
}

-(long long) length
{
    return self.innerDataSource.length;
}

-(void) seekToOffset:(long long)offset
{
    return [self.innerDataSource seekToOffset:offset];
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    return [self.innerDataSource readIntoBuffer:buffer withSize:size];
}

-(long long) position
{
    return self.innerDataSource.position;
}

-(BOOL) registerForEvents:(NSRunLoop*)runLoop
{
    return [self.innerDataSource registerForEvents:runLoop];
}

-(void) unregisterForEvents
{
    [self.innerDataSource unregisterForEvents];
}

-(void) close
{
    [self.innerDataSource close];
}

-(BOOL) hasBytesAvailable
{
    return self.innerDataSource.hasBytesAvailable;
}

-(void) dataSourceDataAvailable:(DataSource*)dataSource
{
    [self.delegate dataSourceDataAvailable:self];
}

-(void) dataSourceErrorOccured:(DataSource*)dataSource
{
    [self.delegate dataSourceErrorOccured:self];
}

-(void) dataSourceEof:(DataSource*)dataSource
{
    [self.delegate dataSourceEof:self];
}

@end
