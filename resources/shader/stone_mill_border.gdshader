shader_type canvas_item;
render_mode unshaded;

uniform vec4 idle_gray : source_color = vec4(0.34, 0.36, 0.38, 1.0);
uniform vec4 idle_shadow : source_color = vec4(0.19, 0.21, 0.23, 1.0);
uniform vec4 progress_light_gray : source_color = vec4(0.82, 0.85, 0.87, 1.0);
uniform float stone_shimmer_speed : hint_range(0.25, 4.0, 0.05) = 1.25;

instance uniform bool working_active = false;
instance uniform float progress_value : hint_range(0.0, 1.0) = 0.0;
instance uniform float noise_seed = 0.0;
instance uniform vec4 environment_tint : source_color = vec4(1.0);


float stone_hash(vec2 pixel) {
	return fract(
		sin(dot(pixel + vec2(noise_seed * 19.0, noise_seed * 29.0), vec2(91.73, 263.41)))
		* 14593.271
	);
}

float clockwise_progress(vec2 pixel) {
	vec2 direction = pixel + vec2(0.5) - vec2(8.0);
	float angle = atan(direction.x, -direction.y);
	return fract(angle / TAU + 1.0);
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
	COLOR = vec4(0.0);
	if (border) {
		float speckle = stone_hash(floor(pixel));
		float pulse = sin(
			TIME * stone_shimmer_speed
			+ speckle * TAU
			+ noise_seed * TAU
		) * 0.5 + 0.5;
		float idle_mix = mix(0.38, 0.72, mix(speckle, pulse, 0.24));
		vec3 idle_color = (
			mix(idle_shadow.rgb, idle_gray.rgb, idle_mix)
			* environment_tint.rgb
		);
		COLOR = vec4(idle_color, 1.0);
		if (working_active) {
			float path_progress = clockwise_progress(pixel);
			float completed = step(path_progress, progress_value);
			float leading_edge = 1.0 - smoothstep(
				0.0,
				0.055,
				abs(path_progress - progress_value)
			);
			vec3 completed_color = progress_light_gray.rgb * mix(0.9, 1.08, pulse);
			completed_color = mix(
				completed_color,
				vec3(0.96, 0.975, 0.985),
				leading_edge * 0.78
			);
			COLOR = vec4(
				mix(idle_color * 0.72, completed_color, completed),
				1.0
			);
		}
	}
}
