shader_type canvas_item;
render_mode unshaded, blend_mix;

instance uniform float cover_progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float reveal_phase : hint_range(0.0, 1.0) = 0.0;
uniform vec4 cover_color : source_color = vec4(0.018, 0.019, 0.018, 1.0);
uniform vec4 hdr_edge_color : source_color = vec4(1.28, 0.58, 0.16, 0.72);
uniform float edge_width_pixels : hint_range(1.0, 2.0, 0.25) = 1.5;
uniform float target_rows : hint_range(4.0, 36.0, 1.0) = 18.0;


void fragment() {
	vec2 viewport_pixels = 1.0 / max(SCREEN_PIXEL_SIZE, vec2(0.000001));
	float cell_size = max(
		floor(viewport_pixels.y / max(target_rows, 1.0)),
		4.0
	);
	vec2 centered_grid_offset = floor(
		mod(viewport_pixels, vec2(cell_size)) * 0.5
	);
	vec2 screen_pixel = SCREEN_UV / max(SCREEN_PIXEL_SIZE, vec2(0.000001));
	vec2 cell_uv = fract((screen_pixel - centered_grid_offset) / cell_size);
	float diamond_distance_pixels = (
		abs(cell_uv.x - 0.5) + abs(cell_uv.y - 0.5)
	) * cell_size;

	float progress = clamp(cover_progress, 0.0, 1.0);
	float phase_progress = mix(progress, 1.0 - progress, reveal_phase);
	float threshold = mix(
		-edge_width_pixels * 2.0,
		cell_size + edge_width_pixels * 2.0,
		phase_progress
	);
	float diamond_fill = step(diamond_distance_pixels, threshold);
	float coverage = mix(diamond_fill, 1.0 - diamond_fill, reveal_phase);

	float edge_distance = abs(diamond_distance_pixels - threshold);
	float edge = 1.0 - smoothstep(
		edge_width_pixels * 0.5,
		edge_width_pixels * 0.5 + 0.5,
		edge_distance
	);
	float active_front = (
		step(0.002, phase_progress)
		* (1.0 - step(0.998, phase_progress))
	);
	edge *= active_front;

	vec3 output_color = mix(cover_color.rgb, hdr_edge_color.rgb, edge);
	float output_alpha = max(coverage * cover_color.a, edge * hdr_edge_color.a);
	COLOR = vec4(output_color, output_alpha);
}
