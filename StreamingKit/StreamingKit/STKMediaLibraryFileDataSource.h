//
//  STKMediaLibraryFileDataSource.h
//  StreamingKit
//
//  Created by Andrey Ryabov on 09.06.14.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKLocalFileDataSource.h"

@interface STKMediaLibraryFileDataSource : STKCoreFoundationDataSource
@property (nonatomic, strong) NSURL *mediaURL;
- (instancetype)initWithMediaURL:(NSURL *)url;
@end
