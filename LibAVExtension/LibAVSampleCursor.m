//
//  LibAVSampleCursor.m
//  LibAVExtensionHost
//
//  Created by Anton Marini on 7/31/24.
//

#import "LibAVSampleCursor.h"
#import "LibAVTrackReader.h"
#import "LibAVFormatReader.h"
#import "LibAVCodecPacketFormatting.h"
#import "LibAVH264CodecPacketFormatter.h"

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avio.h>
#import <libavutil/file.h>

static const int kCursorAVIOBufferSize = 4096;

typedef NS_ENUM(NSInteger, LibAVCursorStepTimeline) {
    LibAVCursorStepTimelineDecode = 0,
    LibAVCursorStepTimelinePresentation = 1,
};

static NSString *LibAVTimeString(CMTime time)
{
    if (CMTIME_IS_INVALID(time))
    {
        return @"{invalid}";
    }
    if (CMTIME_IS_POSITIVE_INFINITY(time))
    {
        return @"{+inf}";
    }
    if (CMTIME_IS_NEGATIVE_INFINITY(time))
    {
        return @"{-inf}";
    }
    if (CMTIME_IS_INDEFINITE(time))
    {
        return @"{indefinite}";
    }
    return [NSString stringWithFormat:@"{%lld/%d = %.6f}", time.value, time.timescale, CMTimeGetSeconds(time)];
}

@interface LibAVSampleCursor ()
@property (readwrite, strong) LibAVTrackReader* trackReader;

// Required private setters
@property (nonatomic, readwrite) CMTime presentationTimeStamp;
@property (nonatomic, readwrite) CMTime decodeTimeStamp;
@property (nonatomic, readwrite) CMTime currentSampleDuration;
@property (nonatomic, readwrite, nullable) __attribute__((NSObject)) CMFormatDescriptionRef currentSampleFormatDescription;

// Optional sync private setters
@property (nonatomic, readwrite) AVSampleCursorSyncInfo syncInfo;
@property (nonatomic, readwrite) AVSampleCursorDependencyInfo dependencyInfo;
@property (nonatomic, readwrite) CMTime decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource;
@property (nonatomic, readwrite) BOOL isReady;

// Private sample location state
@property (nonatomic, readwrite, assign) int64_t sampleOffset;
@property (nonatomic, readwrite, assign) size_t sampleSize;
@property (nonatomic, readwrite, assign) int64_t cursorReadOffset;
@property (nonatomic, readwrite) CMTime pendingDecodeAnchorTime;
@property (nonatomic, readwrite, assign) int64_t debugOpID;
@property (nonatomic, readwrite, copy) NSString * _Nullable debugOpName;
@property (nonatomic, readwrite, assign) LibAVCursorStepTimeline debugTimeline;
@property (nonatomic, readwrite) CMTime lastDeliveredDecodeTimeStamp;
@property (nonatomic, readwrite, assign) int64_t deliveredSampleAuditCount;
@property (nonatomic, strong, nullable) id<LibAVCodecPacketFormatting> packetFormatter;

- (BOOL)trackLikelyHasReorderedPresentation;
- (void)alignToSourceSampleLocation:(LibAVSampleCursor *)source;
- (void)beginDebugOp:(NSString *)name timeline:(LibAVCursorStepTimeline)timeline;
- (NSString *)debugTracePrefix;
- (void)logSampleAuditForPacket:(const AVPacket *)packet
                   sampleBuffer:(CMSampleBufferRef)sampleBuffer
                    sampleBytes:(const uint8_t *)sampleBytes
                     packetSize:(size_t)packetSize
                         isAVCC:(BOOL)isAVCC;

@end

@implementation LibAVSampleCursor
{
    AVFormatContext *_cursorFormatCtx;
    AVIOContext *_cursorAVIOCtx;
    uint8_t *_cursorAVIOBuffer;
    AVPacket *_packet;
}

static int64_t gLibAVCursorDebugOpCounter = 0;
static int64_t gLibAVCursorGlobalSampleEmitCounter = 0;

#pragma mark - FFmpeg I/O callbacks

static int libavCursorReadPacket(void *opaque, uint8_t *buf, int bufSize)
{
    LibAVSampleCursor *cursor = (__bridge LibAVSampleCursor *)opaque;

    size_t bytesRead = 0;
    NSError *error = nil;

    BOOL readResult = [cursor.trackReader.formatReader.byteSource readDataOfLength:(size_t)bufSize
                                                                         fromOffset:cursor.cursorReadOffset
                                                                      toDestination:buf
                                                                          bytesRead:&bytesRead
                                                                              error:&error];

    if (!readResult || error != nil)
    {
        if (error == nil)
        {
            return AVERROR_UNKNOWN;
        }

        if (error.code == MEErrorEndOfStream)
        {
            return AVERROR_EOF;
        }

        if (error.code == MEErrorPermissionDenied)
        {
            return AVERROR(EACCES);
        }

        if (error.code == MEErrorInvalidParameter)
        {
            return AVERROR(EINVAL);
        }

        return AVERROR_UNKNOWN;
    }

    cursor.cursorReadOffset += (int64_t)bytesRead;

    if (bytesRead > INT_MAX)
    {
        return INT_MAX;
    }

    return (int)bytesRead;
}

static int64_t libavCursorSeek(void *opaque, int64_t offset, int whence)
{
    LibAVSampleCursor *cursor = (__bridge LibAVSampleCursor *)opaque;
    MEByteSource *byteSource = cursor.trackReader.formatReader.byteSource;
    int origin = whence & ~AVSEEK_FORCE;

    switch (origin)
    {
        case SEEK_SET:
            cursor.cursorReadOffset = MAX((int64_t)0, offset);
            return cursor.cursorReadOffset;

        case SEEK_CUR:
            cursor.cursorReadOffset = MAX((int64_t)0, cursor.cursorReadOffset + offset);
            return cursor.cursorReadOffset;

        case SEEK_END:
            cursor.cursorReadOffset = MAX((int64_t)0, byteSource.fileLength + offset);
            return cursor.cursorReadOffset;

        case AVSEEK_SIZE:
            return byteSource.fileLength;

        default:
            return AVERROR(EINVAL);
    }
}

#pragma mark - Lifecycle

- (instancetype)initWithTrackReader:(LibAVTrackReader*)trackReader pts:(CMTime)pts
{
    self = [super init];
    if (self)
    {
        self.trackReader = trackReader;
        self.currentSampleFormatDescription = trackReader.formatDescription;
        self.presentationTimeStamp = kCMTimeInvalid;
        self.decodeTimeStamp = kCMTimeInvalid;
        self.currentSampleDuration = kCMTimeIndefinite;
        self.sampleOffset = -1;
        self.sampleSize = 0;
        self.cursorReadOffset = 0;
        self.pendingDecodeAnchorTime = kCMTimeInvalid;
        self.isReady = NO;
        self.debugOpID = 0;
        self.debugOpName = @"init";
        self.debugTimeline = LibAVCursorStepTimelinePresentation;
        self.lastDeliveredDecodeTimeStamp = kCMTimeInvalid;
        self.deliveredSampleAuditCount = 0;
        self.packetFormatter = nil;

        if (self.trackReader != nil &&
            self.trackReader->stream != NULL &&
            self.trackReader->stream->codecpar != NULL &&
            self.trackReader->stream->codecpar->codec_id == AV_CODEC_ID_H264)
        {
            self.packetFormatter = [[LibAVH264CodecPacketFormatter alloc] initWithCodecParameters:self.trackReader->stream->codecpar];
        }

        [self beginDebugOp:@"initWithPTS" timeline:LibAVCursorStepTimelinePresentation];
        NSLog(@"[LibAVSampleCursor %p %@] init requestedPTS=%@", self, [self debugTracePrefix], LibAVTimeString(pts));
        [self openDemuxContext];

        if (_cursorFormatCtx == NULL || _packet == NULL || !self.isReady)
        {
            [self closeDemuxContext];
            return nil;
        }

        int seekResult = [self seekToPTS:pts];
        if (seekResult < 0)
        {
            [self closeDemuxContext];
            return nil;
        }

        int readResult = [self readPacketAtOrAfterTime:pts timeline:LibAVCursorStepTimelinePresentation];
        if (readResult < 0)
        {
            [self closeDemuxContext];
            return nil;
        }
        NSLog(@"[LibAVSampleCursor %p %@] init ready pts=%@ dts=%@ dur=%@ size=%zu offset=%lld",
              self,
              [self debugTracePrefix],
              LibAVTimeString(self.presentationTimeStamp),
              LibAVTimeString(self.decodeTimeStamp),
              LibAVTimeString(self.currentSampleDuration),
              self.sampleSize,
              self.sampleOffset);
    }

    return self;
}

- (instancetype)initWithTrackReader:(LibAVTrackReader *)trackReader
                                 pts:(CMTime)pts
                                 dts:(CMTime)dts
                            duration:(CMTime)duration
                                size:(size_t)sampleSize
                              offset:(int64_t)offset
                            syncInfo:(AVSampleCursorSyncInfo)syncInfo
                      dependencyInfo:(AVSampleCursorDependencyInfo)dependencyInfo
{
    self = [self initWithTrackReader:trackReader pts:pts];
    if (self)
    {
        // Keep the packet-positioned timestamps resolved by initWithTrackReader:pts:.
        // Re-injecting caller-provided DTS values can poison future seeks/copies.
        self.currentSampleDuration = duration;
        self.sampleSize = sampleSize;
        self.sampleOffset = offset;
        self.syncInfo = syncInfo;
        self.dependencyInfo = dependencyInfo;
        (void)dts;
    }

    return self;
}

- (void)dealloc
{
    [self closeDemuxContext];
    self.trackReader = nil;
    self.currentSampleFormatDescription = NULL;
}

- (id)copyWithZone:(nullable NSZone *)zone
{
    LibAVSampleCursor *copy = [[LibAVSampleCursor alloc] initWithTrackReader:self.trackReader
                                                                          pts:self.presentationTimeStamp
                                                                          dts:self.decodeTimeStamp
                                                                     duration:self.currentSampleDuration
                                                                         size:self.sampleSize
                                                                       offset:self.sampleOffset
                                                                     syncInfo:self.syncInfo
                                                               dependencyInfo:self.dependencyInfo];
    if (copy != nil)
    {
        [copy alignToSourceSampleLocation:self];
    }
    NSLog(@"[LibAVSampleCursor %p %@] copy -> %p srcPTS=%@ srcDTS=%@ dstPTS=%@ dstDTS=%@",
          self,
          [self debugTracePrefix],
          copy,
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp),
          LibAVTimeString(copy.presentationTimeStamp),
          LibAVTimeString(copy.decodeTimeStamp));
    return copy;
}

#pragma mark - MESampleCursor required stepping

- (void)stepByDecodeTime:(CMTime)deltaDecodeTime
       completionHandler:(void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
    [self beginDebugOp:@"stepByDecodeTime" timeline:LibAVCursorStepTimelineDecode];
    if (!self.isReady)
    {
        completionHandler(self.decodeTimeStamp, YES, [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorInternalFailure userInfo:nil]);
        return;
    }

    CMTime targetDTS = CMTimeAdd(self.decodeTimeStamp, deltaDecodeTime);
    CMTimeRange trackRange = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);

    BOOL wasPinned = NO;
    if (CMTIME_IS_VALID(self.trackReader.formatReader.duration) && !CMTimeRangeContainsTime(trackRange, targetDTS))
    {
        targetDTS = CMTimeClampToRange(targetDTS, trackRange);
        wasPinned = YES;
    }

    int seekResult = [self seekToDTS:targetDTS];
    if (seekResult < 0)
    {
        completionHandler(self.decodeTimeStamp, wasPinned, [self libAVFormatErrorFrom:seekResult]);
        return;
    }

    int readResult = [self readPacketAtOrAfterTime:targetDTS timeline:LibAVCursorStepTimelineDecode];
    if (readResult < 0)
    {
        if (readResult == AVERROR_EOF)
        {
            completionHandler(self.decodeTimeStamp, YES, nil);
            return;
        }

        completionHandler(self.decodeTimeStamp, wasPinned, [self libAVFormatErrorFrom:readResult]);
        return;
    }

    NSLog(@"[LibAVSampleCursor %p %@] stepByDecodeTime delta=%@ target=%@ resultDTS=%@ resultPTS=%@ pinned=%d",
          self,
          [self debugTracePrefix],
          LibAVTimeString(deltaDecodeTime),
          LibAVTimeString(targetDTS),
          LibAVTimeString(self.decodeTimeStamp),
          LibAVTimeString(self.presentationTimeStamp),
          wasPinned);
    completionHandler(self.decodeTimeStamp, wasPinned, nil);
}

- (void)stepByPresentationTime:(CMTime)deltaPresentationTime
             completionHandler:(void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
    [self beginDebugOp:@"stepByPresentationTime" timeline:LibAVCursorStepTimelinePresentation];
    if (!self.isReady)
    {
        completionHandler(self.presentationTimeStamp, YES, [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorInternalFailure userInfo:nil]);
        return;
    }

    CMTime targetPTS = CMTimeAdd(self.presentationTimeStamp, deltaPresentationTime);
    CMTimeRange trackRange = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);

    BOOL wasPinned = NO;
    if (CMTIME_IS_VALID(self.trackReader.formatReader.duration) && !CMTimeRangeContainsTime(trackRange, targetPTS))
    {
        targetPTS = CMTimeClampToRange(targetPTS, trackRange);
        wasPinned = YES;
    }

    int seekResult = [self seekToPTS:targetPTS];
    if (seekResult < 0)
    {
        completionHandler(self.presentationTimeStamp, wasPinned, [self libAVFormatErrorFrom:seekResult]);
        return;
    }

    int readResult = [self readPacketAtOrAfterTime:targetPTS timeline:LibAVCursorStepTimelinePresentation];
    if (readResult < 0)
    {
        if (readResult == AVERROR_EOF)
        {
            completionHandler(self.presentationTimeStamp, YES, nil);
            return;
        }

        completionHandler(self.presentationTimeStamp, wasPinned, [self libAVFormatErrorFrom:readResult]);
        return;
    }

    NSLog(@"[LibAVSampleCursor %p %@] stepByPresentationTime delta=%@ target=%@ resultPTS=%@ resultDTS=%@ pinned=%d",
          self,
          [self debugTracePrefix],
          LibAVTimeString(deltaPresentationTime),
          LibAVTimeString(targetPTS),
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp),
          wasPinned);
    completionHandler(self.presentationTimeStamp, wasPinned, nil);
}

- (void)stepInDecodeOrderByCount:(int64_t)stepCount
                completionHandler:(void (^)(int64_t actualStepCount, NSError * _Nullable error))completionHandler
{
    [self beginDebugOp:@"stepInDecodeOrderByCount" timeline:LibAVCursorStepTimelineDecode];
    NSLog(@"[LibAVSampleCursor %p %@] stepInDecodeOrderByCount requested=%lld", self, [self debugTracePrefix], stepCount);
    [self stepByCount:stepCount timeline:LibAVCursorStepTimelineDecode completionHandler:completionHandler];
}

- (void)stepInPresentationOrderByCount:(int64_t)stepCount
                     completionHandler:(void (^)(int64_t actualStepCount, NSError * _Nullable error))completionHandler
{
    [self beginDebugOp:@"stepInPresentationOrderByCount" timeline:LibAVCursorStepTimelinePresentation];
    NSLog(@"[LibAVSampleCursor %p %@] stepInPresentationOrderByCount requested=%lld", self, [self debugTracePrefix], stepCount);
    [self stepByCount:stepCount timeline:LibAVCursorStepTimelinePresentation completionHandler:completionHandler];
}

#pragma mark - MESampleCursor optional behavior

- (BOOL)samplesWithEarlierDTSsMayHaveLaterPTSsThanCursor:(id<MESampleCursor>)cursor
{
    // Advertise stream-level reordering capability consistently. Waiting to "observe"
    // PTS!=DTS at the current cursor can mislead host policy at startup/keyframe regions.
    BOOL reordered = [self trackLikelyHasReorderedPresentation];
    NSLog(@"[LibAVSampleCursor %p %@] query earlierDTSLaterPTSThan cursor=%p -> %d",
          self,
          [self debugTracePrefix],
          cursor,
          reordered);
    return reordered;
}

- (BOOL)samplesWithLaterDTSsMayHaveEarlierPTSsThanCursor:(id<MESampleCursor>)cursor
{
    // Advertise stream-level reordering capability consistently. Waiting to "observe"
    // PTS!=DTS at the current cursor can mislead host policy at startup/keyframe regions.
    BOOL reordered = [self trackLikelyHasReorderedPresentation];
    NSLog(@"[LibAVSampleCursor %p %@] query laterDTSEarlierPTSThan cursor=%p -> %d",
          self,
          [self debugTracePrefix],
          cursor,
          reordered);
    return reordered;
}

- (MESampleCursorChunk * _Nullable)chunkDetailsReturningError:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    if (![self currentPacketHasValidData] || self.sampleOffset < 0 || self.sampleSize == 0)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorLocationNotAvailable userInfo:nil];
        }
        return nil;
    }

    BOOL requiresSampleBufferPath = (self.packetFormatter != nil && [self.packetFormatter requiresSampleBufferPath]);
    // Keep reordered/dependent/formatter-required samples on the sample-buffer path.
    if (requiresSampleBufferPath || [self trackLikelyHasReorderedPresentation] || self.dependencyInfo.sampleDependsOnOthers)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorLocationNotAvailable userInfo:nil];
        }
        return nil;
    }

    AVSampleCursorStorageRange range;
    range.offset = self.sampleOffset;
    range.length = self.sampleSize;

    AVSampleCursorChunkInfo info;
    info.chunkSampleCount = 1;
    info.chunkHasUniformSampleSizes = true;
    info.chunkHasUniformSampleDurations = true;
    info.chunkHasUniformFormatDescriptions = true;

    MESampleCursorChunk *chunk =
        [[MESampleCursorChunk alloc] initWithByteSource:self.trackReader.formatReader.byteSource
                                      chunkStorageRange:range
                                              chunkInfo:info
                                 sampleIndexWithinChunk:0];
    return chunk;
}

- (MESampleLocation * _Nullable)sampleLocationReturningError:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    if (![self currentPacketHasValidData] || self.sampleOffset < 0 || self.sampleSize == 0)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorLocationNotAvailable userInfo:nil];
        }
        return nil;
    }

    BOOL requiresSampleBufferPath = (self.packetFormatter != nil && [self.packetFormatter requiresSampleBufferPath]);
    // Keep reordered/dependent/formatter-required samples on the sample-buffer path.
    if (requiresSampleBufferPath || [self trackLikelyHasReorderedPresentation] || self.dependencyInfo.sampleDependsOnOthers)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorLocationNotAvailable userInfo:nil];
        }
        return nil;
    }

    AVSampleCursorStorageRange range;
    range.offset = self.sampleOffset;
    range.length = self.sampleSize;
    MESampleLocation *location =
        [[MESampleLocation alloc] initWithByteSource:self.trackReader.formatReader.byteSource
                                      sampleLocation:range];
    return location;
}

- (void)loadSampleBufferContainingSamplesToEndCursor:(id<MESampleCursor> _Nullable)endSampleCursor
                                   completionHandler:(void (^)(CMSampleBufferRef _Nullable, NSError * _Nullable))completionHandler
{
    [self beginDebugOp:@"loadSampleBuffer" timeline:LibAVCursorStepTimelinePresentation];
    NSLog(@"[LibAVSampleCursor %p %@] loadSampleBuffer start cursorPTS=%@ cursorDTS=%@ cursorDur=%@ cursorSize=%zu endPTS=%@",
          self,
          [self debugTracePrefix],
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp),
          LibAVTimeString(self.currentSampleDuration),
          self.sampleSize,
          (endSampleCursor != nil) ? LibAVTimeString(endSampleCursor.presentationTimeStamp) : @"{nil}");

    if (!self.isReady)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorInternalFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    if (endSampleCursor != nil)
    {
        // Validate "end before start" only in decode order. Presentation timestamps can
        // legitimately move backward on reordered GOP streams and must not cause NO_SAMPLES.
        CMTime endDTS = endSampleCursor.decodeTimeStamp;
        CMTime startDTS = self.decodeTimeStamp;
        if (CMTIME_IS_NUMERIC(endDTS) &&
            CMTIME_IS_NUMERIC(startDTS) &&
            CMTIME_COMPARE_INLINE(endDTS, <, startDTS))
        {
            NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorNoSamples userInfo:nil];
            completionHandler(nil, error);
            return;
        }

        // For non-reordered tracks, opportunistically batch a short decode-order run.
        if (![self trackLikelyHasReorderedPresentation] &&
            CMTIME_IS_NUMERIC(endDTS) &&
            CMTIME_IS_NUMERIC(startDTS) &&
            CMTIME_COMPARE_INLINE(endDTS, >, startDTS))
        {
            const int kMaxBatchSamples = 8;
            LibAVSampleCursor *batchCursor = [self copy];
            NSMutableData *batchedPayload = [NSMutableData dataWithCapacity:4096];
            NSMutableArray<NSValue *> *timingValues = [NSMutableArray arrayWithCapacity:kMaxBatchSamples];
            NSMutableArray<NSNumber *> *sampleSizes = [NSMutableArray arrayWithCapacity:kMaxBatchSamples];
            NSMutableArray<NSNumber *> *sampleIsKeyframe = [NSMutableArray arrayWithCapacity:kMaxBatchSamples];

            int collected = 0;
            while (batchCursor != nil && collected < kMaxBatchSamples && [batchCursor currentPacketHasValidData])
            {
                CMSampleBufferRef one = [batchCursor createSampleBufferFromPacket:batchCursor->_packet];
                if (one == NULL)
                {
                    break;
                }

                CMBlockBufferRef oneData = CMSampleBufferGetDataBuffer(one);
                size_t oneSize = (size_t)CMBlockBufferGetDataLength(oneData);
                NSMutableData *oneBytes = [NSMutableData dataWithLength:oneSize];
                OSStatus copyStatus = CMBlockBufferCopyDataBytes(oneData, 0, oneSize, oneBytes.mutableBytes);
                if (copyStatus != noErr)
                {
                    CFRelease(one);
                    break;
                }

                CMSampleTimingInfo oneTiming;
                OSStatus timingStatus = CMSampleBufferGetSampleTimingInfo(one, 0, &oneTiming);
                if (timingStatus != noErr)
                {
                    CFRelease(one);
                    break;
                }

                [batchedPayload appendData:oneBytes];
                [timingValues addObject:[NSValue valueWithBytes:&oneTiming objCType:@encode(CMSampleTimingInfo)]];
                [sampleSizes addObject:@(oneSize)];
                [sampleIsKeyframe addObject:@(((batchCursor->_packet->flags & AV_PKT_FLAG_KEY) != 0) ? YES : NO)];
                collected += 1;

                CMTime batchDTS = batchCursor.decodeTimeStamp;
                CFRelease(one);

                if (CMTIME_COMPARE_INLINE(batchDTS, >=, endDTS))
                {
                    break;
                }

                __block int64_t actualStep = 0;
                __block NSError *stepError = nil;
                [batchCursor stepInDecodeOrderByCount:1 completionHandler:^(int64_t actual, NSError * _Nullable error) {
                    actualStep = actual;
                    stepError = error;
                }];
                if (stepError != nil || actualStep != 1)
                {
                    break;
                }
            }

            if (collected > 1 && batchedPayload.length > 0)
            {
                CMBlockBufferRef batchedBlockBuffer = NULL;
                CMSampleBufferRef batchedSampleBuffer = NULL;
                OSStatus blockStatus = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                                           NULL,
                                                                           batchedPayload.length,
                                                                           kCFAllocatorDefault,
                                                                           NULL,
                                                                           0,
                                                                           batchedPayload.length,
                                                                           0,
                                                                           &batchedBlockBuffer);
                if (blockStatus == kCMBlockBufferNoErr)
                {
                    blockStatus = CMBlockBufferReplaceDataBytes(batchedPayload.bytes,
                                                                batchedBlockBuffer,
                                                                0,
                                                                batchedPayload.length);
                }

                if (blockStatus == kCMBlockBufferNoErr)
                {
                    CMSampleTimingInfo *timings = calloc((size_t)collected, sizeof(CMSampleTimingInfo));
                    size_t *sizes = calloc((size_t)collected, sizeof(size_t));
                    if (timings != NULL && sizes != NULL)
                    {
                        for (int i = 0; i < collected; i++)
                        {
                            CMSampleTimingInfo timing;
                            [timingValues[(NSUInteger)i] getValue:&timing];
                            timings[i] = timing;
                            sizes[i] = (size_t)sampleSizes[(NSUInteger)i].unsignedLongLongValue;
                        }

                        OSStatus sampleStatus = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                                                          batchedBlockBuffer,
                                                                          self.currentSampleFormatDescription,
                                                                          collected,
                                                                          collected,
                                                                          timings,
                                                                          collected,
                                                                          sizes,
                                                                          &batchedSampleBuffer);
                        if (sampleStatus == noErr && batchedSampleBuffer != NULL)
                        {
                            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(batchedSampleBuffer, true);
                            if (attachments != NULL)
                            {
                                CFIndex attachmentCount = CFArrayGetCount(attachments);
                                for (CFIndex i = 0; i < attachmentCount && i < (CFIndex)sampleIsKeyframe.count; i++)
                                {
                                    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, i);
                                    BOOL keyframe = sampleIsKeyframe[(NSUInteger)i].boolValue;
                                    if (keyframe)
                                    {
                                        CFDictionaryRemoveValue(dict, kCMSampleAttachmentKey_NotSync);
                                        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanFalse);
                                    }
                                    else
                                    {
                                        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
                                        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
                                    }
                                }
                            }

                            NSLog(@"[LibAVSampleCursor %p %@] loadSampleBuffer batched count=%d startPTS=%@ endPTS=%@",
                                  self,
                                  [self debugTracePrefix],
                                  collected,
                                  LibAVTimeString(self.presentationTimeStamp),
                                  LibAVTimeString(batchCursor.presentationTimeStamp));
                            completionHandler(batchedSampleBuffer, nil);
                            self.lastDeliveredDecodeTimeStamp = self.decodeTimeStamp;
                            CFRelease(batchedBlockBuffer);
                            free(timings);
                            free(sizes);
                            return;
                        }
                        free(timings);
                        free(sizes);
                    }
                }

                if (batchedBlockBuffer != NULL)
                {
                    CFRelease(batchedBlockBuffer);
                }
            }
        }
    }

    if (![self currentPacketHasValidData])
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorNoSamples userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    if ([self trackLikelyHasReorderedPresentation] &&
        CMTIME_IS_NUMERIC(self.lastDeliveredDecodeTimeStamp) &&
        CMTIME_IS_NUMERIC(self.decodeTimeStamp) &&
        CMTIME_COMPARE_INLINE(self.decodeTimeStamp, <=, self.lastDeliveredDecodeTimeStamp))
    {
        CMTime step = CMTIME_IS_NUMERIC(self.currentSampleDuration) &&
                      CMTIME_COMPARE_INLINE(self.currentSampleDuration, >, kCMTimeZero)
                        ? self.currentSampleDuration
                        : [self fallbackSampleDuration];
        CMTime adjusted = CMTimeAdd(self.lastDeliveredDecodeTimeStamp, step);
        NSLog(@"[LibAVSampleCursor %p %@] decodeAudit adjusted non-forward DTS old=%@ lastDelivered=%@ new=%@",
              self,
              [self debugTracePrefix],
              LibAVTimeString(self.decodeTimeStamp),
              LibAVTimeString(self.lastDeliveredDecodeTimeStamp),
              LibAVTimeString(adjusted));
        self.decodeTimeStamp = adjusted;
    }

    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPacket:_packet];
    if (sampleBuffer == NULL)
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorInternalFailure userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    // Ownership is transferred to the consumer via completion callback.
    completionHandler(sampleBuffer, nil);
    self.lastDeliveredDecodeTimeStamp = self.decodeTimeStamp;
    NSLog(@"[LibAVSampleCursor %p %@] loadSampleBuffer delivered pts=%@ dts=%@ dur=%@ size=%zu",
          self,
          [self debugTracePrefix],
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp),
          LibAVTimeString(self.currentSampleDuration),
          self.sampleSize);
}

#pragma mark - Private demux helpers

- (void)openDemuxContext
{
    [self closeDemuxContext];

    _cursorFormatCtx = avformat_alloc_context();
    if (_cursorFormatCtx == NULL)
    {
        return;
    }

    _cursorAVIOBuffer = av_malloc(kCursorAVIOBufferSize);
    if (_cursorAVIOBuffer == NULL)
    {
        [self closeDemuxContext];
        return;
    }

    self.cursorReadOffset = 0;
    _cursorAVIOCtx = avio_alloc_context(_cursorAVIOBuffer,
                                        kCursorAVIOBufferSize,
                                        0,
                                        (__bridge void *)self,
                                        &libavCursorReadPacket,
                                        NULL,
                                        &libavCursorSeek);

    if (_cursorAVIOCtx == NULL)
    {
        [self closeDemuxContext];
        return;
    }

    _cursorFormatCtx->pb = _cursorAVIOCtx;
    _cursorFormatCtx->avio_flags = AVIO_FLAG_DIRECT;

    if (avformat_open_input(&_cursorFormatCtx, NULL, NULL, NULL) < 0)
    {
        [self closeDemuxContext];
        return;
    }

    if (avformat_find_stream_info(_cursorFormatCtx, NULL) < 0)
    {
        [self closeDemuxContext];
        return;
    }

    _packet = av_packet_alloc();
    if (_packet == NULL)
    {
        [self closeDemuxContext];
        return;
    }

    self.isReady = YES;
}

- (void)closeDemuxContext
{
    if (_packet != NULL)
    {
        av_packet_free(&_packet);
        _packet = NULL;
    }

    if (_cursorFormatCtx != NULL)
    {
        AVIOContext *localPB = _cursorFormatCtx->pb;
        _cursorFormatCtx->pb = NULL;
        avformat_close_input(&_cursorFormatCtx);
        _cursorFormatCtx = NULL;

        if (localPB != NULL)
        {
            av_freep(&localPB->buffer);
            avio_context_free(&localPB);
        }
    }

    _cursorAVIOCtx = NULL;
    _cursorAVIOBuffer = NULL;
    self.isReady = NO;
}

- (int)seekToPTS:(CMTime)time
{
    return [self seekToTime:time forTimeline:LibAVCursorStepTimelinePresentation];
}

- (int)seekToDTS:(CMTime)time
{
    return [self seekToTime:time forTimeline:LibAVCursorStepTimelineDecode];
}

- (int)seekToTime:(CMTime)time forTimeline:(LibAVCursorStepTimeline)timeline
{
    if (_cursorFormatCtx == NULL)
    {
        return AVERROR(EINVAL);
    }

    int streamIndex = self.trackReader.streamIndex - 1;
    if (streamIndex < 0 || streamIndex >= (int)_cursorFormatCtx->nb_streams)
    {
        return AVERROR(EINVAL);
    }

    CMTime normalizedTime = [self normalizedSeekTime:time];
    AVRational timeBase = _cursorFormatCtx->streams[streamIndex]->time_base;
    int64_t ts = [self ffmpegTimestampFromCMTime:normalizedTime timeBase:timeBase];

    int flags = AVSEEK_FLAG_BACKWARD;
    int64_t minTs = INT64_MIN;
    int64_t maxTs = ts;

    int result = avformat_seek_file(_cursorFormatCtx,
                                    streamIndex,
                                    minTs,
                                    ts,
                                    maxTs,
                                    flags);

    if (result >= 0)
    {
        avformat_flush(_cursorFormatCtx);
        if (_packet != NULL)
        {
            av_packet_unref(_packet);
        }
        self.decodeTimeStamp = kCMTimeInvalid;
        self.presentationTimeStamp = kCMTimeInvalid;
        self.pendingDecodeAnchorTime = kCMTimeInvalid;
    }

    (void)timeline;
    NSLog(@"[LibAVSampleCursor %p %@] seek timeline=%@ requested=%@ normalized=%@ ffTs=%lld result=%d",
          self,
          [self debugTracePrefix],
          (timeline == LibAVCursorStepTimelineDecode) ? @"dts" : @"pts",
          LibAVTimeString(time),
          LibAVTimeString(normalizedTime),
          ts,
          result);
    return result;
}

- (int)readNextPacketForTrack
{
    if (_cursorFormatCtx == NULL || _packet == NULL)
    {
        return AVERROR(EINVAL);
    }

    int streamIndex = self.trackReader.streamIndex - 1;

    av_packet_unref(_packet);

    for (;;)
    {
        int readResult = av_read_frame(_cursorFormatCtx, _packet);
        if (readResult < 0)
        {
            return readResult;
        }

        if (_packet->stream_index == streamIndex)
        {
            return 0;
        }

        av_packet_unref(_packet);
    }
}

- (int)readPacketAtOrAfterTime:(CMTime)target timeline:(LibAVCursorStepTimeline)timeline
{
    CMTime normalizedTarget = [self normalizedSeekTime:target];
    CMTime probeDuration = [self fallbackSampleDuration];
    CMTime nearEndThreshold = kCMTimeInvalid;
    BOOL targetNearEnd = NO;

    if (CMTIME_IS_VALID(self.trackReader.formatReader.duration) &&
        CMTIME_IS_NUMERIC(probeDuration) &&
        CMTIME_COMPARE_INLINE(probeDuration, >, kCMTimeZero))
    {
        nearEndThreshold = CMTimeSubtract(self.trackReader.formatReader.duration, probeDuration);
        if (CMTIME_COMPARE_INLINE(nearEndThreshold, <, kCMTimeZero))
        {
            nearEndThreshold = kCMTimeZero;
        }
        targetNearEnd = CMTIME_IS_NUMERIC(normalizedTarget) && CMTIME_COMPARE_INLINE(normalizedTarget, >=, nearEndThreshold);
    }

    BOOL observedAnyPacket = NO;
    int readResult = [self readNextPacketForTrack];
    if (readResult < 0)
    {
        if (readResult == AVERROR_EOF && targetNearEnd)
        {
            // Some containers demux to EOF when seeking to exact duration.
            // Step back by a couple frame durations and read once to anchor a valid end cursor.
            CMTime rewind = CMTIME_IS_NUMERIC(probeDuration) ? CMTimeMultiplyByFloat64(probeDuration, 2.0) : CMTimeMake(1, 30);
            CMTime fallbackTarget = CMTimeSubtract(self.trackReader.formatReader.duration, rewind);
            if (CMTIME_COMPARE_INLINE(fallbackTarget, <, kCMTimeZero))
            {
                fallbackTarget = kCMTimeZero;
            }

            int rewindSeek = [self seekToTime:fallbackTarget forTimeline:timeline];
            if (rewindSeek < 0)
            {
                return rewindSeek;
            }

            readResult = [self readNextPacketForTrack];
            if (readResult < 0)
            {
                if (targetNearEnd)
                {
                    return AVERROR_EOF;
                }
                return readResult;
            }

            [self updateStateForPacket:_packet];
            observedAnyPacket = YES;
            return 0;
        }

        if (targetNearEnd)
        {
            return AVERROR_EOF;
        }
        return readResult;
    }

    [self updateStateForPacket:_packet];
    observedAnyPacket = YES;
    if (!CMTIME_IS_NUMERIC(normalizedTarget))
    {
        return 0;
    }

    // Reordered codecs (e.g. H.264 with B-frames): the first packet after seek can overshoot
    // the requested presentation timestamp. Scan a bounded window and pick the closest packet
    // whose PTS is >= target.
    if (timeline == LibAVCursorStepTimelinePresentation && [self trackLikelyHasReorderedPresentation])
    {
        AVPacket *bestAtOrAfterPacket = av_packet_alloc();
        AVPacket *bestLastPacket = av_packet_alloc();
        if (bestAtOrAfterPacket == NULL || bestLastPacket == NULL)
        {
            if (bestAtOrAfterPacket != NULL) av_packet_free(&bestAtOrAfterPacket);
            if (bestLastPacket != NULL) av_packet_free(&bestLastPacket);
            return 0;
        }

        BOOL hasBestAtOrAfter = NO;
        BOOL hasBestLast = NO;
        CMTime bestAtOrAfterPTS = kCMTimeInvalid;
        CMTime bestLastPTS = kCMTimeInvalid;

        const int maxReorderScan = 256;
        int scan = 0;

        while (scan < maxReorderScan)
        {
            CMTime cursorPTS = self.presentationTimeStamp;
            if (CMTIME_IS_NUMERIC(cursorPTS))
            {
                if (hasBestLast == NO || CMTIME_COMPARE_INLINE(cursorPTS, >, bestLastPTS))
                {
                    av_packet_unref(bestLastPacket);
                    if (av_packet_ref(bestLastPacket, _packet) == 0)
                    {
                        hasBestLast = YES;
                        bestLastPTS = cursorPTS;
                    }
                }
            }

            if (CMTIME_IS_NUMERIC(cursorPTS) && CMTIME_COMPARE_INLINE(cursorPTS, >=, normalizedTarget))
            {
                if (!hasBestAtOrAfter || CMTIME_COMPARE_INLINE(cursorPTS, <, bestAtOrAfterPTS))
                {
                    av_packet_unref(bestAtOrAfterPacket);
                    if (av_packet_ref(bestAtOrAfterPacket, _packet) == 0)
                    {
                        hasBestAtOrAfter = YES;
                        bestAtOrAfterPTS = cursorPTS;
                    }
                }

                // Exact target match: no need to continue scanning.
                if (hasBestAtOrAfter && CMTIME_COMPARE_INLINE(bestAtOrAfterPTS, ==, normalizedTarget))
                {
                    break;
                }
            }

            int nextResult = [self readNextPacketForTrack];
            if (nextResult < 0)
            {
                break;
            }

            [self updateStateForPacket:_packet];
            observedAnyPacket = YES;
            scan += 1;
        }

        AVPacket *selectedPacket = NULL;
        if (hasBestAtOrAfter)
        {
            selectedPacket = bestAtOrAfterPacket;
        }
        else if (hasBestLast)
        {
            selectedPacket = bestLastPacket;
        }

        if (selectedPacket != NULL)
        {
            av_packet_unref(_packet);
            if (av_packet_ref(_packet, selectedPacket) == 0)
            {
                // We are explicitly repositioning to a selected packet.
                // Clear decode anchor state so stale scan-end decode values do not bleed into
                // synthesized decode timestamps for the selected packet.
                self.decodeTimeStamp = kCMTimeInvalid;
                self.pendingDecodeAnchorTime = kCMTimeInvalid;
                [self updateStateForPacket:_packet];
            }
        }

        av_packet_free(&bestAtOrAfterPacket);
        av_packet_free(&bestLastPacket);
        return observedAnyPacket ? 0 : AVERROR_EOF;
    }

    int guard = 0;
    const int maxPacketsToScan = 20000;

    while (guard < maxPacketsToScan)
    {
        CMTime cursorTime = (timeline == LibAVCursorStepTimelineDecode) ? self.decodeTimeStamp : self.presentationTimeStamp;
        if (!CMTIME_IS_VALID(cursorTime))
        {
            break;
        }

        CMTime threshold = normalizedTarget;
        if (CMTIME_IS_NUMERIC(probeDuration) && CMTIME_COMPARE_INLINE(probeDuration, >, kCMTimeZero))
        {
            threshold = CMTimeSubtract(normalizedTarget, probeDuration);
            if (CMTIME_COMPARE_INLINE(threshold, <, kCMTimeZero))
            {
                threshold = kCMTimeZero;
            }
        }

        if (CMTIME_COMPARE_INLINE(cursorTime, >=, threshold))
        {
            break;
        }

        readResult = [self readNextPacketForTrack];
        if (readResult < 0)
        {
            if (readResult == AVERROR_EOF)
            {
                return observedAnyPacket ? 0 : AVERROR_EOF;
            }
            if (targetNearEnd && observedAnyPacket)
            {
                return 0;
            }
            return readResult;
        }

        [self updateStateForPacket:_packet];
        guard += 1;
    }

    return 0;
}

- (void)updateStateForPacket:(const AVPacket *)packet
{
    int streamIndex = self.trackReader.streamIndex - 1;
    if (_cursorFormatCtx == NULL || streamIndex < 0 || streamIndex >= (int)_cursorFormatCtx->nb_streams)
    {
        return;
    }

    AVRational timeBase = _cursorFormatCtx->streams[streamIndex]->time_base;

    CMTime previousDecode = self.decodeTimeStamp;
    CMTime packetDTS = [self cmTimeFromTimestamp:packet->dts timeBase:timeBase];
    CMTime packetPTS = [self cmTimeFromTimestamp:packet->pts timeBase:timeBase];

    CMTime duration = [self cmTimeFromTimestamp:packet->duration timeBase:timeBase];
    if (!CMTIME_IS_NUMERIC(duration) || CMTIME_COMPARE_INLINE(duration, <=, kCMTimeZero))
    {
        duration = [self fallbackSampleDuration];
    }
    self.currentSampleDuration = duration;

    // Decode timeline should preserve demux-provided DTS whenever available.
    // Only synthesize when container DTS is actually missing (AV_NOPTS_VALUE).
    CMTime nextMonotonicDecode = kCMTimeInvalid;
    if (CMTIME_IS_NUMERIC(previousDecode) &&
        CMTIME_IS_NUMERIC(duration) &&
        CMTIME_COMPARE_INLINE(duration, >, kCMTimeZero))
    {
        nextMonotonicDecode = CMTimeAdd(previousDecode, duration);
    }

    CMTime chosenDecode = packetDTS;
    if (!CMTIME_IS_NUMERIC(chosenDecode))
    {
        chosenDecode = nextMonotonicDecode;
    }

    if (!CMTIME_IS_NUMERIC(chosenDecode))
    {
        // Final fallback only when neither packet DTS nor monotonic synthesis is possible.
        chosenDecode = CMTIME_IS_NUMERIC(packetPTS) ? packetPTS : kCMTimeInvalid;
    }

    self.decodeTimeStamp = chosenDecode;
    self.pendingDecodeAnchorTime = kCMTimeInvalid;

    if (CMTIME_IS_NUMERIC(self.decodeTimeStamp) && CMTIME_IS_VALID(self.trackReader.formatReader.duration))
    {
        CMTimeRange range = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);
        self.decodeTimeStamp = CMTimeClampToRange(self.decodeTimeStamp, range);
    }

    if (CMTIME_IS_NUMERIC(packetPTS))
    {
        self.presentationTimeStamp = packetPTS;
    }
    else if (CMTIME_IS_NUMERIC(packetDTS))
    {
        // Only when PTS is absent, derive presentation from real DTS.
        self.presentationTimeStamp = packetDTS;
    }
    else
    {
        self.presentationTimeStamp = kCMTimeInvalid;
    }

    self.syncInfo = [self extractSyncInfoFromPacket:packet];
    self.dependencyInfo = [self extractDependencyInfoFromPacket:packet];

    self.sampleSize = (size_t)MAX(packet->size, 0);
    self.sampleOffset = packet->pos;
    NSLog(@"[LibAVSampleCursor %p %@] packetState pts=%@ dts=%@ dur=%@ packetPts=%lld packetDts=%lld packetDur=%lld packetPos=%lld size=%zu key=%d",
          self,
          [self debugTracePrefix],
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp),
          LibAVTimeString(self.currentSampleDuration),
          packet->pts,
          packet->dts,
          packet->duration,
          packet->pos,
          self.sampleSize,
          ((packet->flags & AV_PKT_FLAG_KEY) != 0));

    // This field is an absolute decode timeline value, not remaining duration.
    // For local file-backed sources, the byte source has the whole file available.
    self.decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource =
        CMTIME_IS_VALID(self.trackReader.formatReader.duration) ? self.trackReader.formatReader.duration : kCMTimeInvalid;
}

- (void)alignToSourceSampleLocation:(LibAVSampleCursor *)source
{
    if (source == nil || source.sampleOffset < 0 || _cursorFormatCtx == NULL || _packet == NULL)
    {
        return;
    }

    if (self.sampleOffset == source.sampleOffset)
    {
        return;
    }

    // Start from source PTS neighborhood, then scan forward in decode order until exact packet offset matches.
    int seekResult = [self seekToPTS:source.presentationTimeStamp];
    if (seekResult < 0)
    {
        return;
    }

    int readResult = [self readPacketAtOrAfterTime:source.presentationTimeStamp timeline:LibAVCursorStepTimelinePresentation];
    if (readResult < 0)
    {
        return;
    }

    if (self.sampleOffset == source.sampleOffset)
    {
        return;
    }

    const int maxScan = 512;
    for (int i = 0; i < maxScan; i++)
    {
        int next = [self readNextPacketForTrack];
        if (next < 0)
        {
            break;
        }
        [self updateStateForPacket:_packet];
        if (self.sampleOffset == source.sampleOffset)
        {
            NSLog(@"[LibAVSampleCursor %p] copy-align matched source offset=%lld via local scan",
                  self,
                  source.sampleOffset);
            break;
        }
    }

    if (self.sampleOffset == source.sampleOffset)
    {
        return;
    }

    // Fallback: full scan from start to exact source packet offset.
    // This is expensive, but guarantees copy stability for host probe patterns.
    int restartSeek = [self seekToPTS:kCMTimeZero];
    if (restartSeek < 0)
    {
        return;
    }
    int restartRead = [self readPacketAtOrAfterTime:kCMTimeZero timeline:LibAVCursorStepTimelinePresentation];
    if (restartRead < 0)
    {
        return;
    }
    if (self.sampleOffset == source.sampleOffset)
    {
        NSLog(@"[LibAVSampleCursor %p] copy-align matched source offset=%lld after restart at zero",
              self,
              source.sampleOffset);
        return;
    }

    const int maxFullScan = 50000;
    for (int i = 0; i < maxFullScan; i++)
    {
        int next = [self readNextPacketForTrack];
        if (next < 0)
        {
            break;
        }
        [self updateStateForPacket:_packet];
        if (self.sampleOffset == source.sampleOffset)
        {
            NSLog(@"[LibAVSampleCursor %p] copy-align matched source offset=%lld via full scan",
                  self,
                  source.sampleOffset);
            return;
        }
    }

    NSLog(@"[LibAVSampleCursor %p] copy-align failed source offset=%lld dst offset=%lld",
          self,
          source.sampleOffset,
          self.sampleOffset);
}

- (CMTime)fallbackSampleDuration
{
    AVRational avgFrameRate = self.trackReader->stream->avg_frame_rate;
    if (avgFrameRate.num > 0 && avgFrameRate.den > 0)
    {
        return CMTimeMake(avgFrameRate.den, avgFrameRate.num);
    }

    AVRational rFrameRate = self.trackReader->stream->r_frame_rate;
    if (rFrameRate.num > 0 && rFrameRate.den > 0)
    {
        return CMTimeMake(rFrameRate.den, rFrameRate.num);
    }

    return CMTimeMake(1, 30);
}

- (CMTime)cmTimeFromTimestamp:(int64_t)timestamp timeBase:(AVRational)timeBase
{
    if (timestamp == AV_NOPTS_VALUE || timeBase.num <= 0 || timeBase.den <= 0)
    {
        return kCMTimeInvalid;
    }

    int64_t micros = av_rescale_q(timestamp, timeBase, (AVRational){1, 1000000});
    return CMTimeMake(micros, 1000000);
}

- (int64_t)ffmpegTimestampFromCMTime:(CMTime)time timeBase:(AVRational)timeBase
{
    if (!CMTIME_IS_NUMERIC(time) || timeBase.num <= 0 || timeBase.den <= 0)
    {
        return 0;
    }

    CMTime microTime = CMTimeConvertScale(time, 1000000, kCMTimeRoundingMethod_RoundTowardZero);
    return av_rescale_q(microTime.value, (AVRational){1, 1000000}, timeBase);
}

#pragma mark - Step helpers

- (void)stepByCount:(int64_t)stepCount
           timeline:(LibAVCursorStepTimeline)timeline
  completionHandler:(void (^)(int64_t, NSError * _Nullable))completionHandler
{
    if (!self.isReady)
    {
        completionHandler(0, [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorInternalFailure userInfo:nil]);
        return;
    }

    if (stepCount == 0)
    {
        completionHandler(0, nil);
        return;
    }

    int64_t actualStepCount = 0;
    NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=%@ requested=%lld startPTS=%@ startDTS=%@",
          self,
          [self debugTracePrefix],
          (timeline == LibAVCursorStepTimelineDecode) ? @"dts" : @"pts",
          stepCount,
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp));

    if (stepCount > 0)
    {
        for (int64_t i = 0; i < stepCount; i++)
        {
            if (timeline == LibAVCursorStepTimelineDecode)
            {
                CMTime startDTS = self.decodeTimeStamp;
                int scan = 0;
                const int maxScan = 4096;
                BOOL advanced = NO;

                while (scan < maxScan)
                {
                    int readResult = [self readNextPacketForTrack];
                    if (readResult < 0)
                    {
                        if (readResult == AVERROR_EOF)
                        {
                            completionHandler(actualStepCount, nil);
                            return;
                        }
                        completionHandler(actualStepCount, [self libAVFormatErrorFrom:readResult]);
                        return;
                    }

                    [self updateStateForPacket:_packet];
                    scan += 1;

                    if (!CMTIME_IS_NUMERIC(startDTS) ||
                        !CMTIME_IS_NUMERIC(self.decodeTimeStamp) ||
                        CMTIME_COMPARE_INLINE(self.decodeTimeStamp, >, startDTS))
                    {
                        advanced = YES;
                        break;
                    }
                }

                if (!advanced)
                {
                    NSLog(@"[LibAVSampleCursor %p %@] stepByCount no-forward-progress timeline=dts startDTS=%@ endDTS=%@",
                          self,
                          [self debugTracePrefix],
                          LibAVTimeString(startDTS),
                          LibAVTimeString(self.decodeTimeStamp));
                    completionHandler(actualStepCount, nil);
                    return;
                }

                actualStepCount += 1;
                continue;
            }

            BOOL reorderedPresentation = [self trackLikelyHasReorderedPresentation];
            if (!reorderedPresentation)
            {
                int readResult = [self readNextPacketForTrack];
                if (readResult < 0)
                {
                    if (readResult == AVERROR_EOF)
                    {
                        completionHandler(actualStepCount, nil);
                        return;
                    }
                    completionHandler(actualStepCount, [self libAVFormatErrorFrom:readResult]);
                    return;
                }

                [self updateStateForPacket:_packet];
                actualStepCount += 1;
                continue;
            }

            // Reordered streams (e.g. AVC/HEVC): find the NEXT presentation sample by
            // scanning forward in decode order and choosing the minimum PTS greater than
            // current PTS inside a bounded lookahead window.
            CMTime startPTS = self.presentationTimeStamp;
            AVPacket *bestPacket = av_packet_alloc();
            if (bestPacket == NULL)
            {
                completionHandler(actualStepCount, [NSError errorWithDomain:MediaExtensionErrorDomain
                                                                        code:MEErrorInternalFailure
                                                                    userInfo:nil]);
                return;
            }

            BOOL hasBest = NO;
            CMTime bestPTS = kCMTimeInvalid;
            int scan = 0;
            int scansAfterFirstCandidate = 0;
            const int maxScan = 4096;
            int lookahead = 6;
            if (self.trackReader != nil && self.trackReader->stream != NULL && self.trackReader->stream->codecpar != NULL)
            {
                lookahead = MAX(6, self.trackReader->stream->codecpar->video_delay + 2);
            }

            while (scan < maxScan)
            {
                int readResult = [self readNextPacketForTrack];
                if (readResult < 0)
                {
                    if (readResult == AVERROR_EOF)
                    {
                        NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=pts reached EOF scan=%d startPTS=%@ hasBest=%d bestPTS=%@",
                              self,
                              [self debugTracePrefix],
                              scan,
                              LibAVTimeString(startPTS),
                              hasBest ? 1 : 0,
                              LibAVTimeString(bestPTS));
                        break;
                    }

                    BOOL nearDurationEnd = NO;
                    if (CMTIME_IS_NUMERIC(startPTS) &&
                        CMTIME_IS_VALID(self.trackReader.formatReader.duration))
                    {
                        CMTime tailMargin = [self fallbackSampleDuration];
                        if (!CMTIME_IS_NUMERIC(tailMargin) || CMTIME_COMPARE_INLINE(tailMargin, <=, kCMTimeZero))
                        {
                            tailMargin = CMTimeMake(1, 30);
                        }
                        tailMargin = CMTimeMultiplyByFloat64(tailMargin, 2.0);
                        CMTime cutoff = CMTimeSubtract(self.trackReader.formatReader.duration, tailMargin);
                        if (CMTIME_COMPARE_INLINE(cutoff, <, kCMTimeZero))
                        {
                            cutoff = kCMTimeZero;
                        }
                        nearDurationEnd = CMTIME_COMPARE_INLINE(startPTS, >=, cutoff);
                    }

                    if (nearDurationEnd)
                    {
                        // Some demuxers surface non-EOF negative codes at stream tail.
                        // At/near duration end and with no forward candidate, treat this
                        // as normal end-of-stream rather than a fatal playback error.
                        NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=pts treating tail scan error as EOF error=%d scan=%d startPTS=%@ duration=%@",
                              self,
                              [self debugTracePrefix],
                              readResult,
                              scan,
                              LibAVTimeString(startPTS),
                              LibAVTimeString(self.trackReader.formatReader.duration));
                        break;
                    }

                    if (hasBest)
                    {
                        // We already found a valid forward PTS candidate. Some demuxers can
                        // report non-EOF read failures near stream tail; treat those as
                        // scan termination and keep the best candidate instead of surfacing
                        // a fatal step error to the host.
                        NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=pts scan nonfatal error=%d scan=%d startPTS=%@ hasBest=1 bestPTS=%@",
                              self,
                              [self debugTracePrefix],
                              readResult,
                              scan,
                              LibAVTimeString(startPTS),
                              LibAVTimeString(bestPTS));
                        break;
                    }
                    NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=pts scan error=%d scan=%d startPTS=%@",
                          self,
                          [self debugTracePrefix],
                          readResult,
                          scan,
                          LibAVTimeString(startPTS));
                    av_packet_free(&bestPacket);
                    completionHandler(actualStepCount, [self libAVFormatErrorFrom:readResult]);
                    return;
                }

                [self updateStateForPacket:_packet];
                scan += 1;

                CMTime candidatePTS = self.presentationTimeStamp;
                if (!CMTIME_IS_NUMERIC(startPTS) ||
                    !CMTIME_IS_NUMERIC(candidatePTS) ||
                    CMTIME_COMPARE_INLINE(candidatePTS, >, startPTS))
                {
                    if (!hasBest ||
                        !CMTIME_IS_NUMERIC(bestPTS) ||
                        !CMTIME_IS_NUMERIC(candidatePTS) ||
                        CMTIME_COMPARE_INLINE(candidatePTS, <, bestPTS))
                    {
                        av_packet_unref(bestPacket);
                        if (av_packet_ref(bestPacket, _packet) == 0)
                        {
                            hasBest = YES;
                            bestPTS = candidatePTS;
                            scansAfterFirstCandidate = 0;
                            NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=pts candidate update bestPTS=%@ scan=%d pos=%lld",
                                  self,
                                  [self debugTracePrefix],
                                  LibAVTimeString(bestPTS),
                                  scan,
                                  _packet->pos);
                        }
                    }
                    else if (hasBest)
                    {
                        scansAfterFirstCandidate += 1;
                    }
                }

                if (hasBest && scansAfterFirstCandidate >= lookahead)
                {
                    break;
                }
            }

            if (!hasBest)
            {
                av_packet_free(&bestPacket);
                NSLog(@"[LibAVSampleCursor %p %@] stepByCount no-forward-progress timeline=pts startPTS=%@ endPTS=%@",
                      self,
                      [self debugTracePrefix],
                      LibAVTimeString(startPTS),
                      LibAVTimeString(self.presentationTimeStamp));
                completionHandler(actualStepCount, nil);
                return;
            }

            av_packet_unref(_packet);
            if (av_packet_ref(_packet, bestPacket) != 0)
            {
                av_packet_free(&bestPacket);
                completionHandler(actualStepCount, [NSError errorWithDomain:MediaExtensionErrorDomain
                                                                        code:MEErrorInternalFailure
                                                                    userInfo:nil]);
                return;
            }
            av_packet_free(&bestPacket);

            self.decodeTimeStamp = kCMTimeInvalid;
            self.pendingDecodeAnchorTime = kCMTimeInvalid;
            [self updateStateForPacket:_packet];
            NSLog(@"[LibAVSampleCursor %p %@] stepByCount timeline=pts selected nextPTS=%@ nextDTS=%@",
                  self,
                  [self debugTracePrefix],
                  LibAVTimeString(self.presentationTimeStamp),
                  LibAVTimeString(self.decodeTimeStamp));

            actualStepCount += 1;
        }

        completionHandler(actualStepCount, nil);
        NSLog(@"[LibAVSampleCursor %p %@] stepByCount done actual=%lld endPTS=%@ endDTS=%@",
              self,
              [self debugTracePrefix],
              actualStepCount,
              LibAVTimeString(self.presentationTimeStamp),
              LibAVTimeString(self.decodeTimeStamp));
        return;
    }

    // Backward stepping for demuxed packet streams: seek backward by sample duration repeatedly.
    for (int64_t i = 0; i < -stepCount; i++)
    {
        CMTime cursorTime = (timeline == LibAVCursorStepTimelineDecode) ? self.decodeTimeStamp : self.presentationTimeStamp;
        CMTime duration = CMTIME_IS_NUMERIC(self.currentSampleDuration) && CMTIME_COMPARE_INLINE(self.currentSampleDuration, >, kCMTimeZero)
            ? self.currentSampleDuration
            : [self fallbackSampleDuration];

        CMTime target = CMTimeSubtract(cursorTime, duration);
        if (CMTIME_COMPARE_INLINE(target, <, kCMTimeZero))
        {
            target = kCMTimeZero;
        }

        int seekResult = (timeline == LibAVCursorStepTimelineDecode) ? [self seekToDTS:target] : [self seekToPTS:target];
        if (seekResult < 0)
        {
            completionHandler(actualStepCount, [self libAVFormatErrorFrom:seekResult]);
            return;
        }

        int readResult = [self readNextPacketForTrack];
        if (readResult < 0)
        {
            if (readResult == AVERROR_EOF)
            {
                completionHandler(actualStepCount, nil);
                return;
            }
            completionHandler(actualStepCount, [self libAVFormatErrorFrom:readResult]);
            return;
        }

        [self updateStateForPacket:_packet];
        actualStepCount -= 1;

        if (CMTIME_COMPARE_INLINE(target, ==, kCMTimeZero))
        {
            break;
        }
    }

    completionHandler(actualStepCount, nil);
    NSLog(@"[LibAVSampleCursor %p %@] stepByCount done actual=%lld endPTS=%@ endDTS=%@",
          self,
          [self debugTracePrefix],
          actualStepCount,
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp));
}

- (BOOL)currentPacketHasValidData
{
    return (_packet != NULL && _packet->data != NULL && _packet->size > 0);
}

- (CMTime)normalizedSeekTime:(CMTime)time
{
    CMTime normalized = time;

    if (CMTIME_IS_POSITIVE_INFINITY(normalized))
    {
        normalized = CMTIME_IS_VALID(self.trackReader.formatReader.duration) ? self.trackReader.formatReader.duration : kCMTimeZero;
    }
    else if (!CMTIME_IS_NUMERIC(normalized))
    {
        normalized = kCMTimeZero;
    }

    if (CMTIME_COMPARE_INLINE(normalized, <, kCMTimeZero))
    {
        normalized = kCMTimeZero;
    }

    if (CMTIME_IS_VALID(self.trackReader.formatReader.duration))
    {
        CMTimeRange range = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);
        if (CMTimeRangeContainsTime(range, normalized) == NO)
        {
            normalized = CMTimeClampToRange(normalized, range);
        }
    }

    return normalized;
}

#pragma mark - Sample buffer creation

- (CMSampleBufferRef _Nullable)createSampleBufferFromPacket:(const AVPacket *)packet
{
    if (packet == NULL || packet->data == NULL || packet->size <= 0)
    {
        return NULL;
    }

    CMBlockBufferRef blockBuffer = NULL;
    CMSampleBufferRef sampleBuffer = NULL;

    const uint8_t *packetBytes = packet->data;
    size_t packetSize = (size_t)packet->size;
    NSData *convertedData = nil;
    BOOL emittedAVCC = NO;

    if (self.packetFormatter != nil)
    {
        NSString *normalizationNote = nil;
        convertedData = [self.packetFormatter normalizedPacketDataForBytes:packetBytes
                                                                      size:packetSize
                                                               emittedAVCC:&emittedAVCC
                                                         normalizationNote:&normalizationNote];
        if (normalizationNote.length > 0)
        {
            NSLog(@"[LibAVSampleCursor %p %@] %@", self, [self debugTracePrefix], normalizationNote);
        }

        if (convertedData != nil && convertedData.length > 0)
        {
            packetBytes = convertedData.bytes;
            packetSize = convertedData.length;
        }
    }

    // Allocate block-buffer-owned memory and copy packet bytes into it.
    // Never pass FFmpeg-owned packet memory directly, because CMBlockBuffer finalization
    // can otherwise attempt to free memory that is managed by libavcodec/libavformat.
    OSStatus blockStatus = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                               NULL,
                                                               packetSize,
                                                               kCFAllocatorDefault,
                                                               NULL,
                                                               0,
                                                               packetSize,
                                                               0,
                                                               &blockBuffer);
    if (blockStatus != kCMBlockBufferNoErr)
    {
        return NULL;
    }

    blockStatus = CMBlockBufferReplaceDataBytes(packetBytes,
                                                blockBuffer,
                                                0,
                                                packetSize);
    if (blockStatus != kCMBlockBufferNoErr)
    {
        CFRelease(blockBuffer);
        return NULL;
    }

    CMSampleTimingInfo timingInfo;
    timingInfo.duration = self.currentSampleDuration;
    timingInfo.presentationTimeStamp = self.presentationTimeStamp;
    timingInfo.decodeTimeStamp = self.decodeTimeStamp;

    size_t sampleSize = packetSize;

    OSStatus sampleStatus = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                                      blockBuffer,
                                                      self.currentSampleFormatDescription,
                                                      1,
                                                      1,
                                                      &timingInfo,
                                                      1,
                                                      &sampleSize,
                                                      &sampleBuffer);

    CFRelease(blockBuffer);

    if (sampleStatus != noErr)
    {
        return NULL;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0)
    {
        CFMutableDictionaryRef sampleAttachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        BOOL isKeyframe = ((packet->flags & AV_PKT_FLAG_KEY) != 0);

        if (isKeyframe)
        {
            CFDictionaryRemoveValue(sampleAttachment, kCMSampleAttachmentKey_NotSync);
        }
        else
        {
            CFDictionarySetValue(sampleAttachment, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        }

        CFDictionarySetValue(sampleAttachment,
                             kCMSampleAttachmentKey_DependsOnOthers,
                             (!isKeyframe ? kCFBooleanTrue : kCFBooleanFalse));
    }

    if (emittedAVCC)
    {
        NSLog(@"[LibAVSampleCursor %p %@] emitted H264 AVCC packetSize=%d outputSize=%zu",
              self,
              [self debugTracePrefix],
              packet->size,
              packetSize);
    }

    [self logSampleAuditForPacket:packet
                     sampleBuffer:sampleBuffer
                      sampleBytes:packetBytes
                       packetSize:packetSize
                           isAVCC:emittedAVCC];

    return sampleBuffer;
}

- (void)logSampleAuditForPacket:(const AVPacket *)packet
                   sampleBuffer:(CMSampleBufferRef)sampleBuffer
                    sampleBytes:(const uint8_t *)sampleBytes
                     packetSize:(size_t)packetSize
                         isAVCC:(BOOL)isAVCC
{
    self.deliveredSampleAuditCount += 1;
    BOOL shouldLog = (self.deliveredSampleAuditCount <= 160 || (self.deliveredSampleAuditCount % 120) == 0);
    if (!shouldLog)
    {
        return;
    }

    BOOL notSync = NO;
    BOOL dependsOnOthers = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0)
    {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFTypeRef notSyncValue = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        CFTypeRef dependsValue = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_DependsOnOthers);
        notSync = (notSyncValue == kCFBooleanTrue);
        dependsOnOthers = (dependsValue == kCFBooleanTrue);
    }

    NSString *codecSummary = @"codec=passthrough";
    if (self.packetFormatter != nil && sampleBytes != NULL && packetSize > 0)
    {
        codecSummary = [self.packetFormatter auditSummaryForBytes:sampleBytes size:packetSize emittedAVCC:isAVCC];
    }

    int64_t globalIdx = 0;
    @synchronized([LibAVSampleCursor class]) {
        gLibAVCursorGlobalSampleEmitCounter += 1;
        globalIdx = gLibAVCursorGlobalSampleEmitCounter;
    }

    NSLog(@"[LibAVSampleCursor %p %@] sampleAudit idx=%lld global=%lld pts=%@ dts=%@ dur=%@ key=%d notSync=%d depends=%d size=%zu %s %@",
          self,
          [self debugTracePrefix],
          self.deliveredSampleAuditCount,
          globalIdx,
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp),
          LibAVTimeString(self.currentSampleDuration),
          (packet != NULL && ((packet->flags & AV_PKT_FLAG_KEY) != 0)) ? 1 : 0,
          notSync ? 1 : 0,
          dependsOnOthers ? 1 : 0,
          packetSize,
          isAVCC ? "avcc" : "native",
          codecSummary);
}

#pragma mark - Dependency extraction

- (AVSampleCursorSyncInfo)extractSyncInfoFromPacket:(const AVPacket *)packet
{
    AVSampleCursorSyncInfo info = {0};

    info.sampleIsFullSync = ((packet->flags & AV_PKT_FLAG_KEY) != 0);
    info.sampleIsPartialSync = NO;
    info.sampleIsDroppable = ((packet->flags & (AV_PKT_FLAG_DISPOSABLE | AV_PKT_FLAG_DISCARD)) != 0);

    return info;
}

- (AVSampleCursorDependencyInfo)extractDependencyInfoFromPacket:(const AVPacket *)packet
{
    AVSampleCursorDependencyInfo info = {0};

    BOOL isKeyframe = ((packet->flags & AV_PKT_FLAG_KEY) != 0);

    info.sampleIndicatesWhetherItDependsOnOthers = YES;
    info.sampleDependsOnOthers = !isKeyframe;

    info.sampleIndicatesWhetherItHasDependentSamples = NO;
    info.sampleHasDependentSamples = NO;

    info.sampleIndicatesWhetherItHasRedundantCoding = NO;
    info.sampleHasRedundantCoding = NO;

    return info;
}

#pragma mark - Error

- (NSError *)libAVFormatErrorFrom:(int)returnCode
{
    return [NSError errorWithDomain:@"libavformat.ffmpeg" code:returnCode userInfo:nil];
}

- (BOOL)trackLikelyHasReorderedPresentation
{
    if (self.trackReader == nil || self.trackReader->stream == NULL)
    {
        return NO;
    }

    const AVCodecParameters *codecpar = self.trackReader->stream->codecpar;
    if (codecpar == NULL)
    {
        return NO;
    }

    // Prefer stream signaled reordering depth; this avoids forcing reordered handling
    // for all-I or otherwise monotonic H.264/HEVC streams.
    if (codecpar->video_delay > 0)
    {
        return YES;
    }

    return NO;
}

- (void)beginDebugOp:(NSString *)name timeline:(LibAVCursorStepTimeline)timeline
{
    @synchronized([LibAVSampleCursor class]) {
        gLibAVCursorDebugOpCounter += 1;
        self.debugOpID = gLibAVCursorDebugOpCounter;
    }
    self.debugOpName = name;
    self.debugTimeline = timeline;
}

- (NSString *)debugTracePrefix
{
    NSString *op = (self.debugOpName.length > 0) ? self.debugOpName : @"unknown";
    NSString *timeline = (self.debugTimeline == LibAVCursorStepTimelineDecode) ? @"dts" : @"pts";
    return [NSString stringWithFormat:@"op=%@#%lld tl=%@", op, self.debugOpID, timeline];
}

@end
