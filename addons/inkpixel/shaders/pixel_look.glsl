#[compute]
#version 450

// ink-studio 的像素风后处理：低分辨率块化 + 调色板量化 + 有序抖动 + 描边。
//
// 算法出处是 ink-studio 自己的 constraintPalette / paletteRow（src/webgl/shaders.mjs:716-757）：
//   dot(weight*delta, inputColor-best) >= threshold*dot(weight,delta*delta)
// 即"投影到 best->second 连线上，再用 Bayer 秩当阈值决定翻不翻"。
// 这和"先加噪声再取最近"看着像，但关键区别在于：输入色已经精确命中调色板时
// 投影为 0，抖动量自动归零 —— 不会在纯色区域凭空造出噪点。
//
// 真正让画面"像像素画"的是低分辨率，不是量化。所以第一步先把 ps×ps 的块平均成
// 一个颜色，抖动和量化都基于块坐标，最后整块写同一个值。

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, binding = 0, set = 0) uniform image2D color_tex;

layout(set = 0, binding = 1, std430) restrict readonly buffer PaletteBuffer {
    vec4 entries[];
} pal;

layout(push_constant, std430) uniform Params {
    vec2 screen_size;
    float dither;         // 抖动强度，ink-studio 的 world.dither
    float palette_count;  // 有效调色板条目数
    float edge_amount;    // 描边强度 0=关
    float edge_threshold; // 亮度突变阈值
    float edge_darken;    // 描边压到多少
    float pixel_size;     // 像素块边长，1 = 全分辨率
} p;

// 和 ink-studio 逐位相同的 4x4 Bayer 矩阵
const float BAYER[16] = float[16](
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0);

vec3 linear_to_srgb(vec3 c) {
    c = max(c, vec3(0.0));
    bvec3 lo = lessThanEqual(c, vec3(0.0031308));
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, c * 12.92, lo);
}

vec3 srgb_to_linear(vec3 c) {
    bvec3 lo = lessThanEqual(c, vec3(0.04045));
    vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(hi, c / 12.92, lo);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// 邻域像素的 sRGB 亮度；越界时退回自己的值，避免画布边缘出现假描边
float srgb_luma_at(ivec2 q, ivec2 size, float fallback) {
    if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) return fallback;
    return luma(linear_to_srgb(imageLoad(color_tex, q).rgb));
}

// 把 ps×ps 的块平均成一个线性颜色。块可能超出画布，所以有边界检查。
vec3 block_average(ivec2 block, int ps, ivec2 size) {
    vec3 acc = vec3(0.0);
    int taps = 0;
    for (int dy = 0; dy < 16; dy++) {
        if (dy >= ps) break;
        for (int dx = 0; dx < 16; dx++) {
            if (dx >= ps) break;
            ivec2 q = block + ivec2(dx, dy);
            if (q.x >= size.x || q.y >= size.y) continue;
            acc += imageLoad(color_tex, q).rgb;
            taps++;
        }
    }
    return taps > 0 ? acc / float(taps) : vec3(0.0);
}

void main() {
    ivec2 px = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(p.screen_size);
    if (px.x >= size.x || px.y >= size.y) return;

    int ps = clamp(int(p.pixel_size + 0.5), 1, 16);
    ivec2 block = (px / ps) * ps;
    ivec2 pq = block;   // 抖动/描边都按块坐标算，否则会被块平均洗掉

    vec4 src = imageLoad(color_tex, px);
    vec3 lin = ps > 1 ? block_average(block, ps, size) : src.rgb;

    // 背景原样透过：清屏色直接从颜色缓冲的角落取，不靠猜颜色空间。
    // diorama 的顶角必是背景，等值像素说明 splat 没覆盖到这里。
    vec3 bg = imageLoad(color_tex, ivec2(0, 0)).rgb;
    if (all(equal(lin, bg))) {
        return;
    }

    vec3 srgb = clamp(linear_to_srgb(lin), 0.0, 1.0);

    // ---- 调色板量化 + 投影抖动
    int n = int(p.palette_count + 0.5);
    if (n > 0 && n <= 64) {
        const vec3 W = vec3(0.30, 0.55, 0.15);   // ink-studio 的通道权重
        float bd = 1e9, sd = 1e9;
        int best = 0, second = -1;
        for (int i = 0; i < 64; i++) {
            if (i >= n) break;
            vec3 d = srgb - pal.entries[i].rgb;
            float dd = dot(W * d, d);
            if (dd < bd) {
                sd = bd; second = best;
                bd = dd; best = i;
            } else if (dd < sd) {
                sd = dd; second = i;
            }
        }
        vec3 c0 = pal.entries[best].rgb;
        if (second >= 0) {
            vec3 delta = pal.entries[second].rgb - c0;
            float denom = dot(W * delta, delta);
            if (denom > 1e-9) {
                float t = dot(W * delta, srgb - c0) / denom;   // 0 = 正好是 best
                float rank = (BAYER[(pq.x & 3) + ((pq.y & 3) << 2)] + 0.5) / 16.0;
                float thr = 0.5 + (rank - 0.5) * p.dither;
                if (t >= thr) c0 = pal.entries[second].rgb;
            }
        }
        srgb = c0;
    }

    // ---- 描边：GDGS 的 raster splat 用 depth_draw_never，深度缓冲里没有 splat，
    // 所以只能从量化后的亮度突变求边，不是真正的几何轮廓。
    if (p.edge_amount > 0.0) {
        float me = luma(srgb);
        float d = abs(srgb_luma_at(pq + ivec2(ps, 0), size, me) - me);
        d = max(d, abs(srgb_luma_at(pq - ivec2(ps, 0), size, me) - me));
        d = max(d, abs(srgb_luma_at(pq + ivec2(0, ps), size, me) - me));
        d = max(d, abs(srgb_luma_at(pq - ivec2(0, ps), size, me) - me));
        float k = smoothstep(p.edge_threshold, p.edge_threshold * 2.0, d) * p.edge_amount;
        srgb = mix(srgb, srgb * p.edge_darken, k);
    }

    imageStore(color_tex, px, vec4(srgb_to_linear(srgb), src.a));
}
