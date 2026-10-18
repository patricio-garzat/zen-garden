// SandCompute.metal
// GPU side of the sand engine.
//
// The sand is a single-channel heightmap (r32Float, world units, 0 = perfectly flat).
// Tools never "paint": every rake stamp reshapes the height toward the profile a real rake
// leaves (grooves + ridges of displaced sand), so crossing an old pattern erases it the way
// sand does. A second pass derives a small "surface" texture (slopes, cavity and self-shadow)
// that the fragment shader samples once per pixel, which keeps the per-pixel cost tiny.

#include <metal_stdlib>
using namespace metal;

struct Stamp { float4 a; float4 b; float4 c; };
struct StampBatch { uint count; uint originX; uint originY; uint stoneCount; uint sizeX; uint sizeY; uint pad0; uint pad1; };
struct Footprint { float4 a; float4 b; };
struct DeriveParams { int4 rect; float4 light; float4 misc; };
struct SweepParams { float4 a; uint4 b; };
struct GridParams { uint4 rect; float4 v; };

constant float TAU = 6.2831853;

// ---------------------------------------------------------------------------------------------
// Noise

static inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// The resting surface of untouched sand: tiny irregular undulations (a few hundredths of a mm).
static inline float microRelief(float2 p) {
    return (valueNoise(p * 0.45) - 0.5) * 0.00010 + (valueNoise(p * 0.11 + 31.7) - 0.5) * 0.00014;
}

/// 1 on open sand, 0 under a resting stone (the rake goes around stones, it never digs below them).
static inline float stoneMask(float2 p, constant Footprint* fp, uint n) {
    float m = 1.0;
    for (uint i = 0; i < n; i++) {
        float2 d = p - fp[i].a.xy;
        float2 r = float2(d.x * fp[i].b.x + d.y * fp[i].b.y, -d.x * fp[i].b.y + d.y * fp[i].b.x);
        float e = length(r / max(fp[i].a.zw, float2(1.0)));
        m = min(m, smoothstep(0.80, 0.97, e));
    }
    return m;
}

static inline float readH(texture2d<float, access::read> t, int2 q, int2 mx) {
    return t.read(uint2(clamp(q, int2(0), mx))).r;
}

static inline float readBilinear(texture2d<float, access::read> t, float2 p, int2 mx) {
    float2 q = p - 0.5;
    float2 fl = floor(q);
    int2 i = int2(fl);
    float2 f = q - fl;
    float a = readH(t, i, mx), b = readH(t, i + int2(1, 0), mx);
    float c = readH(t, i + int2(0, 1), mx), d = readH(t, i + int2(1, 1), mx);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// ---------------------------------------------------------------------------------------------
// Initialization

kernel void initSand(texture2d<float, access::write> hmap [[texture(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= hmap.get_width() || gid.y >= hmap.get_height()) return;
    hmap.write(float4(microRelief(float2(gid) + 0.5)), gid);
}

// ---------------------------------------------------------------------------------------------
// Tool stamps
//
// One thread per texel inside the batch's bounding box. Each thread walks the stamps in
// order, so overlapping stamps compose exactly like sequential strokes would, with no
// cross-thread hazards (a texel only ever depends on itself).

kernel void applyStamps(texture2d<float, access::read_write> hmap [[texture(0)]],
                        constant Stamp* stamps [[buffer(0)]],
                        constant StampBatch& batch [[buffer(1)]],
                        constant Footprint* fps [[buffer(2)]],
                        uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= batch.sizeX || tid.y >= batch.sizeY) return;
    uint2 gid = tid + uint2(batch.originX, batch.originY);
    if (gid.x >= hmap.get_width() || gid.y >= hmap.get_height()) return;

    float2 p = float2(gid) + 0.5;
    float h = hmap.read(gid).r;
    float mask = stoneMask(p, fps, batch.stoneCount);

    for (uint i = 0; i < batch.count; i++) {
        Stamp s = stamps[i];
        int kind = int(s.c.x + 0.5);
        float2 v = p - s.a.xy;

        if (kind == 0) {
            // ---- Rake: tines across the head, perpendicular to the motion.
            float W = s.b.x;
            float spacing = s.b.y;
            float2 dir = s.a.zw;
            float2 nrm = float2(-dir.y, dir.x);
            float along = dot(v, dir);
            float u = dot(v, nrm);
            float A = s.c.y;
            if (abs(along) > A + 1.0 || abs(u) > W + 2.0) continue;

            float wA = 1.0 - smoothstep(A * 0.5, A + 1.0, abs(along));
            float feather = max(1.5, spacing * 0.3);
            float wU = 1.0 - smoothstep(W - feather, W + feather * 0.5, abs(u));

            // Tines sit at the half-way points; ridges of pushed sand form between them and
            // at the outer edges of the rake.
            float x = (u + W) / spacing;
            float prof = cos(TAU * x);
            // Rounded crests, slightly crisper troughs: reads as packed sand, not a sine wave.
            prof = prof > 0.0 ? pow(prof, 0.85) : -pow(-prof, 1.2);
            // Natural irregularity along the stroke, so ridges never look machine made.
            float irr = 1.0 + (valueNoise(p * 0.07 + s.c.z) - 0.5) * 0.28;
            float target = s.b.z * prof * irr + microRelief(p);
            h = mix(h, target, s.b.w * wA * wU * mask);

        } else if (kind == 1) {
            // ---- Smoother: a soft round board that relaxes the sand toward flat.
            float r = length(v);
            float R = s.b.x;
            if (r > R) continue;
            float w = 1.0 - smoothstep(R * 0.45, R, r);
            h = mix(h, microRelief(p), s.b.w * w * mask);

        } else if (kind == 2) {
            // ---- Stone landing: a little sand pushed out into a soft rim, pressed sand below.
            float2 rr = float2(v.x * s.c.z + v.y * s.c.w, -v.x * s.c.w + v.y * s.c.z);
            float2 radii = max(s.b.xy, float2(1.0));
            float e = length(rr / radii);
            float R = max(radii.x, radii.y);
            float dist = (e - 1.0) * R;                 // texels outside the contact edge
            float rimW = max(s.b.w, 1.5);
            float rim = exp(-pow((dist - rimW * 0.35) / rimW, 2.0));
            if (e < 0.92) h = min(h, -s.b.z * 0.35);
            // Only near the rim: sand piles up on top of whatever pattern is there.
            float rimH = s.b.z * rim + microRelief(p);
            h = mix(h, max(h, rimH), saturate(rim * 2.5));

        } else if (kind == 3) {
            // ---- Concentric ripples, growing outward (around a stone or a single touch).
            float d = length(v);
            float r0 = s.b.x;
            float spacing = s.b.y;
            float R = s.c.y;
            float Rmax = r0 + s.c.z * spacing;
            if (d > R + 2.0 || d > Rmax + spacing) continue;
            float x = (d - r0) / spacing;
            float prof = cos(TAU * x);
            prof = prof > 0.0 ? pow(prof, 0.85) : -pow(-prof, 1.2);
            float wIn = r0 < spacing ? 1.0 : smoothstep(r0 - spacing * 0.6, r0 - spacing * 0.1, d);
            float wOut = 1.0 - smoothstep(R - 2.0, R + 1.0, d);
            float wEnd = 1.0 - smoothstep(Rmax - spacing * 0.25, Rmax + spacing * 0.3, d);
            float target = s.b.z * prof + microRelief(p);
            h = mix(h, target, s.b.w * wIn * wOut * wEnd * mask);
        }
    }
    hmap.write(float4(h), gid);
}

// ---------------------------------------------------------------------------------------------
// Surface derivation (only for the dirty rectangle)
//
// Output (rgba16Float):
//   r, g  slope of the sand (dh/dx, dh/dy)            → normals in the fragment shader
//   b     cavity (height minus local average) * scale → soft ambient occlusion in grooves
//   a     direct-light visibility (0 = in shadow)     → the delicate shadows inside the furrows

kernel void deriveSurface(texture2d<float, access::read> hmap [[texture(0)]],
                          texture2d<half, access::write> surf [[texture(1)]],
                          constant DeriveParams& P [[buffer(0)]],
                          uint2 tid [[thread_position_in_grid]]) {
    if (int(tid.x) >= P.rect.z || int(tid.y) >= P.rect.w) return;
    int2 g = int2(tid) + P.rect.xy;
    int2 mx = int2(hmap.get_width() - 1, hmap.get_height() - 1);
    if (g.x > mx.x || g.y > mx.y) return;

    float tw = P.misc.x;
    float hc = readH(hmap, g, mx);
    float dx = (readH(hmap, g + int2(1, 0), mx) - readH(hmap, g - int2(1, 0), mx)) / (2.0 * tw);
    float dy = (readH(hmap, g + int2(0, 1), mx) - readH(hmap, g - int2(0, 1), mx)) / (2.0 * tw);

    // Cavity: compare with a ring of neighbours four texels away.
    float ring = 0.0;
    for (int k = 0; k < 8; k++) {
        float a = float(k) * (TAU / 8.0);
        ring += readH(hmap, g + int2(round(float2(cos(a), sin(a)) * 4.0)), mx);
    }
    float cavity = hc - ring / 8.0;

    // Self shadow: march toward the sun through the heightfield.
    float vis = 1.0;
    int steps = int(P.light.w);
    if (steps > 0) {
        float2 ld = normalize(P.light.xy);
        float rise = P.light.z / max(length(P.light.xy), 1e-3) * tw;    // world height per texel
        float2 pc = float2(g) + 0.5;
        float occl = 0.0;
        for (int k = 1; k <= steps; k++) {
            float t = float(k);
            float hs = readBilinear(hmap, pc + ld * t, mx);
            float ray = hc + t * rise;
            // Penumbra widens with distance, like a real sun disc.
            occl = max(occl, (hs - ray) / (0.00012 + 0.00006 * t));
        }
        vis = 1.0 - saturate(occl);
    }
    surf.write(half4(half(dx), half(dy), half(cavity * P.misc.y), half(vis)), uint2(g));
}

// ---------------------------------------------------------------------------------------------
// Copies (undo snapshots are stored as half floats to halve their memory)

kernel void copyToHalf(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<half, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(half4(half(src.read(gid).r)), gid);
}

kernel void copyFromHalf(texture2d<half, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(float(src.read(gid).r)), gid);
}

kernel void resampleHalf(texture2d<half, access::sample> src [[texture(0)]],
                         texture2d<half, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(src.sample(s, uv), gid);
}

kernel void uploadHalf(device const half* src [[buffer(0)]],
                       constant GridParams& G [[buffer(1)]],
                       texture2d<half, access::write> dst [[texture(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= G.rect.z || gid.y >= G.rect.w) return;
    dst.write(half4(src[gid.y * G.rect.z + gid.x]), gid);
}

kernel void downloadHalf(texture2d<float, access::read> src [[texture(0)]],
                         device half* dst [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint w = src.get_width();
    if (gid.x >= w || gid.y >= src.get_height()) return;
    dst[gid.y * w + gid.x] = half(src.read(gid).r);
}

// ---------------------------------------------------------------------------------------------
// "Smooth the whole garden": a wide board travels from the far edge to the near edge.
// Behind it the sand is flat; just ahead of it rides a soft ridge of collected sand.
// Reads the snapshot taken when the sweep started, so it is stateless frame to frame.

kernel void sweepSmooth(texture2d<half, access::read> snap [[texture(0)]],
                        texture2d<float, access::write> hmap [[texture(1)]],
                        constant SweepParams& S [[buffer(0)]],
                        constant Footprint* fps [[buffer(1)]],
                        uint2 tid [[thread_position_in_grid]]) {
    uint2 gid = uint2(tid.x, tid.y + S.b.x);
    if (gid.x >= hmap.get_width() || gid.y >= hmap.get_height() || tid.y >= S.b.y) return;
    float2 p = float2(gid) + 0.5;
    float front = S.a.x;
    float ridgeW = S.a.y;
    float old = float(snap.read(gid).r);

    float swept = smoothstep(front - 1.5, front + 1.5, p.y);     // 1 = the board already passed
    float ahead = front - p.y;                                   // > 0 = not reached yet
    float ridge = S.a.z * exp(-pow(max(ahead, 0.0) / ridgeW, 2.0)) * smoothstep(-2.0, 0.5, ahead);
    float h = mix(old, microRelief(p), swept);
    h = max(h, ridge + microRelief(p));
    h = mix(old, h, stoneMask(p, fps, S.b.z));
    hmap.write(float4(h), gid);
}

// Cross-fade between two heightfields (used when opening a saved garden).
kernel void blendHeights(texture2d<half, access::read> a [[texture(0)]],
                         texture2d<half, access::read> b [[texture(1)]],
                         texture2d<float, access::write> hmap [[texture(2)]],
                         constant GridParams& G [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= hmap.get_width() || gid.y >= hmap.get_height()) return;
    float t = G.v.x;
    float h = mix(float(a.read(gid).r), float(b.read(gid).r), t);
    hmap.write(float4(h), gid);
}
