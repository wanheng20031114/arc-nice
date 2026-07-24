shader_type canvas_item;
render_mode unshaded, blend_add;

// Calculation stays in the tower script. This material only draws a soft,
// colorful world-space rain curtain over the configured circular range.
instance uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
instance uniform float rain_seed = 0.0;

uniform vec4 blue_color : source_color = vec4(0.35, 0.72, 1.0, 1.0);
uniform vec4 violet_color : source_color = vec4(0.55, 0.32, 1.0, 1.0);
uniform vec4 pink_color : source_color = vec4(1.0, 0.48, 0.92, 1.0);
uniform vec4 white_violet_color : source_color = vec4(0.9, 0.86, 1.0, 1.0);


float hash21(vec2 value) {
	value = fract(value * vec2(123.34, 456.21));
	value += dot(value, value + 45.32);
	return fract(value.x * value.y);
}


vec3 pick_hydrangea_color(float selector) {
	if (selector < 0.25) {
		return blue_color.rgb;
	}
	if (selector < 0.5) {
		return violet_color.rgb;
	}
	if (selector < 0.75) {
		return pink_color.rgb;
	}
	return white_violet_color.rgb;
}


void fragment() {
	vec2 centered = UV * 2.0 - vec2(1.0);
	float radial_distance = length(centered);
	float circle_mask = 1.0 - smoothstep(0.82, 1.0, radial_distance);

	float time_offset = TIME * 1.65;
	vec2 rain_grid = vec2(
		UV.x * 38.0 + sin(TIME * 0.37) * 0.35,
		(UV.y - time_offset) * 24.0
	);
	vec2 rain_cell = floor(rain_grid);
	vec2 rain_local = fract(rain_grid) - vec2(0.5);
	float drop_exists_random = hash21(
		rain_cell + vec2(rain_seed, rain_seed * 1.73)
	);
	float drop_color_random = hash21(
		rain_cell.yx + vec2(91.37 + rain_seed * 2.11, 17.53)
	);
	float drop_exists = step(0.66, drop_exists_random);
	float narrow_body = 1.0 - smoothstep(0.035, 0.095, abs(rain_local.x));
	float short_body = 1.0 - smoothstep(0.12, 0.42, abs(rain_local.y));
	float rain_drop = drop_exists * narrow_body * short_body;

	float ring_distance = abs(radial_distance - 0.78);
	float edge_ring = 1.0 - smoothstep(0.012, 0.045, ring_distance);
	float ground_aura = pow(max(1.0 - radial_distance, 0.0), 2.2);
	float pulse = 0.92 + sin(TIME * 2.1) * 0.08;
	vec3 drop_color = pick_hydrangea_color(drop_color_random);
	vec3 aura_color = mix(blue_color.rgb, violet_color.rgb, 0.58);
	vec3 final_color = (
		drop_color * rain_drop * 1.25
		+ aura_color * edge_ring * 0.22
		+ pink_color.rgb * ground_aura * 0.085 * pulse
	);
	float alpha = (
		rain_drop * 0.78
		+ edge_ring * 0.18
		+ ground_aura * 0.08
	) * circle_mask * rain_intensity;
	COLOR = vec4(final_color * circle_mask * rain_intensity, alpha);
}
