//
//  CoreAudioLoopback.mm
//  EqualEase
//

#import "CoreAudioLoopback.h"
#import "EqualizerEngine.h"

#include <algorithm>

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
}

@synthesize deviceID = _deviceID;
@synthesize lastStartError = _lastStartError;
@synthesize running = _running;
@synthesize ioProcID = _ioProcID;

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _deviceID = kAudioObjectUnknown;
    _lastStartError = kAudioHardwareNoError;
    _running = false;
    _ioProcID = nullptr;
    _engine = [[EqualizerEngine alloc] initWithChannelCount:8 sampleRate:48000.0f];

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
}

@end

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
    const UInt32 bufferCount = std::min(inputBufferCount, outputBufferCount);

    for (UInt32 bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
        const AudioBuffer inputBuffer = inputData->mBuffers[bufferIndex];
        AudioBuffer outputBuffer = outputData->mBuffers[bufferIndex];
        if (inputBuffer.mData == nullptr || outputBuffer.mData == nullptr) {
            continue;
        }

        const UInt32 byteCount = std::min(inputBuffer.mDataByteSize, outputBuffer.mDataByteSize);
        const auto* input = static_cast<const Float32*>(inputBuffer.mData);
        auto* output = static_cast<Float32*>(outputBuffer.mData);
        const UInt32 sampleCount = byteCount / sizeof(Float32);

        for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
            output[sampleIndex] = [loopback processSample:input[sampleIndex] channelIndex:bufferIndex];
        }
    }

    return kAudioHardwareNoError;
}
