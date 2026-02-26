//
//  LibAVCodecPacketFormatting.h
//  LibAVExtension
//
//  Strategy protocol for codec-specific packet shaping before CMSampleBuffer creation.
//
//  Why this exists:
//  - Container payloads are not always in the exact byte format VT expects.
//  - Some codecs require Annex-B -> length-prefixed conversion or similar rewrites.
//  - Cursor logic (seek/step/timestamps) should stay generic while payload rules stay codec-local.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol LibAVCodecPacketFormatting <NSObject>

// Returns normalized packet bytes when conversion is needed, else nil to use original bytes.
// `emittedAVCC` indicates whether the output packet should be treated as AVCC-style payload.
// `normalizationNote` is optional debug text for logs.
- (NSData * _Nullable)normalizedPacketDataForBytes:(const uint8_t *)bytes
                                              size:(size_t)size
                                       emittedAVCC:(BOOL *)emittedAVCC
                                 normalizationNote:(NSString * _Nullable __autoreleasing *)normalizationNote;

// Codec-specific packet audit summary used by debug logging.
- (NSString *)auditSummaryForBytes:(const uint8_t *)bytes
                              size:(size_t)size
                        emittedAVCC:(BOOL)emittedAVCC;

// When YES, cursor should avoid exposing chunk/location byte paths because this codec relies
// on sample-buffer path normalization for correctness.
- (BOOL)requiresSampleBufferPath;

@end

NS_ASSUME_NONNULL_END
