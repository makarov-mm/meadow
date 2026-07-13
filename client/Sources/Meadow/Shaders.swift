import Foundation

/// All Metal shaders as one source string, compiled at runtime. FX vertex
/// struct uses unpacked float3/float2 on purpose: Swift SIMD types are
/// 16-byte aligned and packed Metal types would shift every field.
enum Shaders {
    static let source = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 vp;
    float4 cam;       // xyz eye, w time
    float4 sun;       // xyz light dir, w intensity
    float4 camRight;
    float4 camUp;
    float4 species;   // x: species id for this draw call (0 deer, 1 wolf, 2 bush, 3 pine)
    float4 env;       // dayPhase, daylight 0..1, nightGlow 0..1, time
};

struct VIn {
    packed_float3 pos;
    packed_float3 nrm;
    float part;
    float pad;
};

struct Inst {
    float4 posHead;   // x, y, z, heading
    float4 misc;      // animPhase, stateTime, state, scale
};

struct VOut {
    float4 clip [[position]];
    float3 color;
};

static float3 rotZp(float3 p, float3 pivot, float a) {
    p -= pivot;
    float c = cos(a), s = sin(a);
    float3 r = float3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
    return r + pivot;
}

// Heading rotation about Y so that +X maps to (cos h, 0, sin h).
static float3 rotY(float3 p, float h) {
    float c = cos(h), s = sin(h);
    return float3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

// ------------------------------------------------------------- sky

struct SkyOut {
    float4 clip [[position]];
    float2 uv;
};

vertex SkyOut v_sky(uint vid [[vertex_id]]) {
    float2 p = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
    SkyOut o;
    o.clip = float4(p, 1.0, 1.0);
    o.uv = p * 0.5 + 0.5;
    return o;
}

static float hash12(float2 p) {
    p = fract(p * float2(443.897, 441.423));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

fragment float4 f_sky(SkyOut in [[stage_in]],
                      constant Uniforms& U [[buffer(2)]]) {
    float t = clamp(in.uv.y, 0.0, 1.0);
    float daylight = U.env.y;
    float night = U.env.z;
    float day = U.env.x;

    float3 dayHorizon = float3(0.82, 0.88, 0.86);
    float3 dayZenith  = float3(0.45, 0.66, 0.85);
    float3 duskHorizon = float3(0.95, 0.55, 0.3);
    float3 duskZenith  = float3(0.35, 0.3, 0.5);
    float3 nightHorizon = float3(0.08, 0.1, 0.17);
    float3 nightZenith  = float3(0.02, 0.03, 0.08);

    // dusk factor peaks around dawn (day 0) and dusk (day 0.5)
    float e = sin(6.2831853 * day);
    float dusk = 1.0 - smoothstep(0.0, 0.35, fabs(e));

    float3 horizon = mix(mix(dayHorizon, nightHorizon, night), duskHorizon, dusk * 0.8);
    float3 zenith  = mix(mix(dayZenith, nightZenith, night), duskZenith, dusk * 0.6);
    float3 col = mix(horizon, zenith, smoothstep(0.05, 0.85, t));

    // stars fade in at night, gentle twinkle
    if (night > 0.2) {
        float2 sp = in.uv * float2(240.0, 130.0);
        float h = hash12(floor(sp));
        float star = step(0.995, h);
        float tw = 0.6 + 0.4 * sin(U.env.w * 2.0 + h * 40.0);
        col += star * tw * night * smoothstep(0.15, 0.5, t);
    }
    return float4(col, 1.0);
}

// ------------------------------------------------------------- animals

vertex VOut v_char(uint vid [[vertex_id]],
                   uint iid [[instance_id]],
                   const device VIn*   verts [[buffer(0)]],
                   const device Inst*  insts [[buffer(1)]],
                   constant Uniforms&  U     [[buffer(2)]]) {
    VIn  v = verts[vid];
    Inst I = insts[iid];

    float3 p = float3(v.pos);
    float3 n = float3(v.nrm);
    float part = v.part;

    float phase = I.misc.x;
    float stateTime = I.misc.y;
    float state = I.misc.z;
    float scl = max(I.misc.w, 0.2);
    float species = U.species.x;

    bool isAnimal = species < 1.5;

    if (isAnimal) {
        // gait: diagonal leg pairs; amplitude by state
        float amp = 0.0;
        if (state == 1.0) amp = 0.55;
        else if (state == 2.0) amp = 0.95;
        float sw = sin(phase);

        float hipF = 0.8;   // front hip height
        float hipB = 0.8;
        if (species > 0.5) { hipF = 0.56; hipB = 0.56; }

        if (part > 1.5 && part < 2.5)      p = rotZp(p, float3(0.45, hipF, 0.0), sw * amp);
        else if (part > 2.5 && part < 3.5) p = rotZp(p, float3(0.45, hipF, 0.0), -sw * amp);
        else if (part > 3.5 && part < 4.5) p = rotZp(p, float3(-0.45, hipB, 0.0), -sw * amp);
        else if (part > 4.5 && part < 5.5) p = rotZp(p, float3(-0.45, hipB, 0.0), sw * amp);

        // head down while grazing or eating
        bool headDown = (state == 0.0 || state == 5.0);
        if (headDown && part > 0.5 && part < 1.5) {
            float neckY = (species > 0.5) ? 0.85 : 1.35;
            p = rotZp(p, float3(0.5, neckY, 0.0), -0.85);
        }
        // subtle idle head bob
        if (state == 4.0 && part > 0.5 && part < 1.5) {
            p.y += sin(U.cam.w * 1.3 + phase) * 0.02;
        }
        // tail wag while running
        if (part > 5.5 && part < 6.5 && state == 2.0) {
            p.z += sin(U.cam.w * 14.0 + phase) * 0.05;
        }
        // death: topple sideways over 0.5 s, sink slightly
        if (state == 3.0) {
            float f = clamp(stateTime / 0.5, 0.0, 1.0);
            f = f * f * (3.0 - 2.0 * f);
            float c = cos(f * 1.5), s = sin(f * 1.5);
            p = float3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
            p.y = max(p.y, 0.02) - 0.05 * f;
        }
        // calves and pups are smaller
        p *= scl;
        // berries do not exist on animals; nothing else scales
    } else if (species > 2.5) {
        // pine: scale whole tree
        p *= scl;
    } else {
        // bush: berries scale with fill (misc.w is berries/6-ish, 0..1.3)
        if (part > 10.5 && part < 11.5) {
            float fill = clamp(I.misc.w, 0.0, 1.2);
            float3 center = float3(0.0, 0.8, 0.0);
            p = center + (p - center) * (0.2 + 0.8 * min(fill, 1.0));
            if (fill < 0.08) p = center; // no berries: collapse to nothing
        }
    }

    p = rotY(p, I.posHead.w);
    n = rotY(n, I.posHead.w);
    float3 world = p + I.posHead.xyz;

    // --- color ---
    float3 base;
    if (species < 0.5) {
        base = float3(0.62, 0.44, 0.26);                     // deer tan
        if (part > 0.5 && part < 1.5) base *= 0.92;          // head
        if (part > 5.5 && part < 6.5) base = float3(0.9, 0.88, 0.8); // tail flash
        if (part > 6.5 && part < 7.5) base *= 0.75;          // ears
        if (part > 1.5 && part < 5.5) base *= 0.85;          // legs darker
    } else if (species < 1.5) {
        base = float3(0.38, 0.39, 0.43);                     // wolf gray
        if (part > 0.5 && part < 1.5) base *= 0.9;
        if (part > 1.5 && part < 5.5) base *= 0.8;
        if (part > 5.5 && part < 6.5) base *= 0.85;
    } else if (species < 2.5) {
        base = (part > 10.5) ? float3(0.78, 0.16, 0.18)      // berries
                             : float3(0.16, 0.4, 0.18);      // foliage
    } else {
        base = (part > 12.5) ? float3(0.12, 0.34, 0.16)      // pine foliage
                             : float3(0.36, 0.26, 0.16);     // trunk
    }

    if (state == 3.0 && isAnimal) {
        float f = clamp(stateTime / 0.5, 0.0, 1.0);
        base *= (1.0 - 0.45 * f);
    }

    float3 L = normalize(U.sun.xyz);
    float diff = max(dot(normalize(n), L), 0.0);
    float amb = 0.18 + 0.3 * U.env.y;
    float3 lit = base * (amb + 0.65 * diff * U.sun.w);
    // moonlight tint at night
    lit = mix(lit, lit * float3(0.75, 0.82, 1.1), U.env.z * 0.6);

    float3 bg = mix(float3(0.8, 0.86, 0.85), float3(0.07, 0.09, 0.15), U.env.z);
    float d = distance(world, U.cam.xyz);
    lit = mix(lit, bg, smoothstep(180.0, 420.0, d));

    VOut o;
    o.clip = U.vp * float4(world, 1.0);
    o.color = lit;
    return o;
}

fragment float4 f_char(VOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

// ------------------------------------------------------------- ground

struct GOut {
    float4 clip [[position]];
    float3 world;
};

vertex GOut v_ground(uint vid [[vertex_id]],
                     const device VIn* verts [[buffer(0)]],
                     constant Uniforms& U [[buffer(2)]]) {
    VIn v = verts[vid];
    float3 world = float3(v.pos);
    GOut o;
    o.clip = U.vp * float4(world, 1.0);
    o.world = world;
    return o;
}

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Field and pond constants; must match the server's Meadow.Const.
constant float FIELD_X = 140.0;
constant float FIELD_Z = 90.0;
constant float POND_CX = 34.0;
constant float POND_CZ = -18.0;
constant float POND_RX = 20.0;
constant float POND_RZ = 13.0;

fragment float4 f_ground(GOut in [[stage_in]],
                         constant Uniforms& U [[buffer(2)]],
                         texture2d<float> grassTex [[texture(0)]]) {
    constexpr sampler smp(address::clamp_to_edge, filter::linear);

    float2 xz = in.world.xz;
    float2 uv = float2((xz.x + FIELD_X) / (2.0 * FIELD_X),
                       (xz.y + FIELD_Z) / (2.0 * FIELD_Z));

    float grass = 0.55;
    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
        grass = grassTex.sample(smp, uv).r;
    }

    float n = vnoise(xz * 0.12) * 0.6 + vnoise(xz * 0.5) * 0.4;

    float3 lush = float3(0.28, 0.5, 0.2);
    float3 grazed = float3(0.52, 0.44, 0.26);
    float3 col = mix(grazed, lush, grass);
    col *= 0.9 + n * 0.2;

    // pond
    float dx = (xz.x - POND_CX) / POND_RX;
    float dz = (xz.y - POND_CZ) / POND_RZ;
    float pf = dx * dx + dz * dz;
    if (pf < 1.0) {
        float depth = 1.0 - pf;
        float ripple = sin(xz.x * 1.4 + U.cam.w * 1.7) * sin(xz.y * 1.6 - U.cam.w * 1.3);
        float3 water = mix(float3(0.32, 0.5, 0.55), float3(0.13, 0.3, 0.42), depth);
        water += ripple * 0.02;
        col = water;
    } else if (pf < 1.25) {
        // sandy shore ring
        float sh = 1.0 - smoothstep(1.0, 1.25, pf);
        col = mix(col, float3(0.62, 0.55, 0.38), sh * 0.8);
    }

    col *= (0.25 + 0.75 * U.env.y);
    col = mix(col, col * float3(0.7, 0.8, 1.15), U.env.z * 0.55);

    float3 bg = mix(float3(0.8, 0.86, 0.85), float3(0.07, 0.09, 0.15), U.env.z);
    float d = distance(in.world, U.cam.xyz);
    col = mix(col, bg, smoothstep(180.0, 460.0, d));
    return float4(col, 1.0);
}

// ------------------------------------------------------------- FX

struct FXV {
    float3 center;
    float2 corner;
    float4 data;   // kind, age 0..1, unused, size
};

struct FXOut {
    float4 clip [[position]];
    float2 uv;
    float4 data;
};

vertex FXOut v_fx(uint vid [[vertex_id]],
                  const device FXV* verts [[buffer(0)]],
                  constant Uniforms& U [[buffer(2)]]) {
    FXV v = verts[vid];
    float size = v.data.w;
    float3 world = v.center
                 + U.camRight.xyz * (v.corner.x * size)
                 + U.camUp.xyz    * (v.corner.y * size);
    FXOut o;
    o.clip = U.vp * float4(world, 1.0);
    o.uv = v.corner;
    o.data = v.data;
    return o;
}

fragment float4 f_fx(FXOut in [[stage_in]]) {
    float kind = in.data.x;
    float u = in.data.y;
    float r = length(in.uv);

    if (kind < 0.5) {
        // kill: red puff
        float a = smoothstep(1.0, 0.25, r) * (1.0 - u) * 0.85;
        return float4(0.75, 0.12, 0.1, a);
    } else if (kind < 1.5) {
        // birth: soft expanding ring
        float ring = smoothstep(0.18, 0.0, fabs(r - 0.75));
        float a = ring * (1.0 - u) * 0.8;
        return float4(0.95, 0.98, 0.8, a);
    } else if (kind < 2.5) {
        // starvation: gray puff
        float a = smoothstep(1.0, 0.3, r) * (1.0 - u) * 0.6;
        return float4(0.5, 0.5, 0.5, a);
    } else if (kind < 3.5) {
        // berry sparkle
        float a = smoothstep(0.7, 0.0, r) * (1.0 - u);
        return float4(0.95, 0.4, 0.45, a);
    } else {
        // firefly: u carries brightness, not age
        float a = smoothstep(1.0, 0.0, r) * u;
        return float4(0.85, 0.95, 0.45, a);
    }
}
"""
}
