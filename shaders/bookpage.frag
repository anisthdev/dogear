#version 440

// The paper of the Book scheme, laid over the page: fibres and mottling,
// the crease and the shadows falling into it, the sheet rising beside it,
// and a dog-ear on a bookmarked page. It's all shade except the dog-ear, so
// the page shows through and takes every click. Output is premultiplied:
// black to darken, white to lighten.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float spread;       // 1: two pages
    float mirror;       // 1: right to left
    float dogear;       // 0 flat to 1 folded
    vec2 area;
    vec4 paper;
    vec4 board;
};

const float EAR = 38.0;     // the fold's reach along each edge, px

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

// Roughly -1 to 1: fine tooth, specks, long fibres, slow mottling
float grain(vec2 p)
{
    float fibre = noise(vec2(p.x * 0.11 + 3.0 * noise(p * 0.03), p.y * 1.3));
    return 1.1 * (noise(p * 1.1) - 0.5) + 0.8 * (noise(p * 0.37) - 0.5)
        + 0.7 * (fibre - 0.5) + 1.0 * (noise(p * 0.011) - 0.5);
}

void main()
{
    vec2 p = qt_TexCoord0 * area;
    if (mirror > 0.5)
        p.x = area.x - p.x;
    float W = area.x, H = area.y;
    float tooth = grain(p);

    // Dark is positive
    float shade = 0.05 * tooth;

    // Into the spine: a two-page book has a crease, a one-page view has the
    // spine at its edge. The light comes from the left, so the left page
    // falls into more shadow.
    float dx = spread > 0.5 ? abs(p.x - W * 0.5) : p.x;
    float depth = spread > 0.5 && p.x < W * 0.5 ? 1.0 : 0.72;
    shade += depth * (0.3 * exp(-dx / 9.0) + 0.17 * exp(-dx / 62.0));
    float rise = (dx - 130.0) / 100.0;
    shade -= 0.035 * exp(-rise * rise);
    if (spread > 0.5)
        shade += 0.42 * smoothstep(1.6, 0.2, dx);

    // Sheets fall away a little at the outer edges
    float outer = W - p.x;
    if (spread > 0.5)
        outer = min(outer, p.x);
    shade += 0.09 * exp(-outer / 16.0) + 0.05 * exp(-min(p.y, H - p.y) / 12.0);

    vec4 col = shade > 0.0 ? vec4(0.13, 0.08, 0.03, 1.0) * shade
                           : vec4(1.0, 0.98, 0.92, 1.0) * -shade;

    // The pages dip into the spine at top and bottom, showing the boards
    if (spread > 0.5) {
        float dip = 6.0 * exp(-dx / 24.0);
        float edge = min(p.y, H - p.y) - dip;
        col = mix(vec4(board.rgb * 0.62, 1.0), col, clamp(edge + 0.5, 0.0, 1.0));
    }

    // The dog-ear, in the top outer corner: the corner folded down on the
    // page along u.x + u.y = reach, the next page showing where it was
    float reach = EAR * dogear;
    if (reach > 0.5) {
        vec2 u = vec2(W - p.x, p.y);
        float across = u.x + u.y - reach;
        float flap = max(u.x, u.y) - reach;

        // Its shadow, thrown down and away from the corner
        vec2 s = u - vec2(2.0, 3.0);
        float gone = max(max(s.x, s.y) - reach, 0.0);
        if (across > 0.0)
            col += (vec4(0.0, 0.0, 0.0, 1.0) - col) * 0.3 * exp(-gone / 3.5) * step(0.0, across);

        vec3 next = paper.rgb * (0.9 + 0.012 * tooth) * (0.8 + 0.2 * smoothstep(0.0, reach, -across));
        col = mix(col, vec4(next, 1.0), clamp(0.5 - across, 0.0, 1.0));

        // The flap shows the paper's back, brighter at the fold's far tip
        float up = clamp(across / reach, 0.0, 1.0);
        vec3 back = paper.rgb * (0.93 + 0.1 * up + 0.012 * tooth);
        back *= 1.0 - 0.28 * exp(-across / 1.8);
        col = mix(col, vec4(back, 1.0), clamp(0.5 + min(across, 0.0) + min(-flap, 0.0) + 0.5, 0.0, 1.0)
                  * step(0.0, across) * step(flap, 0.5));
    }

    fragColor = col * qt_Opacity;
}
