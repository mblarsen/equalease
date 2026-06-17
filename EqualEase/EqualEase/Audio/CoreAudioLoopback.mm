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
/// CoreAudio provides non-interleaved buffers here: one buffer per channel.
/// With multi-tap routing, buffers are ordered by stream then channel:
/// tap0-left, tap0-right, tap1-left, tap1-right, ...
///
/// Processing:
/// 1. Map each input buffer to `(streamIndex, channelIndex)`.
/// 2. Bypassed streams accumulate verbatim into `bypassAccum[channel]`.
/// 3. Non-bypassed streams apply per-app gain and accumulate into `eqAccum[channel]`.
/// 4. Apply global EQ/preamp/clipping to the non-bypassed accumulation.
/// 5. Mix processed + bypass accumulations into the output channel buffers.
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

    const UInt32 maxChannels = 8;
    const UInt32 channelsPerStream = std::max<UInt32>(1, std::min<UInt32>((UInt32)loopback.channelsPerStream, maxChannels));
    const auto* streamConfigs = [loopback streamConfigsPointer];
    const NSUInteger configCount = streamConfigs ? streamConfigs->size() : 0;

    const UInt32 sampleCount = (outputData->mBuffers[0].mDataByteSize > 0 && outputData->mBuffers[0].mData != nullptr)
        ? outputData->mBuffers[0].mDataByteSize / sizeof(Float32)
        : 0;

    if (sampleCount == 0) {
        return kAudioHardwareNoError;
    }

    // Global bypass: preserve the old pass-through semantics, copying each
    // channel of the first stream to the matching output channel.
    if (loopback.bypassed) {
        for (UInt32 outIdx = 0; outIdx < outputBufferCount; ++outIdx) {
            AudioBuffer& outBuf = outputData->mBuffers[outIdx];
            if (outBuf.mData == nullptr) continue;

            const UInt32 sourceInputIdx = outIdx % channelsPerStream;
            if (sourceInputIdx < inputBufferCount && inputData->mBuffers[sourceInputIdx].mData != nullptr) {
                const AudioBuffer& inBuf = inputData->mBuffers[sourceInputIdx];
                const UInt32 copyBytes = std::min(inBuf.mDataByteSize, outBuf.mDataByteSize);
                memcpy(outBuf.mData, inBuf.mData, copyBytes);
                if (copyBytes < outBuf.mDataByteSize) {
                    memset(static_cast<char*>(outBuf.mData) + copyBytes, 0, outBuf.mDataByteSize - copyBytes);
                }
            } else {
                memset(outBuf.mData, 0, outBuf.mDataByteSize);
            }
        }
        return kAudioHardwareNoError;
    }

    Float32 eqAccum[maxChannels];
    Float32 bypassAccum[maxChannels];

    for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
        memset(eqAccum, 0, sizeof(Float32) * channelsPerStream);
        memset(bypassAccum, 0, sizeof(Float32) * channelsPerStream);

        for (UInt32 inputIdx = 0; inputIdx < inputBufferCount; ++inputIdx) {
            const AudioBuffer& inBuf = inputData->mBuffers[inputIdx];
            if (inBuf.mData == nullptr) continue;
            if ((sampleIndex + 1) * sizeof(Float32) > inBuf.mDataByteSize) continue;

            const UInt32 streamIdx = inputIdx / channelsPerStream;
            const UInt32 channelIdx = inputIdx % channelsPerStream;
            const auto* inSamples = static_cast<const Float32*>(inBuf.mData);
            const Float32 inputSample = inSamples[sampleIndex];

            bool isBypassed = false;
            float gain = 1.0f;
            if (streamIdx < configCount) {
                const StreamConfig& cfg = (*streamConfigs)[streamIdx];
                isBypassed = cfg.bypassed;
                gain = std::max(0.0f, std::min(cfg.gain, 1.0f));
            }

            if (isBypassed) {
                bypassAccum[channelIdx] += inputSample;
            } else {
                eqAccum[channelIdx] += inputSample * gain;
            }
        }

        for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
            eqAccum[ch] = [loopback processSample:eqAccum[ch] channelIndex:ch];
        }

        for (UInt32 outIdx = 0; outIdx < outputBufferCount; ++outIdx) {
            AudioBuffer& outBuf = outputData->mBuffers[outIdx];
            if (outBuf.mData == nullptr) continue;
            if ((sampleIndex + 1) * sizeof(Float32) > outBuf.mDataByteSize) continue;

            const UInt32 channelIdx = outIdx % channelsPerStream;
            auto* outSamples = static_cast<Float32*>(outBuf.mData);
            Float32 mixed = eqAccum[channelIdx] + bypassAccum[channelIdx];
            mixed = std::max(-1.0f, std::min(mixed, 1.0f));
            outSamples[sampleIndex] = mixed;
        }
    }

    return kAudioHardwareNoError;
}