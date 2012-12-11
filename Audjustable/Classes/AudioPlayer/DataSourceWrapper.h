//
//  DataSourceWrapper.h
//  bloom
//
//  Created by Thong Nguyen on 16/10/2012.
//  Copyright (c) 2012 DDN Ltd. All rights reserved.
//

#import "DataSource.h"

@interface DataSourceWrapper : DataSource<DataSourceDelegate>

-(id) initWithDataSource:(DataSource*)innerDataSource;

@property (readonly) DataSource* innerDataSource;

@end
