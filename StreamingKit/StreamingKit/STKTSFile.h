#import "STKLocalFileDataSource.h"
#import "STKHLSDataSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface STKTSFile : NSObject
@property (readwrite, weak) STKHLSDataSource* hlsDelegate;
@property (nonatomic, assign, getter=isReadyToUse) BOOL readyToUse;

-(instancetype) initWithUrl:(NSURL*)url;
-(void) prepareWithIndex:(NSUInteger)index WithQueue:(NSOperationQueue*)queue;
-(BOOL) isLocked;

@end
NS_ASSUME_NONNULL_END
