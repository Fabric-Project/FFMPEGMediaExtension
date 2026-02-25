//
//  LibAVH264CodecPacketFormatter.h
//  LibAVExtension
//

#import <Foundation/Foundation.h>
#import "LibAVCodecPacketFormatting.h"

#import <libavcodec/avcodec.h>

NS_ASSUME_NONNULL_BEGIN

@interface LibAVH264CodecPacketFormatter : NSObject <LibAVCodecPacketFormatting>

- (instancetype)initWithCodecParameters:(const AVCodecParameters *)codecpar;

@end

NS_ASSUME_NONNULL_END
