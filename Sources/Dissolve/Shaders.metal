#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;          // sample location in this window's screenshot
    float2 localUV;     // 0..1 within the particle quad (for circular mask)
    float  alpha;
    float  glow;
    float  local;       // 0..1 particle life — drives shape ramp in fragment
};

struct WindowUniforms {
    float2 origin;      // window's top-left in screen UV (0..1, top-left origin)
    float2 size;        // window's size in screen UV
    float  progress;
    uint   cols;
    uint   rows;
};

// ---------- noise ----------

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash(i);
    float b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1));
    float d = hash(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// Multi-octave noise → organic patchy pattern.
static float fbm(float2 p) {
    return valueNoise(p * 4.0)  * 0.55
         + valueNoise(p * 12.0) * 0.30
         + valueNoise(p * 36.0) * 0.15;
}

// 2D curl of a scalar noise field — divergence-free, so grains swirl rather
// than stagnate or converge. Used as a turbulence field on top of an upward drift.
static float2 curlNoise(float2 p) {
    const float eps = 0.015;
    float n_yp = valueNoise((p + float2(0.0,  eps)) * 5.0);
    float n_yn = valueNoise((p - float2(0.0,  eps)) * 5.0);
    float n_xp = valueNoise((p + float2(eps,  0.0)) * 5.0);
    float n_xn = valueNoise((p - float2(eps,  0.0)) * 5.0);
    return float2((n_yp - n_yn) / (2.0 * eps),
                 -(n_xp - n_xn) / (2.0 * eps));
}

// ---------- particle pass ----------

vertex VSOut particleVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant WindowUniforms& u [[buffer(0)]]) {
    uint col = iid % u.cols;
    uint row = iid / u.cols;

    float fcol = float(col), frow = float(row);
    float fcols = float(u.cols), frows = float(u.rows);

    // Cell centre + size in both window-local and screen UV spaces.
    float2 cellLocal      = float2((fcol + 0.5) / fcols, (frow + 0.5) / frows);
    float2 cellSizeLocal  = float2(1.0 / fcols, 1.0 / frows);
    float2 cellScreen     = u.origin + cellLocal * u.size;
    float2 cellSizeScreen = cellSizeLocal * u.size;

    // Per-grain pseudo-randoms keyed by world position.
    float h1 = hash(cellScreen * 173.0);
    float h2 = hash(cellScreen * 173.0 + float2(17.3, -8.1));
    float h3 = hash(cellScreen * 173.0 + float2(-4.7, 33.7));
    float h4 = hash(cellScreen * 173.0 + float2(91.1, 12.4));

    // Organic wavy dissolve front: fbm noise + vertical bias (top goes first),
    // plus a small per-grain jitter so adjacent cells don't ignite identically.
    float frontField = fbm(cellScreen) * 0.55 + cellScreen.y * 0.45;
    float delay = frontField * 0.85 + h1 * 0.15;
    float local = clamp((u.progress - delay) / max(0.001, 1.0 - delay), 0.0, 1.5);

    // Primary drift: gentle upward baseline, with a scaled-down curl-noise
    // turbulence that evolves as the grain moves so trails swirl organically.
    float2 driftPos = cellScreen + float2(h2 * 0.1, -local * 0.15);
    float2 curl = curlNoise(driftPos);
    float2 velocity = float2(curl.x * 0.55,
                             -(0.18 + h3 * 0.22) + curl.y * 0.35);
    float2 gravity = float2(0.0, 0.05);        // near-zero so grains float
    float2 displacement = velocity * local + 0.5 * gravity * local * local;

    // Very mild rotation — visible only on larger grains.
    float angle = (h4 - 0.5) * 2.5 * local;
    float cs = cos(angle), sn = sin(angle);

    // At local=0 every cell tiles its window perfectly; once it ignites, jitter & shrink.
    float ignite = smoothstep(0.0, 0.05, local);
    float sizeJitter = mix(1.0, 0.7 + h4 * 0.7, ignite);
    float scale = max(0.0, sizeJitter * (1.0 - local * 0.3));

    // Quad corners.
    float2 corners[6] = {
        float2(-0.5, -0.5), float2( 0.5, -0.5), float2(-0.5,  0.5),
        float2(-0.5,  0.5), float2( 0.5, -0.5), float2( 0.5,  0.5)
    };
    float2 cornerUVs[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 corner = corners[vid];
    float2 cuv    = cornerUVs[vid];
    float2 rotated = float2(cs * corner.x - sn * corner.y,
                            sn * corner.x + cs * corner.y);

    float2 posUV = cellScreen + rotated * cellSizeScreen * scale + displacement;
    float2 clip = float2(posUV.x * 2.0 - 1.0, 1.0 - posUV.y * 2.0);

    VSOut out;
    out.position = float4(clip, 0, 1);

    // Sample the window texture at the corner's actual position so an un-ignited
    // tile shows the original pixels exactly.
    out.uv = cellLocal + (cuv - 0.5) * cellSizeLocal;
    out.localUV = cuv;
    // Long, gentle fade for the ethereal lingering look.
    out.alpha = 1.0 - smoothstep(0.30, 1.0, local);
    out.glow  = exp(-local * 10.0) * smoothstep(0.0, 0.04, local);
    out.local = local;
    return out;
}

fragment float4 particleFragment(VSOut in [[stage_in]],
                                 texture2d<float> screen [[texture(0)]]) {
    // Shape ramps from full square (covers cell completely) to a circular grain
    // as the particle ignites. 0.71 ≈ sqrt(0.5) — corner of a unit square.
    float r = length(in.localUV - 0.5);
    float ignite = smoothstep(0.0, 0.05, in.local);
    float threshold = mix(0.71, 0.50, ignite);
    if (r > threshold) discard_fragment();
    float disc = 1.0 - smoothstep(threshold - 0.02, threshold, r);

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = screen.sample(s, in.uv);

    // Subtle warm ignition wash — keeps source colours mostly intact.
    float3 ember = float3(1.0, 0.72, 0.42);
    float3 rgb = mix(color.rgb, ember, in.glow * 0.25);

    return float4(rgb, color.a * in.alpha * disc);
}
