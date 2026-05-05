shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

// PSX post-process: attach to a QuadMesh in front of Camera3D (same setup as
// cctv.gdshader). Samples the screen then applies a suite of optional PS1-era
// effects: Bayer dithering, colour depth reduction, banding, chromatic
// aberration, vignette, saturation, interlace flicker, and CRT tint.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

// --- Depth of field ---
uniform bool dof_enabled = true;
// View-space distance at which blurring starts.
uniform float dof_focus_distance : hint_range(0.5, 50.0) = 8.0;
// Distance over which blur ramps from 0 to full strength.
uniform float dof_falloff : hint_range(0.1, 20.0) = 6.0;
// Maximum blur radius in UV units.
uniform float dof_blur_radius : hint_range(0.0, 0.02) = 0.006;

// --- Colour depth & dither ---
uniform float color_depth : hint_range(2.0, 8.0) = 5.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.6;

// --- Colour banding ---
uniform bool banding_enabled = true;
// Number of discrete luminance bands. Lower = more flat-shaded PS1 look.
uniform float banding_steps : hint_range(2.0, 32.0) = 8.0;
uniform float banding_strength : hint_range(0.0, 1.0) = 0.4;

// --- Chromatic aberration ---
uniform bool chromatic_enabled = true;
uniform float chromatic_aberration : hint_range(0.0, 0.02) = 0.004;

// --- Vignette ---
uniform bool vignette_enabled = true;
uniform float vignette_strength : hint_range(0.0, 2.0) = 0.8;
uniform float vignette_softness : hint_range(0.05, 1.5) = 0.4;

// --- Saturation ---
uniform bool saturation_enabled = true;
// >1 = oversaturated, <1 = washed out, 0 = greyscale.
uniform float saturation : hint_range(0.0, 2.0) = 1.3;

// --- Interlace flicker ---
uniform bool interlace_enabled = true;
// How much odd lines are dimmed to fake 480i composite.
uniform float interlace_strength : hint_range(0.0, 1.0) = 0.15;

// --- CRT colour tint ---
uniform bool tint_enabled = true;
uniform vec3 tint_color : source_color = vec3(1.05, 0.95, 0.88);

// 4x4 Bayer ordered dither matrix, normalised to [-0.5, 0.5].
float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int index = x + y * 4;
	float table[16] = float[](
		 0.0,  8.0,  2.0, 10.0,
		12.0,  4.0, 14.0,  6.0,
		 3.0, 11.0,  1.0,  9.0,
		15.0,  7.0, 13.0,  5.0
	);
	return (table[index] / 16.0) - 0.5;
}


void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 from_center = uv - vec2(0.5);

	// Depth of field: reconstruct linear view-space distance from depth buffer.
	float dof_blur = 0.0;
	if (dof_enabled) {
		float raw_depth = texture(depth_texture, uv).r;
		// Remap depth from [0,1] to NDC [-1,1] on Z, then unproject to view space.
		vec4 ndc = vec4(uv * 2.0 - 1.0, raw_depth * 2.0 - 1.0, 1.0);
		vec4 view_pos = INV_PROJECTION_MATRIX * ndc;
		float view_dist = -view_pos.z / view_pos.w;
		dof_blur = clamp((view_dist - dof_focus_distance) / max(dof_falloff, 0.001), 0.0, 1.0);
	}

	// Sample screen colour. When DOF is active, box-blur scaled by dof_blur.
	// Chromatic aberration offsets are applied per-channel on the blurred samples.
	vec3 col;
	float blur_r = dof_blur_radius * dof_blur;
	vec2 ca = chromatic_enabled ? from_center * chromatic_aberration : vec2(0.0);
	if (blur_r > 0.0) {
		vec3 acc = vec3(0.0);
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				vec2 off = vec2(float(dx), float(dy)) * blur_r;
				acc.r += texture(screen_texture, uv + ca + off).r;
				acc.g += texture(screen_texture, uv + off).g;
				acc.b += texture(screen_texture, uv - ca + off).b;
			}
		}
		col = acc / 9.0;
	} else if (chromatic_enabled) {
		col.r = texture(screen_texture, uv + ca).r;
		col.g = texture(screen_texture, uv).g;
		col.b = texture(screen_texture, uv - ca).b;
	} else {
		col = texture(screen_texture, uv).rgb;
	}

	// Saturation: push away from or toward luminance.
	if (saturation_enabled) {
		float luma = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(luma), col, saturation);
	}

	// Colour banding: posterise luminance into discrete steps then blend back.
	if (banding_enabled) {
		float luma = dot(col, vec3(0.299, 0.587, 0.114));
		float banded = floor(luma * banding_steps + 0.5) / banding_steps;
		float band_scale = banded / max(luma, 0.0001);
		col = mix(col, col * band_scale, banding_strength);
	}

	// Ordered Bayer dither + colour depth quantisation.
	float levels = pow(2.0, color_depth) - 1.0;
	float dither_offset = bayer4(floor(FRAGCOORD.xy)) / levels * dither_strength;
	vec3 dithered = col + vec3(dither_offset);
	col = floor(dithered * levels + 0.5) / levels;

	// Interlace: dim every other scanline to fake 480i composite output.
	if (interlace_enabled) {
		float line = mod(floor(FRAGCOORD.y), 2.0);
		col *= 1.0 - interlace_strength * line;
	}

	// CRT colour tint: multiply through a warm/cool colour cast.
	if (tint_enabled) {
		col *= tint_color;
	}

	// Vignette: darken corners like a CRT bezel shadow.
	if (vignette_enabled) {
		float vignette = smoothstep(vignette_softness, 0.0, length(from_center));
		col *= mix(1.0 - vignette_strength, 1.0, vignette);
	}

	ALBEDO = col;
}
