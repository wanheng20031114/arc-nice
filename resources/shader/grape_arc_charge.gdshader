shader_type canvas_item;
render_mode blend_add, unshaded;

instance uniform float charge_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float release_flash : hint_range(0.0, 1.0) = 0.0;
instance uniform float idle_scan_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float idle_scan_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 electric_color : source_color = vec4(0.24, 0.72, 1.0, 1.0);
instance uniform float charge_uv_top : hint_range(0.0, 1.0) = 0.34;
instance uniform float charge_uv_bottom : hint_range(0.0, 1.0) = 0.70;


void fragment() {
	vec4 source = texture(TEXTURE, UV);
	float local_y = clamp(
		(UV.y - charge_uv_top)
		/ max(charge_uv_bottom - charge_uv_top, 0.001),
		0.0,
		1.0
	);
	float active = step(0.001, charge_progress);
	float charged = (
		1.0
		- smoothstep(
			charge_progress - 0.02,
			charge_progress + 0.16,
			local_y
		)
	) * active;
	float wave = (
		1.0
		- smoothstep(0.015, 0.10, abs(local_y - charge_progress))
	) * active;
	float idle_wave = (
		1.0
		- smoothstep(0.018, 0.115, abs(local_y - idle_scan_progress))
	) * idle_scan_strength;
	float grape_highlight = smoothstep(0.12, 0.72, max(source.b, source.r));
	float energy = (
		charged * (0.14 + grape_highlight * 0.28)
		+ wave * 0.78
		+ idle_wave * (0.60 + grape_highlight * 0.18)
		+ release_flash * 0.88
	);
	COLOR = vec4(
		electric_color.rgb * energy + source.rgb * charged * 0.10,
		source.a * clamp(energy, 0.0, 1.0) * COLOR.a
	);
}
