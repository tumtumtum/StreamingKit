/**********************************************************************************
 STKBufferingDataSource.m
 
 Created by Thong Nguyen on 16/10/2012.
 https://github.com/tumtumtum/audjustable
 
 Copyright (c) 2012-2014 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
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

#import "STKBufferingDataSource.h"
#import "STKBufferChunk.h"
#import <pthread.h>

#define STK_BUFFER_CHUNK_SIZE (128 * 1024)

@interface STKBufferingDataSource()
{
@private
    NSRunLoop* runLoop;
    SInt32 maxSize;
    UInt32 chunkSize;
    UInt32 chunkCount;
    SInt64 position;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    STKBufferChunk* __strong * bufferChunks;
    STKDataSource* dataSource;
}
@end

@interface STKBufferingDataSourceThread : NSThread
{
@private
    NSRunLoop* runLoop;
    NSConditionLock* threadStartedLock;
}
@end

@implementation STKBufferingDataSourceThread

-(id) init
{
    if (self = [super init])
    {
        threadStartedLock = [[NSConditionLock alloc] initWithCondition:0];
	}
    
    return self;
}

-(NSRunLoop*) runLoop
{
    [threadStartedLock lockWhenCondition:1];
    [threadStartedLock unlockWithCondition:0];
    
    return self->runLoop;
}

-(void) main
{
    runLoop = [NSRunLoop currentRunLoop];
    
    [threadStartedLock lockWhenCondition:0];
    [threadStartedLock unlockWithCondition:1];
    
    [runLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
    
    while (true)
    {
        NSDate* date = [[NSDate alloc] initWithTimeIntervalSinceNow:10];
        
        [runLoop runMode:NSDefaultRunLoopMode beforeDate:date];
    }
}

@end

static STKBufferingDataSourceThread* thread;

@implementation STKBufferingDataSource

+(void) initialize
{
    thread = [[STKBufferingDataSourceThread alloc] init];
    
    [thread start];
}

-(id) initWithDataSource:(STKDataSource*)dataSourceIn withMaxSize:(int)maxSizeIn
{
    if (self = [super init])
    {
        self->maxSize = maxSizeIn;
        self->dataSource = dataSourceIn;
        self->chunkSize = STK_BUFFER_CHUNK_SIZE;
        
        self->dataSource.delegate = self.delegate;
        
        [self->dataSource registerForEvents:[thread runLoop]];
        
        pthread_mutexattr_t attr;
        
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);

        pthread_mutex_init(&self->mutex, &attr);
        pthread_cond_init(&self->condition, NULL);
    }
    
    return self;
}

-(void) dealloc
{
	self->dataSource.delegate = nil;
    
    for (int i = 0; i < self->chunkCount; i++)
    {
        self->bufferChunks[i] = nil;
    }
    
    free(self->bufferChunks);
    
    pthread_mutex_destroy(&self->mutex);
    pthread_cond_destroy(&self->condition);
}

-(void) createBuffer
{
    if (self->bufferChunks == nil)
    {
        int length = (int)MIN(self.length == 0? 1024 * 1024 : self.length, self->maxSize);
        
        self->chunkCount = (int)((length / self->chunkSize) + 1);
        self->bufferChunks = (__strong STKBufferChunk**)calloc(sizeof(STKBufferChunk*), self->chunkCount);
    }
}

-(STKBufferChunk*) chunkForPosition:(SInt64)positionIn createIfNotExist:(BOOL)createIfNotExist
{
    int chunkIndex = (int)(positionIn / chunkCount);
    
    if (self->bufferChunks[chunkIndex] == nil && createIfNotExist)
    {
        self->bufferChunks[chunkIndex] = [[STKBufferChunk alloc] initWithBufferSize:STK_BUFFER_CHUNK_SIZE];
    }
    
    return self->bufferChunks[chunkIndex];
}

-(SInt64) length
{
    return self->dataSource.length;
}

-(void) seekToOffset:(SInt64)offset
{
    pthread_mutex_lock(&mutex);
    
    [self seekToNextGap];
    
    pthread_mutex_unlock(&mutex);
}

-(BOOL) hasBytesAvailable
{
    return NO;
}

-(int) readIntoBuffer:(UInt8*)bufferIn withSize:(int)size
{
    return 0;
}

-(BOOL) registerForEvents:(NSRunLoop*)runLoopIn
{
    runLoop = runLoopIn;
    
    [dataSource registerForEvents:[thread runLoop]];
    
    return YES;
}

-(void) unregisterForEvents
{
    runLoop = nil;
    
    [dataSource unregisterForEvents];
}

-(void) close
{
    [dataSource unregisterForEvents];
    [dataSource close];
}

-(void) seekToNextGap
{
}

-(void) dataSourceDataAvailable:(STKDataSource*)dataSourceIn
{
    if (![dataSourceIn hasBytesAvailable])
    {
        return;
    }
    
    pthread_mutex_lock(&mutex);
    
    if (self->bufferChunks == nil)
    {
    	[self createBuffer];
    }
    
    SInt64 sourcePosition = dataSourceIn.position;
    
    STKBufferChunk* chunk = [self chunkForPosition:sourcePosition createIfNotExist:YES];
    
    if (chunk->position >= chunk->size)
    {
        [self seekToNextGap];
        
        return;
    }
    
    int offset = dataSourceIn.position % self->chunkSize;
    
    if (offset > chunk->position)
    {
        [self seekToNextGap];
        
        return;
    }
    
    int bytesToRead = self->chunkSize - offset;
    int bytesRead = [dataSourceIn readIntoBuffer:(chunk->buffer + offset) withSize:bytesToRead];
    
    chunk->position = offset + bytesRead;
    
    pthread_mutex_unlock(&mutex);
}

-(void) dataSourceErrorOccured:(STKDataSource*)dataSourceIn
{
    [self.delegate dataSourceErrorOccured:self];
}

-(void) dataSourceEof:(STKDataSource*)dataSourceIn
{
}

@end
