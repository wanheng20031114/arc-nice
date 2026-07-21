shader_type canvas_item;

// Keep the standard per-instance plant lifecycle contract so the glow follows
// the exact same construction reveal and removal dissolve as the body sprite.
instance uniform float construction_progress : hint_range(0.0, 1.0) = 1.0;
instance uniform float construction_front_strength : hint_range(0.0, 1.0) = 0.0;
instance uniform bool removal_enabled = false;
instance uniform float removal_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float effect_top_y = 0.0;
instance uniform float effect_bottom_y = 1.0;
instance uniform vec2 noise_offset = vec2(0.0);

uniform sampler2D lifecycle_noise : repeat_enable, filter_nearest;
uniform vec4 glow_color : source_color = vec4(0.52, 1.08, 0.18, 1.0);
uniform float glow_core_strength : hint_range(0.0, 1.0) = 0.30;
uniform float glow_halo_strength : hint_range(0.0, 0.25) = 0.05;
uniform float glow_halo_alpha : hint_range(0.0, 0.25) = 0.045;
uniform float glow_pulse_amount : hint_range(0.0, 0.02) = 0.006;
uniform float glow_pulse_speed : hint_range(0.0, 4.0) = 0.85;
// Split sprites keep emissive pixels on both layers. Only the back layer paints
// the soft halo into transparent texels, preventing a doubled full-canvas glow.
uniform float transparent_halo_weight : hint_range(0.0, 1.0) = 1.0;

varying vec2 lifecycle_world_position;
varying float glow_pulse;


float small_light_core(vec2 pixel_position, vec2 center) {
	float distance_to_center = max(
		abs(pixel_position.x - center.x),
		abs(pixel_position.y - center.y)
	);
	return 1.0 - step(2.0, distance_to_center);
}


float small_light_profile(vec2 pixel_position, vec2 center) {
	float distance_to_center = max(
		abs(pixel_position.x - center.x),
		abs(pixel_position.y - center.y)
	);
	return 1.0 - smoothstep(1.75, 4.25, distance_to_center);
}


float panel_core(vec2 pixel_position) {
	vec2 normalized_distance = abs(
		pixel_position - vec2(32.5, 52.5)
	) / vec2(4.6, 3.6);
	return 1.0 - step(
		1.0,
		max(normalized_distance.x, normalized_distance.y)
	);
}


float panel_profile(vec2 pixel_position) {
	vec2 outside_distance = max(
		abs(pixel_position - vec2(32.5, 52.5)) - vec2(4.6, 3.6),
		vec2(0.0)
	);
	return 1.0 - smoothstep(
		0.0,
		2.5,
		max(outside_distance.x, outside_distance.y)
	);
}


void vertex() {
	// Keep the static 64×64 sprite on the logical canvas pixel grid.
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);

	lifecycle_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	glow_pulse = 1.0 + glow_pulse_amount * sin(
		TIME * glow_pulse_speed + noise_offset.x * 6.28318530718
	);
}


void fragment() {
	// COLOR already contains the texture sample and node modulation.
	vec4 result = COLOR;
	vec2 pixel_position = UV * vec2(64.0);

	float small_core = max(
		max(
			small_light_core(pixel_position, vec2(32.0, 12.0)),
			small_light_core(pixel_position, vec2(10.0, 32.0))
		),
		max(
			small_light_core(pixel_position, vec2(54.0, 32.0)),
			small_light_core(pixel_position, vec2(22.0, 40.0))
		)
	);
	float small_profile = max(
		max(
			small_light_profile(pixel_position, vec2(32.0, 12.0)),
			small_light_profile(pixel_position, vec2(10.0, 32.0))
		),
		max(
			small_light_profile(pixel_position, vec2(54.0, 32.0)),
			small_light_profile(pixel_position, vec2(22.0, 40.0))
		)
	);
	float authored_core = max(small_core, panel_core(pixel_position));
	float authored_profile = max(
		small_profile,
		panel_profile(pixel_position)
	);
	float authored_halo = max(authored_profile - authored_core, 0.0);
	float transparent_halo_gate = max(
		step(0.01, result.a),
		transparent_halo_weight
	);

	float green_dominance = result.g - max(result.r, result.b);
	float green_surface = (
		smoothstep(0.01, 0.16, green_dominance)
		* step(0.01, result.a)
	);
	float bright_surface = (
		smoothstep(0.68, 0.98, max(result.r, max(result.g, result.b)))
		* result.a
		* 0.16
	);
	float emissive_surface = max(green_surface, bright_surface);
	vec3 active_glow = glow_color.rgb * glow_pulse;
	result.rgb += active_glow * (
		authored_core * emissive_surface * glow_core_strength
		+ authored_halo * glow_halo_strength * transparent_halo_gate
	);
	result.a = max(
		result.a,
		authored_halo * glow_halo_alpha * glow_color.a
			* transparent_halo_gate
	);

	float build_progress = clamp(construction_progress, 0.0, 1.0);
	float front_strength = clamp(construction_front_strength, 0.0, 1.0);
	if (build_progress < 0.9999 || front_strength > 0.0001) {
		float top_y = min(effect_top_y, effect_bottom_y);
		float bottom_y = max(effect_top_y, effect_bottom_y);
		float build_front_y = mix(bottom_y, top_y, build_progress);
		float revealed = step(build_front_y, lifecycle_world_position.y);
		float front_distance = abs(
			lifecycle_world_position.y - build_front_y
		);
		float build_front = 1.0 - smoothstep(
			0.35,
			1.65,
			front_distance
		);
		build_front *= front_strength;
		result.rgb = mix(result.rgb, vec3(3.2), build_front * 0.92);
		result.a *= max(revealed, build_front);
	}

	if (removal_enabled) {
		vec2 noise_uv = (
			lifecycle_world_position / 64.0 + noise_offset
		);
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
		result.rgb = mix(
			result.rgb,
			vec3(1.15, 1.18, 1.12),
			dissolve_edge * 0.9
		);
		result.a *= keep_pixel;
	}

	COLOR = result;
}
