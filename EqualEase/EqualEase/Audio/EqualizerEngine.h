//
//  EqualizerEngine.h
//  EqualEase
//

#ifndef EqualizerEngine_h
#define EqualizerEngine_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns EqualEase's MVP 10-band graphic EQ processing.
///
/// This module intentionally has no SwiftUI, AppKit, or main-actor coupling so
/// the Core Audio loopback adapter can call it directly from the real-time audio
/// path. Product-facing callers configure bypass, preamp, and ten fixed band
/// gains; the engine owns DSP-safe clamping and sample clipping.
@interface EqualizerEngine : NSObject

@property (readwrite, atomic) float sampleRate;
@property (readwrite, atomic) float preamp;
@property (readwrite, atomic) BOOL bypassed;
@property (readwrite, atomic) BOOL equalizerEnabled;
@property (readonly, nonatomic) NSUInteger channelCount;

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithChannelCount:(NSUInteger)channelCount sampleRate:(float)sampleRate NS_DESIGNATED_INITIALIZER;

- (void)setBandGain:(float)gain atIndex:(NSInteger)index;
- (float)bandGainAtIndex:(NSInteger)index;
- (float)processSample:(float)input channelIndex:(NSUInteger)channelIndex;
- (void)processInput:(const float *)input
              output:(float *)output
         sampleCount:(NSUInteger)sampleCount
        channelIndex:(NSUInteger)channelIndex;
- (void)reset;

@end

NS_ASSUME_NONNULL_END

#endif /* EqualizerEngine_h */
