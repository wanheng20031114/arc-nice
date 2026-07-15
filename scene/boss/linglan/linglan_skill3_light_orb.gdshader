shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.78, 0.18);
instance uniform float pulse = 1.0;
uniform bool gpu_pulse_enabled = false;
uniform float gpu_pulse_frequency = 3.5;
uniform float gpu_pulse_min = 0.9;
uniform float gpu_pulse_max = 1.12;
instance uniform float gpu_pulse_phase = 0.0;
uniform float inner_radius = 0.0;
uniform float outer_softness = 1.0;
uniform float fill_strength = 1.0;
uniform float ring_radius = 0.0;
uniform float ring_width = 0.0;
uniform float ring_strength = 0.0;

varying vec2 local_unit_position;
varying float resolved_pulse;

void vertex() {
	local_unit_position = VERTEX;
	resolved_pulse = pulse;
	if (gpu_pulse_enabled) {
		float wave = (sin(TIME * 6.28318530718 * gpu_pulse_frequency + gpu_pulse_phase) + 1.0) * 0.5;
		resolved_pulse = mix(gpu_pulse_min, gpu_pulse_max, wave);
	}
}

void fragment() {
	float distance_from_center = length(local_unit_position);
	float radial_alpha = 1.0 - smoothstep(inner_radius, outer_softness, distance_from_center);
	float ring_alpha = 0.0;
	if (ring_strength > 0.0 && ring_width > 0.0) {
		float distance_to_ring = abs(distance_from_center - ring_radius);
		ring_alpha = (1.0 - smoothstep(0.0, ring_width, distance_to_ring)) * ring_strength;
	}
	float final_alpha = clamp((radial_alpha * fill_strength + ring_alpha) * tint.a * resolved_pulse, 0.0, 1.0);
	COLOR = vec4(tint.rgb, final_alpha);
}
