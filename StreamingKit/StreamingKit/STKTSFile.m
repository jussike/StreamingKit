#import "STKTSFile.h"
#import "Utilities.h"
#import "STKTSDemuxer.h"
#import "NSString+MD5.h"
#import "libkern/OSAtomic.h"
#import "NSFileManager+STKAudioPlayer.h"

#define tsTimeout 30

@interface STKTSFile() {
    OSSpinLock lock;
    NSUInteger retryCount;
}

@property (nonatomic, retain) NSURL* url;

@end

@implementation STKTSFile

-(instancetype) initWithUrl:(NSURL*)url
{
    self.url = url;

    if (self = [super init])
    {
        self.readyToUse = NO;
        retryCount = 5;
    }
    return self;
}

-(void) prepareWithIndex:(NSUInteger)index WithQueue:(NSOperationQueue*)queue
{
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* hostWoDomain = [[self.url.host componentsSeparatedByString:@"."] firstObject];
    NSString* identify = [[NSString stringWithFormat:@"%@%@", hostWoDomain, self.url.query] MD5];
    NSString* aacPath = [NSString stringWithFormat:@"%@%@.aac", NSTemporaryDirectory(), identify];
    NSString* tsPath = [NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), identify];
    __weak __typeof__(self) weakSelf = self;

    if ([fm isReadableFileAtPath:aacPath]) {
        
        [fm removeItemAtPath:tsPath error:nil];
        
        dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            OSSpinLockLock(&lock);
            [weakSelf.hlsDelegate concatenateSegment: aacPath toIndex:index];
            weakSelf.readyToUse = YES;
            OSSpinLockUnlock(&lock);

            [weakSelf.hlsDelegate maybeStartDownloads: nil];

        });
        
    } else if ([fm isReadableFileAtPath:tsPath]) {
        
        STKTSDemuxer* t = [[STKTSDemuxer alloc] init];
        [t demux: tsPath]; //this writes a file to aacPath
        [fm removeItemAtPath:tsPath error:nil];
        dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            OSSpinLockLock(&lock);
            [weakSelf.hlsDelegate concatenateSegment: aacPath toIndex:index];
            weakSelf.readyToUse = YES;
            OSSpinLockUnlock(&lock);
            [weakSelf.hlsDelegate maybeStartDownloads: nil];

        });
        
    } else {
        NSURLRequest* request = [[NSURLRequest alloc] initWithURL:weakSelf.url
                                                      cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                  timeoutInterval:tsTimeout];

        [NSURLConnection sendAsynchronousRequest:request queue:queue
                               completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {

                                if (error || ((NSHTTPURLResponse *)response).statusCode != 200) {
                                    NSLog(@"error %@", [error description]);
                                    NSLog(@"Retrying %d", retryCount);
                                    if (retryCount--) {
                                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0ul), ^{
                                            [weakSelf prepareWithIndex:index WithQueue:queue];
                                        });
                                    }
                                    return;
                                }
                                                    
                                BOOL dataReady = [data writeToFile:tsPath atomically:YES];
                                if (dataReady == NO) {
                                    NSLog(@"Error occurred");
                                }
                                if (weakSelf.hlsDelegate) {
                                                    
                                    STKTSDemuxer* t = [[STKTSDemuxer alloc] init];
                                    [t demux: tsPath]; //this writes a file to aacPath
                                    [fm removeItemAtPath:tsPath error:nil];

                                    OSSpinLockLock(&lock);
                                    [weakSelf.hlsDelegate concatenateSegment: aacPath toIndex:index];
                                    weakSelf.readyToUse = YES;
                                    OSSpinLockUnlock(&lock);
                                    [weakSelf.hlsDelegate maybeStartDownloads: nil];
                                }

                                if (dataReady == YES) {
                                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0ul), ^{
                                        // Limit old files in tmp directory
                                        [NSFileManager cleanAacTmpDir:50 keepMax:5000];
                                    });
                                }
                            }];
    }
}

-(BOOL) isReadyToUse
{
    OSSpinLockLock(&lock);
    BOOL ret = _readyToUse;
    OSSpinLockUnlock(&lock);
    return ret;
}

-(BOOL) isLocked
{
    return (lock != 0);
}
@end
