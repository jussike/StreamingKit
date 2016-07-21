#import "STKHLSDataSource.h"
#import "STKTSFile.h"
#import "NSString+MD5.h"
#import "libkern/OSAtomic.h"
#import "NSMutableDictionary+STKAudioPlayer.h"

#define defaultRefreshDelay 5
#define defaultSegmentDelay 1
#define playlistTimeoutInterval 60
#define downloadTimerInterval 2
#define maxConcurrentDownloads 2

@interface STKHLSDataSource()
{
    OSSpinLock segmentsLock;
    OSSpinLock appendLock;
    OSSpinLock streamLock;
    NSTimer* downloadTimer;

}

@property (readwrite, copy) NSString* filePath;
@property (strong) NSOperationQueue* downloadQueue;
@property (strong) NSOperationQueue* playlistQueue;
@property (nonatomic, assign) BOOL fetchingStarted;

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
        self.canceled = NO;

        downloadTimer = [NSTimer timerWithTimeInterval:downloadTimerInterval
                                                target:self
                                              selector:@selector(maybeStartDownloads:)
                                              userInfo:nil
                                               repeats:YES];
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
    
    NSURLRequest* request = [[NSURLRequest alloc] initWithURL:self.playlistUrl cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:playlistTimeoutInterval];
    
    [NSURLConnection sendAsynchronousRequest:request queue:self.playlistQueue
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {

                               if (error) {
                                   NSLog(@"error %@", [error description]);
                                   return;
                                }
                               if (self.canceled == NO) {
                                   NSString* playlist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                                   [self parsePlaylist: playlist];
                               }
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
        }
    }
    if (self.segments.count == 0) {
        nextRefreshDelay = 0;
    }

    NSLog(@"Using next call delay: %d", nextRefreshDelay);
    if (self.playlistReady != YES && self.canceled == NO) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextRefreshDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self fetchPlaylist];
        });
    }
    OSSpinLockLock(&segmentsLock);

    if ([newSegments count] > self.segments.count) {
        for (int i = 0; i < newSegments.count; i++) {

                NSString* segment = [newSegments objectAtIndex:i];
                if (![self.segments containsObject:segment]) {
                    NSURL *fileURL = [NSURL URLWithString:segment];

                    STKTSFile* tsFile = [[STKTSFile alloc] initWithUrl:fileURL];
                    tsFile.hlsDelegate = self;
                    [self.tsFiles addObject:tsFile];
                    [self.segments addObject:segment];
                    if (self.currentDownloads.count < maxConcurrentDownloads) {
                        //NSLog(@"downloading %d", i);
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

-(void)concatenateSegment:(NSString*)aacPath toIndex:(NSUInteger)index
{
    NSLog(@"Received segment %d, self %p", index, self);
    OSSpinLockLock(&segmentsLock);
    NSAssert(self.currentDownloads.count > 0, @"current download");
    [self.currentDownloads removeObjectForKey:@(index)];
    OSSpinLockUnlock(&segmentsLock);

    
    if (self.canceled == YES) {
        NSLog(@"Prevented playback file corruption");
        return;
    }
    OSSpinLockLock(&appendLock);

    [self.pendingSegments setObject:aacPath forKey:@(index)];
    //NSLog(@"Added segment %d to pending", index);

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
            NSLog(@"Append path %@", self.filePath);

            NSData* newData = [fm contentsAtPath:aacPath];
            [fileHandle writeData:newData];
            self.appendedSegments++;
            [self.pendingSegments removeObjectForKey:@(firstPendingSegment+i)];
            i++;

            if (self.supportsSeek && [self.delegate respondsToSelector:@selector(dataSourceIsNowSeekable:)]) {
                [self.delegate dataSourceIsNowSeekable:self];
            }

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

    if ([self hasBytesAvailable]) {

        if (!stream) {
            if (self.appendedSegments > 0) {
                [self seekToOffset:position];
            } else {
                [self dataAvailable];
            }
        } else if (eventsRunLoop) {
                CFRunLoopPerformBlock(eventsRunLoop.getCFRunLoop, NSRunLoopCommonModes, ^{
                    [self dataAvailable];
                });
                CFRunLoopWakeUp(eventsRunLoop.getCFRunLoop);
        }
    }
}


-(AudioFileTypeID) audioFileTypeHint
{
    return @(kAudioFileAAC_ADTSType).intValue;
}

-(void) seekToOffset:(SInt64)offset
{
    NSAssert(self.canceled == NO, @"canceled");

    if (self.fetchingStarted == NO && self.canceled == NO) {
        [self fetchPlaylist];
    }

    if (self.appendedSegments > 0) {
        [super seekToOffset:offset];
        return;
    }
    
    self.position = offset;

}



-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    if (self.appendedSegments > 0) {
        if (!stream) {
            [super seekToOffset:self.position];
        }
        return [super readIntoBuffer:buffer withSize:size];
    }
    
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:self.filePath];
    [fileHandle seekToFileOffset:self.position];
    NSData* data = [fileHandle readDataOfLength:size];
    [fileHandle closeFile];
    memcpy(buffer, data.bytes, data.length);
    //[data getBytes:buffer length:size];
    self.position += data.length;

    return data.length;
}

-(void) maybeStartDownloads:(NSTimer*)timer
{
    //NSLog(@"DOWNLOADS, timer %@", timer);
    if (!OSSpinLockTry(&segmentsLock)) {
        NSLog(@"Segment already locked");
        return;
    }
    if (self.currentDownloads.count < maxConcurrentDownloads) {
        [self.tsFiles enumerateObjectsUsingBlock:^(STKTSFile *tsFile, NSUInteger idx, BOOL * _Nonnull stop) {
            if (idx < self.appendedSegments || tsFile.isLocked) {
                return;
            }
            if (tsFile.readyToUse == NO && ![[self.currentDownloads allKeys] containsObject:@(idx)]) {

                NSLog(@"Downloading segment: %lu, i'm %p", (unsigned long)idx, self);
                [self.currentDownloads setObject:tsFile forKey:@(idx)];
                OSSpinLockUnlock(&segmentsLock);
                [tsFile prepareWithIndex:idx WithQueue:self.downloadQueue];
                OSSpinLockLock(&segmentsLock);

            }
            if (self.currentDownloads.count >= maxConcurrentDownloads) {
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


-(void) open
{
    if (self.appendedSegments > 0) {
        OSSpinLockLock(&streamLock);
        [super open];
        OSSpinLockUnlock(&streamLock);
        if (downloadTimer) {
            [eventsRunLoop addTimer:downloadTimer forMode:NSRunLoopCommonModes];
        }
        return;
    }
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

    if ([self supportsSeek] || self.canceled == YES) {
        self.canceled = YES;
        [self dispose];
        [super eof];
        return;
    }

    [self seekToOffset:self.position];

}

-(void) dispose
{
    NSLog(@"Dispose %p", self);
    self.canceled = YES;
    [downloadTimer invalidate];
    downloadTimer = nil;
    [self.downloadQueue cancelAllOperations];
    [self.playlistQueue cancelAllOperations];
    // Prevent ts files to call concatenateSegment
    [self.tsFiles enumerateObjectsUsingBlock:^(STKTSFile*  tsFile, NSUInteger idx, BOOL * _Nonnull stop) {
        [tsFile setHlsDelegate:nil];
    }];

}

@end
