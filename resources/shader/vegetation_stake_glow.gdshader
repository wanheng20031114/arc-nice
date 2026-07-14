shader_type canvas_item;
render_mode unshaded, blend_add;

void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
}

void fragment() {
	vec4 sample_color = texture(TEXTURE, UV) * COLOR;
	float pulse = 1.3 + 0.22 * sin(TIME * 3.1);
	COLOR = vec4(sample_color.rgb * pulse, sample_color.a * 0.82);
}
