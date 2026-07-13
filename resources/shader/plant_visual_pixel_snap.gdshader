shader_type canvas_item;

// Keep a static plant drawable on the logical canvas pixel grid without
// quantizing the camera, gameplay node, collision shapes, or other entities.
// Every vertex receives the same translation, so scale and rotation remain
// unchanged (important for the independently rotating agave cannon head).
void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
}
