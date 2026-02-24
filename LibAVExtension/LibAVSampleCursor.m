//
//  LibAVSampleCursor.m
//  LibAVExtensionHost
//
//  Created by Anton Marini on 7/31/24.
//

#import "LibAVSampleCursor.h"
#import "LibAVTrackReader.h"
#import "LibAVFormatReader.h"

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

- (BOOL)trackLikelyHasReorderedPresentation;

@end

@implementation LibAVSampleCursor
{
    AVFormatContext *_cursorFormatCtx;
    AVIOContext *_cursorAVIOCtx;
    uint8_t *_cursorAVIOBuffer;
    AVPacket *_packet;
}

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

        NSLog(@"[LibAVSampleCursor %p] init requestedPTS=%@", self, LibAVTimeString(pts));
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
        NSLog(@"[LibAVSampleCursor %p] init ready pts=%@ dts=%@ dur=%@ size=%zu offset=%lld",
              self,
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
    return copy;
}

#pragma mark - MESampleCursor required stepping

- (void)stepByDecodeTime:(CMTime)deltaDecodeTime
       completionHandler:(void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
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

    NSLog(@"[LibAVSampleCursor %p] stepByDecodeTime delta=%@ target=%@ resultDTS=%@ resultPTS=%@ pinned=%d",
          self,
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

    NSLog(@"[LibAVSampleCursor %p] stepByPresentationTime delta=%@ target=%@ resultPTS=%@ resultDTS=%@ pinned=%d",
          self,
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
    NSLog(@"[LibAVSampleCursor %p] stepInDecodeOrderByCount requested=%lld", self, stepCount);
    [self stepByCount:stepCount timeline:LibAVCursorStepTimelineDecode completionHandler:completionHandler];
}

- (void)stepInPresentationOrderByCount:(int64_t)stepCount
                     completionHandler:(void (^)(int64_t actualStepCount, NSError * _Nullable error))completionHandler
{
    NSLog(@"[LibAVSampleCursor %p] stepInPresentationOrderByCount requested=%lld", self, stepCount);
    [self stepByCount:stepCount timeline:LibAVCursorStepTimelinePresentation completionHandler:completionHandler];
}

#pragma mark - MESampleCursor optional behavior

- (BOOL)samplesWithEarlierDTSsMayHaveLaterPTSsThanCursor:(id<MESampleCursor>)cursor
{
    (void)cursor;
    return [self trackLikelyHasReorderedPresentation];
}

- (BOOL)samplesWithLaterDTSsMayHaveEarlierPTSsThanCursor:(id<MESampleCursor>)cursor
{
    (void)cursor;
    return [self trackLikelyHasReorderedPresentation];
}

- (MESampleCursorChunk * _Nullable)chunkDetailsReturningError:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    if (self.sampleOffset < 0 || self.sampleSize == 0 || self.trackReader.formatReader.byteSource == nil)
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

    AVSampleCursorChunkInfo info = {0};
    info.chunkSampleCount = 1;
    info.chunkHasUniformSampleSizes = false;
    info.chunkHasUniformSampleDurations = false;
    info.chunkHasUniformFormatDescriptions = true;

    return [[MESampleCursorChunk alloc] initWithByteSource:self.trackReader.formatReader.byteSource
                                         chunkStorageRange:range
                                                 chunkInfo:info
                                    sampleIndexWithinChunk:0];
}

- (MESampleLocation * _Nullable)sampleLocationReturningError:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    if (self.sampleOffset < 0 || self.sampleSize == 0 || self.trackReader.formatReader.byteSource == nil)
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
    return [[MESampleLocation alloc] initWithByteSource:self.trackReader.formatReader.byteSource sampleLocation:range];
}

- (void)loadSampleBufferContainingSamplesToEndCursor:(id<MESampleCursor> _Nullable)endSampleCursor
                                   completionHandler:(void (^)(CMSampleBufferRef _Nullable, NSError * _Nullable))completionHandler
{
    NSLog(@"[LibAVSampleCursor %p] loadSampleBuffer start cursorPTS=%@ cursorDTS=%@ cursorDur=%@ cursorSize=%zu endPTS=%@",
          self,
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

    if (endSampleCursor != nil && CMTIME_COMPARE_INLINE(endSampleCursor.presentationTimeStamp, <, self.presentationTimeStamp))
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorNoSamples userInfo:nil];
        completionHandler(nil, error);
        return;
    }

    if (![self currentPacketHasValidData])
    {
        NSError *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorNoSamples userInfo:nil];
        completionHandler(nil, error);
        return;
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
    NSLog(@"[LibAVSampleCursor %p] loadSampleBuffer delivered pts=%@ dts=%@ dur=%@ size=%zu",
          self,
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
        self.pendingDecodeAnchorTime = normalizedTime;
    }

    (void)timeline;
    NSLog(@"[LibAVSampleCursor %p] seek timeline=%@ requested=%@ normalized=%@ ffTs=%lld result=%d",
          self,
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

    CMTime packetDTS = [self cmTimeFromTimestamp:packet->dts timeBase:timeBase];
    CMTime packetPTS = [self cmTimeFromTimestamp:packet->pts timeBase:timeBase];

    CMTime duration = [self cmTimeFromTimestamp:packet->duration timeBase:timeBase];
    if (!CMTIME_IS_NUMERIC(duration) || CMTIME_COMPARE_INLINE(duration, <=, kCMTimeZero))
    {
        duration = [self fallbackSampleDuration];
    }
    self.currentSampleDuration = duration;

    // Keep decode and presentation timelines independent.
    if (CMTIME_IS_NUMERIC(packetDTS))
    {
        self.decodeTimeStamp = packetDTS;
        self.pendingDecodeAnchorTime = kCMTimeInvalid;
    }
    else
    {
        if (CMTIME_IS_NUMERIC(self.decodeTimeStamp))
        {
            self.decodeTimeStamp = CMTimeAdd(self.decodeTimeStamp, duration);
        }
        else if (CMTIME_IS_NUMERIC(self.pendingDecodeAnchorTime))
        {
            self.decodeTimeStamp = self.pendingDecodeAnchorTime;
        }
        else
        {
            self.decodeTimeStamp = kCMTimeInvalid;
        }
    }

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
    NSLog(@"[LibAVSampleCursor %p] packetState pts=%@ dts=%@ dur=%@ packetPts=%lld packetDts=%lld packetDur=%lld packetPos=%lld size=%zu key=%d",
          self,
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
    NSLog(@"[LibAVSampleCursor %p] stepByCount timeline=%@ requested=%lld startPTS=%@ startDTS=%@",
          self,
          (timeline == LibAVCursorStepTimelineDecode) ? @"dts" : @"pts",
          stepCount,
          LibAVTimeString(self.presentationTimeStamp),
          LibAVTimeString(self.decodeTimeStamp));

    if (stepCount > 0)
    {
        for (int64_t i = 0; i < stepCount; i++)
        {
            BOOL useLinearDemuxStep = (timeline == LibAVCursorStepTimelineDecode) || ![self trackLikelyHasReorderedPresentation];
            if (useLinearDemuxStep)
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

            // Reordered streams (e.g. AVC/HEVC): advance by presentation timeline.
            CMTime startPTS = self.presentationTimeStamp;
            CMTime duration = CMTIME_IS_NUMERIC(self.currentSampleDuration) && CMTIME_COMPARE_INLINE(self.currentSampleDuration, >, kCMTimeZero)
                ? self.currentSampleDuration
                : [self fallbackSampleDuration];
            CMTime target = CMTIME_IS_NUMERIC(startPTS) ? CMTimeAdd(startPTS, duration) : duration;
            if (CMTIME_IS_VALID(self.trackReader.formatReader.duration))
            {
                CMTimeRange range = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);
                target = CMTimeClampToRange(target, range);
            }

            int seekResult = [self seekToPTS:target];
            if (seekResult < 0)
            {
                completionHandler(actualStepCount, [self libAVFormatErrorFrom:seekResult]);
                return;
            }

            int readResult = [self readPacketAtOrAfterTime:target timeline:LibAVCursorStepTimelinePresentation];
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

            // Ensure actual forward PTS progression after seek anchoring.
            if (CMTIME_IS_NUMERIC(startPTS) && CMTIME_IS_NUMERIC(self.presentationTimeStamp) &&
                CMTIME_COMPARE_INLINE(self.presentationTimeStamp, <=, startPTS))
            {
                int scan = 0;
                const int maxScan = 2048;
                while (scan < maxScan && CMTIME_IS_NUMERIC(self.presentationTimeStamp) &&
                       CMTIME_COMPARE_INLINE(self.presentationTimeStamp, <=, startPTS))
                {
                    int next = [self readNextPacketForTrack];
                    if (next < 0)
                    {
                        if (next == AVERROR_EOF)
                        {
                            break;
                        }
                        completionHandler(actualStepCount, [self libAVFormatErrorFrom:next]);
                        return;
                    }
                    [self updateStateForPacket:_packet];
                    scan += 1;
                }
            }

            actualStepCount += 1;
        }

        completionHandler(actualStepCount, nil);
        NSLog(@"[LibAVSampleCursor %p] stepByCount done actual=%lld endPTS=%@ endDTS=%@",
              self,
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
    NSLog(@"[LibAVSampleCursor %p] stepByCount done actual=%lld endPTS=%@ endDTS=%@",
          self,
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

    // Allocate block-buffer-owned memory and copy packet bytes into it.
    // Never pass FFmpeg-owned packet memory directly, because CMBlockBuffer finalization
    // can otherwise attempt to free memory that is managed by libavcodec/libavformat.
    OSStatus blockStatus = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                               NULL,
                                                               packet->size,
                                                               kCFAllocatorDefault,
                                                               NULL,
                                                               0,
                                                               packet->size,
                                                               0,
                                                               &blockBuffer);
    if (blockStatus != kCMBlockBufferNoErr)
    {
        return NULL;
    }

    blockStatus = CMBlockBufferReplaceDataBytes(packet->data,
                                                blockBuffer,
                                                0,
                                                packet->size);
    if (blockStatus != kCMBlockBufferNoErr)
    {
        CFRelease(blockBuffer);
        return NULL;
    }

    CMSampleTimingInfo timingInfo;
    timingInfo.duration = self.currentSampleDuration;
    timingInfo.presentationTimeStamp = self.presentationTimeStamp;
    timingInfo.decodeTimeStamp = self.decodeTimeStamp;

    size_t sampleSize = (size_t)packet->size;

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

    return sampleBuffer;
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
    const AVCodecParameters *codecpar = self.trackReader->stream->codecpar;
    if (codecpar == NULL)
    {
        return YES;
    }

    switch (codecpar->codec_id)
    {
        case AV_CODEC_ID_H264:
        case AV_CODEC_ID_HEVC:
        case AV_CODEC_ID_MPEG2VIDEO:
        case AV_CODEC_ID_MPEG4:
            return YES;
        default:
            return NO;
    }
}

@end
