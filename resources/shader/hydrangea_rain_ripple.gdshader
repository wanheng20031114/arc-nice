shader_type canvas_item;
render_mode unshaded, blend_add;

// GPUParticles2D writes normalized lifetime progress into INSTANCE_CUSTOM.y.
// Each sub-particle therefore expands one procedural circular water ripple.
varying float particle_phase;


void vertex() {
	particle_phase = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
}


void fragment() {
	vec2 centered = UV * 2.0 - vec2(1.0);
	float radial_distance = length(centered);
	float eased_phase = smoothstep(0.0, 1.0, particle_phase);
	float ring_radius = mix(0.08, 0.82, eased_phase);
	float ring_half_width = mix(0.16, 0.035, eased_phase);
	float edge_softness = mix(0.035, 0.018, eased_phase);
	float ring = 1.0 - smoothstep(
		ring_half_width,
		ring_half_width + edge_softness,
		abs(radial_distance - ring_radius)
	);
	float fade_in = smoothstep(0.0, 0.08, particle_phase);
	float fade_out = 1.0 - smoothstep(0.48, 1.0, particle_phase);
	vec4 particle_color = COLOR;
	float alpha = particle_color.a * ring * fade_in * fade_out;
	COLOR = vec4(particle_color.rgb * 1.12, alpha);
}
