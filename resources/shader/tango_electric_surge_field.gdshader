shader_type canvas_item;
render_mode unshaded, blend_add;

// One analytic draw keeps the eight-second field cheap even when several Tango
// players overlap their zones.  The authored quad extends beyond the gameplay
// circle so only the faint halo spills outside the exact 72-pixel radius.
instance uniform float surge_seed = 0.0;

uniform vec4 field_color : source_color = vec4(0.08, 0.82, 0.92, 1.0);
uniform vec4 arc_color : source_color = vec4(0.48, 1.0, 0.96, 1.0);
uniform vec4 core_color : source_color = vec4(0.82, 1.0, 1.0, 1.0);
uniform float gameplay_radius_ratio : hint_range(0.1, 1.0) = 0.75;
uniform float animation_speed : hint_range(0.0, 4.0) = 0.72;


void fragment() {
	vec2 centered = UV * 2.0 - vec2(1.0);
	float radial_distance = length(centered);
	float safe_radius = max(gameplay_radius_ratio, 0.001);
	float normalized_radius = radial_distance / safe_radius;
	float time_phase = TIME * animation_speed + surge_seed * 6.2831853;

	float gameplay_mask = 1.0 - smoothstep(0.965, 1.015, normalized_radius);
	float soft_halo = smoothstep(0.76, 0.98, normalized_radius) * (
		1.0 - smoothstep(0.98, 1.27, normalized_radius)
	);
	float boundary = 1.0 - smoothstep(
		0.012,
		0.055,
		abs(normalized_radius - 0.985)
	);

	// A phase that subtracts time moves equal-phase rings away from the center.
	float wave_phase = fract(
		normalized_radius * 2.55 - time_phase * 0.56
	);
	float outward_wave = 1.0 - smoothstep(
		0.035,
		0.13,
		abs(wave_phase - 0.5)
	);
	outward_wave *= gameplay_mask;
	outward_wave *= smoothstep(0.08, 0.28, normalized_radius);

	float angle = atan(centered.y, centered.x);
	float arc_noise = sin(
		angle * 11.0
		+ normalized_radius * 31.0
		- time_phase * 3.1
		+ surge_seed * 17.0
	) * 0.5 + 0.5;
	float broken_arcs = smoothstep(0.78, 0.98, arc_noise);
	broken_arcs *= outward_wave;

	float center_falloff = pow(
		max(1.0 - normalized_radius, 0.0),
		2.2
	);
	float pulse = 0.88 + sin(time_phase * 2.2) * 0.12;
	float alpha = (
		center_falloff * 0.035 * pulse
		+ outward_wave * 0.12
		+ broken_arcs * 0.09
		+ boundary * 0.38
		+ soft_halo * 0.045
	);
	// Keep the exact 72-pixel edge readable on busy daytime terrain while the
	// overlapping waves remain transparent enough to preserve combat clarity.
	alpha = min(alpha, 0.46);
	vec3 color = mix(field_color.rgb, arc_color.rgb, outward_wave * 0.68);
	color = mix(color, core_color.rgb, broken_arcs * 0.58 + boundary * 0.18);
	COLOR = vec4(color, alpha);
}
