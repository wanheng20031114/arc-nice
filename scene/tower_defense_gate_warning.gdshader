shader_type canvas_item;
render_mode unshaded;

uniform vec4 edge_color : source_color = vec4(1.0, 0.08, 0.035, 0.72);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float edge_width : hint_range(0.05, 0.5) = 0.24;

void fragment() {
	float aspect_ratio = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 0.000001);
	vec2 edge_distances = min(UV, vec2(1.0) - UV);
	edge_distances.x *= aspect_ratio;
	float edge_distance = min(edge_distances.x, edge_distances.y);
	float edge_mask = 1.0 - smoothstep(0.0, edge_width, edge_distance);
	float corner_boost = 1.0 - smoothstep(0.0, edge_width * 1.5, length(edge_distances));
	float alpha = clamp(edge_mask * 0.82 + corner_boost * 0.18, 0.0, 1.0);
	COLOR = vec4(edge_color.rgb, edge_color.a * alpha * intensity);
}
