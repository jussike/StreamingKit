#import "NSMutableDictionary+STKAudioPlayer.h"

@implementation NSMutableDictionary (STKAudioPlayer)

- (NSNumber*) firstNSNumberKeyByAscendingOrder
{
    NSUInteger first = NSUIntegerMax;
    NSEnumerator *enumerator = [self keyEnumerator];

    NSNumber* key;
    while ((key = [enumerator nextObject])) {
        NSUInteger a = key.unsignedIntegerValue;
        first = (a < first) ? a : first;
    }
    return @(first);
}

@end
