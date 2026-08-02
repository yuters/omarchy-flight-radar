#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lightMode;
    vec4 backgroundColor;
    vec2 sourceSize;
} ubuf;

layout(binding = 1) uniform sampler2D source;

vec3 sampleScreen(vec2 uv) {
    vec4 sampleValue = texture(source, uv);
    return sampleValue.rgb + ubuf.backgroundColor.rgb * (1.0 - sampleValue.a);
}

float roundedScreen(vec2 p) {
    const float radius = 0.055;
    vec2 q = abs(p) - vec2(0.998) + radius;
    float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return 1.0 - smoothstep(-0.006, 0.004, distance);
}

void main() {
    // Size arrives as a uniform rather than through textureSize(), which is
    // unavailable in ESSL 100 and would drop the GL ES 2 and legacy desktop
    // targets from the baked shader.
    vec2 size = max(ubuf.sourceSize, vec2(1.0));
    vec2 texel = 1.0 / size;

    // Sample through a subtly convex tube. The source bends away from the
    // viewer near the corners while the centre stays essentially undistorted.
    vec2 p = qt_TexCoord0 * 2.0 - 1.0;
    float radius2 = dot(p, p);
    vec2 curved = p * (1.0 + 0.012 * radius2) * 0.975;
    vec2 uv = curved * 0.5 + 0.5;

    float inside = roundedScreen(p);
    if (inside <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    // Horizontal beam spread plus restrained red/blue convergence error. This
    // is what makes luminous lines feel emitted instead of merely anti-aliased.
    float separation = (0.18 + radius2 * 0.55) * texel.x;
    vec2 redUv = uv + vec2(separation, 0.0);
    vec2 blueUv = uv - vec2(separation, 0.0);
    vec3 centre = sampleScreen(uv);
    vec3 colour = vec3(sampleScreen(redUv).r,
                       centre.g,
                       sampleScreen(blueUv).b);
    colour += sampleScreen(uv + vec2(texel.x * 1.25, 0.0)) * 0.10;
    colour += sampleScreen(uv - vec2(texel.x * 1.25, 0.0)) * 0.10;
    colour += sampleScreen(uv + vec2(texel.x * 2.5, 0.0)) * 0.045;
    colour += sampleScreen(uv - vec2(texel.x * 2.5, 0.0)) * 0.045;
    colour *= 0.84;

    // A small cross-shaped bloom around bright phosphors. It is deliberately
    // bounded so normal body text remains legible.
    vec3 bloom = sampleScreen(uv + vec2(texel.x * 2.8, 0.0));
    bloom += sampleScreen(uv - vec2(texel.x * 2.8, 0.0));
    bloom += sampleScreen(uv + vec2(0.0, texel.y * 1.8));
    bloom += sampleScreen(uv - vec2(0.0, texel.y * 1.8));
    colour += max(bloom * 0.25 - vec3(0.34), vec3(0.0)) * 0.28;

    vec2 pixel = uv * size;
    float scanWave = sin(pixel.y * 1.57079633);
    float scanFloor = mix(0.70, 0.88, ubuf.lightMode);
    float scanline = mix(scanFloor, 1.0, smoothstep(-0.62, 0.68, scanWave));

    // Three-column aperture grille. Low contrast keeps it visible as texture,
    // not as coloured stripes, at both 1x and 2x output scale.
    float grilleCell = mod(floor(pixel.x), 3.0);
    vec3 grille = grilleCell < 1.0 ? vec3(1.0, 0.985, 0.985)
                : grilleCell < 2.0 ? vec3(0.985, 1.0, 0.985)
                                   : vec3(0.985, 0.985, 1.0);
    grille = mix(grille, vec3(1.0), ubuf.lightMode * 0.72);
    colour *= scanline * grille;

    // Tube-edge light loss and a fixed diagonal glass reflection.
    float vignette = clamp(16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y), 0.0, 1.0);
    float edgeFloor = mix(0.42, 0.82, ubuf.lightMode);
    vignette = mix(edgeFloor, 1.0, pow(vignette, 0.2));
    float reflection = smoothstep(0.28, 0.02, abs(uv.y - (0.13 + uv.x * 0.10)));
    reflection *= smoothstep(0.02, 0.24, uv.x) * (1.0 - smoothstep(0.58, 0.92, uv.x));
    colour = colour * vignette + vec3(0.06, 0.085, 0.12) * reflection * 0.13;

    fragColor = vec4(colour * inside, inside) * ubuf.qt_Opacity;
}
