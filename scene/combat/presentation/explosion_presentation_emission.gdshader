shader_type canvas_item;
render_mode blend_add, unshaded;

uniform sampler2D explosion_atlas : source_color, filter_nearest;
uniform vec4 emission_tint : source_color = vec4(1.08, 0.78, 0.46, 0.62);
uniform float emission_strength = 0.78;

varying vec4 explosion_data;

void vertex() {
	explosion_data = INSTANCE_CUSTOM;
}

void fragment() {
	float frame = floor(clamp(explosion_data.r, 0.0, 0.9999) * 8.0);
	vec2 atlas_uv = vec2((UV.x + frame) * 0.125, UV.y);
	vec4 source = texture(explosion_atlas, atlas_uv);
	float peak = max(source.r, max(source.g, source.b));
	float mask = smoothstep(0.38, 0.66, peak);
	COLOR = vec4(
		source.rgb * emission_tint.rgb * emission_strength * mask,
		source.a * emission_tint.a
	);
}
