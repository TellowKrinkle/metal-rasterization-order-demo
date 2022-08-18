// Based on https://github.com/cginternals/blog-demos/blob/screen-aligned-triangle-v1.0.0/screen-aligned-triangle/data/replay.frag

#include <metal_stdlib>
using namespace metal;

vertex float4 vs_fullscreen(uint vid [[vertex_id]]) {
	return float4(vid & 1 ? 3 : -1, vid & 2 ? 3 : -1, 0, 1);
}

vertex float4 vs(uint vid [[vertex_id]], device const float4* vertices [[buffer(0)]]) {
	return vertices[vid];
}

struct V2F {
	float4 pos [[position]];
	float2 tex;
};

vertex V2F vs_stretch(uint vid [[vertex_id]], device const float4* vertices [[buffer(0)]]) {
	float4 this_vertex = vertices[vid];
	return {float4(this_vertex.xy, 0, 1), this_vertex.zw};
}

fragment half4 fs_stretch(V2F in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
	constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
	return tex.sample(s, in.tex);
}

fragment float4 fs_record(device atomic_uint& atomic [[buffer(0)]]) {
	uint me = atomic_fetch_add_explicit(&atomic, 1, memory_order_relaxed);
	return float4(as_type<uchar4>(me)) / 255.f;
}

struct DepthOut {
	float depth [[depth(any)]];
};

fragment DepthOut fs_record_depth(device atomic_uint& atomic [[buffer(0)]]) {
	uint me = atomic_fetch_add_explicit(&atomic, 1, memory_order_relaxed);
	return {float(me) * 0x1p-32f};
}

float3 hsl2rgb(float3 hsl) // https://www.shadertoy.com/view/4sS3Dc
{
	float3 rgb = clamp(abs(fmod(hsl.x + float3(0, 4, 2), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return hsl.z + hsl.y * (rgb - 0.5) * (1.0 - abs(2.0 * hsl.z - 1.0));
}

float4 replay(uint idx, uint total, uint threshold) {
	float4 idx_unorm = float4(as_type<uchar4>(idx)) / 255.h;

	if (threshold < idx)
		return float4(0, 0, 0, 1);

	float3 hsl = float3(6.f * float(idx) / float(total), idx_unorm.r, idx_unorm.g);

	// highlight newest pixel and fade out highlighting over the last 250000 pixels
	float fence = smoothstep(0.0, 1.0, (threshold - idx) / 200000.f);

	float3 color = hsl2rgb(float3(
		hsl.r,                                 // hue - continuous, not influenced by fence highlighting
		mix(1.f, hsl.g, fence),                // saturation - restarts every 256 pixels
		mix(1.f, 0.05f + hsl.b * 0.85f, fence) // luminance - restarts every 65536 pixels, scale luminance to avoid extreme contrasts
	));

	return float4(color, 1.f);
}

fragment float4 fs_replay(float4 pos [[position]], texture2d<half> tex [[texture(0)]], constant uint& threshold [[buffer(0)]]) {
	uint idx = as_type<uint>(uchar4(tex.read(uint2(pos.xy)) * 255.5h));
	uint total = tex.get_width() * tex.get_height();
	return replay(idx, total, threshold);
}

fragment float4 fs_replay_depth(float4 pos [[position]], depth2d<float> tex [[texture(0)]], constant uint& threshold [[buffer(0)]]) {
	uint idx = uint(tex.read(uint2(pos.xy)) * 0x1p32f);
	uint total = tex.get_width() * tex.get_height();
	return replay(idx, total, threshold);
}
