//
//  CoreAudioLoopback.mm
//  EqualEase
//

#import "CoreAudioLoopback.h"
#import "EqualizerEngine.h"

#include <algorithm>
#include <atomic>
#include <mutex>
#include <vector>

/// Snapshot of the stream config vector plus a monotonic epoch.
/// The IOProc reports back the epoch it observed, allowing retired snapshots
/// to be freed only after the real-time callback has moved past them.
struct StreamConfigSnapshot {
    uint64_t epoch;
    std::vector<StreamConfig>* configs;
};

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
    // Per-stream config snapshot, atomically swapped via setStreamConfigs:count:.
    // The IOProc reads the snapshot atomically and reports back the epoch it observed.
    std::atomic<StreamConfigSnapshot*> _streamConfigs;
    std::atomic<uint64_t> _completedEpoch;
    std::atomic<uint64_t> _diagnosticsLoggedEpoch;
    std::mutex _retiredSnapshotsMutex;
    std::vector<StreamConfigSnapshot*> _retiredSnapshots;
    // Scratch buffers for accumulating non-bypassed audio before EQ processing.
    // Sized lazily; once grown they stay allocated to avoid real-time heap traffic.
    std::vector<Float32> _eqScratch[8];
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
    _completedEpoch.store(0, std::memory_order_relaxed);
    _diagnosticsLoggedEpoch.store(0, std::memory_order_relaxed);

    // Default: single stream, unity gain, not bypassed (legacy behavior).
    auto* defaultConfigs = new std::vector<StreamConfig>(1, {1.0f, NO, NO});
    auto* defaultSnapshot = new StreamConfigSnapshot{1, defaultConfigs};
    _streamConfigs.store(defaultSnapshot, std::memory_order_release);

    // Pre-allocate scratch buffers to a typical CoreAudio buffer size.
    // Using resize (not reserve) so no lazy heap allocation happens in the IOProc.
    constexpr size_t kMaxBufferFrames = 4096;
    for (size_t ch = 0; ch < 8; ++ch) {
        _eqScratch[ch].resize(kMaxBufferFrames);
    }

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
    auto* oldSnapshot = _streamConfigs.load(std::memory_order_acquire);
    uint64_t newEpoch = 1;
    if (oldSnapshot != nullptr) {
        newEpoch = oldSnapshot->epoch + 1;
    }
    auto* newSnapshot = new StreamConfigSnapshot{newEpoch, newConfigs};
    auto* retiredSnapshot = _streamConfigs.exchange(newSnapshot, std::memory_order_acq_rel);

    {
        std::lock_guard<std::mutex> lock(_retiredSnapshotsMutex);
        _retiredSnapshots.push_back(retiredSnapshot);
    }
    [self cleanupRetiredSnapshots];
}

/// Returns the current stream config snapshot for the IOProc.
/// NOT part of the public header — used only by the static IOProc.
- (const StreamConfigSnapshot*)streamConfigsPointer {
    return _streamConfigs.load(std::memory_order_acquire);
}

/// Returns a writable scratch buffer for the given channel, sized to at least `size`.
/// NOT part of the public header — used only by the static IOProc.
- (Float32*)eqScratchBufferForChannel:(NSUInteger)channel size:(UInt32)size {
    if (channel >= 8 || size > _eqScratch[channel].size()) {
        return nullptr;
    }
    return _eqScratch[channel].data();
}

/// Called by the IOProc after it finishes processing a callback.
/// NOT part of the public header.
- (void)markEpochCompleted:(uint64_t)epoch {
    _completedEpoch.store(epoch, std::memory_order_release);
}

/// Returns YES once for each stream-config epoch so the IOProc can emit
/// first-callback route diagnostics without logging on every callback.
/// NOT part of the public header.
- (BOOL)shouldLogStreamMappingDiagnosticsForEpoch:(uint64_t)epoch {
    if (epoch == 0) {
        return NO;
    }
    uint64_t previous = _diagnosticsLoggedEpoch.load(std::memory_order_acquire);
    while (previous != epoch) {
        if (_diagnosticsLoggedEpoch.compare_exchange_weak(previous, epoch, std::memory_order_acq_rel)) {
            return YES;
        }
    }
    return NO;
}

/// Frees retired snapshots once a newer snapshot has also been retired,
/// guaranteeing no in-flight IOProc is still using the old one.
///
/// Keeps the most recently retired snapshot as a safety buffer: it may have
/// been read by an IOProc just before the swap, and that IOProc may still be
/// running. A snapshot is only freed when another snapshot has been retired
/// after it, guaranteeing the in-flight IOProc has moved on.
- (void)cleanupRetiredSnapshots {
    std::lock_guard<std::mutex> lock(_retiredSnapshotsMutex);
    while (_retiredSnapshots.size() > 1) {
        auto* snapshot = _retiredSnapshots.front();
        _retiredSnapshots.erase(_retiredSnapshots.begin());
        delete snapshot->configs;
        delete snapshot;
    }
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

- (void)processInput:(const float *)input
              output:(float *)output
         sampleCount:(NSUInteger)sampleCount
        channelIndex:(NSUInteger)channelIndex {
    [_engine processInput:input output:output sampleCount:sampleCount channelIndex:channelIndex];
}

- (void)dealloc {
    [self stop];
    auto* snapshot = _streamConfigs.load(std::memory_order_acquire);
    if (snapshot != nullptr) {
        delete snapshot->configs;
        delete snapshot;
    }
    {
        std::lock_guard<std::mutex> lock(_retiredSnapshotsMutex);
        for (auto* retired : _retiredSnapshots) {
            if (retired != nullptr) {
                delete retired->configs;
                delete retired;
            }
        }
        _retiredSnapshots.clear();
    }
}

@end

static const char* streamMappingLayoutName(StreamMappingInputBufferLayout layout) noexcept {
    switch (layout) {
        case StreamMappingInputBufferLayoutEmpty:
            return "empty";
        case StreamMappingInputBufferLayoutInterleavedStreams:
            return "interleaved-streams";
        case StreamMappingInputBufferLayoutChannelSplitStreams:
            return "channel-split-streams";
        case StreamMappingInputBufferLayoutAmbiguous:
            return "ambiguous";
    }
}

extern "C" StreamMappingLayoutDiagnostics StreamMappingClassifyLayout(UInt32 inputBufferCount,
                                                                        const UInt32 *inputChannelCounts,
                                                                        UInt32 outputBufferCount,
                                                                        const UInt32 *outputChannelCounts,
                                                                        UInt32 expectedStreamCount,
                                                                        UInt32 channelsPerStream) {
    const UInt32 safeChannelsPerStream = std::max<UInt32>(1, channelsPerStream);
    StreamMappingLayoutDiagnostics diagnostics = {
        StreamMappingInputBufferLayoutEmpty,
        inputBufferCount,
        outputBufferCount,
        expectedStreamCount,
        0,
        safeChannelsPerStream,
        NO,
        outputBufferCount == 1 ? YES : NO,
        NO,
    };

    if (outputBufferCount > 0 && outputChannelCounts != nullptr) {
        diagnostics.outputBuffersAreStreams = (outputChannelCounts[0] > 1 || outputBufferCount == 1) ? YES : NO;
    }

    if (inputBufferCount == 0 || inputChannelCounts == nullptr) {
        return diagnostics;
    }

    bool allSingleChannel = true;
    bool allMultiChannel = true;
    for (UInt32 idx = 0; idx < inputBufferCount; ++idx) {
        const UInt32 channelCount = std::max<UInt32>(1, inputChannelCounts[idx]);
        allSingleChannel = allSingleChannel && channelCount == 1;
        allMultiChannel = allMultiChannel && channelCount > 1;
    }

    if (allMultiChannel) {
        diagnostics.inputLayout = StreamMappingInputBufferLayoutInterleavedStreams;
        diagnostics.inputBuffersAreStreams = YES;
        diagnostics.observedStreamCount = inputBufferCount;
    } else if (allSingleChannel && inputBufferCount % safeChannelsPerStream == 0) {
        diagnostics.inputLayout = StreamMappingInputBufferLayoutChannelSplitStreams;
        diagnostics.inputBuffersAreStreams = NO;
        diagnostics.observedStreamCount = inputBufferCount / safeChannelsPerStream;
    } else {
        diagnostics.inputLayout = StreamMappingInputBufferLayoutAmbiguous;
        diagnostics.inputBuffersAreStreams = NO;
        diagnostics.observedStreamCount = 0;
    }

    diagnostics.canApplyStreamConfigs = (
        diagnostics.inputLayout != StreamMappingInputBufferLayoutAmbiguous
        && diagnostics.observedStreamCount == expectedStreamCount
        && expectedStreamCount > 0
    ) ? YES : NO;
    return diagnostics;
}

/// Adds `sample` to every output buffer location that corresponds to
/// `channelIdx` at `sampleIndex`. Handles both stream-shaped (interleaved)
/// and channel-shaped output buffer lists.
static inline void addSampleToOutput(Float32 sample,
                                     UInt32 sampleIndex,
                                     UInt32 channelIdx,
                                     UInt32 channelsPerStream,
                                     AudioBufferList* outputData,
                                     bool outputBuffersAreStreams) noexcept {
    const UInt32 outputBufferCount = outputData->mNumberBuffers;
    for (UInt32 outIdx = 0; outIdx < outputBufferCount; ++outIdx) {
        AudioBuffer& outBuf = outputData->mBuffers[outIdx];
        if (outBuf.mData == nullptr) continue;

        if (outputBuffersAreStreams) {
            const UInt32 outChannels = std::max<UInt32>(1, outBuf.mNumberChannels);
            if (channelIdx >= outChannels) continue;
            const UInt32 offset = sampleIndex * outChannels + channelIdx;
            if ((offset + 1) * sizeof(Float32) > outBuf.mDataByteSize) continue;
            auto* outSamples = static_cast<Float32*>(outBuf.mData);
            outSamples[offset] += sample;
        } else {
            if (outIdx % channelsPerStream != channelIdx) continue;
            if ((sampleIndex + 1) * sizeof(Float32) > outBuf.mDataByteSize) continue;
            auto* outSamples = static_cast<Float32*>(outBuf.mData);
            outSamples[sampleIndex] += sample;
        }
    }
}

/// Real-time audio callback.
///
/// CoreAudio tap-backed aggregates may deliver either:
/// - one buffer per stream, with `mNumberChannels > 1` (interleaved stereo), or
/// - one buffer per channel, ordered by stream then channel.
///
/// The IOProc supports both shapes so multiple app taps can be mixed reliably.
/// EQ processing is performed on whole buffers via `processInput:` to avoid
/// Objective-C message sends inside the per-sample hot loop.
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
    const auto* snapshot = [loopback streamConfigsPointer];
    const auto* streamConfigs = snapshot ? snapshot->configs : nullptr;
    const NSUInteger configCount = streamConfigs ? streamConfigs->size() : 0;
    const uint64_t observedEpoch = snapshot ? snapshot->epoch : 0;

    constexpr UInt32 maxDiagnosticBuffers = 64;
    UInt32 inputChannelCounts[maxDiagnosticBuffers] = {0};
    UInt32 outputChannelCounts[maxDiagnosticBuffers] = {0};
    const bool diagnosticsBufferOverflow = inputBufferCount > maxDiagnosticBuffers || outputBufferCount > maxDiagnosticBuffers;
    for (UInt32 idx = 0; idx < std::min(inputBufferCount, maxDiagnosticBuffers); ++idx) {
        inputChannelCounts[idx] = inputData->mBuffers[idx].mNumberChannels;
    }
    for (UInt32 idx = 0; idx < std::min(outputBufferCount, maxDiagnosticBuffers); ++idx) {
        outputChannelCounts[idx] = outputData->mBuffers[idx].mNumberChannels;
    }

    StreamMappingLayoutDiagnostics diagnostics;
    if (diagnosticsBufferOverflow) {
        diagnostics = {
            StreamMappingInputBufferLayoutAmbiguous,
            inputBufferCount,
            outputBufferCount,
            (UInt32)configCount,
            0,
            channelsPerStream,
            NO,
            outputData->mBuffers[0].mNumberChannels > 1 || outputBufferCount == 1,
            NO,
        };
    } else {
        diagnostics = StreamMappingClassifyLayout(
            inputBufferCount,
            inputChannelCounts,
            outputBufferCount,
            outputChannelCounts,
            (UInt32)configCount,
            channelsPerStream
        );
    }

    const bool inputBuffersAreStreams = diagnostics.inputBuffersAreStreams;
    const bool outputBuffersAreStreams = diagnostics.outputBuffersAreStreams;
    const UInt32 firstOutputChannels = std::max<UInt32>(1, outputData->mBuffers[0].mNumberChannels);
    const UInt32 sampleCount = (outputData->mBuffers[0].mDataByteSize > 0 && outputData->mBuffers[0].mData != nullptr)
        ? outputData->mBuffers[0].mDataByteSize / (sizeof(Float32) * (outputBuffersAreStreams ? firstOutputChannels : 1))
        : 0;

    if ([loopback shouldLogStreamMappingDiagnosticsForEpoch:observedEpoch]) {
        const char* safeAction = diagnostics.canApplyStreamConfigs ? "applying stream configs" : "using unity per-stream fallback";
        NSLog(@"EqualEase routing stream mapping: epoch=%llu expectedStreams=%u observedStreams=%u inputBuffers=%u outputBuffers=%u channelsPerStream=%u inputLayout=%s action=%s",
              observedEpoch,
              diagnostics.expectedStreamCount,
              diagnostics.observedStreamCount,
              diagnostics.inputBufferCount,
              diagnostics.outputBufferCount,
              diagnostics.channelsPerStream,
              streamMappingLayoutName(diagnostics.inputLayout),
              safeAction);
    }

    if (sampleCount == 0) {
        return kAudioHardwareNoError;
    }

    // Cache global state outside the hot loop; avoid Objective-C messaging per sample.
    const bool globalBypassed = loopback.bypassed;

    // Clear output buffers and per-channel EQ scratch buffers.
    for (UInt32 outIdx = 0; outIdx < outputBufferCount; ++outIdx) {
        AudioBuffer& outBuf = outputData->mBuffers[outIdx];
        if (outBuf.mData != nullptr && outBuf.mDataByteSize > 0) {
            memset(outBuf.mData, 0, outBuf.mDataByteSize);
        }
    }

    Float32* eqScratch[8] = {nullptr};
    for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
        eqScratch[ch] = [loopback eqScratchBufferForChannel:ch size:sampleCount];
        if (eqScratch[ch] != nullptr) {
            memset(eqScratch[ch], 0, sizeof(Float32) * sampleCount);
        }
    }

    // First pass: classify each input sample as muted, bypassed, or processed,
    // and route it to the appropriate accumulator.
    for (UInt32 inputIdx = 0; inputIdx < inputBufferCount; ++inputIdx) {
        const AudioBuffer& inBuf = inputData->mBuffers[inputIdx];
        if (inBuf.mData == nullptr) continue;

        const UInt32 bufferChannels = std::max<UInt32>(1, inBuf.mNumberChannels);
        const auto* inSamples = static_cast<const Float32*>(inBuf.mData);

        if (inputBuffersAreStreams) {
            const UInt32 streamIdx = inputIdx;
            const UInt32 channelLimit = std::min(channelsPerStream, bufferChannels);
            for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
                for (UInt32 channelIdx = 0; channelIdx < channelLimit; ++channelIdx) {
                    const UInt32 offset = sampleIndex * bufferChannels + channelIdx;
                    if ((offset + 1) * sizeof(Float32) > inBuf.mDataByteSize) continue;

                    bool isBypassed = globalBypassed;
                    bool isMuted = false;
                    float gain = 1.0f;
                    if (diagnostics.canApplyStreamConfigs && streamIdx < configCount) {
                        const StreamConfig& cfg = (*streamConfigs)[streamIdx];
                        isBypassed = isBypassed || cfg.bypassed;
                        isMuted = cfg.muted;
                        gain = std::max(0.0f, std::min(cfg.gain, 1.0f));
                    }

                    if (isMuted) continue;
                    if (isBypassed) {
                        // Bypass = verbatim pass-through: no app volume, no EQ, no preamp.
                        addSampleToOutput(inSamples[offset], sampleIndex, channelIdx, channelsPerStream, outputData, outputBuffersAreStreams);
                    } else if (eqScratch[channelIdx] != nullptr) {
                        eqScratch[channelIdx][sampleIndex] += inSamples[offset] * gain;
                    }
                }
            }
        } else {
            const UInt32 streamIdx = inputIdx / channelsPerStream;
            const UInt32 channelIdx = inputIdx % channelsPerStream;
            if (channelIdx >= channelsPerStream) continue;

            for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
                if ((sampleIndex + 1) * sizeof(Float32) > inBuf.mDataByteSize) continue;

                bool isBypassed = globalBypassed;
                bool isMuted = false;
                float gain = 1.0f;
                if (diagnostics.canApplyStreamConfigs && streamIdx < configCount) {
                    const StreamConfig& cfg = (*streamConfigs)[streamIdx];
                    isBypassed = isBypassed || cfg.bypassed;
                    isMuted = cfg.muted;
                    gain = std::max(0.0f, std::min(cfg.gain, 1.0f));
                }

                if (isMuted) continue;
                if (isBypassed) {
                    // Bypass = verbatim pass-through: no app volume, no EQ, no preamp.
                    addSampleToOutput(inSamples[sampleIndex], sampleIndex, channelIdx, channelsPerStream, outputData, outputBuffersAreStreams);
                } else if (eqScratch[channelIdx] != nullptr) {
                    eqScratch[channelIdx][sampleIndex] += inSamples[sampleIndex] * gain;
                }
            }
        }
    }

    // Second pass: run EQ/preamp/clipping on each channel's accumulated buffer.
    // One Objective-C message per channel per callback — no per-sample messaging.
    if (!globalBypassed) {
        for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
            if (eqScratch[ch] == nullptr) continue;
            [loopback processInput:eqScratch[ch] output:eqScratch[ch] sampleCount:sampleCount channelIndex:ch];
        }
    }

    // Third pass: mix processed audio into the output and clamp.
    for (UInt32 ch = 0; ch < channelsPerStream; ++ch) {
        if (eqScratch[ch] == nullptr) continue;
        for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
            addSampleToOutput(eqScratch[ch][sampleIndex], sampleIndex, ch, channelsPerStream, outputData, outputBuffersAreStreams);
        }
    }

    for (UInt32 outIdx = 0; outIdx < outputBufferCount; ++outIdx) {
        AudioBuffer& outBuf = outputData->mBuffers[outIdx];
        if (outBuf.mData == nullptr) continue;
        auto* outSamples = static_cast<Float32*>(outBuf.mData);
        const UInt32 outChannels = std::max<UInt32>(1, outBuf.mNumberChannels);
        if (outputBuffersAreStreams) {
            const UInt32 channelLimit = std::min(channelsPerStream, outChannels);
            for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
                for (UInt32 channelIdx = 0; channelIdx < channelLimit; ++channelIdx) {
                    const UInt32 offset = sampleIndex * outChannels + channelIdx;
                    if ((offset + 1) * sizeof(Float32) > outBuf.mDataByteSize) continue;
                    outSamples[offset] = std::max(-1.0f, std::min(outSamples[offset], 1.0f));
                }
            }
        } else {
            for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
                if ((sampleIndex + 1) * sizeof(Float32) > outBuf.mDataByteSize) continue;
                outSamples[sampleIndex] = std::max(-1.0f, std::min(outSamples[sampleIndex], 1.0f));
            }
        }
    }

    [loopback markEpochCompleted:observedEpoch];

    return kAudioHardwareNoError;
}