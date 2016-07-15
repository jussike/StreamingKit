//
//  STKTSDemuxer.cpp
//
//  Created by Jussi on 15/06/16.
//
//

#import "STKTSDemuxer.h"
#import "ts.h"

@implementation STKTSDemuxer

-(id) init
{
    self = [super init];
    return self;
}

-(int) demux:(NSString*)filepath
{
    ts::demuxer cpp_demuxer;
    cpp_demuxer.parse_only=false; //enable demuxing
    cpp_demuxer.es_parse=false;
    cpp_demuxer.dump=0;
    cpp_demuxer.av_only=true;
    cpp_demuxer.channel=0;
    cpp_demuxer.pes_output=false;
    cpp_demuxer.prefix = [[[NSProcessInfo processInfo] globallyUniqueString] UTF8String];

    return cpp_demuxer.demux_file([filepath UTF8String]);
}

@end