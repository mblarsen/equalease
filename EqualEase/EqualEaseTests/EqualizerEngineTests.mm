//
//  EqualizerEngineTests.mm
//  EqualEaseTests
//

#import <XCTest/XCTest.h>
#import "../EqualEase/Audio/EqualizerEngine.h"

#include <cmath>

@interface EqualizerEngineTests : XCTestCase
@end

@implementation EqualizerEngineTests

- (void)testBypassReturnsInputUnchanged {
    EqualizerEngine *engine = [[EqualizerEngine alloc] initWithChannelCount:2 sampleRate:48000.0f];
    engine.bypassed = YES;
    engine.equalizerEnabled = YES;
    engine.preamp = 2.0f;
    [engine setBandGain:12.0f atIndex:5];

    const float input[] = { -1.5f, -0.75f, -0.1f, 0.0f, 0.25f, 0.9f, 1.4f };
    float output[sizeof(input) / sizeof(float)] = { 0.0f };

    [engine processInput:input output:output sampleCount:sizeof(input) / sizeof(float) channelIndex:0];

    for (NSUInteger index = 0; index < sizeof(input) / sizeof(float); ++index) {
        XCTAssertEqual(output[index], input[index], @"Bypass should copy input sample %lu unchanged", (unsigned long)index);
    }
}

- (void)testFlatEQWithUnityPreampPreservesInputWithinTolerance {
    EqualizerEngine *engine = [[EqualizerEngine alloc] initWithChannelCount:2 sampleRate:48000.0f];
    engine.equalizerEnabled = YES;
    engine.preamp = 1.0f;

    const float input[] = { -0.75f, -0.5f, -0.125f, 0.0f, 0.125f, 0.5f, 0.75f };
    float output[sizeof(input) / sizeof(float)] = { 0.0f };

    [engine processInput:input output:output sampleCount:sizeof(input) / sizeof(float) channelIndex:0];

    for (NSUInteger index = 0; index < sizeof(input) / sizeof(float); ++index) {
        XCTAssertEqualWithAccuracy(output[index], input[index], 0.000001f, @"Flat EQ should preserve sample %lu", (unsigned long)index);
    }
}

- (void)testPreampClampsToSafeRange {
    EqualizerEngine *engine = [[EqualizerEngine alloc] initWithChannelCount:1 sampleRate:48000.0f];

    engine.preamp = -1.0f;
    XCTAssertEqualWithAccuracy(engine.preamp, 0.0f, 0.000001f);
    XCTAssertEqualWithAccuracy([engine processSample:0.5f channelIndex:0], 0.0f, 0.000001f);

    engine.preamp = 3.5f;
    XCTAssertEqualWithAccuracy(engine.preamp, 2.0f, 0.000001f);
    XCTAssertEqualWithAccuracy([engine processSample:0.25f channelIndex:0], 0.5f, 0.000001f);
}

- (void)testOutputSamplesStayWithinUnitRange {
    EqualizerEngine *engine = [[EqualizerEngine alloc] initWithChannelCount:1 sampleRate:48000.0f];
    engine.preamp = 2.0f;

    const float input[] = { -0.9f, -0.6f, 0.0f, 0.6f, 0.9f };
    float output[sizeof(input) / sizeof(float)] = { 0.0f };

    [engine processInput:input output:output sampleCount:sizeof(input) / sizeof(float) channelIndex:0];

    for (NSUInteger index = 0; index < sizeof(input) / sizeof(float); ++index) {
        XCTAssertGreaterThanOrEqual(output[index], -1.0f);
        XCTAssertLessThanOrEqual(output[index], 1.0f);
    }
    XCTAssertEqualWithAccuracy(output[0], -1.0f, 0.000001f);
    XCTAssertEqualWithAccuracy(output[4], 1.0f, 0.000001f);
}

- (void)testBandGainsClampToSafeRange {
    EqualizerEngine *engine = [[EqualizerEngine alloc] initWithChannelCount:1 sampleRate:48000.0f];

    [engine setBandGain:-30.0f atIndex:0];
    [engine setBandGain:30.0f atIndex:9];

    XCTAssertEqualWithAccuracy([engine bandGainAtIndex:0], -12.0f, 0.000001f);
    XCTAssertEqualWithAccuracy([engine bandGainAtIndex:9], 12.0f, 0.000001f);
}

- (void)testNonFlatPresetChangesDeterministicBuffer {
    EqualizerEngine *engine = [[EqualizerEngine alloc] initWithChannelCount:1 sampleRate:48000.0f];
    engine.equalizerEnabled = YES;
    engine.preamp = 1.0f;
    [engine setBandGain:6.0f atIndex:5];

    constexpr NSUInteger sampleCount = 256;
    float input[sampleCount] = { 0.0f };
    float output[sampleCount] = { 0.0f };
    constexpr float sampleRate = 48000.0f;
    constexpr float toneFrequency = 1000.0f;
    constexpr float pi = 3.14159265358979323846f;

    for (NSUInteger index = 0; index < sampleCount; ++index) {
        input[index] = 0.2f * sinf(2.0f * pi * toneFrequency * static_cast<float>(index) / sampleRate);
    }

    [engine processInput:input output:output sampleCount:sampleCount channelIndex:0];

    BOOL foundDifference = NO;
    for (NSUInteger index = 0; index < sampleCount; ++index) {
        if (fabsf(output[index] - input[index]) > 0.00001f) {
            foundDifference = YES;
            break;
        }
    }

    XCTAssertTrue(foundDifference, @"A non-flat 10-band EQ should alter a deterministic in-band tone.");
}

@end
