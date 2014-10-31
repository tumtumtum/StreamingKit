//
//  STKiTunesFileDataSource.h
//  StreamingKit
//
//  Created by Андрей on 05.06.14.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKLocalFileDataSource.h"
@interface STKMediaLibraryFileLoader : NSObject
+ (STKLocalFileDataSource *)localFileDataSourceWithMediaLibraryURL:(NSURL *)url;
@end
