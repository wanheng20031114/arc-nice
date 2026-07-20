shader_type canvas_item;

instance uniform float construction_progress : hint_range(0.0, 1.0) = 1.0;
instance uniform float construction_front_strength : hint_range(0.0, 1.0) = 0.0;
instance uniform bool removal_enabled = false;
instance uniform float removal_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float effect_top_y = 0.0;
instance uniform float effect_bottom_y = 1.0;
instance uniform vec2 noise_offset = vec2(0.0);

uniform sampler2D lifecycle_noise : repeat_enable, filter_nearest;
uniform vec4 glow_color : source_color = vec4(0.30, 0.90, 1.18, 1.0);
uniform float glow_core_strength : hint_range(0.0, 1.0) = 0.22;
uniform float glow_halo_strength : hint_range(0.0, 0.25) = 0.04;
uniform float glow_halo_alpha : hint_range(0.0, 0.25) = 0.035;
uniform float glow_pulse_amount : hint_range(0.0, 0.02) = 0.004;
uniform float glow_pulse_speed : hint_range(0.0, 4.0) = 0.72;

varying vec2 lifecycle_world_position;
varying float glow_pulse;


float square_distance(vec2 pixel_position, vec2 center) {
	return max(
		abs(pixel_position.x - center.x),
		abs(pixel_position.y - center.y)
	);
}


float hotspot_core(
	vec2 pixel_position,
	vec2 center,
	float half_extent
) {
	return 1.0 - step(
		half_extent,
		square_distance(pixel_position, center)
	);
}


float hotspot_profile(
	vec2 pixel_position,
	vec2 center,
	float inner_extent,
	float outer_extent
) {
	return 1.0 - smoothstep(
		inner_extent,
		outer_extent,
		square_distance(pixel_position, center)
	);
}


void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);

	lifecycle_world_position = (
		MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)
	).xy;
	glow_pulse = 1.0 + glow_pulse_amount * sin(
		TIME * glow_pulse_speed + noise_offset.x * 6.28318530718
	);
}


void fragment() {
	vec4 result = COLOR;
	vec2 pixel_position = UV * vec2(64.0);

	float authored_core = max(
		hotspot_core(
			pixel_position,
			vec2(50.5, 25.7),
			1.55
		),
		max(
			hotspot_core(
				pixel_position,
				vec2(13.25, 51.1),
				2.05
			),
			hotspot_core(
				pixel_position,
				vec2(51.0, 50.7),
				2.05
			)
		)
	);
	float authored_profile = max(
		hotspot_profile(
			pixel_position,
			vec2(50.5, 25.7),
			1.3,
			3.8
		),
		max(
			hotspot_profile(
				pixel_position,
				vec2(13.25, 51.1),
				1.8,
				4.4
			),
			hotspot_profile(
				pixel_position,
				vec2(51.0, 50.7),
				1.8,
				4.4
			)
		)
	);
	float authored_halo = max(authored_profile - authored_core, 0.0);
	float blue_surface = (
		smoothstep(0.08, 0.36, result.b - result.r)
		* smoothstep(0.16, 0.72, result.b)
		* result.a
	);
	vec3 active_glow = glow_color.rgb * glow_pulse;
	result.rgb += active_glow * (
		authored_core * blue_surface * glow_core_strength
		+ authored_halo * blue_surface * glow_halo_strength
	);
	result.a = max(
		result.a,
		authored_halo * glow_halo_alpha * glow_color.a
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
		result.rgb = mix(
			result.rgb,
			vec3(3.2),
			build_front * 0.92
		);
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
		result.rgb = mix(
			result.rgb,
			vec3(1.15, 1.18, 1.12),
			dissolve_edge * 0.9
		);
		result.a *= keep_pixel;
	}

	COLOR = result;
}
