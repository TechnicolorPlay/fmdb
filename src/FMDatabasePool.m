//
//  FMDatabasePool.m
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

#import "FMDatabasePool.h"
#import "FMDatabase.h"

@interface FMDatabasePool()

- (void)pushDatabaseBackInPool:(FMDatabase*)db;
- (FMDatabase*)db;

@end


@implementation FMDatabasePool
{
    NSString            *_path;
    
    dispatch_queue_t    _lockQueue;
    
    NSMutableArray      *_databaseInPool;
    NSMutableArray      *_databaseOutPool;
    
    __unsafe_unretained id _delegate;
    
    NSUInteger          _maximumNumberOfDatabasesToCreate;
}

@synthesize path=_path;
@synthesize delegate=_delegate;
@synthesize maximumNumberOfDatabasesToCreate=_maximumNumberOfDatabasesToCreate;


+ (instancetype)databasePoolWithPath:(NSString*)aPath {
    return FMDBReturnAutoreleased([[self alloc] initWithPath:aPath]);
}

- (instancetype)initWithPath:(NSString*)aPath {
    
    self = [super init];
    
    if (self != nil) {
        _path               = [aPath copy];
        _lockQueue          = dispatch_queue_create([[NSString stringWithFormat:@"fmdb.%@", self] UTF8String], NULL);
        _databaseInPool     = FMDBReturnRetained([NSMutableArray array]);
        _databaseOutPool    = FMDBReturnRetained([NSMutableArray array]);
    }
    
    return self;
}

- (void)dealloc {
    
    _delegate = 0x00;
    FMDBRelease(_path);
    FMDBRelease(_databaseInPool);
    FMDBRelease(_databaseOutPool);
    
    if (_lockQueue) {
        FMDBDispatchQueueRelease(_lockQueue);
        _lockQueue = 0x00;
    }
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}


- (void)executeLocked:(void (^)(void))aBlock {
    dispatch_sync(_lockQueue, aBlock);
}

- (void)pushDatabaseBackInPool:(FMDatabase*)db {
    
    if (!db) { // db can be null if we set an upper bound on the # of databases to create.
        return;
    }
    
    typeof(self) s_self = self;
    [s_self executeLocked:^() {
        
        if ([s_self->_databaseInPool containsObject:db]) {
            [[NSException exceptionWithName:@"Database already in pool" reason:@"The FMDatabase being put back into the pool is already present in the pool" userInfo:nil] raise];
        }
        
        [s_self->_databaseInPool addObject:db];
        [s_self->_databaseOutPool removeObject:db];
        
    }];
}

- (FMDatabase*)db {
    
    __block FMDatabase *db;
    
    typeof(self) s_self = self;
    [s_self executeLocked:^() {
        db = [s_self->_databaseInPool lastObject];
        
        if (db) {
            [s_self->_databaseOutPool addObject:db];
            [s_self->_databaseInPool removeLastObject];
        }
        else {
            
            if (s_self->_maximumNumberOfDatabasesToCreate) {
                NSUInteger currentCount = [s_self->_databaseOutPool count] + [s_self->_databaseInPool count];
                
                if (currentCount >= s_self->_maximumNumberOfDatabasesToCreate) {
                    NSLog(@"Maximum number of databases (%ld) has already been reached!", (long)currentCount);
                    return;
                }
            }
            
            db = [FMDatabase databaseWithPath:s_self->_path];
        }
        
        //This ensures that the db is opened before returning
        if ([db open]) {
            if ([s_self->_delegate respondsToSelector:@selector(databasePool:shouldAddDatabaseToPool:)] && ![s_self->_delegate databasePool:self shouldAddDatabaseToPool:db]) {
                [db close];
                db = 0x00;
            }
            else {
                //It should not get added in the pool twice if lastObject was found
                if (![s_self->_databaseOutPool containsObject:db]) {
                    [s_self->_databaseOutPool addObject:db];
                }
            }
        }
        else {
            NSLog(@"Could not open up the database at path %@", s_self->_path);
            db = 0x00;
        }
    }];
    
    return db;
}

- (NSUInteger)countOfCheckedInDatabases {
    
    __block NSUInteger count;
    
    typeof(self) s_self = self;
    [s_self executeLocked:^() {
        count = [s_self->_databaseInPool count];
    }];
    
    return count;
}

- (NSUInteger)countOfCheckedOutDatabases {
    
    __block NSUInteger count;

    typeof(self) s_self = self;
    [self executeLocked:^() {
        count = [s_self->_databaseOutPool count];
    }];
    
    return count;
}

- (NSUInteger)countOfOpenDatabases {
    __block NSUInteger count;

    typeof(self) s_self = self;
    [self executeLocked:^() {
        count = [s_self->_databaseOutPool count] + [s_self->_databaseInPool count];
    }];
    
    return count;
}

- (void)releaseAllDatabases {
    typeof(self) s_self = self;
    [self executeLocked:^() {
        [s_self->_databaseOutPool removeAllObjects];
        [s_self->_databaseInPool removeAllObjects];
    }];
}

- (void)inDatabase:(void (^)(FMDatabase *db))block {
    
    FMDatabase *db = [self db];
    
    block(db);
    
    [self pushDatabaseBackInPool:db];
}

- (void)beginTransaction:(BOOL)useDeferred withBlock:(void (^)(FMDatabase *db, BOOL *rollback))block {
    
    BOOL shouldRollback = NO;
    
    FMDatabase *db = [self db];
    
    if (useDeferred) {
        [db beginDeferredTransaction];
    }
    else {
        [db beginTransaction];
    }
    
    
    block(db, &shouldRollback);
    
    if (shouldRollback) {
        [db rollback];
    }
    else {
        [db commit];
    }
    
    [self pushDatabaseBackInPool:db];
}

- (void)inDeferredTransaction:(void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:YES withBlock:block];
}

- (void)inTransaction:(void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:NO withBlock:block];
}
#if SQLITE_VERSION_NUMBER >= 3007000
- (NSError*)inSavePoint:(void (^)(FMDatabase *db, BOOL *rollback))block {
    
    static unsigned long savePointIdx = 0;
    
    NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];
    
    BOOL shouldRollback = NO;
    
    FMDatabase *db = [self db];
    
    NSError *err = 0x00;
    
    if (![db startSavePointWithName:name error:&err]) {
        [self pushDatabaseBackInPool:db];
        return err;
    }
    
    block(db, &shouldRollback);
    
    if (shouldRollback) {
        [db rollbackToSavePointWithName:name error:&err];
    }
    else {
        [db releaseSavePointWithName:name error:&err];
    }
    
    [self pushDatabaseBackInPool:db];
    
    return err;
}
#endif

@end
