#import "STKHLSDataSource.h"
#import "STKTSFile.h"
#import "NSString+MD5.h"
#import "libkern/OSAtomic.h"
#import "NSMutableDictionary+STKAudioPlayer.h"

#define defaultRefreshDelay 5
#define defaultSegmentDelay 1
#define playlistTimeoutInterval 30
#define downloadTimerInterval 2
#define maxConcurrentDownloads 2

@interface STKHLSDataSource()
{
    OSSpinLock segmentsLock;
    OSSpinLock appendLock;
    OSSpinLock streamLock;
    NSTimer* downloadTimer;
    NSUInteger retryCount;

}

@property (readwrite, copy) NSString* filePath;
@property (strong) NSOperationQueue* downloadQueue;
@property (strong) NSOperationQueue* playlistQueue;
@property (nonatomic, assign) BOOL fetchingStarted;
@property (nonatomic, assign) BOOL active;


@end


@implementation STKHLSDataSource
@synthesize filePath;
@synthesize position;
@synthesize length;

-(instancetype) init
{
    if (self = [super init]) {
        self.segments = [[NSMutableArray alloc] init];
        self.tsFiles = [[NSMutableArray alloc] init];
        self.currentDownloads = [[NSMutableDictionary alloc] init];
        self.pendingSegments = [[NSMutableDictionary alloc] init];
        self.downloadQueue = [[NSOperationQueue alloc] init];
        self.playlistQueue = [[NSOperationQueue alloc] init];
        self.appendedSegments = 0;
        self.fetchingStarted = NO;
        downloadTimer = nil;
        retryCount = 1;
    }
    return self;
}

-(instancetype) initWithURL:(NSURL*)url andTempFileName:(NSString*)tempFile
{
    if (self = [self init])
    {
        self.playlistUrl = url;
        self.filePath = [NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), tempFile];
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    }
    
    return self;
}

-(void) fetchPlaylist
{
    NSLog(@"Fetching playlist");
    self.fetchingStarted = YES;

    __weak __typeof__(self) weakSelf = self;

    NSURLRequest* request = [[NSURLRequest alloc] initWithURL:self.playlistUrl cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:playlistTimeoutInterval];
    
    [NSURLConnection sendAsynchronousRequest:request queue:self.playlistQueue
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {

                               if (error || ((NSHTTPURLResponse *)response).statusCode != 200) {
                                   NSLog(@"error %@", [error description]);
                                   if (retryCount-- && self.playlistReady != YES) {
                                       NSLog(@"Retrying %d", retryCount);
                                       dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0ul), ^{
                                           [weakSelf fetchPlaylist];
                                       });
                                   }
                                   return;
                                }
                                NSString* playlist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                                [weakSelf parsePlaylist: playlist];
                           }];
    
}

-(void) parsePlaylist:(NSString*)playlist
{
    NSLog(@"Parsing playlist");

    NSCharacterSet *separator = [NSCharacterSet newlineCharacterSet];
    NSArray *lines = [playlist componentsSeparatedByCharactersInSet:separator];
    NSMutableArray* newSegments = [[NSMutableArray alloc] init];
    
    int nextRefreshDelay = defaultRefreshDelay;
    
    for (NSString* aLine in lines) {
        if ([aLine rangeOfString:@"http"].location != NSNotFound && [aLine rangeOfString:@"EXTINF"].location == NSNotFound) {
            [newSegments skipQueue: aLine];
        }
        else if ([aLine rangeOfString:@"TARGETDURATION"].location != NSNotFound) {
            NSString* delayStr = [aLine substringFromIndex:[aLine rangeOfString:@":"].location + 1];
            int delay = [delayStr intValue];
            nextRefreshDelay = (delay > 2) ? [delayStr intValue] - 2 : 1;
        }
        else if ([aLine rangeOfString:@"ENDLIST"].location != NSNotFound) {
            self.playlistReady = YES;
            ([self supportsSeek]) ? [self tellDelegateIAmSeekable] : 0;
        }
    }
    if (self.segments.count == 0) {
        nextRefreshDelay = 0;
    }
    
    if (self.playlistReady != YES) {
        __weak __typeof__(self) weakSelf = self;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextRefreshDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.active) {
                [weakSelf fetchPlaylist];
            } else {
                NSLog(@"Stop fetching playlist for %@", self.filePath);
            }
        });
    }
    OSSpinLockLock(&segmentsLock);

    if ([newSegments count] > self.segments.count) {
        for (int i = 0; i < newSegments.count; i++) {

                NSString* segment = [newSegments objectAtIndex:i];
                if (![self.segments containsObject:segment]) {
                    NSURL *fileURL = [NSURL URLWithString:segment];
                    STKTSFile* tsFile = [self allocateTSFileWithUrl:fileURL];
                    tsFile.hlsDelegate = self;
                    [self.tsFiles addObject:tsFile];
                    [self.segments addObject:segment];
                    if (self.currentDownloads.count < maxConcurrentDownloads) {
                        [self.currentDownloads setObject:tsFile forKey:@(i)];
                        OSSpinLockUnlock(&segmentsLock);
                        [tsFile prepareWithIndex:i WithQueue:self.downloadQueue];
                        OSSpinLockLock(&segmentsLock);
                    }

                }
        }
    }
    OSSpinLockUnlock(&segmentsLock);

}

/* You should override this */
-(id) allocateTSFileWithUrl: (NSURL*)fileURL
{
    return [[STKTSFile alloc] initWithUrl:fileURL];
}

-(void)concatenateSegment:(NSString*)aacPath toIndex:(NSUInteger)index
{
    OSSpinLockLock(&segmentsLock);
    NSAssert(self.currentDownloads.count > 0, @"current download");
    [self.currentDownloads removeObjectForKey:@(index)];
    OSSpinLockUnlock(&segmentsLock);

    OSSpinLockLock(&appendLock);

    [self.pendingSegments setObject:aacPath forKey:@(index)];

    NSUInteger firstPendingSegment = [self.pendingSegments firstNSNumberKeyByAscendingOrder].unsignedIntegerValue;
    
    if (firstPendingSegment < index) {
        NSLog(@"Waiting previous segment, first pending is %u, index is %u", firstPendingSegment, index);
        OSSpinLockUnlock(&appendLock);
        return;
    }
    if (firstPendingSegment == self.appendedSegments) {
        [self appendPendingSegmentsFromIndex:firstPendingSegment];
    } else {
        OSSpinLockUnlock(&appendLock);
    }
}

-(void) appendPendingSegmentsFromIndex:(NSUInteger)firstPendingSegment
{

    NSFileManager* fm = [NSFileManager defaultManager];
    if (self.appendedSegments == 0 && [fm fileExistsAtPath:self.filePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    }
    if (![fm fileExistsAtPath:self.filePath]) {
        [fm createFileAtPath:self.filePath contents:nil attributes:nil];
    }

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.filePath];
    [fileHandle seekToEndOfFile];

    NSUInteger i = 0;
    while (true) {
        NSString* aacPath = [self.pendingSegments objectForKey:@(firstPendingSegment+i)];
        if (aacPath) {
            NSLog(@"Appending segment: %u, i'm %p", firstPendingSegment+i, self);

            NSData* newData = [fm contentsAtPath:aacPath];
            [fileHandle writeData:newData];
            self.appendedSegments++;
            [self.pendingSegments removeObjectForKey:@(firstPendingSegment+i)];
            i++;
            ([self supportsSeek]) ? [self tellDelegateIAmSeekable] : 0;

        } else {
            break;
        }
    }
    
    NSDictionary* attributes = [fm attributesOfItemAtPath:self.filePath error:nil];
    [fileHandle closeFile];

    NSNumber* number = [attributes objectForKey:@"NSFileSize"];
    
    if (number) {
        self.length = number.longLongValue;
    }
    OSSpinLockUnlock(&appendLock);

    if ([self hasBytesAvailable] && position == 0) {
        [self seekToOffset:position];
    }
}


-(AudioFileTypeID) audioFileTypeHint
{
    return @(kAudioFileAAC_ADTSType).intValue;
}

-(void) seekToOffset:(SInt64)offset
{
    if (self.fetchingStarted == NO || self.active == NO) {
        self.active = YES;
        [self fetchPlaylist];
    }
    ([self supportsSeek]) ? [self tellDelegateIAmSeekable] : 0;

    if (self.appendedSegments > 0) {
        [super seekToOffset:offset];
        return;
    }

    self.position = offset;
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    self.active = YES;
    if (self.appendedSegments > 0) {
        if (!stream) {
            [super seekToOffset:self.position];
        }
        return [super readIntoBuffer:buffer withSize:size];
    }
    
    return -1;
}

-(void) maybeStartDownloads:(NSTimer*)timer
{
    ([self supportsSeek]) ? [self tellDelegateIAmSeekable] : 0;

    if ([self supportsSeek] || self.active == NO) {
        [self stopTimers];
        return;
    }

    if (!OSSpinLockTry(&segmentsLock)) {
        return;
    }
    __weak __typeof__(self) weakSelf = self;

    if (self.currentDownloads.count < maxConcurrentDownloads) {
        [self.tsFiles enumerateObjectsUsingBlock:^(STKTSFile *tsFile, NSUInteger idx, BOOL * _Nonnull stop) {
            if (idx < weakSelf.appendedSegments || tsFile.isLocked) {
                return;
            }
            if (tsFile.readyToUse == NO && ![[self.currentDownloads allKeys] containsObject:@(idx)]) {

                NSLog(@"Downloading segment: %lu, i'm %p", (unsigned long)idx, self);
                [weakSelf.currentDownloads setObject:tsFile forKey:@(idx)];
                OSSpinLockUnlock(&segmentsLock);
                [tsFile prepareWithIndex:idx WithQueue:weakSelf.downloadQueue];
                OSSpinLockLock(&segmentsLock);

            }
            if (weakSelf.currentDownloads.count >= maxConcurrentDownloads) {
                *stop = YES;
            }
        }];
    }
    OSSpinLockUnlock(&segmentsLock);
}


-(BOOL) hasBytesAvailable
{
    BOOL bytesAvailable = NO;
    OSSpinLockLock(&streamLock);

    if (stream) {
        bytesAvailable = CFReadStreamHasBytesAvailable(stream);
    } else {
        bytesAvailable = (self.length > self.position);
    }
    
    OSSpinLockUnlock(&streamLock);

    return bytesAvailable;
}

-(void) close
{
    // closed by STKAudioPlayer
    if (self.delegate == nil) {
        self.active = NO;
    }
    [super close];
}

-(void)dealloc
{
    [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
}

-(void) open
{
    if (self.appendedSegments > 0) {
        OSSpinLockLock(&streamLock);
        [super open];
        OSSpinLockUnlock(&streamLock);
    }

    if (!downloadTimer) {
        downloadTimer = [NSTimer timerWithTimeInterval:downloadTimerInterval
                                                target:self
                                              selector:@selector(maybeStartDownloads:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:downloadTimer forMode:NSRunLoopCommonModes];
    }

    ([self supportsSeek]) ? [self tellDelegateIAmSeekable] : 0;

}

-(BOOL) supportsSeek
{
    if (self.playlistReady == YES && self.appendedSegments == self.segments.count) {
        return YES;
    } else {
        return NO;
    }
}

-(void) eof
{
    if ([self supportsSeek]) {
        [super eof];
        return;
    }

    [self seekToOffset:self.position];
}

-(void) stopTimers
{
    NSLog(@"Invalidating timer, self %p", self);
    [downloadTimer invalidate];
    downloadTimer = nil;
}

-(void) tellDelegateIAmSeekable
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(dataSourceIsNowSeekable:)]) {
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.delegate dataSourceIsNowSeekable:self];
        });
    }
}

-(NSString*) description
{
    return self.filePath;
}

@end
