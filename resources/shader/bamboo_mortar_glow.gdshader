shader_type canvas_item;
render_mode unshaded, blend_mix;

const float CORE_HALF_EXTENT = 3.0 / 16.0;
const float CORE_BORDER_HALF_EXTENT = 5.0 / 16.0;
const float INNER_HALO_HALF_EXTENT = 7.0 / 16.0;

varying vec2 shape_uv;

void vertex() {
	shape_uv = (VERTEX + vec2(8.0)) / 16.0;
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
}

void fragment() {
	float pulse = 1.0 + 0.035 * sin(TIME * 3.1);
	vec2 centered_uv = abs(shape_uv - vec2(0.5));
	float square_radius = max(centered_uv.x, centered_uv.y);
	float core_mask = 1.0 - step(CORE_HALF_EXTENT, square_radius);
	float core_border_area = 1.0 - step(
		CORE_BORDER_HALF_EXTENT,
		square_radius
	);
	float core_border_mask = max(core_border_area - core_mask, 0.0);
	float inner_area = 1.0 - step(INNER_HALO_HALF_EXTENT, square_radius);
	float inner_halo_mask = max(inner_area - core_border_area, 0.0);
	float outer_halo_mask = max(1.0 - inner_area, 0.0);
	// Polygon2D's vertex RGB already carries the selected color multiplied by
	// its frame strength. Vertex alpha remains free for loading-screen masking.
	vec3 active_color = COLOR.rgb;
	vec3 output_color = (
		active_color * core_mask
		+ active_color * 0.16 * core_border_mask
		+ active_color * pulse * 0.28 * inner_halo_mask
		+ active_color * pulse * 0.10 * outer_halo_mask
	);
	float output_alpha = (
		core_mask
		+ core_border_mask * 0.92
		+ inner_halo_mask * 0.26
		+ outer_halo_mask * 0.08
	);
	COLOR = vec4(output_color, COLOR.a * output_alpha);
}
