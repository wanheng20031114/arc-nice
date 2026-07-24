shader_type canvas_item;
render_mode unshaded, blend_add;

// Calculation stays in the tower script. Individual falling drops and impact
// ripples are native GPU particles; this material only marks their wet range.
instance uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
instance uniform float rain_seed = 0.0;

uniform vec4 blue_color : source_color = vec4(0.35, 0.72, 1.0, 1.0);
uniform vec4 violet_color : source_color = vec4(0.55, 0.32, 1.0, 1.0);
uniform vec4 pink_color : source_color = vec4(1.0, 0.48, 0.92, 1.0);
uniform vec4 white_violet_color : source_color = vec4(0.9, 0.86, 1.0, 1.0);


void fragment() {
	vec2 centered = UV * 2.0 - vec2(1.0);
	float radial_distance = length(centered);
	float circle_mask = 1.0 - smoothstep(0.9, 1.0, radial_distance);
	float ring_distance = abs(radial_distance - 0.78);
	float edge_ring = 1.0 - smoothstep(0.012, 0.045, ring_distance);
	float ground_aura = pow(max(1.0 - radial_distance, 0.0), 2.2);
	float pulse = 0.94 + sin(TIME * 2.1 + rain_seed * 6.2831853) * 0.06;
	vec3 aura_color = mix(blue_color.rgb, violet_color.rgb, 0.58);
	vec3 inner_color = mix(pink_color.rgb, white_violet_color.rgb, 0.42);
	vec3 final_color = (
		aura_color * edge_ring * 0.2
		+ inner_color * ground_aura * 0.07 * pulse
	);
	float alpha = (
		edge_ring * 0.15
		+ ground_aura * 0.06
	) * circle_mask * rain_intensity;
	COLOR = vec4(final_color * circle_mask * rain_intensity, alpha);
}
