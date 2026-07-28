shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D transition_noise : repeat_enable, filter_linear;
instance uniform float cover_progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 chamber_color : source_color = vec4(0.001, 0.003, 0.002, 1.0);
uniform vec4 growth_edge_color : source_color = vec4(0.22, 0.52, 0.34, 0.72);
uniform vec4 growth_core_color : source_color = vec4(0.94, 0.76, 0.36, 0.9);
uniform float growth_edge_width : hint_range(0.01, 0.16) = 0.045;


void fragment() {
	vec2 screen_uv = SCREEN_UV;
	float aspect = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 0.000001);
	vec2 noise_uv = vec2(screen_uv.x * aspect, screen_uv.y);

	float coarse_noise = texture(
		transition_noise,
		noise_uv * 1.45 + vec2(0.19, 0.41)
	).r - 0.5;
	float detail_noise = texture(
		transition_noise,
		noise_uv * 4.1 + vec2(0.67, 0.23)
	).r - 0.5;
	float root_wave = sin(
		(noise_uv.x * 5.6 + noise_uv.y * 3.1 + coarse_noise * 1.7)
		* 6.2831853
	);
	float root_tendril = pow(max(root_wave, 0.0), 2.3);

	float horizontal_edge_depth = min(screen_uv.x, 1.0 - screen_uv.x) * aspect;
	float vertical_edge_depth = min(screen_uv.y, 1.0 - screen_uv.y);
	float edge_depth = clamp(
		min(horizontal_edge_depth, vertical_edge_depth) * 2.0,
		0.0,
		1.0
	);
	float organic_depth = (
		edge_depth
		+ coarse_noise * 0.14
		+ detail_noise * 0.045
		- root_tendril * 0.026
	);

	float threshold = mix(-0.24, 1.24, cover_progress);
	float coverage = 1.0 - smoothstep(
		threshold - 0.032,
		threshold + 0.032,
		organic_depth
	);
	float front_distance = abs(organic_depth - threshold);
	float front_glow = 1.0 - smoothstep(
		growth_edge_width * 0.32,
		growth_edge_width,
		front_distance
	);
	float front_core = 1.0 - smoothstep(
		growth_edge_width * 0.08,
		growth_edge_width * 0.34,
		front_distance
	);
	float front_active = step(0.005, cover_progress);
	front_active *= 1.0 - step(0.995, cover_progress);
	front_glow *= front_active;
	front_core *= front_active;

	float front_alpha = clamp(
		front_glow * growth_edge_color.a
		+ front_core * growth_core_color.a,
		0.0,
		1.0
	);
	vec3 front_color = mix(
		growth_edge_color.rgb,
		growth_core_color.rgb,
		front_core
	);
	vec3 color = mix(chamber_color.rgb, front_color, front_alpha);
	float alpha = max(coverage * chamber_color.a, front_alpha);
	COLOR = vec4(color, alpha);
}
