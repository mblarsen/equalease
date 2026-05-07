//
//  CoreAudioLoopback.h
//  EqualEase
//

#ifndef CoreAudioLoopback_h
#define CoreAudioLoopback_h

#include <AppKit/AppKit.h>
#include <CoreAudio/CoreAudio.h>

/// A tiny Objective-C++ wrapper around an AudioDevice IOProc.
///
/// Swift should not own the real-time audio callback. This class copies
/// aggregate-device input to output while applying the current processing state.
@interface CoreAudioLoopback : NSObject

@property (readwrite, nonatomic) AudioObjectID deviceID;
@property (readonly, nonatomic) OSStatus lastStartError;
@property (readwrite, atomic) float outputGain;
@property (readwrite, atomic) float sampleRate;
@property (readwrite, atomic) BOOL bypassed;
@property (readwrite, atomic) BOOL equalizerEnabled;
@property (readonly, atomic) bool running;

- (void)setBandGain:(float)gain atIndex:(NSInteger)index;
- (BOOL)start;
- (void)stop;

@end

#endif /* CoreAudioLoopback_h */
