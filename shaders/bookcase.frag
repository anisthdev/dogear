#version 440

// The book-shaped part of the Book scheme, under the page: its shadow, the
// boards, and the page edges, which pile up on the spine's side as the book
// is read. The rest of the window is left see-through. See Reader.qml.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float spread;       // 1: open at two pages
    float mirror;       // 1: right to left
    float fraction;     // how far through the book
    vec2 area;
    vec4 pageRect;      // x, y, w, h
    vec4 board;
    vec4 paper;
};

float hash(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p)
{
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

// Distance to a box with rounded corners: negative inside
float box(vec2 p, vec4 ltrb, float radius)
{
    vec2 c = (ltrb.xy + ltrb.zw) * 0.5, half_ = (ltrb.zw - ltrb.xy) * 0.5 - radius;
    vec2 d = abs(p - c) - half_;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main()
{
    vec2 p = qt_TexCoord0 * area;
    float l = pageRect.x, t = pageRect.y, r = l + pageRect.z, b = t + pageRect.w;
    if (mirror > 0.5)
        p.x = l + r - p.x;

    // Pages read lie on the left, those to come on the right
    float left = spread > 0.5 ? 3.0 + 19.0 * fraction : 0.0;
    float right = 3.0 + 19.0 * (1.0 - fraction);
    vec4 stack = vec4(l - left, t - 1.0, r + right, b + 5.0);
    vec4 cover = stack + vec4(-8.0, -7.0, 8.0, 7.0);

    // The book's shadow, on whatever is behind the window: one tight, one
    // wide, fading out before the window's edge
    float tight = box(p - vec2(3.0, 5.0), cover, 7.0);
    float wide = box(p - vec2(8.0, 12.0), cover, 12.0);
    float shadow = 0.5 * exp(-max(tight, 0.0) / 5.0) + 0.3 * exp(-max(wide, 0.0) / 12.0);
    vec2 toEdge = min(qt_TexCoord0, 1.0 - qt_TexCoord0) * area;
    vec4 col = vec4(0.0, 0.0, 0.0, min(shadow, 0.8) * smoothstep(0.0, 24.0, min(toEdge.x, toEdge.y)));

    // The boards: cloth, a lighter edge, the spine's grooves
    float d = box(p, cover, 6.0);
    if (d < 0.5) {
        float weave = sin(p.x * 2.3) * sin(p.y * 2.3);
        vec3 cloth = board.rgb * (1.0 + 0.06 * weave + 0.14 * (noise(p * 0.6) - 0.5));
        cloth *= 1.0 + 0.3 * smoothstep(-2.5, -0.5, d);
        if (spread > 0.5) {
            float dx = abs(p.x - (l + r) * 0.5);
            cloth *= 1.0 - 0.32 * exp(-dx / 12.0);
        } else {
            cloth *= 1.0 - 0.3 * smoothstep(0.0, 7.0, p.x - l + 7.0) * step(p.x, l);
        }
        col = mix(col, vec4(cloth, 1.0), clamp(0.5 - d, 0.0, 1.0));
    }

    // Page edges, sheet on sheet
    float side = box(p, stack, 1.0);
    if (side < 0.5) {
        bool bottom = p.y > b;
        float along = bottom ? p.y : p.x;
        float wander = noise(bottom ? vec2(p.x * 0.02, p.y) : vec2(p.x, p.y * 0.02)) * 3.0;
        float sheet = 0.5 + 0.5 * sin(along * 2.6 + wander);
        vec3 edge = paper.rgb * mix(0.74, 0.97, sheet);
        // Falling away from the page
        float out_ = bottom ? (p.y - b) / 5.0
            : p.x > r ? (p.x - r) / max(right, 1.0) : (l - p.x) / max(left, 1.0);
        edge *= 1.0 - 0.2 * out_;
        col = mix(col, vec4(edge, 1.0), clamp(0.5 - side, 0.0, 1.0));
    }

    fragColor = col * qt_Opacity;
}
