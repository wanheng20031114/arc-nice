shader_type canvas_item;
render_mode unshaded, blend_mix;

const float CORE_HALF_EXTENT = 3.0 / 16.0;

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
	vec2 centered_uv = abs(shape_uv - vec2(0.5));
	float square_radius = max(centered_uv.x, centered_uv.y);
	float core_mask = 1.0 - step(CORE_HALF_EXTENT, square_radius);
	// The shader only keeps the crisp luminous cell. Its PointLight2D child
	// owns the surrounding falloff, avoiding discrete square halo bands.
	vec3 active_color = COLOR.rgb;
	COLOR = vec4(active_color, COLOR.a) * core_mask;
}
