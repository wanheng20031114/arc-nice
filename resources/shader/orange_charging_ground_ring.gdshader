shader_type canvas_item;
render_mode unshaded, blend_mix;

instance uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 environment_tint : source_color = vec4(1.0);
uniform float ripple_opacity : hint_range(0.0, 1.0) = 0.58;
uniform float night_emission_strength : hint_range(0.0, 4.0) = 1.42;
uniform vec4 night_emission_tint : source_color = vec4(1.0, 0.48, 0.08, 1.0);

varying float particle_phase;


void vertex() {
	particle_phase = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
}


void fragment() {
	vec2 centered = UV * 2.0 - vec2(1.0);
	float radial_distance = length(centered);
	float eased_phase = smoothstep(0.0, 1.0, particle_phase);
	float ring_radius = mix(0.18, 0.82, eased_phase);
	float ring_half_width = mix(0.11, 0.035, eased_phase);
	float edge_softness = mix(0.025, 0.012, eased_phase);
	float ring = 1.0 - smoothstep(
		ring_half_width,
		ring_half_width + edge_softness,
		abs(radial_distance - ring_radius)
	);
	float fade_in = smoothstep(0.0, 0.10, particle_phase);
	float fade_out = 1.0 - smoothstep(0.55, 1.0, particle_phase);
	vec4 source = COLOR;
	float alpha = source.a * ring * fade_in * fade_out * ripple_opacity;
	vec3 environment_color = source.rgb * environment_tint.rgb;
	vec3 emitted_color = source.rgb * night_emission_tint.rgb * night_emission_strength;
	vec3 final_color = mix(
		environment_color,
		max(environment_color, emitted_color),
		clamp(night_factor, 0.0, 1.0)
	);
	COLOR = vec4(final_color, alpha);
}
