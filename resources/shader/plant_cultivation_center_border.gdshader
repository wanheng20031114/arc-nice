shader_type canvas_item;
render_mode unshaded;

uniform vec4 idle_green : source_color = vec4(0.18, 0.45, 0.19, 1.0);
uniform vec4 idle_shadow : source_color = vec4(0.055, 0.19, 0.075, 1.0);
uniform vec4 progress_green : source_color = vec4(0.56, 0.94, 0.18, 1.0);
uniform float leaf_noise_speed : hint_range(0.25, 4.0, 0.05) = 1.55;

instance uniform bool working_active = false;
instance uniform float progress_value : hint_range(0.0, 1.0) = 0.0;
instance uniform float noise_seed = 0.0;
instance uniform vec4 environment_tint : source_color = vec4(1.0);


float leaf_hash(vec2 pixel) {
	return fract(
		sin(dot(pixel + vec2(noise_seed * 23.0, noise_seed * 41.0), vec2(71.53, 263.17)))
		* 19427.113
	);
}


float clockwise_progress(vec2 pixel) {
	vec2 direction = pixel + vec2(0.5) - vec2(16.0);
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
	vec2 pixel = min(floor(UV * 32.0), vec2(31.0));
	bool border = pixel.x < 2.0 || pixel.y < 2.0 || pixel.x >= 30.0 || pixel.y >= 30.0;
	COLOR = vec4(0.0);
	if (border) {
		float noise = leaf_hash(floor(pixel * vec2(0.5, 1.0)));
		float wave = sin(
			pixel.x * 0.81
			+ pixel.y * 0.59
			+ TIME * leaf_noise_speed * mix(0.62, 1.12, noise)
			+ (noise + noise_seed) * TAU
		) * 0.5 + 0.5;
		float idle_mix = mix(0.24, 0.78, wave);
		vec3 idle_color = (
			mix(idle_shadow.rgb, idle_green.rgb, idle_mix)
			* environment_tint.rgb
		);
		COLOR = vec4(idle_color, 1.0);
		if (working_active) {
			float path_progress = clockwise_progress(pixel);
			float completed = step(path_progress, progress_value);
			float leading_edge = 1.0 - smoothstep(
				0.0,
				0.035,
				abs(path_progress - progress_value)
			);
			vec3 completed_color = progress_green.rgb * mix(0.86, 1.12, wave);
			completed_color = mix(
				completed_color,
				vec3(0.83, 1.25, 0.38),
				leading_edge * 0.76
			);
			COLOR = vec4(
				mix(idle_color * 0.72, completed_color, completed),
				1.0
			);
		}
	}
}
