shader_type canvas_item;
render_mode unshaded;

// INSTANCE_CUSTOM.r is authoritative projectile age in seconds. Static
// materials configure each family's authored atlas cadence.
uniform float frame_count : hint_range(1.0, 16.0, 1.0) = 3.0;
uniform float animation_fps : hint_range(0.0, 60.0, 0.1) = 16.0;
uniform float highlight_threshold : hint_range(0.0, 1.0) = 0.38;
uniform float highlight_softness : hint_range(0.001, 0.5) = 0.22;
uniform float emission_strength : hint_range(0.0, 2.0) = 0.58;
uniform vec4 emission_tint : source_color = vec4(1.0, 0.72, 0.28, 1.0);
uniform float quad_expansion : hint_range(1.0, 2.5) = 1.75;
uniform float halo_opacity : hint_range(0.0, 0.3) = 0.085;
varying float projectile_age_seconds;
varying vec4 projectile_modulate;

void vertex() {
	projectile_age_seconds = max(INSTANCE_CUSTOM.r, 0.0);
	// Capture the vertex/CanvasItem tint before Godot multiplies fragment COLOR
	// by the default texture sampled at the unmodified full-atlas UV.
	projectile_modulate = COLOR;
	VERTEX *= quad_expansion;
}

void fragment() {
	float safe_frame_count = max(frame_count, 1.0);
	float frame_index = mod(
		floor(projectile_age_seconds * animation_fps),
		safe_frame_count
	);
	vec2 source_local_uv = (
		(UV - vec2(0.5)) * quad_expansion + vec2(0.5)
	);
	float inside_source = (
		step(0.0, source_local_uv.x)
		* step(source_local_uv.x, 1.0)
		* step(0.0, source_local_uv.y)
		* step(source_local_uv.y, 1.0)
	);
	vec2 frame_half_texel = vec2(
		TEXTURE_PIXEL_SIZE.x * safe_frame_count * 0.5,
		TEXTURE_PIXEL_SIZE.y * 0.5
	);
	vec2 clipped_source_uv = clamp(
		source_local_uv,
		frame_half_texel,
		vec2(1.0) - frame_half_texel
	);
	vec2 atlas_uv = vec2(
		(clipped_source_uv.x + frame_index) / safe_frame_count,
		clipped_source_uv.y
	);
	vec4 source = (
		texture(TEXTURE, atlas_uv)
		* projectile_modulate
		* inside_source
	);
	float peak = max(source.r, max(source.g, source.b));
	float highlight = smoothstep(
		highlight_threshold - highlight_softness,
		highlight_threshold + highlight_softness,
		peak
	);
	vec3 tinted_source = (
		source.rgb * mix(vec3(1.0), emission_tint.rgb, 0.42)
	);
	float emission_gain = emission_strength * mix(0.24, 1.0, highlight);
	vec3 body_color = source.rgb + tinted_source * emission_gain;

	float halo_distance = length((UV - vec2(0.5)) * 2.0);
	float halo = 1.0 - smoothstep(0.18, 1.0, halo_distance);
	float halo_alpha = halo * halo_opacity * (1.0 - source.a);
	vec3 halo_color = emission_tint.rgb * 1.18;
	COLOR = vec4(
		mix(halo_color, body_color, source.a),
		max(source.a, halo_alpha)
	);
}
