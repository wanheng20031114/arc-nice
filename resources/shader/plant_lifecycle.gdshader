shader_type canvas_item;

// Lifecycle values are per CanvasItem so every visual belonging to one plant
// can share this material while still advancing as a single world-space wipe.
instance uniform float construction_progress : hint_range(0.0, 1.0) = 1.0;
instance uniform float construction_front_strength : hint_range(0.0, 1.0) = 0.0;
instance uniform bool removal_enabled = false;
instance uniform float removal_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float effect_top_y = 0.0;
instance uniform float effect_bottom_y = 1.0;
instance uniform vec2 noise_offset = vec2(0.0);

uniform sampler2D lifecycle_noise : repeat_enable, filter_nearest;

varying vec2 lifecycle_world_position;


void vertex() {
	// Keep a static plant drawable on the logical canvas pixel grid. Snapping
	// only the node origin preserves authored local offsets and sprite geometry.
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);

	lifecycle_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}


void fragment() {
	// CanvasItem's fragment COLOR already includes the default TEXTURE sample
	// and node modulation. Sampling TEXTURE again would square and darken it.
	vec4 result = COLOR;
	float build_progress = clamp(construction_progress, 0.0, 1.0);
	float front_strength = clamp(construction_front_strength, 0.0, 1.0);
	if (build_progress < 0.9999 || front_strength > 0.0001) {
		float top_y = min(effect_top_y, effect_bottom_y);
		float bottom_y = max(effect_top_y, effect_bottom_y);

		// Godot's 2D world Y grows downward, so the reveal front travels from the
		// bottom bound toward the top bound. A thin halo just ahead of the front is
		// allowed to show through, giving the emerging edge its white build glow.
		float build_front_y = mix(bottom_y, top_y, build_progress);
		float revealed = step(build_front_y, lifecycle_world_position.y);
		float front_distance = abs(lifecycle_world_position.y - build_front_y);
		float build_front = 1.0 - smoothstep(0.35, 1.65, front_distance);
		build_front *= front_strength;
		result.rgb = mix(result.rgb, vec3(3.2), build_front * 0.92);
		result.a *= max(revealed, build_front);
	}

	if (removal_enabled) {
		// One noise texel corresponds to roughly one world unit. The extended
		// threshold endpoints guarantee fully intact and fully dissolved states.
		vec2 noise_uv = lifecycle_world_position / 64.0 + noise_offset;
		float noise_value = texture(lifecycle_noise, noise_uv).r;
		float dissolve_threshold = mix(-0.08, 1.08, clamp(removal_progress, 0.0, 1.0));
		float remaining = noise_value - dissolve_threshold;
		float keep_pixel = step(0.0, remaining);
		float dissolve_edge = keep_pixel * (1.0 - smoothstep(0.0, 0.055, remaining));
		result.rgb = mix(result.rgb, vec3(1.15, 1.18, 1.12), dissolve_edge * 0.9);
		result.a *= keep_pixel;
	}

	COLOR = result;
}
