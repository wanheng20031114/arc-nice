shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec4 glow_color : source_color = vec4(0.48, 1.0, 0.24, 1.0);
uniform float glow_strength : hint_range(0.0, 3.0) = 1.0;

void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
}

void fragment() {
	vec4 mask = texture(TEXTURE, UV) * COLOR;
	float pulse = 1.0 + 0.16 * sin(TIME * 3.1);
	COLOR = vec4(
		glow_color.rgb * glow_strength * pulse,
		mask.a * glow_color.a * 0.82
	);
}
