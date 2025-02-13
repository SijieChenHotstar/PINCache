//  PINCache is a modified version of TMCache
//  Modifications by Garrett Moon
//  Copyright (c) 2015 Pinterest. All rights reserved.

#import "PINDiskCache.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

#import <pthread.h>

#import <PINOperation/PINOperation.h>

#define PINDiskCacheError(error) if (error) { NSLog(@"%@ (%d) ERROR: %@", \
[[NSString stringWithUTF8String:__FILE__] lastPathComponent], \
__LINE__, [error localizedDescription]); }

#define PINDiskCacheException(exception) if (exception) { NSAssert(NO, [exception reason]); }

NSString * const PINDiskCachePrefix = @"com.pinterest.PINDiskCache";
static NSString * const PINDiskCacheSharedName = @"PINDiskCacheShared";

static NSString * const PINDiskCacheOperationIdentifierTrimToDate = @"PINDiskCacheOperationIdentifierTrimToDate";
static NSString * const PINDiskCacheOperationIdentifierTrimToSize = @"PINDiskCacheOperationIdentifierTrimToSize";
static NSString * const PINDiskCacheOperationIdentifierTrimToSizeByDate = @"PINDiskCacheOperationIdentifierTrimToSizeByDate";

typedef NS_ENUM(NSUInteger, PINDiskCacheCondition) {
    PINDiskCacheConditionNotReady = 0,
    PINDiskCacheConditionReady = 1,
};

static PINOperationDataCoalescingBlock PINDiskTrimmingSizeCoalescingBlock = ^id(NSNumber *existingSize, NSNumber *newSize) {
    NSComparisonResult result = [existingSize compare:newSize];
    return (result == NSOrderedDescending) ? newSize : existingSize;
};

static PINOperationDataCoalescingBlock PINDiskTrimmingDateCoalescingBlock = ^id(NSDate *existingDate, NSDate *newDate) {
    NSComparisonResult result = [existingDate compare:newDate];
    return (result == NSOrderedDescending) ? newDate : existingDate;
};

@interface PINDiskCacheMetadata : NSObject
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, strong) NSNumber *size;
@end

@interface PINDiskCache () {
    PINDiskCacheSerializerBlock _serializer;
    PINDiskCacheDeserializerBlock _deserializer;
    
    PINDiskCacheKeyEncoderBlock _keyEncoder;
    PINDiskCacheKeyDecoderBlock _keyDecoder;
}

@property (assign, nonatomic) pthread_mutex_t mutex;
@property (copy, nonatomic) NSString *name;
@property (assign) NSUInteger byteCount;
@property (strong, nonatomic) NSURL *cacheURL;
@property (strong, nonatomic) PINOperationQueue *operationQueue;
@property (strong, nonatomic) NSMutableDictionary <NSString *, PINDiskCacheMetadata *> *metadata;
@property (assign, nonatomic) pthread_cond_t diskWritableCondition;
@property (assign, nonatomic) BOOL diskWritable;
@property (assign, nonatomic) pthread_cond_t diskStateKnownCondition;
@property (assign, nonatomic) BOOL diskStateKnown;
@end

@implementation PINDiskCache

static NSURL *_sharedTrashURL;

@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize byteLimit = _byteLimit;
@synthesize ageLimit = _ageLimit;
@synthesize ttlCache = _ttlCache;

#if TARGET_OS_IPHONE
@synthesize writingProtectionOption = _writingProtectionOption;
#endif

#pragma mark - Initialization -

- (void)dealloc
{
    __unused int result = pthread_mutex_destroy(&_mutex);
    NSCAssert(result == 0, @"Failed to destroy lock in PINMemoryCache %p. Code: %d", (void *)self, result);
    pthread_cond_destroy(&_diskWritableCondition);
    pthread_cond_destroy(&_diskStateKnownCondition);
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:@"Must initialize with a name" reason:@"PINDiskCache must be initialized with a name. Call initWithName: instead." userInfo:nil];
    return [self initWithName:@""];
}

- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath
{
    return [self initWithName:name rootPath:rootPath serializer:nil deserializer:nil];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath serializer:(PINDiskCacheSerializerBlock)serializer deserializer:(PINDiskCacheDeserializerBlock)deserializer
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self initWithName:name rootPath:rootPath serializer:serializer deserializer:deserializer operationQueue:[PINOperationQueue sharedOperationQueue]];
#pragma clang diagnostic pop
}

- (instancetype)initWithName:(NSString *)name
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
              operationQueue:(PINOperationQueue *)operationQueue
{
  return [self initWithName:name
                     prefix:PINDiskCachePrefix
                   rootPath:rootPath
                 serializer:serializer
               deserializer:deserializer
                 keyEncoder:nil
                 keyDecoder:nil
             operationQueue:operationQueue];
}

- (instancetype)initWithName:(NSString *)name
                      prefix:(NSString *)prefix
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(PINOperationQueue *)operationQueue
{
    if (!name)
        return nil;
    

    NSAssert(((!serializer && !deserializer) || (serializer && deserializer)),
             @"PINDiskCache must be initialized with a serializer AND deserializer.");
    
    NSAssert(((!keyEncoder && !keyDecoder) || (keyEncoder && keyDecoder)),
              @"PINDiskCache must be initialized with a encoder AND decoder.");
    
    if (self = [super init]) {
        __unused int result = pthread_mutex_init(&_mutex, NULL);
        NSAssert(result == 0, @"Failed to init lock in PINMemoryCache %@. Code: %d", self, result);
        
        _name = [name copy];
        _prefix = [prefix copy];
        _operationQueue = operationQueue;
        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;
        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;
        
        _byteCount = 0;
        
        // 50 MB by default
        _byteLimit = 50 * 1024 * 1024;
        // 30 days by default
        _ageLimit = 60 * 60 * 24 * 30;
        
#if TARGET_OS_IPHONE
        _writingProtectionOption = NSDataWritingFileProtectionNone;
#endif
        
        _metadata = [[NSMutableDictionary alloc] init];
        _diskStateKnown = NO;
      
        _cacheURL = [[self class] cacheURLWithRootPath:rootPath prefix:_prefix name:_name];
        
        //setup serializers
        if(serializer) {
            _serializer = [serializer copy];
        } else {
            _serializer = self.defaultSerializer;
        }

        if(deserializer) {
            _deserializer = [deserializer copy];
        } else {
            _deserializer = self.defaultDeserializer;
        }
        
        //setup key encoder/decoder
        if(keyEncoder) {
            _keyEncoder = [keyEncoder copy];
        } else {
            _keyEncoder = self.defaultKeyEncoder;
        }
        
        if(keyDecoder) {
            _keyDecoder = [keyDecoder copy];
        } else {
            _keyDecoder = self.defaultKeyDecoder;
        }
        
        pthread_cond_init(&_diskWritableCondition, NULL);
        pthread_cond_init(&_diskStateKnownCondition, NULL);

        //we don't want to do anything without setting up the disk cache, but we also don't want to block init, it can take a while to initialize. This must *not* be done on _operationQueue because other operations added may hold the lock and fill up the queue.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self lock];
                [self _locked_createCacheDirectory];
            [self unlock];
            [self initializeDiskProperties];
        });
    }
    return self;
}

- (NSString *)description
{
    return [[NSString alloc] initWithFormat:@"%@.%@.%p", PINDiskCachePrefix, _name, (void *)self];
}

+ (PINDiskCache *)sharedCache
{
    static PINDiskCache *cache;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        cache = [[PINDiskCache alloc] initWithName:PINDiskCacheSharedName];
    });
    
    return cache;
}

+ (NSURL *)cacheURLWithRootPath:(NSString *)rootPath prefix:(NSString *)prefix name:(NSString *)name
{
    NSString *pathComponent = [[NSString alloc] initWithFormat:@"%@.%@", prefix, name];
    return [NSURL fileURLWithPathComponents:@[ rootPath, pathComponent ]];
}

#pragma mark - Private Methods -

- (NSURL *)encodedFileURLForKey:(NSString *)key
{
    if (![key length])
        return nil;
    
    //Significantly improve performance by indicating that the URL will *not* result in a directory.
    //Also note that accessing _cacheURL is safe without the lock because it is only set on init.
    return [_cacheURL URLByAppendingPathComponent:[self encodedString:key] isDirectory:NO];
}

- (NSString *)keyForEncodedFileURL:(NSURL *)url
{
    NSString *fileName = [url lastPathComponent];
    if (!fileName)
        return nil;
    
    return [self decodedString:fileName];
}

- (NSString *)encodedString:(NSString *)string
{
    return _keyEncoder(string);
}

- (NSString *)decodedString:(NSString *)string
{
    return _keyDecoder(string);
}

- (PINDiskCacheSerializerBlock)defaultSerializer
{
    return ^NSData*(id<NSCoding> object, NSString *key){
        return [NSKeyedArchiver archivedDataWithRootObject:object];
    };
}

- (PINDiskCacheDeserializerBlock)defaultDeserializer
{
    return ^id(NSData * data, NSString *key){
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
    };
}

- (PINDiskCacheKeyEncoderBlock)defaultKeyEncoder
{
    return ^NSString *(NSString *decodedKey) {
        if (![decodedKey length]) {
            return @"";
        }
        
        if (@available(macOS 10.9, iOS 7.0, tvOS 9.0, watchOS 2.0, *)) {
            NSString *encodedString = [decodedKey stringByAddingPercentEncodingWithAllowedCharacters:[[NSCharacterSet characterSetWithCharactersInString:@".:/%"] invertedSet]];
            return encodedString;
        } else {
            CFStringRef static const charsToEscape = CFSTR(".:/%");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CFStringRef escapedString = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                                (__bridge CFStringRef)decodedKey,
                                                                                NULL,
                                                                                charsToEscape,
                                                                                kCFStringEncodingUTF8);
#pragma clang diagnostic pop
            
            return (__bridge_transfer NSString *)escapedString;
        }
    };
}

- (PINDiskCacheKeyEncoderBlock)defaultKeyDecoder
{
    return ^NSString *(NSString *encodedKey) {
        if (![encodedKey length]) {
            return @"";
        }
        
        if (@available(macOS 10.9, iOS 7.0, tvOS 9.0, watchOS 2.0, *)) {
            return [encodedKey stringByRemovingPercentEncoding];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CFStringRef unescapedString = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault,
                                                                                                  (__bridge CFStringRef)encodedKey,
                                                                                                  CFSTR(""),
                                                                                                  kCFStringEncodingUTF8);
#pragma clang diagnostic pop
            return (__bridge_transfer NSString *)unescapedString;
        }
    };
}


#pragma mark - Private Trash Methods -

+ (dispatch_queue_t)sharedTrashQueue
{
    static dispatch_queue_t trashQueue;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.trash", PINDiskCachePrefix];
        trashQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(trashQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    
    return trashQueue;
}

+ (NSLock *)sharedLock
{
    static NSLock *sharedLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLock = [NSLock new];
    });
    return sharedLock;
}

+ (NSURL *)sharedTrashURL
{
    NSURL *trashURL = nil;
    
    [[PINDiskCache sharedLock] lock];
        if (_sharedTrashURL == nil) {
            NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
            _sharedTrashURL = [[[NSURL alloc] initFileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:uniqueString isDirectory:YES];
            
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtURL:_sharedTrashURL
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&error];
            PINDiskCacheError(error);
        }
        trashURL = _sharedTrashURL;
    [[PINDiskCache sharedLock] unlock];
    
    return trashURL;
}

+ (BOOL)moveItemAtURLToTrash:(NSURL *)itemURL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:[itemURL path]])
        return NO;
    
    NSError *error = nil;
    NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
    NSURL *uniqueTrashURL = [[PINDiskCache sharedTrashURL] URLByAppendingPathComponent:uniqueString isDirectory:NO];
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:itemURL toURL:uniqueTrashURL error:&error];
    PINDiskCacheError(error);
    return moved;
}

+ (void)emptyTrash
{
    dispatch_async([PINDiskCache sharedTrashQueue], ^{
        NSURL *trashURL = nil;
      
        // If _sharedTrashURL is unset, there's nothing left to do because it hasn't been accessed and therefore items haven't been added to it.
        // If it is set, we can just remove it.
        // We also need to nil out _sharedTrashURL so that a new one will be created if there's an attempt to move a new file to the trash.
        [[PINDiskCache sharedLock] lock];
            if (_sharedTrashURL != nil) {
                trashURL = _sharedTrashURL;
                _sharedTrashURL = nil;
            }
        [[PINDiskCache sharedLock] unlock];
        
        if (trashURL != nil) {
            NSError *removeTrashedItemError = nil;
            [[NSFileManager defaultManager] removeItemAtURL:trashURL error:&removeTrashedItemError];
            PINDiskCacheError(removeTrashedItemError);
        }
    });
}

#pragma mark - Private Queue Methods -

- (BOOL)_locked_createCacheDirectory
{
    BOOL created = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[_cacheURL path]] == NO) {
        NSError *error = nil;
        created = [[NSFileManager defaultManager] createDirectoryAtURL:_cacheURL
                                                withIntermediateDirectories:YES
                                                                 attributes:nil
                                                                      error:&error];
        PINDiskCacheError(error);
    }
    

    
    // while this may not be true if success is false, it's better than deadlocking later.
    _diskWritable = YES;
    pthread_cond_broadcast(&_diskWritableCondition);
    
    return created;
}

- (void)initializeDiskProperties
{
    NSUInteger byteCount = 0;
    NSArray *keys = @[ NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ];
    
    NSError *error = nil;
    
    [self lock];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:_cacheURL
                                                       includingPropertiesForKeys:keys
                                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                            error:&error];
    [self unlock];
    
    PINDiskCacheError(error);
    
    for (NSURL *fileURL in files) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        
        error = nil;
        
        // Continually grab and release lock while processing files to avoid contention
        [self lock];
            NSDictionary *dictionary = [fileURL resourceValuesForKeys:keys error:&error];
            PINDiskCacheError(error);
            
            if (_metadata[key] == nil) {
                _metadata[key] = [[PINDiskCacheMetadata alloc] init];
            }
        
            NSDate *date = [dictionary objectForKey:NSURLContentModificationDateKey];
            if (date && key)
                _metadata[key].date = date;
        
            NSNumber *fileSize = [dictionary objectForKey:NSURLTotalFileAllocatedSizeKey];
            if (fileSize) {
                _metadata[key].size = fileSize;
                byteCount += [fileSize unsignedIntegerValue];
            }
        [self unlock];
    }
    
    [self lock];
        if (byteCount > 0)
            _byteCount = byteCount;
    
        if (self->_byteLimit > 0 && self->_byteCount > self->_byteLimit)
            [self trimToSizeByDateAsync:self->_byteLimit completion:nil];
    
        _diskStateKnown = YES;
        pthread_cond_broadcast(&_diskStateKnownCondition);
    [self unlock];
}

- (void)asynchronouslySetFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            [self _locked_setFileModificationDate:date forURL:fileURL];
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (BOOL)_locked_setFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    if (!date || !fileURL) {
        return NO;
    }
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date }
                                                    ofItemAtPath:[fileURL path]
                                                           error:&error];
    PINDiskCacheError(error);
    
    if (success) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if (key) {
            _metadata[key].date = date;
        }
    }
    
    return success;
}

- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key
{
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    // We only need to lock until writable at the top because once writable, always writable
    [self lockForWriting];
        if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [self unlock];
            return NO;
        }
    
    PINDiskCacheObjectBlock willRemoveObjectBlock = _willRemoveObjectBlock;
        if (willRemoveObjectBlock) {
            [self unlock];
            willRemoveObjectBlock(self, key, nil);
            [self lock];
        }
        
        BOOL trashed = [PINDiskCache moveItemAtURLToTrash:fileURL];
        if (!trashed) {
            [self unlock];
            return NO;
        }
    
        [PINDiskCache emptyTrash];
        
        NSNumber *byteSize = _metadata[key].size;
        if (byteSize)
            self.byteCount = _byteCount - [byteSize unsignedIntegerValue]; // atomic
        
        [_metadata removeObjectForKey:key];
    
    PINDiskCacheObjectBlock didRemoveObjectBlock = _didRemoveObjectBlock;
        if (didRemoveObjectBlock) {
            [self unlock];
            _didRemoveObjectBlock(self, key, nil);
            [self lock];
        }
    
    [self unlock];
    
    return YES;
}

- (void)trimDiskToSize:(NSUInteger)trimByteCount
{
    [self lockForWriting];
        if (_byteCount > trimByteCount) {
            NSArray *keysSortedBySize = [_metadata keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
                return [obj1.size compare:obj2.size];
            }];
            
            for (NSString *key in [keysSortedBySize reverseObjectEnumerator]) { // largest objects first
                [self unlock];
                
                //unlock, removeFileAndExecuteBlocksForKey handles locking itself
                [self removeFileAndExecuteBlocksForKey:key];
                
                [self lock];
                
                if (_byteCount <= trimByteCount)
                    break;
            }
        }
    [self unlock];
}

- (void)trimDiskToSizeByDate:(NSUInteger)trimByteCount
{
    [self lockForWriting];
        if (_byteCount > trimByteCount) {
            NSArray *keysSortedByDate = [_metadata keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
                return [obj1.date compare:obj2.date];
            }];
            
            for (NSString *key in keysSortedByDate) { // oldest objects first
                [self unlock];
                
                //unlock, removeFileAndExecuteBlocksForKey handles locking itself
                [self removeFileAndExecuteBlocksForKey:key];
                
                [self lock];
                
                if (_byteCount <= trimByteCount)
                    break;
            }
        }
    [self unlock];
}

- (void)trimDiskToDate:(NSDate *)trimDate
{
    [self lockForWriting];
        NSArray *keysSortedByDate = [_metadata keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
            return [obj1.date compare:obj2.date];
        }];
        
        for (NSString *key in keysSortedByDate) { // oldest files first
            NSDate *accessDate = _metadata[key].date;
            if (!accessDate)
                continue;
            
            if ([accessDate compare:trimDate] == NSOrderedAscending) { // older than trim date
                [self unlock];
                
                //unlock, removeFileAndExecuteBlocksForKey handles locking itself
                [self removeFileAndExecuteBlocksForKey:key];
                
                [self lock];
            } else {
                break;
            }
        }
    [self unlock];
}

- (void)trimToAgeLimitRecursively
{
    [self lock];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlock];
    if (ageLimit == 0.0)
        return;
    
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-ageLimit];
    [self trimDiskToDate:date];
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_ageLimit * NSEC_PER_SEC));
    dispatch_after(time, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        [self.operationQueue scheduleOperation:^{
            [self trimToAgeLimitRecursively];
        } withPriority:PINOperationQueuePriorityLow];
    });
}

#pragma mark - Public Asynchronous Methods -

- (void)lockFileAccessWhileExecutingBlockAsync:(PINCacheBlock)block
{
    if (block == nil) {
      return;
    }

    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            block(self);
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)containsObjectForKeyAsync:(NSString *)key completion:(PINDiskCacheContainsBlock)block
{
    if (!key || !block)
        return;
    
    [self.operationQueue scheduleOperation:^{
        block([self containsObjectForKey:key]);
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)objectForKeyAsync:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        id <NSCoding> object = [self objectForKey:key fileURL:&fileURL];
        
        block(self, key, object);
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)fileURLForKeyAsync:(NSString *)key completion:(PINDiskCacheFileURLBlock)block
{
    if (block == nil) {
      return;
    }

    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = [self fileURLForKey:key];
      
        [self lockForWriting];
            block(key, fileURL);
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        [self setObject:object forKey:key fileURL:&fileURL];
        
        if (block) {
            block(self, key, object);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost completion:(nullable PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:(PINDiskCacheObjectBlock)block];
}

- (void)removeObjectForKeyAsync:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        [self removeObjectForKey:key fileURL:&fileURL];
        
        if (block) {
            block(self, key, nil);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)trimToSizeAsync:(NSUInteger)trimByteCount completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data) {
        [self trimToSize:((NSNumber *)data).unsignedIntegerValue];
    };
  
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToSize
                            coalescingData:[NSNumber numberWithUnsignedInteger:trimByteCount]
                       dataCoalescingBlock:PINDiskTrimmingSizeCoalescingBlock
                                completion:completion];
}

- (void)trimToDateAsync:(NSDate *)trimDate completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data){
        [self trimToDate:(NSDate *)data];
    };
    
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToDate
                            coalescingData:trimDate
                       dataCoalescingBlock:PINDiskTrimmingDateCoalescingBlock
                                completion:completion];
}

- (void)trimToSizeByDateAsync:(NSUInteger)trimByteCount completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data){
        [self trimToSizeByDate:((NSNumber *)data).unsignedIntegerValue];
    };
    
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToSizeByDate
                            coalescingData:[NSNumber numberWithUnsignedInteger:trimByteCount]
                       dataCoalescingBlock:PINDiskTrimmingSizeCoalescingBlock
                                completion:completion];
}

- (void)removeAllObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeAllObjects];
        
        if (block) {
            block(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)enumerateObjectsWithBlockAsync:(PINDiskCacheFileURLEnumerationBlock)block completionBlock:(PINCacheBlock)completionBlock
{
    [self.operationQueue scheduleOperation:^{
        [self enumerateObjectsWithBlock:block];
        
        if (completionBlock) {
            completionBlock(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

#pragma mark - Public Synchronous Methods -

- (void)synchronouslyLockFileAccessWhileExecutingBlock:(PINCacheBlock)block
{
    if (block) {
        [self lockForWriting];
            block(self);
        [self unlock];
    }
}

- (BOOL)containsObjectForKey:(NSString *)key
{
    [self lock];
        if (_metadata[key] != nil || _diskStateKnown == NO) {
            [self unlock];
            return ([self fileURLForKey:key updateFileModificationDate:NO] != nil);
        }
    [self unlock];
    return NO;
}

- (nullable id<NSCoding>)objectForKey:(NSString *)key
{
    return [self objectForKey:key fileURL:nil];
}

- (id)objectForKeyedSubscript:(NSString *)key
{
    return [self objectForKey:key];
}

- (nullable id <NSCoding>)objectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    [self lock];
        BOOL containsKey = _metadata[key] != nil || _diskStateKnown == NO;
    [self unlock];

    if (!key || !containsKey)
        return nil;
    
    id <NSCoding> object = nil;
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    NSDate *now = [[NSDate alloc] init];
    [self lock];
        if (self->_ttlCache) {
            // We actually need to know the entire disk state if we're a TTL cache.
            [self unlock];
            [self lockAndWaitForKnownState];
        }
    
        if (!self->_ttlCache || self->_ageLimit <= 0 || fabs([_metadata[key].date timeIntervalSinceDate:now]) < self->_ageLimit) {
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and  the object is still alive
            
            NSData *objectData = [[NSData alloc] initWithContentsOfFile:[fileURL path]];
          
            if (objectData) {
              //Be careful with locking below. We unlock here so that we're not locked while deserializing, we re-lock after.
              [self unlock];
              @try {
                  object = _deserializer(objectData, key);
              }
              @catch (NSException *exception) {
                  NSError *error = nil;
                  [self lock];
                      [[NSFileManager defaultManager] removeItemAtPath:[fileURL path] error:&error];
                  [self unlock];
                  PINDiskCacheError(error)
                  PINDiskCacheException(exception);
              }
              [self lock];
            }
            if (object && !self->_ttlCache) {
                [self asynchronouslySetFileModificationDate:now forURL:fileURL];
            }
        }
    [self unlock];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
    
    return object;
}

/// Helper function to call fileURLForKey:updateFileModificationDate:
- (NSURL *)fileURLForKey:(NSString *)key
{
    // Don't update the file modification time, if self is a ttlCache
    return [self fileURLForKey:key updateFileModificationDate:!self->_ttlCache];
}

- (NSURL *)fileURLForKey:(NSString *)key updateFileModificationDate:(BOOL)updateFileModificationDate
{
    if (!key) {
        return nil;
    }
    
    NSDate *now = [[NSDate alloc] init];
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    [self lockForWriting];
        if (fileURL.path && [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            if (updateFileModificationDate) {
                [self asynchronouslySetFileModificationDate:now forURL:fileURL];
            }
        } else {
            fileURL = nil;
        }
    [self unlock];
    return fileURL;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    [self setObject:object forKey:key fileURL:nil];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost
{
    [self setObject:object forKey:key];
}

- (void)setObject:(id)object forKeyedSubscript:(NSString *)key
{
    if (object == nil) {
        [self removeObjectForKey:key];
    } else {
        [self setObject:object forKey:key];
    }
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    if (!key || !object)
        return;
    
    #if TARGET_OS_IPHONE
      NSDataWritingOptions writeOptions = NSDataWritingAtomic | self.writingProtectionOption;
    #else
      NSDataWritingOptions writeOptions = NSDataWritingAtomic;
    #endif
  
    // Remain unlocked here so that we're not locked while serializing.
    NSData *data = _serializer(object, key);
    NSURL *fileURL = nil;

    NSUInteger byteLimit = self.byteLimit;
    if (data.length <= byteLimit || byteLimit == 0) {
        // The cache is large enough to fit this object (although we may need to evict others).
        fileURL = [self encodedFileURLForKey:key];
    } else {
        // The cache isn't large enough to fit this object (even if all others were evicted).
        // We should not write it to disk because it will be deleted immediately after.
        if (outFileURL) {
            *outFileURL = nil;
        }
        return;
    }

    [self lockForWriting];
    PINDiskCacheObjectBlock willAddObjectBlock = self->_willAddObjectBlock;
        if (willAddObjectBlock) {
            [self unlock];
                willAddObjectBlock(self, key, object);
            [self lock];
        }
    
        NSError *writeError = nil;
        BOOL written = [data writeToURL:fileURL options:writeOptions error:&writeError];
        PINDiskCacheError(writeError);
        
        if (written) {
            if (_metadata[key] == nil) {
                _metadata[key] = [[PINDiskCacheMetadata alloc] init];
            }
            
            NSError *error = nil;
            NSDictionary *values = [fileURL resourceValuesForKeys:@[ NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ] error:&error];
            PINDiskCacheError(error);
            
            NSNumber *diskFileSize = [values objectForKey:NSURLTotalFileAllocatedSizeKey];
            if (diskFileSize) {
                NSNumber *prevDiskFileSize = self->_metadata[key].size;
                if (prevDiskFileSize) {
                    self.byteCount = self->_byteCount - [prevDiskFileSize unsignedIntegerValue];
                }
                self->_metadata[key].size = diskFileSize;
                self.byteCount = self->_byteCount + [diskFileSize unsignedIntegerValue]; // atomic
            }
            NSDate *date = [values objectForKey:NSURLContentModificationDateKey];
            if (date) {
                self->_metadata[key].date = date;
            }
            
            if (self->_byteLimit > 0 && self->_byteCount > self->_byteLimit)
                [self trimToSizeByDateAsync:self->_byteLimit completion:nil];
        } else {
            fileURL = nil;
        }
    
    PINDiskCacheObjectBlock didAddObjectBlock = self->_didAddObjectBlock;
        if (didAddObjectBlock) {
            [self unlock];
                didAddObjectBlock(self, key, object);
            [self lock];
        }
    [self unlock];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

- (void)removeObjectForKey:(NSString *)key
{
    [self removeObjectForKey:key fileURL:nil];
}

- (void)removeObjectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    if (!key)
        return;
    
    NSURL *fileURL = nil;
    
    fileURL = [self encodedFileURLForKey:key];
    
    [self removeFileAndExecuteBlocksForKey:key];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

- (void)trimToSize:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToSize:trimByteCount];
}

- (void)trimToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToDate:trimDate];
}

- (void)trimToSizeByDate:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToSizeByDate:trimByteCount];
}

- (void)removeAllObjects
{
    // We don't need to know the disk state since we're just going to remove everything.
    [self lockForWriting];
        PINCacheBlock willRemoveAllObjectsBlock = self->_willRemoveAllObjectsBlock;
        if (willRemoveAllObjectsBlock) {
            [self unlock];
                willRemoveAllObjectsBlock(self);
            [self lock];
        }
    
        [PINDiskCache moveItemAtURLToTrash:self->_cacheURL];
        [PINDiskCache emptyTrash];
        
        [self _locked_createCacheDirectory];
        
        [self->_metadata removeAllObjects];
        self.byteCount = 0; // atomic
    
        PINCacheBlock didRemoveAllObjectsBlock = self->_didRemoveAllObjectsBlock;
        if (didRemoveAllObjectsBlock) {
            [self unlock];
                didRemoveAllObjectsBlock(self);
            [self lock];
        }
    
    [self unlock];
}

- (void)enumerateObjectsWithBlock:(PINDiskCacheFileURLEnumerationBlock)block
{
    if (!block)
        return;
    
    [self lockAndWaitForKnownState];
        NSDate *now = [NSDate date];
    
        for (NSString *key in _metadata) {
            NSURL *fileURL = [self encodedFileURLForKey:key];
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and the object is still alive
            NSDate *date = _metadata[key].date;
            if (!self->_ttlCache || self->_ageLimit <= 0 || (date && fabs([date timeIntervalSinceDate:now]) < self->_ageLimit)) {
                BOOL stop = NO;
                block(key, fileURL, &stop);
                if (stop)
                    break;
            }
        }
    [self unlock];
}

#pragma mark - Public Thread Safe Accessors -

- (PINDiskCacheObjectBlock)willAddObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _willAddObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setWillAddObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willAddObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)willRemoveObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _willRemoveObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setWillRemoveObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willRemoveObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINCacheBlock)willRemoveAllObjectsBlock
{
    PINCacheBlock block = nil;
    
    [self lock];
        block = _willRemoveAllObjectsBlock;
    [self unlock];
    
    return block;
}

- (void)setWillRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willRemoveAllObjectsBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)didAddObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _didAddObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setDidAddObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didAddObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)didRemoveObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _didRemoveObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setDidRemoveObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didRemoveObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINCacheBlock)didRemoveAllObjectsBlock
{
    PINCacheBlock block = nil;
    
    [self lock];
        block = _didRemoveAllObjectsBlock;
    [self unlock];
    
    return block;
}

- (void)setDidRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didRemoveAllObjectsBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (NSUInteger)byteLimit
{
    NSUInteger byteLimit;
    
    [self lock];
        byteLimit = _byteLimit;
    [self unlock];
    
    return byteLimit;
}

- (void)setByteLimit:(NSUInteger)byteLimit
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_byteLimit = byteLimit;
        [self unlock];
        
        if (byteLimit > 0)
            [self trimDiskToSizeByDate:byteLimit];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (NSTimeInterval)ageLimit
{
    NSTimeInterval ageLimit;
    
    [self lock];
        ageLimit = _ageLimit;
    [self unlock];
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_ageLimit = ageLimit;
        [self unlock];
        
        [self trimToAgeLimitRecursively];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (BOOL)isTTLCache {
    BOOL isTTLCache;
    
    [self lock];
        isTTLCache = _ttlCache;
    [self unlock];
  
    return isTTLCache;
}

- (void)setTtlCache:(BOOL)ttlCache {
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_ttlCache = ttlCache;
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

#if TARGET_OS_IPHONE
- (NSDataWritingOptions)writingProtectionOption {
    NSDataWritingOptions option;
  
    [self lock];
        option = _writingProtectionOption;
    [self unlock];
  
    return option;
}

- (void)setWritingProtectionOption:(NSDataWritingOptions)writingProtectionOption {
  [self.operationQueue scheduleOperation:^{
    NSDataWritingOptions option = NSDataWritingFileProtectionMask & writingProtectionOption;
    
    [self lock];
        self->_writingProtectionOption = option;
    [self unlock];
  } withPriority:PINOperationQueuePriorityHigh];
}
#endif

- (void)lockForWriting
{
    [self lock];
    
    // spinlock if the disk isn't writable
    if (_diskWritable == NO) {
        pthread_cond_wait(&_diskWritableCondition, &_mutex);
    }
}

- (void)lockAndWaitForKnownState
{
    [self lock];
    
    // spinlock if the disk state isn't known
    if (_diskStateKnown == NO) {
        pthread_cond_wait(&_diskStateKnownCondition, &_mutex);
    }
}

- (void)lock
{
    __unused int result = pthread_mutex_lock(&_mutex);
    NSAssert(result == 0, @"Failed to lock PINDiskCache %@. Code: %d", self, result);
}

- (void)unlock
{
    __unused int result = pthread_mutex_unlock(&_mutex);
    NSAssert(result == 0, @"Failed to unlock PINDiskCache %@. Code: %d", self, result);
}

@end

@implementation PINDiskCache (Deprecated)

- (void)lockFileAccessWhileExecutingBlock:(nullable PINCacheBlock)block
{
    [self lockFileAccessWhileExecutingBlockAsync:block];
}

- (void)containsObjectForKey:(NSString *)key block:(PINDiskCacheContainsBlock)block
{
    [self containsObjectForKeyAsync:key completion:block];
}

- (void)objectForKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self objectForKeyAsync:key completion:block];
}

- (void)fileURLForKey:(NSString *)key block:(nullable PINDiskCacheFileURLBlock)block
{
    [self fileURLForKeyAsync:key completion:block];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:block];
}

- (void)removeObjectForKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self removeObjectForKeyAsync:key completion:block];
}

- (void)trimToDate:(NSDate *)date block:(nullable PINDiskCacheBlock)block
{
    [self trimToDateAsync:date completion:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)trimToSize:(NSUInteger)byteCount block:(nullable PINDiskCacheBlock)block
{
    [self trimToSizeAsync:byteCount completion:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)trimToSizeByDate:(NSUInteger)byteCount block:(nullable PINDiskCacheBlock)block
{
    [self trimToSizeAsync:byteCount completion:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)removeAllObjects:(nullable PINDiskCacheBlock)block
{
    [self removeAllObjectsAsync:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)enumerateObjectsWithBlock:(PINDiskCacheFileURLBlock)block completionBlock:(nullable PINDiskCacheBlock)completionBlock
{
    [self enumerateObjectsWithBlockAsync:^(NSString * _Nonnull key, NSURL * _Nullable fileURL, BOOL * _Nonnull stop) {
      block(key, fileURL);
    } completionBlock:^(id<PINCaching> diskCache) {
        if (completionBlock) {
            completionBlock((PINDiskCache *)diskCache);
        }
    }];
}

@end

@implementation PINDiskCacheMetadata
@end
