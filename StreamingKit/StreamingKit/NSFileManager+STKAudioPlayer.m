#import "NSFileManager+STKAudioPlayer.h"
#import "sys/stat.h"

@implementation NSFileManager (STKAudioPlayer)

+(NSUInteger)aacFilesOfFolder:(NSString *)folderPath
{
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderPath error:nil];
    NSEnumerator *contentsEnumurator = [contents objectEnumerator];
    NSString *file;
    NSUInteger count = 0;
    while (file = [contentsEnumurator nextObject]) {
        if ([[file pathExtension] isEqualToString:@"aac"]) {
            count++;
        }
    }
    
    return count;
}


+(NSArray*)oldFilesInDirectory:(NSString *)folderPath count:(NSUInteger)count
{
    NSArray *directoryContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderPath
                                                                                    error:nil];

    __block NSMutableArray* files = [[NSMutableArray alloc] initWithCapacity:count];
    __block NSDate* someTimeAgo = [NSDate dateWithTimeIntervalSinceNow:-60*60*24*14];

    [directoryContent enumerateObjectsUsingBlock:^(NSString*  _Nonnull file, NSUInteger idx, BOOL * _Nonnull stop) {
        if (![[file pathExtension] isEqualToString:@"aac"]) {
            return; //same as continue in for-loop
        }
        NSString* filepath = [NSString stringWithFormat:@"%@%@", folderPath, file];
        NSDate *date = [[self class] getATimeForFileAtPath:filepath];
        if ([date compare: someTimeAgo] == NSOrderedAscending) {
            [files addObject:filepath];
            if (files.count >= count) {
                *stop = YES;
            }
        }
    }];
    return files;
}

+(NSDate*)getATimeForFileAtPath:(NSString*)path {
    struct tm* date;
    struct stat attrib;
    
    stat([path UTF8String], &attrib);
    
    date = gmtime(&(attrib.st_atime));  // Get the last access time and put it into the time structure
    
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    [comps setSecond:   date->tm_sec];
    [comps setMinute:   date->tm_min];
    [comps setHour:     date->tm_hour];
    [comps setDay:      date->tm_mday];
    [comps setMonth:    date->tm_mon + 1];
    [comps setYear:     date->tm_year + 1900];
    
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *accessDate = [[cal dateFromComponents:comps] dateByAddingTimeInterval:[[NSTimeZone systemTimeZone] secondsFromGMT]];

    return accessDate;
}

+(void)cleanAacTmpDir:(NSUInteger)items keepMax:(NSUInteger)keep
{
    NSUInteger files = [[self class] aacFilesOfFolder:NSTemporaryDirectory()];
    // 5000 is approx 100 pop songs / 500MiB
    if (files > keep) {
        NSArray* filesToRemove = [[self class]oldFilesInDirectory:NSTemporaryDirectory() count:items];
        [filesToRemove enumerateObjectsUsingBlock:^(NSString*  _Nonnull filepath, NSUInteger idx, BOOL * _Nonnull stop) {
            NSError* error;
            [[NSFileManager defaultManager] removeItemAtPath:filepath error:&error];
            if (error) {
                NSLog(@"Error %@", error);
            }
        }];
    }
}
@end
