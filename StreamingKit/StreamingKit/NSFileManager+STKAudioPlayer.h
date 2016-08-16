#import <Foundation/Foundation.h>

@interface NSFileManager (STKAudioPlayer)
+(void)cleanAacTmpDir:(NSUInteger)items keepMax:(NSUInteger)keep;
@end
