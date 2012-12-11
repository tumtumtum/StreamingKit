//
//  AutoRecoveringHttpDataSource.h
//  bloom
//
//  Created by Thong Nguyen on 16/10/2012.
//  Copyright (c) 2012 DDN Ltd. All rights reserved.
//

#import "DataSource.h"
#import "HttpDataSource.h"
#import "DataSourceWrapper.h"

@interface AutoRecoveringHttpDataSource : DataSourceWrapper

-(id) initWithHttpDataSource:(HttpDataSource*)innerDataSource;

@property (readonly) HttpDataSource* innerDataSource;

@end
