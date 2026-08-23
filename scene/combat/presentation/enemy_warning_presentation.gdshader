shader_type canvas_item;
render_mode unshaded;

uniform int warning_family = 0;

varying vec4 warning_data;

void vertex() {
	warning_data = INSTANCE_CUSTOM;
}

float ring_band(float radius, float center, float half_width) {
	return 1.0 - smoothstep(half_width, half_width + 0.012, abs(radius - center));
}

void fragment() {
	vec2 point = (UV - vec2(0.5)) * 2.0;
	float progress = clamp(warning_data.r, 0.0, 1.0);
	vec4 color = vec4(0.0);
	if (warning_family == 0) {
		float radius = length(point);
		float outer_radius = max(warning_data.b, 1.0);
		float primary = mix(27.0, 17.0, progress) / outer_radius;
		float chain = warning_data.g;
		float angle = atan(point.y, point.x);
		float primary_dash = step(0.28, abs(sin(angle * 4.0)));
		float chain_dash = step(0.55, abs(sin(angle * 2.0 + 0.8)));
		float pulse = 0.86 + 0.14 * (0.5 + 0.5 * sin(progress * 12.56637));
		float primary_alpha = ring_band(radius, primary, 2.0 / outer_radius)
			* primary_dash * mix(0.42, 0.92, progress) * pulse;
		float chain_alpha = ring_band(radius, chain, 1.0 / outer_radius)
			* chain_dash * mix(0.10, 0.17, progress) * pulse;
		vec3 gold = vec3(1.0, 0.82, 0.12);
		vec3 cyan = vec3(0.56, 1.0, 0.96);
		color = vec4(mix(gold, cyan, step(0.0, sin(angle * 4.0))), max(primary_alpha, chain_alpha));
	} else if (warning_family == 1) {
		float edge = 1.0 - smoothstep(0.22, 0.5, abs(point.y));
		float longitudinal = smoothstep(-1.0, -0.92, point.x) * (1.0 - smoothstep(0.92, 1.0, point.x));
		float pulse = mix(0.14, 0.38, progress) * (0.82 + 0.18 * sin(progress * 18.84956));
		color = vec4(1.0, 0.05, 0.03, edge * longitudinal * pulse);
	} else {
		float radius = length(point);
		float band = ring_band(radius, 0.75, 0.045);
		float angle = atan(point.y, point.x) + 1.5707963;
		float normalized_angle = fract(angle / 6.2831853 + 1.0);
		float foreground = step(normalized_angle, progress);
		vec3 background = vec3(0.24, 0.04, 0.02);
		vec3 foreground_color = vec3(1.0, 0.2, 0.08);
		color = vec4(mix(background, foreground_color, foreground), band * mix(0.5, 0.9, foreground));
	}
	COLOR = color;
}
