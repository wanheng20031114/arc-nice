shader_type canvas_item;
render_mode unshaded, blend_add;

instance uniform vec4 glow_color : source_color = vec4(0.34, 1.65, 0.18, 1.0);
instance uniform float glow_strength : hint_range(0.0, 3.0) = 1.0;

const float CORE_HALF_EXTENT = 1.0 / 6.0;
const float INNER_HALO_HALF_EXTENT = 1.0 / 3.0;

void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
}

void fragment() {
	float pulse = 1.0 + 0.06 * sin(TIME * 3.1);
	vec2 centered_uv = abs(UV - vec2(0.5));
	float square_radius = max(centered_uv.x, centered_uv.y);
	float core_mask = 1.0 - step(CORE_HALF_EXTENT, square_radius);
	float inner_area = 1.0 - step(INNER_HALO_HALF_EXTENT, square_radius);
	float inner_halo_mask = max(inner_area - core_mask, 0.0);
	float outer_halo_mask = max(1.0 - inner_area, 0.0);
	float coverage = (
		core_mask
		+ inner_halo_mask * 0.30
		+ outer_halo_mask * 0.10
	);
	COLOR = vec4(
		glow_color.rgb * glow_strength * pulse * coverage,
		glow_color.a * coverage
	);
}
