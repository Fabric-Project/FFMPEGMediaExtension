//
//  LibAVFormatReader.h
//  LibAVExtension
//
//  Created by Anton Marini on 7/25/24.
//

#import <Foundation/Foundation.h>
#import <MediaExtension/MediaExtension.h>

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avio.h>
#import <libavutil/file.h>

#import <dispatch/dispatch.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface LibAVFormatReader : NSObject <MEFormatReader>
{
    @public AVFormatContext *format_ctx;

    // We use this to proxy loading from the vended bytes from whatever the hell sandbox
    // into something that AVFormat can handle
    AVIOContext *avio_ctx;
    uint8_t *avio_ctx_buffer;
}

@property (readonly, assign) CMTime duration;
@property (readonly, assign) int64_t currentReadOffset;
@property (readonly, retain) MEByteSource* byteSource;

- (instancetype) initWithByteSource:(MEByteSource*)byteSource;

@end

NS_ASSUME_NONNULL_END
