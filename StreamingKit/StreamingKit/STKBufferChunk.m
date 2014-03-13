//
//  STKBufferChunk.m
//  StreamingKit
//
//  Created by Thong Nguyen on 24/02/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKBufferChunk.h"

@implementation STKBufferChunk

-(id) initWithBufferSize:(UInt32)sizeIn
{
    if (self = [super init])
    {
        self->size = sizeIn;
        
        self->buffer = calloc(sizeof(UInt8), sizeIn);
    }
    
    return self;
}

-(void) dealloc
{
    free(self->buffer);
}

-(UInt32) absoluteStart
{
	return self->index * self->size;
}

-(UInt32) absolutePosition
{
	return self.absoluteStart + self->position;
}

@end
