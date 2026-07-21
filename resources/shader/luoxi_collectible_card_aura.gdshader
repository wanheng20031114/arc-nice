shader_type canvas_item;
render_mode unshaded, blend_mix;

instance uniform vec4 rarity_color : source_color = vec4(0.94, 0.96, 1.0, 1.0);
instance uniform float aura_strength : hint_range(0.0, 1.0, 0.01) = 0.02;
instance uniform float reveal_power : hint_range(0.0, 2.0, 0.01) = 0.08;
instance uniform float reveal_progress : hint_range(0.0, 1.0, 0.001) = 0.0;
instance uniform float time_offset = 0.0;


float airy_wave(vec2 uv, float time) {
	float first_veil = sin(
		uv.x * 13.0
		+ sin(uv.y * 8.0 - time * 1.15) * 2.4
		+ time * 1.75
	);
	float second_veil = sin(
		uv.y * 16.0
		- cos(uv.x * 7.0 + time * 0.72) * 2.1
		- time * 1.28
	);
	return smoothstep(0.46, 0.96, first_veil * 0.5 + second_veil * 0.25 + 0.75);
}


void fragment() {
	vec4 base_color = texture(TEXTURE, UV) * COLOR;
	vec2 centered_uv = UV * 2.0 - vec2(1.0);
	float time = TIME + time_offset;
	float edge_distance = min(
		min(UV.x, 1.0 - UV.x),
		min(UV.y, 1.0 - UV.y)
	);
	float inner_rim = 1.0 - smoothstep(0.0, 0.13, edge_distance);
	float breathing = 0.82 + sin(time * 1.7) * 0.18;
	float mist = airy_wave(UV, time) * (
		1.0 - smoothstep(0.2, 1.18, length(centered_uv))
	);

	float active_reveal = step(0.0001, reveal_progress) * step(reveal_progress, 0.9999);
	float reveal_envelope = sin(clamp(reveal_progress, 0.0, 1.0) * 3.14159265);
	float reveal_radius = mix(0.08, 1.25, reveal_progress);
	float reveal_ring = 1.0 - smoothstep(
		0.035,
		0.19,
		abs(length(centered_uv) - reveal_radius)
	);
	float vertical_veil = airy_wave(
		UV + vec2(0.0, reveal_progress * 0.24),
		time * 1.35
	);
	float reveal_light = (
		reveal_ring * 1.35
		+ vertical_veil * 0.62
		+ inner_rim * 0.48
	) * reveal_envelope * active_reveal * reveal_power;

	float persistent_light = (
		inner_rim * (0.72 + breathing * 0.3)
		+ mist * (0.2 + breathing * 0.16)
	) * aura_strength;
	vec3 light_color = rarity_color.rgb * (persistent_light + reveal_light);
	vec3 final_rgb = base_color.rgb + light_color * (1.0 - base_color.rgb * 0.34);
	COLOR = vec4(final_rgb, base_color.a);
}
