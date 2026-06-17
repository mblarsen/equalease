//
//  CoreAudioLoopback.mm
//  EqualEase
//

#import "CoreAudioLoopback.h"
#import "EqualizerEngine.h"

#include <algorithm>
#include <atomic>
#include <vector>

static OSStatus RoutingIOProc(AudioObjectID,
                              const AudioTimeStamp*,
                              const AudioBufferList* inputData,
                              const AudioTimeStamp*,
                              AudioBufferList* outputData,
                              const AudioTimeStamp*,
                              void* clientData) noexcept;

@interface CoreAudioLoopback ()
@property (readwrite, nonatomic) AudioDeviceIOProcID ioProcID;
@property (readwrite, nonatomic) OSStatus lastStartError;
@property (readwrite, atomic) bool running;
@end

@implementation CoreAudioLoopback {
    EqualizerEngine *_engine;
    // Per-stream config, atomically swapped via setStreamConfigs:count:.
    // The IOProc reads the pointer atomically; the setter swaps in a new vector.
    std::atomic<std::vector<StreamConfig>*> _streamConfigs;
}

@synthesize deviceID = _deviceID;
@synthesize lastStartError = _lastStartError;
@synthesize running = _running;
@synthesize ioProcID = _ioProcID;
@synthesize channelsPerStream = _channelsPerStream;

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _deviceID = kAudioObjectUnknown;
    _lastStartError = kAudioHardwareNoError;
    _running = false;
    _ioProcID = nullptr;
    _channelsPerStream = 2;
    _engine = [[EqualizerEngine alloc] initWithChannelCount:8 sampleRate:48000.0f];

    // Default: single stream, unity gain, not bypassed (legacy behavior).
    auto* defaultConfigs = new std::vector<StreamConfig>(1, {1.0f, NO});
    _streamConfigs.store(defaultConfigs, std::memory_order_release);

    return self;
}

- (float)outputGain {
    return _engine.preamp;
}

- (void)setOutputGain:(float)outputGain {
    _engine.preamp = outputGain;
}

- (float)sampleRate {
    return _engine.sampleRate;
}

- (void)setSampleRate:(float)sampleRate {
    _engine.sampleRate = sampleRate;
}

- (BOOL)bypassed {
    return _engine.bypassed;
}

- (void)setBypassed:(BOOL)bypassed {
    _engine.bypassed = bypassed;
}

- (BOOL)equalizerEnabled {
    return _engine.equalizerEnabled;
}

- (void)setEqualizerEnabled:(BOOL)equalizerEnabled {
    _engine.equalizerEnabled = equalizerEnabled;
}

- (void)setBandGain:(float)gain atIndex:(NSInteger)index {
    [_engine setBandGain:gain atIndex:index];
}

- (void)setStreamConfigs:(const StreamConfig*)configs count:(NSUInteger)count {
    if (count == 0) {
        return;
    }
    auto* newConfigs = new std::vector<StreamConfig>(configs, configs + count);
    auto* oldConfigs = _streamConfigs.exchange(newConfigs, std::memory_order_acq_rel);
    // The IOProc may still be reading oldConfigs; it will finish before the
    // next callback reads the new pointer. Delete after a safe delay.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        delete oldConfigs;
    });
}

/// Returns a raw pointer to the current stream configs vector for the IOProc.
/// NOT part of the public header — used only by the static IOProc.
- (const std::vector<StreamConfig>*)streamConfigsPointer {
    return _streamConfigs.load(std::memory_order_acquire);
}

- (BOOL)start {
    if (self.running) {
        return YES;
    }
    if (self.deviceID == kAudioObjectUnknown) {
        self.lastStartError = kAudioObjectUnknown;
        return NO;
    }

    self.lastStartError = kAudioHardwareNoError;
    AudioDeviceIOProcID ioProcID = nullptr;
    OSStatus error = AudioDeviceCreateIOProcID(self.deviceID, RoutingIOProc, (__bridge void*)self, &ioProcID);
    if (error != kAudioHardwareNoError) {
        self.lastStartError = error;
        NSLog(@"EqualEase routing: AudioDeviceCreateIOProcID failed: %d", error);
        return NO;
    }

    self.ioProcID = ioProcID;
    error = AudioDeviceStart(self.deviceID, self.ioProcID);
    if (error != kAudioHardwareNoError) {
        self.lastStartError = error;
        NSLog(@"EqualEase routing: AudioDeviceStart failed: %d", error);
        AudioDeviceDestroyIOProcID(self.deviceID, self.ioProcID);
        self.ioProcID = nullptr;
        return NO;
    }

    self.running = true;
    return YES;
}

- (void)stop {
    if (self.ioProcID != nullptr && self.deviceID != kAudioObjectUnknown) {
        AudioDeviceStop(self.deviceID, self.ioProcID);
        AudioDeviceDestroyIOProcID(self.deviceID, self.ioProcID);
    }

    self.ioProcID = nullptr;
    self.running = false;
}

- (float)processSample:(float)input channelIndex:(NSUInteger)channelIndex {
    return [_engine processSample:input channelIndex:channelIndex];
}

- (void)dealloc {
    [self stop];
    auto* configs = _streamConfigs.load(std::memory_order_acquire);
    delete configs;
}

@end

/// Real-time audio callback.
///
/// With multi-tap per-app volume, the aggregate device provides one input buffer
/// per tap (per-app taps + fallback tap). Each buffer is stereo (2 channels).
///
/// Processing:
/// 1. For each stream, check its StreamConfig:
///    - Bypassed streams: accumulate samples verbatim into bypassAccum.
///    - Non-bypassed streams: apply per-app gain, accumulate into eqAccum.
/// 2. Apply global EQ to eqAccum.
/// 3. Apply global preamp to eqAccum.
/// 4. Mix bypassAccum + eqAccum into output, with clamping.
/// 5. If global bypass is on, copy input[0] directly to output (legacy path).
static OSStatus RoutingIOProc(AudioObjectID,
                              const AudioTimeStamp*,
                              const AudioBufferList* inputData,
                              const AudioTimeStamp*,
                              AudioBufferList* outputData,
                              const AudioTimeStamp*,
                              void* clientData) noexcept {
    if (inputData == nullptr || outputData == nullptr || clientData == nullptr) {
        return kAudioHardwareNoError;
    }

    auto* loopback = (__bridge CoreAudioLoopback*)clientData;
    const UInt32 inputBufferCount = inputData->mNumberBuffers;
    const UInt32 outputBufferCount = outputData->mNumberBuffers;

    if (inputBufferCount == 0 || outputBufferCount == 0) {
        return kAudioHardwareNoError;
    }

    const UInt32 channelsPerStream = (UInt32)loopback.channelsPerStream;
    const UInt32 bufferCount = std::min(inputBufferCount, outputBufferCount);
    const auto* streamConfigs = [loopback streamConfigsPointer];
    const NSUInteger configCount = streamConfigs ? streamConfigs->size() : 0;

    // Determine sample count from the first input buffer.
    const UInt32 sampleCount = (inputData->mBuffers[0].mDataByteSize > 0 && inputData->mBuffers[0].mData != nullptr)
        ? inputData->mBuffers[0].mDataByteSize / sizeof(Float32)
        : 0;

    if (sampleCount == 0) {
        // Zero-length buffer — write silence to output.
        for (UInt32 bufIdx = 0; bufIdx < outputBufferCount; ++bufIdx) {
            memset(outputData->mBuffers[bufIdx].mData, 0, outputData->mBuffers[bufIdx].mDataByteSize);
        }
        return kAudioHardwareNoError;
    }

    // Global bypass: legacy single-stream passthrough (no per-stream processing).
    if (loopback.bypassed) {
        // Use only the first input stream (fallback tap) for global bypass.
        const AudioBuffer inputBuffer = inputData->mBuffers[0];
        if (inputBuffer.mData == nullptr) {
            return kAudioHardwareNoError;
        }
        for (UInt32 bufIdx = 0; bufIdx < bufferCount; ++bufIdx) {
            const AudioBuffer& outBuf = outputData->mBuffers[bufIdx];
            if (outBuf.mData == nullptr) continue;
            const UInt32 copyBytes = std::min(inputBuffer.mDataByteSize, outBuf.mDataByteSize);
            memcpy(outBuf.mData, inputBuffer.mData, copyBytes);
        }
        return kAudioHardwareNoError;
    }

    // Multi-stream processing: accumulate bypass and EQ paths separately.
    // Use stack-allocated buffers for zero latency allocation.
    // Channel 0 = left, Channel 1 = right (for stereo; up to 8 channels supported).
    const NSUInteger maxChannels = 8;
    Float32 eqAccum[maxChannels];
    Float32 bypassAccum[maxChannels];

    for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
        // Reset accumulators for this sample.
        memset(eqAccum, 0, sizeof(Float32) * channelsPerStream);
        memset(bypassAccum, 0, sizeof(Float32) * channelsPerStream);

        // Process each input stream (one per tap).
        for (UInt32 streamIdx = 0; streamIdx < inputBufferCount; ++streamIdx) {
            const AudioBuffer& inBuf = inputData->mBuffers[streamIdx];
            if (inBuf.mData == nullptr) continue;

            const auto* inSamples = static_cast<const Float32*>(inBuf.mData);

            // Determine per-stream config.
            bool isBypassed = false;
            float gain = 1.0f;
            if (streamIdx < configCount) {
                const StreamConfig& cfg = (*streamConfigs)[streamIdx];
                isBypassed = cfg.bypassed;
                gain = cfg.gain;
            }
            // Clamp gain for safety.
            gain = std::max(0.0f, std::min(gain, 2.0f));

            if (isBypassed) {
                // Bypass: accumulate verbatim (no gain, no EQ).
                for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
                    UInt32 offset = sampleIndex * channelsPerStream + ch;
                    if (offset * sizeof(Float32) < inBuf.mDataByteSize) {
                        bypassAccum[ch] += inSamples[offset];
                    }
                }
            } else {
                // Non-bypass: apply per-app gain and accumulate for EQ.
                for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
                    UInt32 offset = sampleIndex * channelsPerStream + ch;
                    if (offset * sizeof(Float32) < inBuf.mDataByteSize) {
                        eqAccum[ch] += inSamples[offset] * gain;
                    }
                }
            }
        }

        // Apply global EQ to the non-bypass accumulation.
        for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
            eqAccum[ch] = [loopback processSample:eqAccum[ch] channelIndex:ch];
        }

        // Mix bypass + EQ'd paths, clamp, and write output.
        // Output is interleaved stereo (or multi-channel) — one buffer per channel.
        for (UInt32 bufIdx = 0; bufIdx < bufferCount; ++bufIdx) {
            AudioBuffer& outBuf = outputData->mBuffers[bufIdx];
            if (outBuf.mData == nullptr) continue;
            auto* outSamples = static_cast<Float32*>(outBuf.mData);

            // bufIdx corresponds to channel index in the output buffer list.
            Float32 mixed = eqAccum[bufIdx] + bypassAccum[bufIdx];
            // Clamp to prevent hard clipping.
            mixed = std::max(-1.0f, std::min(mixed, 1.0f));
            outSamples[sampleIndex] = mixed;
        }
    }

    return kAudioHardwareNoError;
}