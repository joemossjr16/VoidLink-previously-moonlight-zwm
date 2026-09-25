//
//  PresentPyroWavePlanes.metal
//  VoidLink
//
//  Converts the three planes PyroWave's Metal decoder writes (Y, Cb, Cr, each
//  a normalized single-channel r16Unorm texture per pyrowave_metal.h) into the
//  drawable's RGBA, using BT.709 limited-range coefficients -- matching what
//  the Vibepollo host's PyroWave encoder path actually produces (see the
//  Android/Qt PyroWave clients, which do the same conversion).
//

#include <metal_stdlib>
using namespace metal;

struct PresentParams {
    uint chroma444;
};

kernel void presentPyroWavePlanes(texture2d<float, access::read> planeY [[texture(0)]],
                                   texture2d<float, access::read> planeCb [[texture(1)]],
                                   texture2d<float, access::read> planeCr [[texture(2)]],
                                   texture2d<float, access::write> outTexture [[texture(3)]],
                                   constant PresentParams &params [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }

    const uint2 chromaCoord = params.chroma444 != 0 ? gid : (gid / 2);

    const float y = planeY.read(gid).r;
    const float cb = planeCb.read(chromaCoord).r;
    const float cr = planeCr.read(chromaCoord).r;

    // BT.709 limited range (matches the host's convert_yuv*_ps shaders):
    // luma [16/255, 235/255], chroma centered at 128/255 over [16/255, 240/255].
    const float yNorm = (y * 255.0 - 16.0) / 219.0;
    const float cbNorm = (cb * 255.0 - 128.0) / 224.0;
    const float crNorm = (cr * 255.0 - 128.0) / 224.0;

    const float r = yNorm + 1.5748 * crNorm;
    const float g = yNorm - 0.1873 * cbNorm - 0.4681 * crNorm;
    const float b = yNorm + 1.8556 * cbNorm;

    outTexture.write(float4(saturate(r), saturate(g), saturate(b), 1.0), gid);
}
