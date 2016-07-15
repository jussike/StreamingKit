#import "STKTSFile.h"
#import "Utilities.h"
#import "STKTSDemuxer.h"
#import "NSString+MD5.h"
#import "libkern/OSAtomic.h"

@interface STKTSFile() {
    OSSpinLock lock;
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

    if ([fm isReadableFileAtPath:aacPath]) {
        
        [fm removeItemAtPath:tsPath error:nil];
        
        dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            OSSpinLockLock(&lock);
            [self.hlsDelegate concatenateSegment: aacPath toIndex:index];
            self.readyToUse = YES;
            OSSpinLockUnlock(&lock);

            [self.hlsDelegate maybeStartDownloads: nil];

        });
        
    } else if ([fm isReadableFileAtPath:tsPath]) {
        
        STKTSDemuxer* t = [[STKTSDemuxer alloc] init];
        [t demux: tsPath]; //this writes a file to aacPath
        [fm removeItemAtPath:tsPath error:nil];
        dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            OSSpinLockLock(&lock);
            [self.hlsDelegate concatenateSegment: aacPath toIndex:index];
            self.readyToUse = YES;
            OSSpinLockUnlock(&lock);
            [self.hlsDelegate maybeStartDownloads: nil];

        });
        
    } else {
        NSURLRequest* request = [[NSURLRequest alloc] initWithURL:self.url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60];

        [NSURLConnection sendAsynchronousRequest:request queue:queue
                               completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {

                                if (error) {
                                    NSLog(@"error %@", [error description]);
                                    return;
                                }
                                                    
                                BOOL dataReady = [data writeToFile:tsPath atomically:YES];
                                if (dataReady == NO) {
                                    NSLog(@"Error occurred");
                                }
                                if (self.hlsDelegate) {
                                                    
                                    STKTSDemuxer* t = [[STKTSDemuxer alloc] init];
                                    [t demux: tsPath]; //this writes a file to aacPath
                                    [fm removeItemAtPath:tsPath error:nil];

                                    OSSpinLockLock(&lock);
                                    [self.hlsDelegate concatenateSegment: aacPath toIndex:index];
                                    self.readyToUse = YES;
                                    OSSpinLockUnlock(&lock);
                                    [self.hlsDelegate maybeStartDownloads: nil];

                                } else {
                                    NSLog(@"Dont concatenate canceled ts download %@", self.url);
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
