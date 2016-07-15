#import "STKLocalFileDataSource.h"
#import "STKDataSource.h"
#import "STKAudioPlayer.h"
#import "NSMutableArray+STKAudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface STKHLSDataSource : STKLocalFileDataSource
@property (nonatomic, retain) NSURL* playlistUrl;
@property (nonatomic, retain) NSMutableArray *segments;
@property (nonatomic, retain) NSMutableArray *tsFiles;
@property (nonatomic, retain) NSMutableDictionary *currentDownloads;
@property (nonatomic, retain) NSMutableDictionary *pendingSegments;
@property (nonatomic, assign) NSUInteger appendedSegments;
@property (nonatomic, assign) BOOL playlistReady;
@property (nonatomic, assign) BOOL canceled;

-(instancetype) initWithURL:(nullable NSURL*)url andTempFileName:(NSString*)tempFile;
-(void) concatenateSegment:(NSString*)aacPath toIndex:(NSUInteger)index;
-(void) maybeStartDownloads:(nullable NSTimer*)timer;
-(void) fetchPlaylist;
-(void) dispose;
@end



NS_ASSUME_NONNULL_END
