shader_type canvas_item;
render_mode unshaded;

uniform vec4 base_color : source_color = vec4(0.298, 0.961, 0.416, 0.96);

float pixel_hash(vec2 pixel) {
	return fract(sin(dot(pixel, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);
}

void fragment() {
	vec2 pixel = min(floor(UV * 16.0), vec2(15.0));
	bool border = pixel.x < 2.0 || pixel.y < 2.0 || pixel.x >= 14.0 || pixel.y >= 14.0;
	if (!border) {
		COLOR = vec4(0.0);
	} else {
		float phase = pixel_hash(pixel) * 6.28318530718;
		float speed = mix(1.8, 3.6, pixel_hash(pixel.yx + vec2(19.0, 7.0)));
		float wave = sin(TIME * speed + phase) * 0.5 + 0.5;
		float brightness = mix(0.72, 1.18, wave);
		COLOR = vec4(base_color.rgb * brightness, base_color.a);
	}
}
