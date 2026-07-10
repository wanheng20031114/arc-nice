shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform vec4 glow_tint : source_color = vec4(1.0, 0.88, 0.52, 1.0);
uniform float hdr_energy : hint_range(1.0, 3.0, 0.05) = 2.15;
uniform float tint_mix : hint_range(0.0, 0.5, 0.01) = 0.18;
uniform float core_alpha_start : hint_range(0.0, 1.0, 0.01) = 0.42;
uniform float core_alpha_end : hint_range(0.0, 1.0, 0.01) = 0.88;

void fragment() {
	vec4 color = COLOR;
	float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
	float alpha_core = smoothstep(core_alpha_start, core_alpha_end, color.a);
	float light_core = smoothstep(0.38, 0.92, luminance) * alpha_core;
	color.rgb = mix(color.rgb, glow_tint.rgb, tint_mix * light_core);
	color.rgb *= mix(1.0, hdr_energy, light_core);
	COLOR = color;
}
