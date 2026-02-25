//
//  LibAVH264CodecPacketFormatter.m
//  LibAVExtension
//

#import "LibAVH264CodecPacketFormatter.h"

static BOOL LibAVH264BufferHasAnnexBStartCode(const uint8_t *data, size_t size)
{
    if (data == NULL || size < 3)
    {
        return NO;
    }

    // Annex-B detection must anchor at packet start (allowing only leading zero bytes).
    size_t i = 0;
    while (i < size && data[i] == 0x00)
    {
        i += 1;
    }

    if (i >= 2 && i < size && data[i] == 0x01)
    {
        return YES;
    }

    if (size >= 4 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01)
    {
        return YES;
    }
    if (size >= 3 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01)
    {
        return YES;
    }
    return NO;
}

@implementation LibAVH264CodecPacketFormatter
{
    int _nalLengthFieldSize;
}

- (instancetype)initWithCodecParameters:(const AVCodecParameters *)codecpar
{
    self = [super init];
    if (self != nil)
    {
        _nalLengthFieldSize = 4;
        if (codecpar != NULL && codecpar->extradata != NULL && codecpar->extradata_size >= 5 && codecpar->extradata[0] == 1)
        {
            int lengthSize = (codecpar->extradata[4] & 0x03) + 1;
            if (lengthSize == 1 || lengthSize == 2 || lengthSize == 4)
            {
                _nalLengthFieldSize = lengthSize;
            }
            else
            {
                NSLog(@"[LibAVH264CodecPacketFormatter] invalid avcC length field size=%d; defaulting to 4", lengthSize);
            }
        }
    }
    return self;
}

- (BOOL)requiresSampleBufferPath
{
    return YES;
}

- (BOOL)looksLikeAVCCData:(const uint8_t *)bytes
                     size:(size_t)size
          lengthFieldSize:(int)lengthFieldSize
{
    if (bytes == NULL || size == 0 || !(lengthFieldSize == 1 || lengthFieldSize == 2 || lengthFieldSize == 4))
    {
        return NO;
    }

    size_t cursor = 0;
    int nalCount = 0;
    while (cursor + (size_t)lengthFieldSize <= size)
    {
        uint32_t nalLen = 0;
        for (int i = 0; i < lengthFieldSize; i++)
        {
            nalLen = (nalLen << 8) | bytes[cursor + (size_t)i];
        }
        cursor += (size_t)lengthFieldSize;
        if (nalLen == 0 || cursor + nalLen > size)
        {
            return NO;
        }
        nalCount += 1;
        cursor += nalLen;
    }

    return (nalCount > 0 && cursor == size);
}

- (int)detectAVCCLengthFieldSize:(const uint8_t *)bytes size:(size_t)size
{
    int bestCandidate = 0;
    int bestScore = INT_MIN;

    for (int candidate = 1; candidate <= 4; candidate++)
    {
        if (![self looksLikeAVCCData:bytes size:size lengthFieldSize:candidate])
        {
            continue;
        }

        size_t cursor = 0;
        int nalCount = 0;
        int validNalCount = 0;
        int commonNalCount = 0;
        int invalidNalCount = 0;

        while (cursor + (size_t)candidate <= size)
        {
            uint32_t nalLen = 0;
            for (int i = 0; i < candidate; i++)
            {
                nalLen = (nalLen << 8) | bytes[cursor + (size_t)i];
            }
            cursor += (size_t)candidate;
            if (nalLen == 0 || cursor + nalLen > size)
            {
                invalidNalCount += 1;
                break;
            }

            uint8_t nalType = bytes[cursor] & 0x1F;
            nalCount += 1;
            if (nalType >= 1 && nalType <= 23)
            {
                validNalCount += 1;
                if (nalType == 1 || nalType == 5 || nalType == 6 || nalType == 7 || nalType == 8 || nalType == 9)
                {
                    commonNalCount += 1;
                }
            }
            else
            {
                invalidNalCount += 1;
            }

            cursor += nalLen;
        }

        if (cursor != size || nalCount == 0)
        {
            continue;
        }

        int score = (commonNalCount * 8) + (validNalCount * 3) - (invalidNalCount * 20) + nalCount;
        if (score > bestScore)
        {
            bestScore = score;
            bestCandidate = candidate;
        }
    }

    if (bestCandidate > 0 && bestScore > -10)
    {
        return bestCandidate;
    }
    return 0;
}

- (NSData * _Nullable)convertAnnexBToAVCCData:(const uint8_t *)bytes size:(size_t)size
{
    if (bytes == NULL || size == 0)
    {
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithCapacity:size];
    size_t cursor = 0;
    while (cursor + 3 < size)
    {
        size_t start = SIZE_MAX;
        size_t startCodeSize = 0;
        for (size_t i = cursor; i + 3 < size; i++)
        {
            if (bytes[i] == 0x00 && bytes[i + 1] == 0x00)
            {
                if (bytes[i + 2] == 0x01)
                {
                    start = i;
                    startCodeSize = 3;
                    break;
                }
                if ((i + 3 < size) && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01)
                {
                    start = i;
                    startCodeSize = 4;
                    break;
                }
            }
        }
        if (start == SIZE_MAX)
        {
            break;
        }

        size_t nalStart = start + startCodeSize;
        size_t nextStart = size;
        for (size_t i = nalStart; i + 3 < size; i++)
        {
            if (bytes[i] == 0x00 && bytes[i + 1] == 0x00 &&
                (bytes[i + 2] == 0x01 || ((i + 3 < size) && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01)))
            {
                nextStart = i;
                break;
            }
        }

        size_t nalSize = (nextStart > nalStart) ? (nextStart - nalStart) : 0;
        if (nalSize > 0)
        {
            uint8_t lengthPrefix[4] = {0, 0, 0, 0};
            switch (_nalLengthFieldSize)
            {
                case 1:
                    if (nalSize > UINT8_MAX) { return nil; }
                    lengthPrefix[0] = (uint8_t)nalSize;
                    break;
                case 2:
                    if (nalSize > UINT16_MAX) { return nil; }
                    lengthPrefix[0] = (uint8_t)((nalSize >> 8) & 0xFF);
                    lengthPrefix[1] = (uint8_t)(nalSize & 0xFF);
                    break;
                default:
                    if (nalSize > UINT32_MAX) { return nil; }
                    lengthPrefix[0] = (uint8_t)((nalSize >> 24) & 0xFF);
                    lengthPrefix[1] = (uint8_t)((nalSize >> 16) & 0xFF);
                    lengthPrefix[2] = (uint8_t)((nalSize >> 8) & 0xFF);
                    lengthPrefix[3] = (uint8_t)(nalSize & 0xFF);
                    break;
            }
            [output appendBytes:lengthPrefix length:(NSUInteger)_nalLengthFieldSize];
            [output appendBytes:(bytes + nalStart) length:nalSize];
        }

        if (nextStart <= cursor)
        {
            break;
        }
        cursor = nextStart;
    }

    return (output.length > 0) ? output : nil;
}

- (NSData * _Nullable)repackAVCCData:(const uint8_t *)bytes
                                size:(size_t)size
                sourceLengthFieldSize:(int)sourceLengthFieldSize
           destinationLengthFieldSize:(int)destinationLengthFieldSize
{
    if (bytes == NULL || size == 0 ||
        !(sourceLengthFieldSize == 1 || sourceLengthFieldSize == 2 || sourceLengthFieldSize == 4) ||
        !(destinationLengthFieldSize == 1 || destinationLengthFieldSize == 2 || destinationLengthFieldSize == 4))
    {
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithCapacity:size + 64];
    size_t cursor = 0;
    while (cursor + (size_t)sourceLengthFieldSize <= size)
    {
        uint32_t nalLen = 0;
        for (int i = 0; i < sourceLengthFieldSize; i++)
        {
            nalLen = (nalLen << 8) | bytes[cursor + (size_t)i];
        }
        cursor += (size_t)sourceLengthFieldSize;
        if (nalLen == 0 || cursor + nalLen > size)
        {
            return nil;
        }
        if ((destinationLengthFieldSize == 1 && nalLen > UINT8_MAX) ||
            (destinationLengthFieldSize == 2 && nalLen > UINT16_MAX))
        {
            return nil;
        }

        uint8_t prefix[4] = {0, 0, 0, 0};
        switch (destinationLengthFieldSize)
        {
            case 1:
                prefix[0] = (uint8_t)nalLen;
                break;
            case 2:
                prefix[0] = (uint8_t)((nalLen >> 8) & 0xFF);
                prefix[1] = (uint8_t)(nalLen & 0xFF);
                break;
            default:
                prefix[0] = (uint8_t)((nalLen >> 24) & 0xFF);
                prefix[1] = (uint8_t)((nalLen >> 16) & 0xFF);
                prefix[2] = (uint8_t)((nalLen >> 8) & 0xFF);
                prefix[3] = (uint8_t)(nalLen & 0xFF);
                break;
        }
        [output appendBytes:prefix length:(NSUInteger)destinationLengthFieldSize];
        [output appendBytes:(bytes + cursor) length:nalLen];
        cursor += nalLen;
    }

    if (cursor != size || output.length == 0)
    {
        return nil;
    }
    return output;
}

- (NSData * _Nullable)wrapSingleNALAsAVCCData:(const uint8_t *)bytes size:(size_t)size
{
    if (bytes == NULL || size == 0 || !(_nalLengthFieldSize == 1 || _nalLengthFieldSize == 2 || _nalLengthFieldSize == 4))
    {
        return nil;
    }
    if ((_nalLengthFieldSize == 1 && size > UINT8_MAX) ||
        (_nalLengthFieldSize == 2 && size > UINT16_MAX) ||
        (_nalLengthFieldSize == 4 && size > UINT32_MAX))
    {
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithCapacity:size + (NSUInteger)_nalLengthFieldSize];
    uint8_t lengthPrefix[4] = {0, 0, 0, 0};
    switch (_nalLengthFieldSize)
    {
        case 1:
            lengthPrefix[0] = (uint8_t)size;
            break;
        case 2:
            lengthPrefix[0] = (uint8_t)((size >> 8) & 0xFF);
            lengthPrefix[1] = (uint8_t)(size & 0xFF);
            break;
        default:
            lengthPrefix[0] = (uint8_t)((size >> 24) & 0xFF);
            lengthPrefix[1] = (uint8_t)((size >> 16) & 0xFF);
            lengthPrefix[2] = (uint8_t)((size >> 8) & 0xFF);
            lengthPrefix[3] = (uint8_t)(size & 0xFF);
            break;
    }
    [output appendBytes:lengthPrefix length:(NSUInteger)_nalLengthFieldSize];
    [output appendBytes:bytes length:size];
    return output;
}

- (NSData * _Nullable)normalizedPacketDataForBytes:(const uint8_t *)bytes
                                              size:(size_t)size
                                       emittedAVCC:(BOOL *)emittedAVCC
                                 normalizationNote:(NSString *__autoreleasing  _Nullable *)normalizationNote
{
    if (emittedAVCC != NULL)
    {
        *emittedAVCC = NO;
    }
    if (normalizationNote != NULL)
    {
        *normalizationNote = nil;
    }
    if (bytes == NULL || size == 0)
    {
        return nil;
    }

    BOOL validConfiguredAVCC = [self looksLikeAVCCData:bytes size:size lengthFieldSize:_nalLengthFieldSize];
    BOOL hasAnnexB = LibAVH264BufferHasAnnexBStartCode(bytes, size);
    int detectedLengthFieldSize = [self detectAVCCLengthFieldSize:bytes size:size];

    if (validConfiguredAVCC)
    {
        if (emittedAVCC != NULL)
        {
            *emittedAVCC = YES;
        }
        return nil;
    }
    if (hasAnnexB)
    {
        NSData *data = [self convertAnnexBToAVCCData:bytes size:size];
        if (data != nil)
        {
            if (emittedAVCC != NULL) { *emittedAVCC = YES; }
            if (normalizationNote != NULL)
            {
                *normalizationNote = [NSString stringWithFormat:@"converted AnnexB->AVCC packetSize=%zu convertedSize=%zu", size, data.length];
            }
        }
        return data;
    }
    if (detectedLengthFieldSize > 0)
    {
        if (detectedLengthFieldSize == _nalLengthFieldSize)
        {
            if (emittedAVCC != NULL) { *emittedAVCC = YES; }
            return nil;
        }
        NSData *data = [self repackAVCCData:bytes
                                       size:size
                       sourceLengthFieldSize:detectedLengthFieldSize
                  destinationLengthFieldSize:_nalLengthFieldSize];
        if (data != nil)
        {
            if (emittedAVCC != NULL) { *emittedAVCC = YES; }
            if (normalizationNote != NULL)
            {
                *normalizationNote = [NSString stringWithFormat:@"normalized AVCC length field size %d -> %d packetSize=%zu",
                                      detectedLengthFieldSize, _nalLengthFieldSize, size];
            }
        }
        return data;
    }

    NSData *data = [self wrapSingleNALAsAVCCData:bytes size:size];
    if (data != nil)
    {
        if (emittedAVCC != NULL) { *emittedAVCC = YES; }
        if (normalizationNote != NULL)
        {
            *normalizationNote = [NSString stringWithFormat:@"normalized non-annexb/non-avcc h264 packet to single-nal AVCC size=%zu", size];
        }
    }
    return data;
}

- (NSString *)auditSummaryForBytes:(const uint8_t *)bytes
                              size:(size_t)size
                        emittedAVCC:(BOOL)isAVCC
{
    if (bytes == NULL || size == 0)
    {
        return @"nal=none";
    }

    int counts[32] = {0};
    int nalCount = 0;
    BOOL sawIDR = NO;

    if (isAVCC)
    {
        size_t cursor = 0;
        while (cursor + (size_t)_nalLengthFieldSize <= size)
        {
            uint32_t nalLen = 0;
            for (int i = 0; i < _nalLengthFieldSize; i++)
            {
                nalLen = (nalLen << 8) | bytes[cursor + (size_t)i];
            }
            cursor += (size_t)_nalLengthFieldSize;
            if (nalLen == 0 || cursor + nalLen > size)
            {
                break;
            }
            uint8_t nalType = bytes[cursor] & 0x1F;
            if (nalType < 32) counts[nalType] += 1;
            sawIDR = sawIDR || (nalType == 5);
            nalCount += 1;
            cursor += nalLen;
        }
    }
    else
    {
        size_t i = 0;
        while (i + 3 < size)
        {
            size_t start = SIZE_MAX;
            size_t startCodeSize = 0;
            for (; i + 3 < size; i++)
            {
                if (bytes[i] == 0x00 && bytes[i + 1] == 0x00 &&
                    (bytes[i + 2] == 0x01 || ((i + 3 < size) && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01)))
                {
                    start = i;
                    startCodeSize = (bytes[i + 2] == 0x01) ? 3 : 4;
                    break;
                }
            }
            if (start == SIZE_MAX)
            {
                break;
            }
            size_t nalStart = start + startCodeSize;
            if (nalStart >= size) break;
            uint8_t nalType = bytes[nalStart] & 0x1F;
            if (nalType < 32) counts[nalType] += 1;
            sawIDR = sawIDR || (nalType == 5);
            nalCount += 1;
            i = nalStart + 1;
        }
    }

    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (int t = 0; t < 32; t++)
    {
        if (counts[t] > 0)
        {
            [types addObject:[NSString stringWithFormat:@"%d:%d", t, counts[t]]];
        }
    }
    NSString *joined = (types.count > 0) ? [types componentsJoinedByString:@","] : @"none";
    return [NSString stringWithFormat:@"nalCount=%d idr=%d types=[%@]", nalCount, sawIDR ? 1 : 0, joined];
}

@end
