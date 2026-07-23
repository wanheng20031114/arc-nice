shader_type canvas_item;
render_mode unshaded;

uniform vec4 idle_brown : source_color = vec4(0.68, 0.39, 0.16, 1.0);
uniform vec4 idle_shadow : source_color = vec4(0.34, 0.15, 0.045, 1.0);
uniform vec4 progress_brown : source_color = vec4(1.0, 0.64, 0.285, 1.0);
uniform float grain_speed : hint_range(0.25, 4.0, 0.05) = 1.8;

instance uniform bool working_active = false;
instance uniform float progress_value : hint_range(0.0, 1.0) = 0.0;
instance uniform float noise_seed = 0.0;
instance uniform vec4 environment_tint : source_color = vec4(1.0);


float wood_hash(vec2 pixel) {
	return fract(
		sin(dot(pixel + vec2(noise_seed * 17.0, noise_seed * 31.0), vec2(83.17, 271.91)))
		* 15731.743
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
		// A banded wood-grain shimmer deliberately differs from the
		// stake's independent per-pixel sine noise while retaining the same
		// pixel-art life.
		float grain_seed = wood_hash(floor(pixel * vec2(0.5, 1.0)));
		float grain_wave = sin(
			pixel.x * 1.13
			+ pixel.y * 0.47
			+ TIME * grain_speed * mix(0.55, 1.05, grain_seed)
			+ (grain_seed + noise_seed) * TAU
		) * 0.5 + 0.5;
		float idle_mix = mix(0.28, 0.72, grain_wave);
		vec3 idle_color = (
			mix(idle_shadow.rgb, idle_brown.rgb, idle_mix)
			* environment_tint.rgb
		);
		COLOR = vec4(idle_color, 1.0);
		if (working_active) {
			float displayed_progress = progress_value;
			float path_progress = clockwise_progress(pixel);
			float completed = step(path_progress, displayed_progress);
			float leading_edge = 1.0 - smoothstep(
				0.0,
				0.055,
				abs(path_progress - displayed_progress)
			);
			float active_noise = mix(0.86, 1.12, grain_wave);
			vec3 completed_color = progress_brown.rgb * active_noise;
			completed_color = mix(
				completed_color,
				vec3(1.32, 0.86, 0.43),
				leading_edge * 0.72
			);
			COLOR = vec4(
				mix(idle_color * 0.72, completed_color, completed),
				1.0
			);
		}
	}
}
