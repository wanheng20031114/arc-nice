shader_type canvas_item;
render_mode unshaded, blend_add;

uniform float ready_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec4 glow_color : source_color = vec4(0.08, 1.55, 1.35, 1.0);
uniform float glow_opacity : hint_range(0.0, 1.0) = 0.18;
uniform float pulse_speed : hint_range(0.0, 8.0) = 2.2;
uniform float pulse_amount : hint_range(0.0, 0.5) = 0.1;

void fragment() {
	vec2 centered_uv = UV * 2.0 - vec2(1.0);
	float ellipse_distance = length(centered_uv);
	float halo = 1.0 - smoothstep(0.08, 1.0, ellipse_distance);
	float core = 1.0 - smoothstep(0.0, 0.46, ellipse_distance);
	float floor_line = (1.0 - smoothstep(0.08, 0.34, abs(centered_uv.y - 0.18)))
		* (1.0 - smoothstep(0.68, 1.0, abs(centered_uv.x)));
	float pulse = 1.0 - pulse_amount + pulse_amount * (0.5 + 0.5 * sin(TIME * pulse_speed));
	float intensity = ready_strength * pulse * (halo * 0.68 + core * 0.22 + floor_line * 0.1);
	COLOR = vec4(glow_color.rgb * intensity, intensity * glow_opacity);
}
