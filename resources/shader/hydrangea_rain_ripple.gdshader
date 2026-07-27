shader_type canvas_item;
render_mode unshaded, blend_mix;

// GPUParticles2D writes normalized lifetime progress into INSTANCE_CUSTOM.y.
// Each sub-particle therefore expands one procedural circular water ripple.
uniform float visible_ratio : hint_range(0.0, 1.0) = 0.18;
uniform float ripple_opacity : hint_range(0.0, 1.0) = 0.52;
varying float particle_phase;
varying float particle_selector;


void vertex() {
	particle_phase = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	particle_selector = fract(INSTANCE_CUSTOM.z);
}


void fragment() {
	if (particle_selector >= visible_ratio) {
		discard;
	}
	vec2 centered = UV * 2.0 - vec2(1.0);
	float radial_distance = length(centered);
	float eased_phase = smoothstep(0.0, 1.0, particle_phase);
	float ring_radius = mix(0.12, 0.72, eased_phase);
	float ring_half_width = mix(0.14, 0.045, eased_phase);
	float edge_softness = mix(0.03, 0.015, eased_phase);
	float ring = 1.0 - smoothstep(
		ring_half_width,
		ring_half_width + edge_softness,
		abs(radial_distance - ring_radius)
	);
	float fade_in = smoothstep(0.0, 0.08, particle_phase);
	float fade_out = 1.0 - smoothstep(0.35, 1.0, particle_phase);
	vec4 particle_color = COLOR;
	float alpha = particle_color.a * ring * fade_in * fade_out * ripple_opacity;
	COLOR = vec4(particle_color.rgb, alpha);
}
