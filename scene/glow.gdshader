shader_type canvas_item;

uniform bool glow_enabled = false;
uniform vec4 glow_color : source_color = vec4(0.35, 0.85, 0.7, 1.0);
uniform float glow_speed : hint_range(0.5, 8.0) = 2.5;
uniform float glow_min : hint_range(0.0, 1.0) = 0.25;
uniform float glow_max : hint_range(0.0, 1.0) = 0.75;

void fragment() {
	vec4 color = texture(TEXTURE, UV) * COLOR;

	if (glow_enabled && color.a > 0.0) {
		float pulse = (sin(TIME * glow_speed) + 1.0) * 0.5;
		float intensity = mix(glow_min, glow_max, pulse);
		color.rgb = mix(color.rgb, glow_color.rgb, intensity);
	}

	COLOR = color;
}
