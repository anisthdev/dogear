#version 440

// A page turning: the sheet rolls off around a cylinder whose axis sweeps
// from the bottom corner across the page, levelling out as it goes. Each
// pixel is worked out from the bottom of the pile up: what's under the
// sheet, the part still lying flat, the roll (its underside, then its
// top), and the part already turned over. See PageCurl.qml.
//
// All of it is in "curl space", pixels with the sheet's free edge on the
// right; right-to-left books mirror it. `s` is a pixel's distance from the
// axis along `n`, positive towards the free edge, and a point of the sheet
// is found by how far along the paper it lies from the axis: flat on one
// side, r·θ round the cylinder, r·π + distance once it's back over.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;     // 0 lying flat, 1 turned right over
    float spread;       // 1: two pages, the sheet hinged in the middle
    float mirror;       // 1: right to left
    float dark;         // 1: a dark page, where shadows can't show
    vec2 area;          // this item's size
    vec4 pageRect;      // where the pictures sit in it (x, y, w, h)
    vec4 paper;         // the colour around them
};

layout(binding = 1) uniform sampler2D sheet;    // what's showing at progress 0
layout(binding = 2) uniform sampler2D under;    // what's showing at progress 1

const float PI = 3.14159265;
const float TILT = 0.38;        // the axis's slant at the start, radians
const float SHADOW = 26.0;      // how far a shadow reaches, px

float hinge;

// A picture at a curl-space point; outside it, plain paper
vec3 pictured(sampler2D tex, vec2 q)
{
    vec2 screen = vec2(mirror > 0.5 ? area.x - q.x : q.x, q.y);
    vec2 uv = (screen - pageRect.xy) / pageRect.zw;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0)
        return paper.rgb;
    return texture(tex, uv).rgb;
}

// How far a point of the paper is off the sheet: negative when on it
float off(vec2 u)
{
    return max(max(hinge - u.x, u.x - area.x), max(-u.y, u.y - area.y));
}

// A pixel's share of the sheet, for smooth edges
float on(float d)
{
    return clamp(0.5 - d, 0.0, 1.0);
}

// The sheet's other side: with two pages, the page it lands as; with one,
// paper with the print showing through, reversed
vec3 backOf(vec2 u)
{
    if (spread > 0.5)
        return pictured(under, vec2(2.0 * hinge - u.x, u.y));
    vec3 blank = mix(paper.rgb, vec3(1.0), 0.07 * dark);
    return mix(blank, pictured(sheet, u), 0.1);
}

// Lit from above: facing up is full light, edge-on is dimmer. On dark
// pages dimming shows nothing, so the curve catches some light instead.
vec3 lit(vec3 c, float facing)
{
    return c * (0.68 + 0.32 * facing) + dark * 0.09 * facing * facing;
}

void main()
{
    vec2 q = qt_TexCoord0 * area;
    if (mirror > 0.5)
        q.x = area.x - q.x;

    hinge = spread > 0.5 ? area.x * 0.5 : 0.0;
    float p = progress;
    float a = TILT * (1.0 - p);
    vec2 n = vec2(cos(a), sin(a));
    float r = max(0.01, clamp((area.x - hinge) * 0.11, 28.0, 96.0) * smoothstep(1.0, 0.82, p));
    float c = mix(dot(area, n), dot(vec2(hinge, area.y * 0.5), n), p);
    float s = dot(q, n) - c;

    // The turned-over part: this point of the paper, if any, lies here
    vec2 over = q + n * (PI * r - 2.0 * s);
    float overOff = off(over);

    // What's underneath, then the sheet still flat
    vec3 col = q.x < hinge ? pictured(sheet, q) : pictured(under, q);
    if (s < 0.0)
        col = mix(col, pictured(sheet, q), on(off(q)));

    // Shadows on those: from the roll ahead of it, the turned part behind
    float shadow = 0.0;
    if (s >= r)
        shadow = exp((r - s) / SHADOW);
    else if (s < 0.0 && overOff > 0.0)
        shadow = exp(-overOff / SHADOW);
    col *= 1.0 - 0.38 * shadow * smoothstep(0.0, 0.06, p) * smoothstep(1.0, 0.9, p);

    if (s >= 0.0 && s <= r + 1.0) {
        // The roll: a pixel looks down on its top and, past the sheet's
        // edge, its underside
        float x = clamp(s / r, 0.0, 1.0);
        float theta = asin(x);
        float facing = sqrt(1.0 - x * x);
        float edge = clamp(r - s + 0.5, 0.0, 1.0);

        vec2 u = q + n * (r * theta - s);
        col = mix(col, lit(pictured(sheet, u), facing), on(off(u)) * edge);
        u = q + n * (r * (PI - theta) - s);
        col = mix(col, lit(backOf(u), facing), on(off(u)) * edge);
    } else if (s < 0.0) {
        float near = exp(s / (r * 1.5 + 1.0));
        col = mix(col, lit(backOf(over), 1.0 - 0.45 * near), on(overOff));
    }

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
