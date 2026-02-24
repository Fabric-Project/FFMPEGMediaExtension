//
//  LibAVTrackReader.m
//  LibAVExtension
//
//  Created by Anton Marini on 7/25/24.
//

#import "LibAVTrackReader.h"
#import "LibAVFormatReader.h"
#import "LibAVSampleCursor.h"

#import <libavcodec/avcodec.h>
#import <libavcodec/h264_parse.h>
#import <libavformat/avformat.h>
#import <libavutil/mem.h>


#import <CoreMedia/CoreMedia.h>

@interface LibAVTrackReader ()
@property (readwrite, strong) LibAVFormatReader* formatReader;
@property (readwrite, assign) int streamIndex;
@property (readwrite, retain, nullable)  __attribute__((NSObject)) CMFormatDescriptionRef formatDescription;

@end

@implementation LibAVTrackReader

- (instancetype) initWithFormatReader:(LibAVFormatReader*)formatReader stream:(AVStream*)stream atIndex:(int)index;
{
    self = [super init];
    if (self != nil)
    {
        self.formatReader = formatReader;
        
        // Cannot have zero index tracks in AVF - ( kCMPersistentTrackID_Invalid = 0 )
        self.streamIndex = index + 1;
        self->stream = stream;
        
        self.formatDescription = [self calculateFormatDescription];

    }
    return self;
}

- (void)generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:(nonnull void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler
{
    NSLog(@"LibAVTrackReader generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler");
    
    LibAVSampleCursor* sampleCursor = [[LibAVSampleCursor alloc] initWithTrackReader:self pts:kCMTimeZero];
    if (sampleCursor == nil)
    {
        completionHandler(nil, [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorInternalFailure userInfo:nil]);
        return;
    }

    completionHandler(sampleCursor, nil);
}

- (void)generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:(nonnull void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler
{
    NSLog(@"LibAVTrackReader generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler");

    LibAVSampleCursor* sampleCursor = [[LibAVSampleCursor alloc] initWithTrackReader:self pts:self.formatReader.duration];
    if (sampleCursor == nil)
    {
        completionHandler(nil, [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorNoSamples userInfo:nil]);
        return;
    }

    completionHandler(sampleCursor, nil);
}

// Provides a new MESampleCursor object pointing to the sample at or near the specified presentation timestamp.
- (void)generateSampleCursorAtPresentationTimeStamp:(CMTime)presentationTimeStamp completionHandler:(nonnull void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler
{
    NSLog(@"LibAVTrackReader generateSampleCursorAtPresentationTimeStamp %@", CMTimeCopyDescription(kCFAllocatorDefault, presentationTimeStamp));

    LibAVSampleCursor* sampleCursor = [[LibAVSampleCursor alloc] initWithTrackReader:self pts:presentationTimeStamp];
    if (sampleCursor == nil)
    {
        completionHandler(nil, [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorNoSamples userInfo:nil]);
        return;
    }

    completionHandler(sampleCursor, nil);
}

- (void)loadTrackInfoWithCompletionHandler:(nonnull void (^)(METrackInfo * _Nullable, NSError * _Nullable))completionHandler {
    
    NSLog(@"LibAVTrackReader loadTrackInfoWithCompletionHandler");

    CMFormatDescriptionRef format = [self formatDescription];
    
    if (format != NULL)
    {
        NSLog(@"Made Format Description: %@", format);

        NSArray* formats = @[(__bridge id)format];
        
        // This is lame as fuck - we dont have zero based indexes!
        // kCMPersistentTrackID_Invalid = 0 !
        METrackInfo* trackInfo = [[METrackInfo alloc] initWithMediaType:[self streamMediaType]
                                                                trackID:(CMPersistentTrackID)self.streamIndex
                                                     formatDescriptions:formats];
        
        [self populateOptionalMetadataFieldsFor:trackInfo];
        
        // do this in place
        completionHandler(trackInfo, nil);
        return;
    }
        
    completionHandler(nil, nil);
}


- (void)loadUneditedDurationWithCompletionHandler:(void (^)(CMTime uneditedDuration, NSError * _Nullable error))completionHandler
{
    CMTime uneditedDuration = CMTimeMake(self->stream->duration, self->stream->time_base.den);
    
    completionHandler(uneditedDuration, nil);
}

//- (void)loadTotalSampleDataLengthWithCompletionHandler:(void (^)(int64_t totalSampleDataLength, NSError * _Nullable error))completionHandler
//{
//    self->stream->
//}

- (void)loadEstimatedDataRateWithCompletionHandler:(void (^)(Float32 estimatedDataRate, NSError * _Nullable error))completionHandler
{
    Float32 estimatedDataRate = 0.0;
    if (self->stream->codecpar->bit_rate > 0)
    {
        // MediaExtension expects bytes per second.
        estimatedDataRate = (Float32)self->stream->codecpar->bit_rate / 8.0f;
    }
    
    completionHandler(estimatedDataRate, nil);
}

//- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray< AVMetadataItem * > * _Nullable metadata, NSError * _Nullable error))completionHandler
//{
//    
//    
//}

// MARK: - Helper Methods

- (void) populateOptionalMetadataFieldsFor:(METrackInfo*)trackInfo
{
    // TODO: How to know if a stream is enabled?
    trackInfo.enabled = true;
    
    // Additional Metadata:
    trackInfo.nominalFrameRate = av_q2d(self->stream->avg_frame_rate);
    
    trackInfo.naturalSize = ([self streamMediaType] == kCMMediaType_Video) ? CGSizeMake(self->stream->codecpar->width, self->stream->codecpar->height) : CGSizeZero;
    
    trackInfo.naturalTimescale = self->stream->time_base.den > 0 ? self->stream->time_base.den : 600;
    
//        trackInfo.preferredTransform
    trackInfo.requiresFrameReordering = (self->stream->codecpar->video_delay > 0);
    
    // IETF BCP 47 (RFC 4646) which might need conversion
//        trackInfo.extendedLanguageTag
}

- (CMMediaType) streamMediaType
{
    switch (self->stream->codecpar->codec_type)
    {
        case AVMEDIA_TYPE_UNKNOWN:
            return -1;
            
        case AVMEDIA_TYPE_VIDEO:
            return kCMMediaType_Video;

        case AVMEDIA_TYPE_AUDIO:
            return kCMMediaType_Audio;

        case AVMEDIA_TYPE_DATA:
            return kCMMediaType_Metadata; //?

        case AVMEDIA_TYPE_SUBTITLE:
            return kCMMediaType_Subtitle;

        case AVMEDIA_TYPE_ATTACHMENT:
            return -1;

        case AVMEDIA_TYPE_NB:
            return -1;
    }

    return -1;
}

// MARK: - CMFormatDescription

- (nullable CMFormatDescriptionRef) calculateFormatDescription
{
    switch (self->stream->codecpar->codec_type)
    {
        case AVMEDIA_TYPE_UNKNOWN:
            return NULL;
            
        case AVMEDIA_TYPE_VIDEO:
            return [self videoFormatDescription];

        case AVMEDIA_TYPE_AUDIO:
            return [self audioFormatDescription];
            
        case AVMEDIA_TYPE_DATA:
            return NULL;

        case AVMEDIA_TYPE_SUBTITLE:
            return NULL;

        case AVMEDIA_TYPE_ATTACHMENT:
            return NULL;

        case AVMEDIA_TYPE_NB:
            return NULL;
    }

    return NULL;
}

- (nullable CMFormatDescriptionRef) videoFormatDescription
{
    CMFormatDescriptionRef formatDescription = NULL;

    // FourCC
    CMVideoCodecType codecType = (CMVideoCodecType) self->stream->codecpar->codec_tag;

    if (codecType == 0)
    {
        codecType = [self videoCodecTypeFromCodecID];
    }
    
    NSLog(@"LibAVTrackReader videoFormatDescription Found Codec Type: %i", codecType);

    // TODO: is this strictly necessary?
    // Handle special cases:
//    if (codecType == kCMVideoCodecType_H264)
//    {
//        CMVideoFormatDescriptionRef h264VideoFormatDescription = [self createh264VideoFormatDescription];
//        if ( h264VideoFormatDescription != NULL )
//        {
//            return h264VideoFormatDescription;
//        }
//
//        NSLog(@"LibAVTrackReader createh264VideoFormatDescription failed - falling back to generic path");
//    }
    
    // Create Generic video format description
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                     codecType,
                                                     self->stream->codecpar->width,
                                                     self->stream->codecpar->height,
                                                     // Optional extensions
                                                     [self createExtraDataForCodecType:codecType],
                                                     &formatDescription);
    
    if (status != noErr)
    {
        // Handle error
        return NULL;
    }
        
    return formatDescription;
}


- (nullable CMVideoFormatDescriptionRef)createh264VideoFormatDescription
{
    const uint8_t *extradata = self->stream->codecpar->extradata;
    int extradata_size = self->stream->codecpar->extradata_size;
    
    if (!extradata || extradata_size <= 0)
    {
        NSLog(@"LibAVTrackReader: createh264VideoFormatDescription: Invalid H.264 extradata");
        return NULL;
    }
    
    H264ParamSets *ps = malloc(sizeof(H264ParamSets));
    memset(ps, 0, sizeof(H264ParamSets));
  
    int is_avc = 0;
    int nal_size = 0;
    
    int ret = ff_h264_decode_extradata(extradata,
                                       extradata_size,
                                       ps,
                                       &is_avc,
                                       &nal_size,
                                       0,
                                       NULL);

//    int ret = ff_h264_decode_extradata(extradata, extradata_size, &ps);
    if (ret < 0)
    {
        NSLog(@"LibAVTrackReader: createh264VideoFormatDescription: Failed to decode H.264 extradata: %s", av_err2str(ret));
        return NULL;
    }
    
    // Prepare arrays for SPS and PPS
    NSMutableArray *spsArray = [NSMutableArray array];
    NSMutableArray *ppsArray = [NSMutableArray array];
    
    // Extract SPS
    for (int i = 0; i < MAX_SPS_COUNT; i++)
    {
        if (ps->sps_list[i])
        {
            NSData *spsData = [NSData dataWithBytes:ps->sps_list[i]->data length:ps->sps_list[i]->data_size];
            [spsArray addObject:spsData];
        }
    }
    
    // Extract PPS
    for (int i = 0; i < MAX_PPS_COUNT; i++)
    {
        if (ps->pps_list[i])
        {
            NSData *ppsData = [NSData dataWithBytes:ps->pps_list[i]->data length:ps->pps_list[i]->data_size];
            [ppsArray addObject:ppsData];
        }
    }
    
    if ([spsArray count] == 0 || [ppsArray count] == 0)
    {
        NSLog(@"LibAVTrackReader: createh264VideoFormatDescription: No valid SPS or PPS found");
        ff_h264_ps_uninit(ps);
        return NULL;
    }
    
    // Prepare parameters for CMVideoFormatDescriptionCreateFromH264ParameterSets
    NSMutableArray *parameterSets = [NSMutableArray arrayWithArray:spsArray];
    [parameterSets addObjectsFromArray:ppsArray];
    
    size_t parameterSetCount = [parameterSets count];

    // Use malloc to dynamically allocate memory
    const uint8_t **parameterSetPointers = malloc(parameterSetCount * sizeof(uint8_t *));
    size_t *parameterSetSizes = malloc(parameterSetCount * sizeof(size_t));

    [parameterSets enumerateObjectsUsingBlock:^(NSData *paramSet, NSUInteger idx, BOOL *stop) {
        parameterSetPointers[idx] = [paramSet bytes];
        parameterSetSizes[idx] = [paramSet length];
    }];

    // Make sure to free the allocated memory when done

    // Create CMVideoFormatDescription
    CMFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          (int)parameterSetCount,
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          nal_size, // NAL unit length size, typically 4 for H.264
                                                                          &formatDescription);
    
    // Clean up
    ff_h264_ps_uninit(ps);
    
    free(parameterSetPointers);
    free(parameterSetSizes);

    if (status != noErr)
    {
        NSLog(@"LibAVTrackReader: createh264VideoFormatDescription: Failed to create video format description: %d", (int)status);
        return NULL;
    }
    
    return formatDescription;
}
- (nullable CMFormatDescriptionRef) audioFormatDescription
{
    CMAudioFormatDescriptionRef audioFormatDescription = NULL;
    

    AudioFormatID audioFormatID = (AudioFormatID)self->stream->codecpar->codec_tag;
//    if (audioFormatID == 0)
//    {
        audioFormatID = [self audioFormatFromCodecID];
//    }

    NSLog(@"LibAVTrackReader audioFormatDescription Found Codec Type: %i", audioFormatID);

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = self->stream->codecpar->sample_rate;
    asbd.mChannelsPerFrame = self->stream->codecpar->ch_layout.nb_channels;
    asbd.mFormatID = audioFormatID;

    //Calculate layout size
    UInt32 layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions[0]) + (self->stream->codecpar->ch_layout.nb_channels * sizeof(AudioChannelDescription));
    AudioChannelLayout *channelLayout = (AudioChannelLayout *)malloc(layoutSize);
    memset(channelLayout, 0, layoutSize);
    channelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    channelLayout->mNumberChannelDescriptions = self->stream->codecpar->ch_layout.nb_channels;
    
    // Set the channel descriptions based on the mask or map
    for (int i = 0; i < self->stream->codecpar->ch_layout.nb_channels; i++)
    {
        // Assume that the mask is used; handle custom maps if necessary
        uint64_t mask = self->stream->codecpar->ch_layout.u.mask;
        // Translate the mask bit to the appropriate Core Audio channel label
        // This is a simplified example; actual mapping requires matching specific bit positions
        if (mask & AV_CH_FRONT_LEFT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Left;
        }
        else if (mask * AV_CH_FRONT_RIGHT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Right;
        }
        else if (mask * AV_CH_FRONT_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Center;
        }
        else if (mask * AV_CH_LOW_FREQUENCY)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LFEScreen;
        }
        else if (mask * AV_CH_BACK_LEFT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LeftBackSurround;
        }
        else if (mask * AV_CH_BACK_RIGHT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_RightBackSurround;
        }
        else if (mask * AV_CH_FRONT_LEFT_OF_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LeftCenter;
        }
        else if (mask * AV_CH_FRONT_RIGHT_OF_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_RightCenter;
        }
        else if (mask * AV_CH_BACK_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_CenterSurround;
        }
        else if (mask * AV_CH_SIDE_LEFT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LeftSurroundDirect;
        }
        else if (mask * AV_CH_SIDE_RIGHT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_RightSurroundDirect;
        }
        else if (mask * AV_CH_TOP_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_TopCenterSurround;
        }

        // Handle other channels similarly...
    }
    
    // Create audio format description
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                                     &asbd,
                                                     layoutSize,
                                                     channelLayout,
                                                     0,       // Magic cookie size
                                                     NULL,    // Magic cookie
                                                     NULL,    // Extensions
                                                     &audioFormatDescription);
    
    if (status != noErr) {
        // Handle error
        return NULL;
    }
    
    return audioFormatDescription;
}

// MARK: - CMFormatDescription Helpers

// BARF
- (CMVideoCodecType) videoCodecTypeFromCodecID
{
    switch (self->stream->codecpar->codec_id)
    {
        case AV_CODEC_ID_H264:
            return kCMVideoCodecType_H264;
            
        default:
            return -1;
    }
}

// BARF
- (AudioFormatID) audioFormatFromCodecID
{
    switch (self->stream->codecpar->codec_id)
    {
        case AV_CODEC_ID_AAC:
            return kAudioFormatMPEG4AAC;
            
        case AV_CODEC_ID_AC3:
            return kAudioFormatAC3;

        case AV_CODEC_ID_EAC3:
            return kAudioFormatEnhancedAC3;

        default:
            return -1;
    }
}

// MARK: - CMFormatDescription Extra Data
- (nullable CFDictionaryRef) createExtraDataForCodecType:(CMVideoCodecType)codecType
{
    
    switch (codecType)
    {
        case kCMVideoCodecType_H264:
            return [self createH264ExtraData];
            
        default:
            return NULL;
    }
}

// No idea!
- (nullable CFDictionaryRef) createH264ExtraData
{
    uint8_t *extradata = self->stream->codecpar->extradata;
    int extradata_size = self->stream->codecpar->extradata_size;
    
    return extradata_size ? (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{
            @"avcC": [NSData dataWithBytes:extradata length:extradata_size]
        }
    } : NULL ;
}



@end
