shader_type canvas_item;
render_mode blend_add, unshaded;

uniform float luminance_threshold : hint_range(0.0, 1.0) = 0.52;
uniform float threshold_softness : hint_range(0.001, 0.5) = 0.14;
uniform float emission_strength : hint_range(0.0, 4.0) = 1.55;
uniform vec4 emission_tint : source_color = vec4(1.0);

void fragment() {
	// Fragment COLOR already contains the sampled texture and the CanvasItem's
	// modulate/self_modulate. Using it keeps pooled fades and inherited tinting
	// synchronized with the visible sprite.
	vec4 source = COLOR;
	float peak = max(source.r, max(source.g, source.b));
	float mask = smoothstep(
		luminance_threshold - threshold_softness,
		luminance_threshold + threshold_softness,
		peak
	);
	COLOR = vec4(
		source.rgb * emission_tint.rgb * emission_strength * mask,
		source.a * emission_tint.a
	);
}
