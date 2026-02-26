//
//  LibAVFormatReader.m
//  LibAVExtension
//
//  Created by Anton Marini on 7/25/24.
//

#import "LibAVFormatReader.h"
#import "LibAVTrackReader.h"
#import "AVMetadataItem+AVDictionaryEntry.h"
#import <AVFoundation/AVFoundation.h>

@interface LibAVFormatReader ()

@property (readwrite, assign) CMTime duration;
@property (readwrite, assign) int64_t currentReadOffset;
//@property (readwrite, retain) dispatch_queue_t completionQueue;
@property (readwrite, retain) MEByteSource* byteSource;

@end


int readPacket(void *opaque, uint8_t *buf, int buf_size)
{
    LibAVFormatReader* formatReader = (__bridge LibAVFormatReader*) opaque;
    
    size_t bytesRead = 0;
    
    NSError* error = nil;
    
    BOOL readResult = [formatReader.byteSource readDataOfLength:(size_t)buf_size
                                                     fromOffset:formatReader.currentReadOffset
                                                  toDestination:buf
                                                      bytesRead:&bytesRead
                                                          error:&error];

    if (readResult != true || error != nil)
    {
        if (error == nil)
        {
            return AVERROR_UNKNOWN;
        }

        switch (error.code)
        {
            case MEErrorUnsupportedFeature:
                NSLog(@"LibAVFormatReader got readPacket MEErrorUnsupportedFeature: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorAllocationFailure:
                NSLog(@"LibAVFormatReader got readPacket MEErrorAllocationFailure: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorInvalidParameter:
                NSLog(@"LibAVFormatReader got readPacket MEErrorInvalidParameter: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorParsingFailure:
                NSLog(@"LibAVFormatReader got readPacket MEErrorParsingFailure: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorInternalFailure:
                NSLog(@"LibAVFormatReader got readPacket MEErrorInternalFailure: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorPropertyNotSupported:
                NSLog(@"LibAVFormatReader got readPacket MEErrorPropertyNotSupported: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorNoSuchEdit:
                NSLog(@"LibAVFormatReader got readPacket MEErrorNoSuchEdit: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorNoSamples:
                NSLog(@"LibAVFormatReader got readPacket MEErrorNoSamples: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_BUG;

            case MEErrorLocationNotAvailable:
                NSLog(@"LibAVFormatReader got readPacket MEErrorLocationNotAvailable: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_UNKNOWN;
                
            case MEErrorEndOfStream:
                NSLog(@"LibAVFormatReader got readPacket MEErrorEndOfStream: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_EOF;

            case MEErrorPermissionDenied:
                NSLog(@"LibAVFormatReader got readPacket MEErrorPermissionDenied: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_HTTP_UNAUTHORIZED;

            case MEErrorReferenceMissing:
                NSLog(@"LibAVFormatReader got readPacket MEErrorReferenceMissing: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);
                return AVERROR_HTTP_UNAUTHORIZED;

            default:
                NSLog(@"LibAVFormatReader got readPacket unknown error: %@, fromOffset: %lld, size: %i, read: %zu", error, formatReader.currentReadOffset, buf_size, bytesRead);

                return AVERROR_BUG;
        }
    }

    formatReader.currentReadOffset += (int64_t)bytesRead;

    if (bytesRead > INT_MAX)
    {
        return INT_MAX;
    }

    return (int)bytesRead;
}

// Seek callback (optional, if your format requires it)
int64_t seek(void *opaque, int64_t offset, int whence)
{
    LibAVFormatReader* formatReader = (__bridge LibAVFormatReader*) opaque;
    
    switch (whence) {
        case SEEK_SET:
            formatReader.currentReadOffset = MAX((int64_t)0, offset);
            return formatReader.currentReadOffset;
            
        case SEEK_CUR:
            formatReader.currentReadOffset = MAX((int64_t)0, formatReader.currentReadOffset + offset);
            return formatReader.currentReadOffset;

        case SEEK_END:
            formatReader.currentReadOffset = MAX((int64_t)0, [formatReader.byteSource fileLength] + offset);
            return formatReader.currentReadOffset;

        case AVSEEK_SIZE:
            return [formatReader.byteSource fileLength];
    }
    
    return 0;
}



@implementation LibAVFormatReader

+ (void) initialize
{
    // Seems as though this has been deprecated for a while.
    // I've been doing this for too long
    // av_register_all();
}

- (instancetype) initWithByteSource:(MEByteSource*)byteSource;
{
    self = [super init];
    if (self != nil)
    {
        NSLog(@"Initiaizing LibAVFormatReader");
        self.byteSource = byteSource;
        self.currentReadOffset = 0;
    }
    
    return self;
}

- (void) dealloc
{
    if (format_ctx != NULL)
    {
        AVIOContext *localAVIO = format_ctx->pb;
        format_ctx->pb = NULL;
        avformat_close_input(&format_ctx);
        format_ctx = NULL;

        if (localAVIO != NULL)
        {
            av_freep(&localAVIO->buffer);
            avio_context_free(&localAVIO);
        }
    }

    avio_ctx = NULL;
    avio_ctx_buffer = NULL;
}


- (void)loadFileInfoWithCompletionHandler:(void (^)(MEFileInfo* _Nullable fileInfo, NSError * _Nullable error))completionHandler
{
    NSLog(@"LibAVFormatReader loadFileInfoWithCompletionHandler");
    MEFileInfo* fileInfo = [[MEFileInfo alloc] init];
    
    self->format_ctx = avformat_alloc_context();
    if (self->format_ctx == NULL)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorAllocationFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    self->format_ctx->avio_flags = AVIO_FLAG_DIRECT;

    self->avio_ctx_buffer = av_malloc(4096);
    if (self->avio_ctx_buffer == NULL)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorAllocationFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }
    
    // Pass self so we have a callback to our Obj-C objects properties
    self->avio_ctx = avio_alloc_context(self->avio_ctx_buffer, 4096, 0, (__bridge void *)(self), &readPacket, NULL, &seek);
    if (self->avio_ctx == NULL)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorAllocationFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    self->format_ctx->pb = self->avio_ctx;

    int openResult = avformat_open_input(&(self->format_ctx), NULL, NULL, NULL);
    if (openResult < 0)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorParsingFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    if (avformat_find_stream_info(self->format_ctx, NULL) < 0)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorParsingFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    if (self->format_ctx->duration > 0)
    {
        self.duration = CMTimeMake(self->format_ctx->duration, AV_TIME_BASE);
    }
    else
    {
        self.duration = kCMTimeInvalid;
    }
    
    fileInfo.duration = self.duration;
    fileInfo.fragmentsStatus = MEFileInfoCouldNotContainFragments;
    
    NSLog(@"LibAVFormatReader loadFileInfoWithCompletionHandler got duration: %@", CMTimeCopyDescription(kCFAllocatorDefault, fileInfo.duration) );
    
    completionHandler(fileInfo, nil);
}

- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray< AVMetadataItem * > * _Nullable metadata, NSError * _Nullable error))completionHandler
{
    NSLog(@"loadMetadataWithCompletionHandler");

    if (self->format_ctx == NULL)
    {
        completionHandler(@[], nil);
        return;
    }
    
//    if ( av_dict_count(self->format_ctx->metadata) > 0)
//    {
//        NSMutableArray<AVMetadataItem*>* metadataItems = [NSMutableArray new];
//        
//        const AVDictionaryEntry *e = NULL;
//        while ((e = av_dict_iterate(self->format_ctx->metadata, e)))
//        {
//            if (e != NULL)
//            {
//                AVMetadataItem* item = [AVMetadataItem metadataItemFrom:e];
//                [metadataItems addObject:item];
//            }
//        }
//        
//        completionHandler(metadataItems, nil);
//
//    }
    
    
    NSMutableArray<AVMetadataItem *> *metadataItems = [NSMutableArray array];
    const AVDictionaryEntry *entry = NULL;

    while ((entry = av_dict_iterate(self->format_ctx->metadata, entry)))
    {
        AVMetadataItem *item = [AVMetadataItem metadataItemFrom:entry];
        if (item != nil)
        {
            [metadataItems addObject:item];
        }
    }

    completionHandler(metadataItems, nil);
}

- (void)loadTrackReadersWithCompletionHandler:(nonnull void (^)(NSArray<id<METrackReader>> * _Nullable, NSError * _Nullable))completionHandler
{
    NSLog(@"loadTrackReadersWithCompletionHandler");
    
    // iterate over our loaded tracks and create a LibAVTrackReader for each
    NSMutableArray<LibAVTrackReader*>* trackReaders = [NSMutableArray new];
    
    for (unsigned int i = 0; i < self->format_ctx->nb_streams; i++)
    {
        AVStream *stream = self->format_ctx->streams[i];
        
        // TODO: Only support video and audio tracks for now
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
//            || stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
            )
        {
            LibAVTrackReader* trackReader = [[LibAVTrackReader alloc] initWithFormatReader:self stream:stream atIndex:i];
            
            [trackReaders addObject:trackReader];
        }
    }
    
    completionHandler(trackReaders, nil);
}




@end
