shader_type canvas_item;

// The three units share one material.  An instance uniform lets every Tango
// switch its own units without duplicating materials or touching SpriteFrames.
instance uniform float electric_surge_strength : hint_range(0.0, 1.0) = 0.0;

uniform vec3 surge_yellow : source_color = vec3(1.0, 0.78, 0.08);
uniform vec3 surge_highlight : source_color = vec3(1.0, 1.0, 0.76);
uniform float pulse_speed : hint_range(0.0, 20.0) = 8.0;


void fragment() {
	vec4 source = COLOR;
	float cyan_dominance = max(min(source.g, source.b) - source.r, 0.0);
	float energy_mask = smoothstep(0.045, 0.22, cyan_dominance);
	float pulse = sin(TIME * pulse_speed) * 0.5 + 0.5;
	vec3 energized = mix(surge_yellow, surge_highlight, pulse * 0.42);
	float replacement = electric_surge_strength * energy_mask;
	COLOR = vec4(mix(source.rgb, energized, replacement), source.a);
}
