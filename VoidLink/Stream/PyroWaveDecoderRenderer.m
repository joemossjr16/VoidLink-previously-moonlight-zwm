//
//  PyroWaveDecoderRenderer.m
//  VoidLink
//
//  See PyroWaveDecoderRenderer.h. Decodes and presents PyroWave frames without
//  going through VideoToolbox: PyroWave's own Metal compute shaders (via
//  pyrowave_metal.h) write directly into three single-channel plane textures,
//  which a small render pass here converts (BT.709 limited range, matching the
//  host's PyroWave encoder) and presents to the given CAMetalLayer.
//
//  UNTESTED: written without access to a Mac/Xcode. Expect this to need real
//  build iteration (see docs/pyrowave-ios-plan.md) before it runs correctly.
//

#import "PyroWaveDecoderRenderer.h"
#import "Log.h"

#include "pyrowave_metal.h"

// PYRW v1 frame container (matches the Vibepollo host's video::pyrowave::make_frame_payload):
//   "PYRW", u8 version(1), be_u16 packet_count, u8 reserved,
//   then packet_count * { be_u32 length, bytes }.
static const uint8_t kPyrwMagic[4] = {'P', 'Y', 'R', 'W'};

@implementation PyroWaveDecoderRenderer {
    id<MTLDevice> _mtlDevice;
    id<MTLCommandQueue> _commandQueue;
    CAMetalLayer *_layer;
    __weak id<ConnectionCallbacks> _callbacks;

    pyrowave_device _device;
    pyrowave_decoder _decoder;
    int _width;
    int _height;
    BOOL _chroma444;

    id<MTLTexture> _planeY;
    id<MTLTexture> _planeCb;
    id<MTLTexture> _planeCr;

    id<MTLComputePipelineState> _presentPipeline;
    id<MTLLibrary> _shaderLibrary;

    BOOL _sawFirstFrame;
}

+ (BOOL)isSupported {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return NO;
    }
    // (__bridge void *) per pyrowave_metal.h's ARC bridging note: PyroWave does
    // not take ownership here, this call just inspects the device.
    return pyrowave_device_is_supported((__bridge pyrowave_mtl_device)device);
}

- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer
                              callbacks:(id<ConnectionCallbacks>)callbacks {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _layer = layer;
    _callbacks = callbacks;
    _mtlDevice = MTLCreateSystemDefaultDevice();
    if (_mtlDevice == nil) {
        Log(LOG_E, @"PyroWave: no Metal device available");
        return nil;
    }
    _layer.device = _mtlDevice;
    _commandQueue = [_mtlDevice newCommandQueue];
    if (_commandQueue == nil) {
        Log(LOG_E, @"PyroWave: failed to create a Metal command queue");
        return nil;
    }

    pyrowave_device_create_info deviceInfo = {0};
    deviceInfo.mtl_device = (__bridge pyrowave_mtl_device)_mtlDevice;
    if (pyrowave_device_create(&deviceInfo, &_device) != PYROWAVE_SUCCESS) {
        Log(LOG_E, @"PyroWave: failed to create the PyroWave Metal device");
        return nil;
    }

    NSError *shaderError = nil;
    // Requires VoidLink/Metal/PresentPyroWavePlanes.metal to be added to the
    // app target's Xcode "Compile Sources" build phase (not yet wired --
    // see docs/pyrowave-ios-plan.md) so it lands in the default Metal library.
    _shaderLibrary = [_mtlDevice newDefaultLibrary];
    id<MTLFunction> presentFn = [_shaderLibrary newFunctionWithName:@"presentPyroWavePlanes"];
    if (presentFn == nil) {
        Log(LOG_E, @"PyroWave: presentPyroWavePlanes compute function not found in the default Metal library");
        return nil;
    }
    _presentPipeline = [_mtlDevice newComputePipelineStateWithFunction:presentFn error:&shaderError];
    if (_presentPipeline == nil) {
        Log(LOG_E, @"PyroWave: failed to create the present pipeline: %@", shaderError);
        return nil;
    }

    return self;
}

- (BOOL)setupWithWidth:(int)width height:(int)height chroma444:(BOOL)chroma444 {
    if (width <= 0 || height <= 0 || (!chroma444 && ((width & 1) || (height & 1)))) {
        Log(LOG_E, @"PyroWave requires positive stream dimensions (even for 4:2:0)");
        return NO;
    }

    _width = width;
    _height = height;
    _chroma444 = chroma444;

    pyrowave_decoder_create_info decoderInfo = {0};
    decoderInfo.device = _device;
    decoderInfo.width = width;
    decoderInfo.height = height;
    decoderInfo.chroma = chroma444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
    if (pyrowave_decoder_create(&decoderInfo, &_decoder) != PYROWAVE_SUCCESS) {
        Log(LOG_E, @"PyroWave: failed to create the decoder for %dx%d", width, height);
        return NO;
    }

    const int chromaWidth = chroma444 ? width : width / 2;
    const int chromaHeight = chroma444 ? height : height / 2;

    MTLTextureDescriptor *lumaDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    lumaDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    lumaDesc.storageMode = MTLStorageModePrivate;
    _planeY = [_mtlDevice newTextureWithDescriptor:lumaDesc];

    MTLTextureDescriptor *chromaDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                                                                            width:chromaWidth
                                                                                           height:chromaHeight
                                                                                        mipmapped:NO];
    chromaDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    chromaDesc.storageMode = MTLStorageModePrivate;
    _planeCb = [_mtlDevice newTextureWithDescriptor:chromaDesc];
    _planeCr = [_mtlDevice newTextureWithDescriptor:chromaDesc];

    if (_planeY == nil || _planeCb == nil || _planeCr == nil) {
        Log(LOG_E, @"PyroWave: failed to allocate plane textures");
        return NO;
    }

    _layer.drawableSize = CGSizeMake(width, height);
    _sawFirstFrame = NO;

    Log(LOG_I, @"PyroWave decoder ready for %dx%d %@ (Metal)", width, height, chroma444 ? @"4:4:4" : @"4:2:0");
    return YES;
}

- (int)submitDecodeBuffer:(unsigned char *)data
                    length:(int)length
                bufferType:(int)bufferType
                decodeUnit:(PDECODE_UNIT)du
           decodeStartTime:(CFTimeInterval)decodeStartTime {
    (void)bufferType;
    (void)du;
    (void)decodeStartTime;

    if (length < 8 || memcmp(data, kPyrwMagic, sizeof(kPyrwMagic)) != 0) {
        Log(LOG_W, @"PyroWave: dropping a frame with a malformed PYRW header");
        free(data);
        return DR_OK;
    }

    const uint8_t version = data[4];
    if (version != 1) {
        Log(LOG_W, @"PyroWave: unsupported PYRW container version %u", version);
        free(data);
        return DR_OK;
    }

    const uint16_t packetCount = ((uint16_t)data[5] << 8) | (uint16_t)data[6];
    // data[7] is reserved.
    size_t offset = 8;
    pyrowave_decoder_clear(_decoder);

    for (uint16_t i = 0; i < packetCount; i++) {
        if (offset + 4 > (size_t)length) {
            Log(LOG_W, @"PyroWave: truncated PYRW packet header");
            break;
        }
        const uint32_t packetLength = ((uint32_t)data[offset] << 24) | ((uint32_t)data[offset + 1] << 16) |
                                       ((uint32_t)data[offset + 2] << 8) | (uint32_t)data[offset + 3];
        offset += 4;
        if (offset + packetLength > (size_t)length) {
            Log(LOG_W, @"PyroWave: truncated PYRW packet body");
            break;
        }

        const pyrowave_result pushResult = pyrowave_decoder_push_packet(_decoder, data + offset, packetLength);
        if (pushResult != PYROWAVE_SUCCESS) {
            Log(LOG_W, @"PyroWave: push_packet failed: %s", pyrowave_result_to_string(pushResult));
        }
        offset += packetLength;
    }

    free(data);

    // Every PyroWave frame is flagged IDR by the host; there is nothing to wait
    // for beyond this frame's own packets, unlike a reference-frame codec.
    if (!pyrowave_decoder_decode_is_ready(_decoder, /* allow_partial_frame */ true)) {
        return DR_OK;
    }

    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (drawable == nil) {
        return DR_OK;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];

    pyrowave_gpu_buffers buffers = {0};
    buffers.planes[0] = (__bridge pyrowave_mtl_texture)_planeY;
    buffers.planes[1] = (__bridge pyrowave_mtl_texture)_planeCb;
    buffers.planes[2] = (__bridge pyrowave_mtl_texture)_planeCr;

    const pyrowave_result decodeResult = pyrowave_decoder_decode_gpu_buffer(
        _decoder, (__bridge pyrowave_mtl_command_buffer)commandBuffer, &buffers);
    if (decodeResult != PYROWAVE_SUCCESS) {
        Log(LOG_W, @"PyroWave: decode_gpu_buffer failed: %s", pyrowave_result_to_string(decodeResult));
        return DR_OK;
    }

    // BT.709 limited-range YCbCr -> the drawable's RGBA, same conversion the
    // Android/Qt PyroWave clients use, matching what the host actually encoded.
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:_presentPipeline];
    [encoder setTexture:_planeY atIndex:0];
    [encoder setTexture:_planeCb atIndex:1];
    [encoder setTexture:_planeCr atIndex:2];
    [encoder setTexture:drawable.texture atIndex:3];
    struct {
        uint32_t chroma444;
    } params = {(uint32_t)(_chroma444 ? 1 : 0)};
    [encoder setBytes:&params length:sizeof(params) atIndex:0];

    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadgroups = MTLSizeMake((_width + 15) / 16, (_height + 15) / 16, 1);
    [encoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    if (!_sawFirstFrame) {
        _sawFirstFrame = YES;
        Log(LOG_I, @"PyroWave: presented the first frame");
    }

    return DR_OK;
}

- (void)cleanup {
    if (_decoder) {
        pyrowave_decoder_destroy(_decoder);
        _decoder = NULL;
    }
    if (_device) {
        pyrowave_device_destroy(_device);
        _device = NULL;
    }
    _planeY = nil;
    _planeCb = nil;
    _planeCr = nil;
}

- (void)dealloc {
    [self cleanup];
}

@end
