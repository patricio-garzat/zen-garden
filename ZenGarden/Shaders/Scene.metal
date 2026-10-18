// Scene.metal
// Rendering of the garden: table background, sand, wooden frame, stones and sand grains.
// All lighting is computed in linear space; the drawable is sRGB so the GPU encodes for us.

#include <metal_stdlib>
using namespace metal;

struct SceneUniforms {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4 cameraPos;
    float4 camRight;
    float4 camUp;
    float4 sunDir;
    float4 sunColor;
    float4 skyColor;
    float4 groundColor;
    float4 sandAlbedo;
    float4 bgTop;
    float4 bgBottom;
    float4 garden;   // halfW, halfL, frame width, frame height
    float4 params;   // normal strength, AO strength, stone count, time
    float4 hm;       // width, height, texel size, cavity scale
    float4 misc;     // glints, dark, grain strength, 0
};

struct StoneGPU {
    float4x4 model;
    float4 n0; float4 n1; float4 n2;
    float4 colorA; float4 colorB; float4 colorC;
    float4 material;  // flecks, moss, veins, seed
    float4 foot;      // world center.xy, radius.xy
    float4 rot;       // cos, sin, top height, lift
    float4 state;     // alpha, grounded, bottom z, 0
};

struct MeshVertex { float4 position; float4 normal; float4 uv; };
struct ParticleGPU { float4 posSize; float4 color; };

// ---------------------------------------------------------------------------------------------
// Noise helpers

static inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float hash31(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static inline float noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i), n100 = hash31(i + float3(1, 0, 0));
    float n010 = hash31(i + float3(0, 1, 0)), n110 = hash31(i + float3(1, 1, 0));
    float n001 = hash31(i + float3(0, 0, 1)), n101 = hash31(i + float3(1, 0, 1));
    float n011 = hash31(i + float3(0, 1, 1)), n111 = hash31(i + float3(1, 1, 1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

static inline float fbm3(float3 p) {
    return noise3(p) * 0.5 + noise3(p * 2.03 + 7.1) * 0.3 + noise3(p * 4.11 + 3.7) * 0.2;
}

static inline float3 ambient(constant SceneUniforms& U, float3 n) {
    return mix(U.groundColor.rgb, U.skyColor.rgb, saturate(n.z * 0.5 + 0.5));
}

// Soft elliptical stone shadows + contact occlusion on the sand/table at world point w.
static inline float2 stoneOcclusion(constant SceneUniforms& U, constant StoneGPU* stones, float2 w, float surfaceZ) {
    float sh = 1.0, contact = 1.0;
    int count = int(U.params.z);
    float3 L = U.sunDir.xyz;
    for (int i = 0; i < count; i++) {
        StoneGPU s = stones[i];
        float alpha = s.state.x;
        if (alpha <= 0.001) continue;
        float lift = s.rot.w;
        float2 c = s.foot.xy;
        float2 radii = s.foot.zw;
        // The shadow is cast from roughly half the stone's height (plus how high it is held).
        float castH = s.rot.z * 0.75 + lift - surfaceZ;
        float2 off = -L.xy / max(L.z, 0.2) * castH;
        float2 d = w - (c + off);
        float2 r = float2(d.x * s.rot.x + d.y * s.rot.y, -d.x * s.rot.y + d.y * s.rot.x);
        float spread = 1.0 + lift * 9.0;
        float e = length(r / (radii * spread));
        float soft = 0.22 + lift * 10.0;
        float strength = 0.85 / (1.0 + lift * 22.0);
        sh *= 1.0 - alpha * strength * (1.0 - smoothstep(1.0 - soft, 1.0 + soft * 0.35, e));

        // Contact occlusion: the sand right next to a resting stone is darker.
        float2 d2 = w - c;
        float2 r2 = float2(d2.x * s.rot.x + d2.y * s.rot.y, -d2.x * s.rot.y + d2.y * s.rot.x);
        float e2 = length(r2 / radii);
        float grounded = s.state.y;
        contact *= 1.0 - alpha * grounded * 0.42 * exp(-max(e2 - 0.92, 0.0) * 7.0) * step(0.6, e2);
    }
    return float2(sh, contact);
}

// ---------------------------------------------------------------------------------------------
// Background: the table the garden rests on, with the garden's own soft drop shadow.

struct BgOut { float4 position [[position]]; float2 ndc; };

vertex BgOut bgVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    BgOut o;
    o.position = float4(p, 0.9999, 1.0);
    o.ndc = p;
    return o;
}

fragment float4 bgFragment(BgOut in [[stage_in]], constant SceneUniforms& U [[buffer(0)]]) {
    float4 nearP = U.invViewProj * float4(in.ndc, 0.0, 1.0);
    float4 farP = U.invViewProj * float4(in.ndc, 1.0, 1.0);
    nearP /= nearP.w; farP /= farP.w;
    float3 dir = farP.xyz - nearP.xyz;
    float tableZ = -0.03;
    float t = (tableZ - nearP.z) / dir.z;
    float2 p = (nearP.xyz + dir * t).xy;

    float3 col = mix(U.bgBottom.rgb, U.bgTop.rgb, saturate(in.ndc.y * 0.5 + 0.5));
    // Very soft linen-like texture.
    col *= 0.985 + 0.03 * noise2(p * 140.0);

    // Drop shadow of the garden box (rounded rectangle SDF, offset away from the sun).
    float boxH = U.garden.w + 0.03;
    float2 off = -U.sunDir.xy / max(U.sunDir.z, 0.2) * boxH * 0.8;
    float2 ext = U.garden.xy + U.garden.z;
    float2 q = abs(p - off) - ext;
    float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float shadow = 1.0 - 0.38 * (1.0 - smoothstep(-0.03, 0.11, sd));
    // Tight contact shadow right at the base.
    float2 q2 = abs(p) - ext;
    float sd2 = length(max(q2, 0.0)) + min(max(q2.x, q2.y), 0.0);
    shadow *= 1.0 - 0.35 * (1.0 - smoothstep(0.0, 0.018, sd2));
    col *= shadow;

    // Gentle vignette.
    float v = length(in.ndc * float2(0.85, 0.6));
    col *= 1.0 - 0.10 * smoothstep(0.6, 1.4, v);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Sand

struct SandOut {
    float4 position [[position]];
    float3 world;
    float2 uv;
};

vertex SandOut sandVertex(uint vid [[vertex_id]], constant SceneUniforms& U [[buffer(0)]]) {
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 xy = c * U.garden.xy;
    SandOut o;
    o.position = U.viewProj * float4(xy, 0.0, 1.0);
    o.world = float3(xy, 0.0);
    o.uv = float2((xy.x + U.garden.x) / (2.0 * U.garden.x), (xy.y + U.garden.y) / (2.0 * U.garden.y));
    return o;
}

fragment float4 sandFragment(SandOut in [[stage_in]],
                             constant SceneUniforms& U [[buffer(0)]],
                             constant StoneGPU* stones [[buffer(1)]],
                             texture2d<half> surf [[texture(0)]],
                             texture2d<half> grain [[texture(1)]]) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    constexpr sampler gs(filter::linear, mip_filter::linear, address::repeat);

    float4 s = float4(surf.sample(ls, in.uv));
    float2 w = in.world.xy;
    float3 V = normalize(U.cameraPos.xyz - in.world);

    // Macro normal from the heightmap.
    float ns = U.params.x;
    float3 n = normalize(float3(-s.x * ns, -s.y * ns, 1.0));

    // Grain: a tiled noise texture at ~1 px per grain adds sparkle and texture without
    // putting any of that detail into the simulation.
    float4 g1 = float4(grain.sample(gs, w * 3.4));
    float4 g2 = float4(grain.sample(gs, w * 0.55 + 0.37));
    float gk = U.misc.z;
    n = normalize(n + float3((g1.xy - 0.5) * 0.42 * gk, 0.0));

    float3 L = U.sunDir.xyz;
    float ndl = saturate((dot(n, L) + 0.12) / 1.12);

    // Shadows from the frame's inner walls (the sun is low, so they are long and soft).
    float fh = U.garden.w;
    float2 swl = fh * abs(L.xy) / max(L.z, 0.2);
    float fromLeft = w.x + U.garden.x, fromRight = U.garden.x - w.x;
    float fromNear = w.y + U.garden.y, fromFar = U.garden.y - w.y;
    float fs = 1.0;
    fs *= smoothstep(swl.x * 0.55, swl.x * 1.25, L.x < 0.0 ? fromLeft : fromRight);
    fs *= smoothstep(swl.y * 0.55, swl.y * 1.25, L.y > 0.0 ? fromFar : fromNear);
    fs = mix(0.35, 1.0, fs);
    float edge = min(min(fromLeft, fromRight), min(fromNear, fromFar));
    float frameAO = 1.0 - 0.30 * exp(-edge / 0.010);

    float2 so = stoneOcclusion(U, stones, w, 0.0);

    float cavityAO = saturate(1.0 + s.z * U.params.y);
    float ao = cavityAO * frameAO * so.y;
    float direct = ndl * s.w * so.x * fs;

    float3 albedo = U.sandAlbedo.rgb * (0.92 + 0.15 * g1.z * gk + 0.075 * (1.0 - gk)) * (0.965 + 0.07 * g2.z);
    float3 col = albedo * (U.sunColor.rgb * direct + ambient(U, n) * ao);

    // Tiny quartz glints that catch the sun on the lit side of the ridges.
    float3 H = normalize(L + V);
    float glint = pow(saturate(dot(n, H)), 90.0) * step(0.982, g1.w) * direct * U.misc.x;
    col += U.sunColor.rgb * glint * 0.9;
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Wooden frame

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 uv;
};

vertex MeshOut frameVertex(uint vid [[vertex_id]],
                           const device MeshVertex* verts [[buffer(0)]],
                           constant SceneUniforms& U [[buffer(1)]]) {
    MeshVertex v = verts[vid];
    MeshOut o;
    o.position = U.viewProj * float4(v.position.xyz, 1.0);
    o.world = v.position.xyz;
    o.normal = v.normal.xyz;
    o.uv = v.uv;
    return o;
}

fragment float4 frameFragment(MeshOut in [[stage_in]],
                              constant SceneUniforms& U [[buffer(0)]],
                              constant StoneGPU* stones [[buffer(1)]]) {
    float along = in.uv.x, across = in.uv.y, seed = in.uv.z;
    // Growth rings stretched along the plank, with slow wobble and fine streaks.
    float wob = noise2(float2(along * 2.2, seed * 7.0)) * 1.6 + noise2(float2(along * 9.0, across * 20.0 + seed)) * 0.25;
    float rings = fract(across * 48.0 + wob + seed * 3.1);
    float ringMask = smoothstep(0.0, 0.18, rings) * (1.0 - smoothstep(0.45, 1.0, rings));
    float streak = noise2(float2(along * 60.0, across * 700.0 + seed * 13.0));
    float pores = noise2(float2(along * 300.0, across * 1600.0 + seed));

    float3 light = float3(0.43, 0.25, 0.125);
    float3 dark  = float3(0.20, 0.10, 0.045);
    float3 albedo = mix(dark, light, 0.35 + 0.65 * ringMask);
    albedo *= 0.86 + 0.22 * streak;
    albedo *= 0.94 + 0.06 * pores;
    // Weathered, slightly lighter top face.
    albedo *= 1.0 + 0.08 * saturate(in.normal.z);

    float3 n = normalize(in.normal);
    float3 V = normalize(U.cameraPos.xyz - in.world);
    float3 L = U.sunDir.xyz;
    float ndl = saturate((dot(n, L) + 0.1) / 1.1);
    float3 Hh = normalize(L + V);
    float spec = pow(saturate(dot(n, Hh)), 28.0) * 0.06;
    float2 so = stoneOcclusion(U, stones, in.world.xy, in.world.z);
    // Bottom of the outer wall meets the table: gentle occlusion.
    float baseAO = mix(0.55, 1.0, smoothstep(-0.03, 0.0, in.world.z));
    float3 col = albedo * (U.sunColor.rgb * ndl * so.x + ambient(U, n) * baseAO) + U.sunColor.rgb * spec * so.x;
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Stones

struct StoneOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 object;
};

vertex StoneOut stoneVertex(uint vid [[vertex_id]],
                            const device MeshVertex* verts [[buffer(0)]],
                            constant SceneUniforms& U [[buffer(1)]],
                            constant StoneGPU& S [[buffer(2)]]) {
    MeshVertex v = verts[vid];
    float4 world = S.model * float4(v.position.xyz, 1.0);
    float3x3 nm = float3x3(S.n0.xyz, S.n1.xyz, S.n2.xyz);
    StoneOut o;
    o.position = U.viewProj * world;
    o.world = world.xyz;
    o.normal = normalize(nm * v.normal.xyz);
    o.object = v.position.xyz;
    return o;
}

fragment float4 stoneFragment(StoneOut in [[stage_in]],
                              constant SceneUniforms& U [[buffer(0)]],
                              constant StoneGPU& S [[buffer(1)]]) {
    float seed = S.material.w;
    float3 po = in.object * 14.0 + seed * 3.17;
    float n1 = fbm3(po * 0.9);
    float n2 = noise3(po * 4.0);
    
    float3 albedo = mix(S.colorA.rgb, S.colorB.rgb, smoothstep(0.25, 0.75, n1));
    albedo *= 0.9 + 0.2 * n2;
    // Mineral flecks (granite), veins (quartz) and moss on the top.
    float fl2 = noise3(po * 22.0 + 5.0);
    float fleck = smoothstep(1.0 - S.material.x * 0.16, 1.03 - S.material.x * 0.16, fl2);
    albedo = mix(albedo, S.colorC.rgb, fleck * 0.55 * step(0.01, S.material.x));
    float vein = pow(1.0 - abs(sin((in.object.x * 40.0 + in.object.z * 95.0 + n1 * 5.0) * 1.7)), 14.0);
    albedo = mix(albedo, S.colorC.rgb, vein * S.material.z * 0.8);

    float3 n = normalize(in.normal);
    // Micro relief from noise: bumps the normal so the surface reads as rock, not plastic.
    float3 bump = float3(noise3(po * 6.0) - 0.5, noise3(po * 6.0 + 19.0) - 0.5, 0.0) * 0.35;
    n = normalize(n + bump);

    // Moss grows in patches on the top, never all over.
    float patch = smoothstep(0.48, 0.62, fbm3(po * 0.55 + 9.0) + (n2 - 0.5) * 0.25);
    float moss = S.material.y * smoothstep(0.72, 0.92, n.z) * patch;
    albedo = mix(albedo, float3(0.075, 0.12, 0.035) * (0.8 + 0.4 * n2), moss);

    float3 V = normalize(U.cameraPos.xyz - in.world);
    float3 L = U.sunDir.xyz;
    float ndl = saturate((dot(n, L) + 0.08) / 1.08);
    float3 Hh = normalize(L + V);
    float spec = pow(saturate(dot(n, Hh)), 36.0) * 0.10 * (1.0 - moss);

    // The part of the stone that sits in the sand is occluded.
    float height = max(S.rot.z, 0.01);
    float lifted = S.rot.w;
    float hz = in.world.z - lifted;
    float baseAO = mix(0.5, 1.0, smoothstep(-0.002, height * 0.35, hz));
    baseAO = mix(baseAO, 1.0, saturate(lifted * 40.0));

    float3 col = albedo * (U.sunColor.rgb * ndl + ambient(U, n) * baseAO) + U.sunColor.rgb * spec;
    return float4(col, S.state.x);
}

// ---------------------------------------------------------------------------------------------
// Sand grains kicked up by the rake (instanced camera-facing discs)

struct GrainOut {
    float4 position [[position]];
    float2 local;
    float4 color;
};

vertex GrainOut grainVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device ParticleGPU* parts [[buffer(0)]],
                            constant SceneUniforms& U [[buffer(1)]]) {
    ParticleGPU p = parts[iid];
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float3 world = p.posSize.xyz + (U.camRight.xyz * c.x + U.camUp.xyz * c.y) * p.posSize.w;
    GrainOut o;
    o.position = U.viewProj * float4(world, 1.0);
    o.local = c;
    o.color = p.color;
    return o;
}

fragment float4 grainFragment(GrainOut in [[stage_in]], constant SceneUniforms& U [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float a = 1.0 - smoothstep(0.55, 1.0, r);
    // Lit from the sun side so a grain reads as a tiny sphere.
    float lit = 0.75 + 0.35 * dot(in.local, normalize(float2(U.sunDir.x, U.sunDir.y)));
    float3 col = in.color.rgb * (U.sunColor.rgb * 0.8 + ambient(U, float3(0, 0, 1))) * lit;
    return float4(col, a * in.color.a);
}
