//
//  CoreAudioLoopback.h
//  EqualEase
//

#ifndef CoreAudioLoopback_h
#define CoreAudioLoopback_h

#include <AppKit/AppKit.h>
#include <CoreAudio/CoreAudio.h>

/// Per-stream configuration: maps aggregate device input streams to apps.
///
/// Each stream in the aggregate device's IOProc corresponds to one tap.
/// StreamConfig tells the callback how to process that stream:
/// normal streams get per-app volume, off streams are copied verbatim, muted streams output silence.
typedef struct StreamConfig {
    /// Per-app volume multiplier (0–1). 1.0 = normal. Only meaningful when bypassed = NO and muted = NO.
    float gain;
    /// If YES, this stream's audio is copied verbatim to the output
    /// with no gain, no EQ, no preamp, no clamping.
    BOOL bypassed;
    /// If YES, this stream's audio is not mixed into the output.
    BOOL muted;
} StreamConfig;

/// Observed aggregate IOProc input layout for stream-to-config mapping.
typedef NS_ENUM(NSInteger, StreamMappingInputBufferLayout) {
    StreamMappingInputBufferLayoutEmpty = 0,
    StreamMappingInputBufferLayoutInterleavedStreams = 1,
    StreamMappingInputBufferLayoutChannelSplitStreams = 2,
    StreamMappingInputBufferLayoutAmbiguous = 3,
};

/// Diagnostics for the route's expected stream configs vs observed IOProc buffers.
typedef struct StreamMappingLayoutDiagnostics {
    StreamMappingInputBufferLayout inputLayout;
    UInt32 inputBufferCount;
    UInt32 outputBufferCount;
    UInt32 expectedStreamCount;
    UInt32 observedStreamCount;
    UInt32 channelsPerStream;
    BOOL inputBuffersAreStreams;
    BOOL outputBuffersAreStreams;
    BOOL canApplyStreamConfigs;
} StreamMappingLayoutDiagnostics;

/// Classifies IOProc buffer shape without inspecting audio samples.
/// Exposed for deterministic tests and used by the realtime callback.
#ifdef __cplusplus
extern "C" {
#endif
StreamMappingLayoutDiagnostics StreamMappingClassifyLayout(UInt32 inputBufferCount,
                                                           const UInt32 *inputChannelCounts,
                                                           UInt32 outputBufferCount,
                                                           const UInt32 *outputChannelCounts,
                                                           UInt32 expectedStreamCount,
                                                           UInt32 channelsPerStream);
#ifdef __cplusplus
}
#endif

/// A tiny Objective-C++ wrapper around an AudioDevice IOProc.
///
/// Swift should not own the real-time audio callback. This class copies
/// aggregate-device input to output while applying the current processing state.
/// Supports per-stream volume, bypass, and mute for multi-tap per-app volume.
@interface CoreAudioLoopback : NSObject

@property (readwrite, nonatomic) AudioObjectID deviceID;
@property (readonly, nonatomic) OSStatus lastStartError;
@property (readwrite, atomic) float outputGain;
@property (readwrite, atomic) float sampleRate;
@property (readwrite, atomic) BOOL bypassed;
@property (readwrite, atomic) BOOL equalizerEnabled;
@property (readonly, atomic) bool running;

/// Number of channels per stream (default 2, stereo).
@property (readwrite, nonatomic) NSUInteger channelsPerStream;

- (void)setBandGain:(float)gain atIndex:(NSInteger)index;
- (BOOL)start;
- (void)stop;

/// Sets the per-stream configuration for the current routing session.
/// The config is read atomically in the IOProc. The caller must ensure
/// the config count matches the number of input streams in the aggregate device.
/// Stream configs are indexed 0..count-1, corresponding to the tap order
/// in the aggregate device's tap list.
- (void)setStreamConfigs:(const StreamConfig*)configs count:(NSUInteger)count;

@end

#endif /* CoreAudioLoopback_h */
