shader_type canvas_item;
render_mode unshaded, blend_mix;

instance uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 environment_tint : source_color = vec4(1.0);
uniform float night_emission_strength : hint_range(0.0, 4.0) = 1.45;
uniform vec4 night_emission_tint : source_color = vec4(0.82, 0.72, 1.0, 1.0);


void fragment() {
	vec4 source = COLOR;
	vec3 environment_color = source.rgb * environment_tint.rgb;
	vec3 emitted_color = (
		source.rgb
		* night_emission_tint.rgb
		* night_emission_strength
	);
	vec3 final_color = mix(
		environment_color,
		max(environment_color, emitted_color),
		clamp(night_factor, 0.0, 1.0)
	);
	COLOR = vec4(final_color, source.a);
}
