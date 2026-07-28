shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D scene_before_overlay : hint_screen_texture, repeat_disable, filter_nearest;
uniform sampler2D reveal_noise : repeat_enable, filter_linear;
instance uniform float reveal_progress : hint_range(0.0, 1.0) = 1.0;
uniform vec4 growth_edge_color : source_color = vec4(0.14, 0.145, 0.15, 0.2);
uniform vec4 growth_core_color : source_color = vec4(0.56, 0.57, 0.58, 0.3);
uniform float growth_edge_width : hint_range(0.01, 0.12) = 0.02;


void fragment() {
	vec2 screen_uv = SCREEN_UV;
	float aspect = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 0.000001);
	vec2 noise_uv = vec2(screen_uv.x * aspect, screen_uv.y);

	float coarse_noise = texture(
		reveal_noise,
		noise_uv * 1.35 + vec2(0.13, 0.37)
	).r - 0.5;
	float detail_noise = texture(
		reveal_noise,
		noise_uv * 3.8 + vec2(0.61, 0.19)
	).r - 0.5;
	float tendril_wave = sin(
		(noise_uv.x * 5.2 + noise_uv.y * 2.8 + coarse_noise * 1.8)
		* 6.2831853
	);
	float tendril = pow(max(tendril_wave, 0.0), 2.0);

	float horizontal_edge_depth = min(screen_uv.x, 1.0 - screen_uv.x) * aspect;
	float vertical_edge_depth = min(screen_uv.y, 1.0 - screen_uv.y);
	float edge_depth = clamp(
		min(horizontal_edge_depth, vertical_edge_depth) * 2.0,
		0.0,
		1.0
	);
	float organic_depth = (
		edge_depth
		+ coarse_noise * 0.16
		+ detail_noise * 0.055
		- tendril * 0.022
	);

	float threshold = mix(-0.18, 1.18, reveal_progress);
	float revealed = 1.0 - smoothstep(
		threshold - 0.028,
		threshold + 0.028,
		organic_depth
	);
	float cover_alpha = 1.0 - revealed;
	float growth_front_glow = 1.0 - smoothstep(
		growth_edge_width * 0.35,
		growth_edge_width,
		abs(organic_depth - threshold)
	);
	float growth_front_core = 1.0 - smoothstep(
		growth_edge_width * 0.08,
		growth_edge_width * 0.34,
		abs(organic_depth - threshold)
	);
	float growth_front_active = step(0.005, reveal_progress);
	growth_front_active *= 1.0 - step(0.995, reveal_progress);
	growth_front_glow *= growth_front_active;
	growth_front_core *= growth_front_active;

	vec3 previous_scene = textureLod(
		scene_before_overlay,
		screen_uv,
		0.0
	).rgb;
	float growth_front_alpha = clamp(
		growth_front_glow * growth_edge_color.a
		+ growth_front_core * growth_core_color.a,
		0.0,
		1.0
	);
	vec3 growth_front_color = mix(
		growth_edge_color.rgb,
		growth_core_color.rgb,
		growth_front_core
	);
	vec3 reveal_color = mix(
		previous_scene,
		growth_front_color,
		growth_front_alpha
	);
	float reveal_alpha = max(
		cover_alpha,
		growth_front_alpha
	);
	COLOR = vec4(reveal_color, reveal_alpha);
}
