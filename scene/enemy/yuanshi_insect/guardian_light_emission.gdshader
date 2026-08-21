shader_type canvas_item;
render_mode unshaded, blend_add;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec3 light_color = vec3(0.22, 0.72, 1.0);
uniform float day_energy = 0.74;
uniform float compatibility_night_energy = 0.678;
uniform float linear_night_energy = 0.45;
uniform vec4 canvas_modulate_color : source_color = vec4(1.0);
uniform float night_factor = 0.0;
uniform float linear_color_space = 0.0;

void fragment() {
	vec4 light_sample = texture(TEXTURE, UV);
	// This grayscale light texture mirrors its intensity into alpha. Sampling
	// alpha twice preserves PointLight2D's RGB × alpha falloff without the
	// renderer-dependent sRGB conversion applied to Sprite2D RGB channels.
	float radial_intensity = light_sample.a * light_sample.a;
	vec3 receiver_color = texture(screen_texture, SCREEN_UV).rgb;
	vec3 receiver_albedo = receiver_color / max(
		canvas_modulate_color.rgb,
		vec3(1.0 / 255.0)
	);
	float night_energy = mix(
		compatibility_night_energy,
		linear_night_energy,
		linear_color_space
	);
	float calibrated_energy = mix(
		day_energy,
		night_energy,
		night_factor
	);
	COLOR = vec4(
		receiver_albedo * light_color * radial_intensity * calibrated_energy,
		1.0
	);
}
