shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

// Attach this shader to a QuadMesh placed directly in front of a Camera3D.
// It samples the screen behind the quad and restyles it like a CCTV feed:
// barrel distortion, scanlines, chromatic aberration, vignette, monochrome
// tint, animated noise grain, and a slow recording corner pulse.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

uniform vec3 tint_color : source_color = vec3(0.78, 0.92, 0.85);
uniform float saturation : hint_range(0.0, 1.0) = 0.15;
uniform float brightness : hint_range(0.0, 2.0) = 0.95;
uniform float contrast : hint_range(0.0, 2.0) = 1.15;

uniform float barrel_distortion : hint_range(0.0, 0.5) = 0.12;
uniform float chromatic_aberration : hint_range(0.0, 0.02) = 0.0035;

uniform float scanline_strength : hint_range(0.0, 1.0) = 0.25;
uniform float scanline_count : hint_range(50.0, 1200.0) = 480.0;
uniform float scanline_scroll_speed : hint_range(-4.0, 4.0) = 0.6;

uniform float vignette_strength : hint_range(0.0, 2.0) = 1.1;
uniform float vignette_softness : hint_range(0.05, 1.5) = 0.55;

uniform float noise_strength : hint_range(0.0, 0.5) = 0.08;
uniform float flicker_strength : hint_range(0.0, 0.5) = 0.04;
uniform float flicker_speed : hint_range(0.0, 30.0) = 12.0;

uniform float rec_pulse_speed : hint_range(0.0, 6.0) = 1.4;
uniform vec3 rec_color : source_color = vec3(1.0, 0.15, 0.15);
uniform float rec_dot_radius : hint_range(0.0, 0.05) = 0.014;
uniform vec2 rec_dot_uv = vec2(0.06, 0.06);

// Hash for cheap per-pixel noise driven by TIME.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Curve UVs outward from center to mimic a CRT's barrel lens.
vec2 barrel(vec2 uv, float amount) {
	vec2 centered = uv - vec2(0.5);
	float r2 = dot(centered, centered);
	centered *= 1.0 + amount * r2;
	return centered + vec2(0.5);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// Barrel-distort the sample coordinate to fake a curved CRT face.
	vec2 distorted_uv = barrel(uv, barrel_distortion);

	// Mask out anything past the curved screen edge so corners go black.
	vec2 edge = step(vec2(0.0), distorted_uv) * step(distorted_uv, vec2(1.0));
	float on_screen = edge.x * edge.y;

	// Chromatic aberration: shift channels along the radial direction.
	vec2 from_center = distorted_uv - vec2(0.5);
	vec2 ca_offset = from_center * chromatic_aberration;
	float r = texture(screen_texture, distorted_uv + ca_offset).r;
	float g = texture(screen_texture, distorted_uv).g;
	float b = texture(screen_texture, distorted_uv - ca_offset).b;
	vec3 col = vec3(r, g, b);

	// Desaturate toward luminance, then push toward the CCTV tint color.
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	vec3 desaturated = mix(vec3(luma), col, saturation);
	col = desaturated * tint_color;

	// Brightness + contrast around midgray.
	col = (col - 0.5) * contrast + 0.5;
	col *= brightness;

	// Animated horizontal scanlines with a slow vertical scroll.
	float scan = sin((uv.y + TIME * scanline_scroll_speed * 0.01) * scanline_count * 3.14159);
	col *= 1.0 - scanline_strength * (0.5 + 0.5 * scan);

	// Static-style grain that resamples every frame.
	float n = hash21(uv * vec2(1920.0, 1080.0) + TIME * 60.0);
	col += (n - 0.5) * noise_strength;

	// Brightness flicker — a subtle high-frequency dip in signal strength.
	float flicker = 1.0 - flicker_strength * (0.5 + 0.5 * sin(TIME * flicker_speed));
	col *= flicker;

	// Soft vignette darkening the corners.
	float vignette = smoothstep(vignette_softness, 0.0, length(from_center));
	col *= mix(1.0 - vignette_strength, 1.0, vignette);

	// Black out the curved-edge mask so the screen has a clear border.
	col *= on_screen;

	// Blinking REC dot in the top-left corner (UV origin convention has y=0 at top in SCREEN_UV).
	float rec_pulse = step(0.0, sin(TIME * rec_pulse_speed * 3.14159));
	float dot_dist = distance(uv, rec_dot_uv);
	float rec_mask = smoothstep(rec_dot_radius, rec_dot_radius * 0.5, dot_dist) * rec_pulse;
	col = mix(col, rec_color, rec_mask * 0.85);

	ALBEDO = col;
}
