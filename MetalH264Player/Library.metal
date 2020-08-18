//
//  Library.metal
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 26.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#include <metal_stdlib>

using namespace metal;

struct InputVertex {
    float2 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct ProjectedVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ProjectedVertex vertex_shader(InputVertex input_vertex [[stage_in]])
{
    ProjectedVertex output;
    output.position = float4(input_vertex.position, 0, 1.0);
    output.uv = input_vertex.uv;
    return output;
}

constexpr sampler frame_sampler(coord::normalized, min_filter::linear, mag_filter::linear);

fragment half4 fragment_shader(ProjectedVertex input [[stage_in]],
                               texture2d<float, access::sample> luma_texture [[texture(0)]],
                               texture2d<float, access::sample> chroma_texture [[texture(1)]])
{
    float y = luma_texture.sample(frame_sampler, input.uv).r;
    float2 uv1 = chroma_texture.sample(frame_sampler, input.uv).rg;

    float u = uv1.x;
    float v = uv1.y;
    u = u - 0.5;
    v = v - 0.5;

    float r = y + 1.403 * v;
    float g = y - 0.344 * u - 0.714 * v;
    float b = y + 1.770 * u;

    return half4(float4(r, g, b, 1.0));
}
