//
//  STKiTunesFileDataSource.m
//  StreamingKit
//
//  Created by Андрей on 05.06.14.
//  Copyright (c) 2014 Thong Nguyen. All rights reserved.
//

#import "STKMediaLibraryFileLoader.h"
#import <AVFoundation/AVFoundation.h>

@interface STKMediaLibraryFileLoader () {
    NSURL *_mediaLibraryURL;
    AVAssetExportSession *_exportSession;
    NSString *_cachedPath;
}
@end


@implementation STKMediaLibraryFileLoader
+ (STKLocalFileDataSource *)localFileDataSourceWithMediaLibraryURL:(NSURL *)url {
    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    if (asset == nil) {
        return nil;
    }
    AVAssetExportSession *_exportSession = [AVAssetExportSession exportSessionWithAsset:asset
                                                       presetName:AVAssetExportPresetPassthrough];
    if (_exportSession == nil) {
        return nil;
    }
    NSString *filePath = [STKMediaLibraryFileLoader temporaryFilePath];
    [_exportSession setOutputFileType:AVFileTypeCoreAudioFormat];
    [_exportSession setOutputURL:[NSURL fileURLWithPath:filePath]];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(sema);
    }];
    STKLocalFileDataSource *localFileDataSource = [[STKLocalFileDataSource alloc] initWithFilePath:filePath];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    dispatch_release(sema);
    return localFileDataSource;
}

+ (NSString *)temporaryFilePath
{
    NSString *filename = [NSString stringWithFormat:@"streamingkittemporaryfile.caf"];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    return path;
}

@end
