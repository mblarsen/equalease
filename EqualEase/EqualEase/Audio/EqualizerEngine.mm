//
//  EqualizerEngine.mm
//  EqualEase
//

#import "EqualizerEngine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>

namespace {

constexpr size_t BandCount = 10;
constexpr size_t MaxChannelCount = 8;
constexpr float MinimumBandGainDB = -12.0f;
constexpr float MaximumBandGainDB = 12.0f;
constexpr float MinimumPreamp = 0.0f;
constexpr float MaximumPreamp = 2.0f;
constexpr std::array<float, BandCount> BandFrequencies = {
    31.0f, 62.0f, 125.0f, 250.0f, 500.0f,
    1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f,
};

struct BiquadFilter {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;
    float z1 = 0.0f;
    float z2 = 0.0f;
    float configuredSampleRate = -1.0f;
    float configuredFrequency = -1.0f;
    float configuredGainDB = 999.0f;

    void configureIdentity() noexcept {
        b0 = 1.0f;
        b1 = 0.0f;
        b2 = 0.0f;
        a1 = 0.0f;
        a2 = 0.0f;
    }

    void configurePeaking(float sampleRate, float frequency, float gainDB) noexcept {
        if (sampleRate == configuredSampleRate
            && frequency == configuredFrequency
            && gainDB == configuredGainDB) {
            return;
        }

        configuredSampleRate = sampleRate;
        configuredFrequency = frequency;
        configuredGainDB = gainDB;

        if (sampleRate <= 0.0f || frequency <= 0.0f || frequency >= sampleRate * 0.5f || std::abs(gainDB) < 0.001f) {
            configureIdentity();
            return;
        }

        constexpr float q = 1.41421356f;
        constexpr float pi = 3.14159265358979323846f;
        const float a = std::pow(10.0f, gainDB / 40.0f);
        const float omega = 2.0f * pi * frequency / sampleRate;
        const float alpha = std::sin(omega) / (2.0f * q);
        const float cosOmega = std::cos(omega);

        const float rawB0 = 1.0f + alpha * a;
        const float rawB1 = -2.0f * cosOmega;
        const float rawB2 = 1.0f - alpha * a;
        const float rawA0 = 1.0f + alpha / a;
        const float rawA1 = -2.0f * cosOmega;
        const float rawA2 = 1.0f - alpha / a;

        b0 = rawB0 / rawA0;
        b1 = rawB1 / rawA0;
        b2 = rawB2 / rawA0;
        a1 = rawA1 / rawA0;
        a2 = rawA2 / rawA0;
    }

    float process(float input) noexcept {
        const float output = b0 * input + z1;
        z1 = b1 * input - a1 * output + z2;
        z2 = b2 * input - a2 * output;
        return output;
    }

    void reset() noexcept {
        z1 = 0.0f;
        z2 = 0.0f;
    }
};

struct EqualizerDSPState {
    std::atomic<float> sampleRate = 48000.0f;
    std::atomic<float> preamp = 1.0f;
    std::atomic<bool> bypassed = false;
    std::atomic<bool> equalizerEnabled = false;
    std::array<std::atomic<float>, BandCount> bandGains;
    std::array<std::array<BiquadFilter, BandCount>, MaxChannelCount> filters;

    EqualizerDSPState() {
        for (auto& gain : bandGains) {
            gain.store(0.0f, std::memory_order_relaxed);
        }
    }

    void setBandGain(float gain, size_t index) noexcept {
        if (index >= bandGains.size()) {
            return;
        }
        bandGains[index].store(std::clamp(gain, MinimumBandGainDB, MaximumBandGainDB), std::memory_order_relaxed);
    }

    float bandGain(size_t index) const noexcept {
        if (index >= bandGains.size()) {
            return 0.0f;
        }
        return bandGains[index].load(std::memory_order_relaxed);
    }

    float process(float input, size_t channelIndex) noexcept {
        if (bypassed.load(std::memory_order_relaxed)) {
            return input;
        }

        const size_t safeChannelIndex = std::min(channelIndex, MaxChannelCount - 1);
        const float safeSampleRate = std::max(sampleRate.load(std::memory_order_relaxed), 1.0f);
        float output = input;

        if (equalizerEnabled.load(std::memory_order_relaxed)) {
            for (size_t bandIndex = 0; bandIndex < BandCount; ++bandIndex) {
                const float gain = bandGains[bandIndex].load(std::memory_order_relaxed);
                auto& filter = filters[safeChannelIndex][bandIndex];
                filter.configurePeaking(safeSampleRate, BandFrequencies[bandIndex], gain);
                output = filter.process(output);
            }
        }

        output *= preamp.load(std::memory_order_relaxed);
        return std::clamp(output, -1.0f, 1.0f);
    }

    void reset() noexcept {
        for (auto& channelFilters : filters) {
            for (auto& filter : channelFilters) {
                filter.reset();
            }
        }
    }
};

} // namespace

@implementation EqualizerEngine {
    std::unique_ptr<EqualizerDSPState> _state;
    NSUInteger _channelCount;
}

- (instancetype)init {
    return [self initWithChannelCount:2 sampleRate:48000.0f];
}

- (instancetype)initWithChannelCount:(NSUInteger)channelCount sampleRate:(float)sampleRate {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _state = std::make_unique<EqualizerDSPState>();
    _channelCount = std::clamp<NSUInteger>(channelCount, 1, MaxChannelCount);
    self.sampleRate = sampleRate;

    return self;
}

- (NSUInteger)channelCount {
    return _channelCount;
}

- (float)sampleRate {
    return _state == nullptr ? 48000.0f : _state->sampleRate.load(std::memory_order_relaxed);
}

- (void)setSampleRate:(float)sampleRate {
    if (_state == nullptr) {
        return;
    }
    _state->sampleRate.store(std::max(sampleRate, 1.0f), std::memory_order_relaxed);
}

- (float)preamp {
    return _state == nullptr ? 1.0f : _state->preamp.load(std::memory_order_relaxed);
}

- (void)setPreamp:(float)preamp {
    if (_state == nullptr) {
        return;
    }
    _state->preamp.store(std::clamp(preamp, MinimumPreamp, MaximumPreamp), std::memory_order_relaxed);
}

- (BOOL)bypassed {
    return _state != nullptr && _state->bypassed.load(std::memory_order_relaxed);
}

- (void)setBypassed:(BOOL)bypassed {
    if (_state == nullptr) {
        return;
    }
    _state->bypassed.store(bypassed, std::memory_order_relaxed);
}

- (BOOL)equalizerEnabled {
    return _state != nullptr && _state->equalizerEnabled.load(std::memory_order_relaxed);
}

- (void)setEqualizerEnabled:(BOOL)equalizerEnabled {
    if (_state == nullptr) {
        return;
    }
    _state->equalizerEnabled.store(equalizerEnabled, std::memory_order_relaxed);
}

- (void)setBandGain:(float)gain atIndex:(NSInteger)index {
    if (_state == nullptr || index < 0) {
        return;
    }
    _state->setBandGain(gain, static_cast<size_t>(index));
}

- (float)bandGainAtIndex:(NSInteger)index {
    if (_state == nullptr || index < 0) {
        return 0.0f;
    }
    return _state->bandGain(static_cast<size_t>(index));
}

- (float)processSample:(float)input channelIndex:(NSUInteger)channelIndex {
    if (_state == nullptr) {
        return input;
    }
    return _state->process(input, channelIndex);
}

- (void)processInput:(const float *)input
              output:(float *)output
         sampleCount:(NSUInteger)sampleCount
        channelIndex:(NSUInteger)channelIndex {
    if (input == nullptr || output == nullptr) {
        return;
    }

    for (NSUInteger sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
        output[sampleIndex] = [self processSample:input[sampleIndex] channelIndex:channelIndex];
    }
}

- (void)reset {
    if (_state == nullptr) {
        return;
    }
    _state->reset();
}

@end
