shader_type canvas_item;
render_mode unshaded;

uniform vec4 edge_color : source_color = vec4(1.0, 0.08, 0.035, 0.72);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float edge_width : hint_range(0.05, 0.5) = 0.24;

void fragment() {
	float edge_distance = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	float edge_mask = 1.0 - smoothstep(0.0, edge_width, edge_distance);
	float corner_boost = pow(1.0 - min(UV.x * (1.0 - UV.x), UV.y * (1.0 - UV.y)) * 4.0, 2.0);
	float alpha = clamp(edge_mask * 0.82 + corner_boost * 0.18, 0.0, 1.0);
	COLOR = vec4(edge_color.rgb, edge_color.a * alpha * intensity);
}
