//
//  PyroWaveDecoderRenderer.h
//  VoidLink
//
//  PyroWave (Vibepollo extension) decode + presentation via the native Metal
//  backend (pyrowave_metal.h). Decode does not go through VideoToolbox/
//  AVSampleBufferDisplayLayer at all -- PyroWave decodes on the GPU with its
//  own compute shaders, so this class owns its own Metal device, command
//  queue and CAMetalLayer presentation instead of sharing VideoDecoderRenderer's
//  VideoToolbox-oriented pipeline.
//

@import Metal;
@import QuartzCore.CAMetalLayer;

#import "ConnectionCallbacks.h"
#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

@interface PyroWaveDecoderRenderer : NSObject

// Whether this device's default Metal device can run the PyroWave decoder
// (Apple7 GPU family and up; Intel/AMD Macs are not supported).
+ (BOOL)isSupported;

- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer
                              callbacks:(id<ConnectionCallbacks>)callbacks;

// chroma444: full-resolution chroma (Moonlight VIDEO_FORMAT_PYROWAVE_444) vs.
// 4:2:0 (VIDEO_FORMAT_PYROWAVE).
- (BOOL)setupWithWidth:(int)width height:(int)height chroma444:(BOOL)chroma444;

// Matches VideoDecoderRenderer's submitDecodeBuffer contract so the two can be
// selected interchangeably based on the negotiated video format.
- (int)submitDecodeBuffer:(unsigned char *)data
                    length:(int)length
                bufferType:(int)bufferType
                decodeUnit:(PDECODE_UNIT)du
           decodeStartTime:(CFTimeInterval)decodeStartTime;

- (void)cleanup;

@end

NS_ASSUME_NONNULL_END
