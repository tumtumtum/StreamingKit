//
//  STKBufferChunk.h
//  StreamingKit
//
//  Created by Thong Nguyen on 24/02/2014.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface STKBufferChunk : NSObject
{
@public
    UInt32 index;
    UInt32 size;
    UInt32 position;
    UInt8* buffer;
}

@property (readonly) UInt32 absoluteStart;
@property (readonly) UInt32 absolutePosition;

-(id) initWithBufferSize:(UInt32)sizeIn;

@end
