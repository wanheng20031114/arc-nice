shader_type canvas_item;
render_mode unshaded, blend_mix;

// The two responsibility layers share one clock.  Each sprite receives an
// instance offset derived from the tower's stable id, so many towers do not
// peak on the same rendered frame.
instance uniform float cycle_offset_seconds = 0.0;

// Keep the complete PlantDefense lifecycle contract on emissive overlays.
instance uniform float construction_progress : hint_range(0.0, 1.0) = 1.0;
instance uniform float construction_front_strength : hint_range(0.0, 1.0) = 0.0;
instance uniform bool removal_enabled = false;
instance uniform float removal_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float effect_top_y = 0.0;
instance uniform float effect_bottom_y = 1.0;
instance uniform vec2 noise_offset = vec2(0.0);
instance uniform float burn_overlay_strength : hint_range(0.0, 1.0) = 0.0;
instance uniform float bleed_overlay_strength : hint_range(0.0, 1.0) = 0.0;

uniform sampler2D lifecycle_noise : repeat_enable, filter_nearest;
uniform float visual_role : hint_range(0.0, 1.0) = 0.0;
uniform vec4 orange_emission : source_color = vec4(1.0, 0.34, 0.035, 1.0);
uniform vec4 glass_emission : source_color = vec4(1.0, 0.55, 0.12, 1.0);
uniform vec4 burn_overlay_color : source_color = vec4(1.0, 0.56, 0.18, 0.46);
uniform vec4 bleed_overlay_color : source_color = vec4(0.95, 0.02, 0.08, 0.58);

varying vec2 lifecycle_world_position;


void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
	lifecycle_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}


float authored_layer_from_y(float pixel_y) {
	// Source-space bands, ordered from bottom (0) to top (3).
	if (pixel_y >= 73.0 && pixel_y < 85.0) {
		return 0.0;
	}
	if (pixel_y >= 59.0 && pixel_y < 73.0) {
		return 1.0;
	}
	if (pixel_y >= 47.0 && pixel_y < 59.0) {
		return 2.0;
	}
	if (pixel_y >= 34.0 && pixel_y < 47.0) {
		return 3.0;
	}
	return -8.0;
}


float cycle_strength(out float active_layer) {
	const float LAYER_SECONDS = 0.80;
	float sequence_time = mod(TIME + cycle_offset_seconds, LAYER_SECONDS * 4.0);
	active_layer = floor(sequence_time / LAYER_SECONDS);
	float local_phase = mod(sequence_time, LAYER_SECONDS) / LAYER_SECONDS;
	float fade_in = smoothstep(0.0, 0.18, local_phase);
	float fade_out = 1.0 - smoothstep(0.56, 0.78, local_phase);
	// local_phase 0.78..1.0 is a deliberate black interval.  Therefore the
	// previous layer is fully off before the next layer can begin to rise.
	return fade_in * fade_out;
}


void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 result = COLOR;
	float active_layer = 0.0;
	float strength = cycle_strength(active_layer);
	float authored_layer = authored_layer_from_y(UV.y * 128.0);
	float layer_match = 1.0 - step(0.1, abs(authored_layer - active_layer));
	float is_glass = step(0.5, visual_role);
	float orange_strength = strength * layer_match * (1.0 - is_glass);
	// The whole pane catches a restrained glow while the pane beside the active
	// slice receives the strong band.  This remains readable in daylight.
	float glass_strength = strength * is_glass * (0.16 + layer_match * 0.84);
	float visible_strength = orange_strength + glass_strength;
	vec3 emission_color = mix(orange_emission.rgb, glass_emission.rgb, is_glass);

	result.rgb = result.rgb * (0.72 + visible_strength * 0.84);
	result.rgb += emission_color * visible_strength * mix(0.74, 0.92, is_glass);
	// The responsibility overlay reaches true zero alpha during its black gap;
	// the dormant orange/glass remains visible only through the static body.
	result.a *= clamp(visible_strength, 0.0, 1.0);

	if (burn_overlay_strength > 0.0 && texture_color.a > 0.0) {
		float burn_mix = burn_overlay_strength * burn_overlay_color.a;
		result.rgb = mix(result.rgb, burn_overlay_color.rgb, burn_mix);
	}
	if (bleed_overlay_strength > 0.0 && texture_color.a > 0.0) {
		float bleed_mix = bleed_overlay_strength * bleed_overlay_color.a;
		result.rgb = mix(result.rgb, bleed_overlay_color.rgb, bleed_mix);
	}

	float build_progress = clamp(construction_progress, 0.0, 1.0);
	float front_strength = clamp(construction_front_strength, 0.0, 1.0);
	if (build_progress < 0.9999 || front_strength > 0.0001) {
		float top_y = min(effect_top_y, effect_bottom_y);
		float bottom_y = max(effect_top_y, effect_bottom_y);
		float build_front_y = mix(bottom_y, top_y, build_progress);
		float revealed = step(build_front_y, lifecycle_world_position.y);
		float front_distance = abs(lifecycle_world_position.y - build_front_y);
		float build_front = 1.0 - smoothstep(0.35, 1.65, front_distance);
		build_front *= front_strength;
		result.rgb = mix(result.rgb, vec3(3.2), build_front * 0.92);
		result.a *= max(revealed, build_front);
	}

	if (removal_enabled) {
		vec2 noise_uv = lifecycle_world_position / 64.0 + noise_offset;
		float noise_value = texture(lifecycle_noise, noise_uv).r;
		float dissolve_threshold = mix(
			-0.08,
			1.08,
			clamp(removal_progress, 0.0, 1.0)
		);
		float remaining = noise_value - dissolve_threshold;
		float keep_pixel = step(0.0, remaining);
		float dissolve_edge = keep_pixel * (
			1.0 - smoothstep(0.0, 0.055, remaining)
		);
		result.rgb = mix(result.rgb, vec3(1.15, 1.18, 1.12), dissolve_edge * 0.9);
		result.a *= keep_pixel;
	}

	COLOR = result;
}
