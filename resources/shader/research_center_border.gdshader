shader_type canvas_item;
render_mode unshaded;

uniform vec4 idle_blue : source_color = vec4(0.0, 0.749, 1.0, 1.0);
uniform vec4 idle_shadow : source_color = vec4(0.0, 0.40, 0.62, 1.0);
uniform vec4 progress_cyan : source_color = vec4(0.0, 1.0, 1.0, 1.0);
uniform vec4 progress_aquamarine : source_color = vec4(0.498, 1.0, 0.831, 1.0);
uniform vec4 progress_turquoise : source_color = vec4(0.251, 0.878, 0.816, 1.0);
uniform float data_noise_speed : hint_range(0.25, 4.0, 0.05) = 1.65;

instance uniform bool working_active = false;
instance uniform float progress_value : hint_range(0.0, 1.0) = 0.0;
instance uniform float noise_seed = 0.0;


float data_hash(vec2 pixel) {
	return fract(
		sin(dot(
			pixel + vec2(noise_seed * 29.0, noise_seed * 43.0),
			vec2(67.71, 241.19)
		)) * 18317.527
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
	bool border = (
		pixel.x < 2.0
		|| pixel.y < 2.0
		|| pixel.x >= 30.0
		|| pixel.y >= 30.0
	);
	COLOR = vec4(0.0);
	if (border) {
		float noise = data_hash(floor(pixel * vec2(0.5, 1.0)));
		float wave = sin(
			pixel.x * 0.73
			+ pixel.y * 0.91
			+ TIME * data_noise_speed * mix(0.58, 1.08, noise)
			+ (noise + noise_seed) * TAU
		) * 0.5 + 0.5;
		float idle_mix = mix(0.62, 0.98, wave);
		vec3 idle_color = mix(
			idle_shadow.rgb,
			idle_blue.rgb,
			idle_mix
		);
		COLOR = vec4(idle_color, 1.0);
		if (working_active) {
			float displayed_progress = clamp(progress_value, 0.0, 1.0);
			float path_progress = clockwise_progress(pixel);
			float completed = (
				step(path_progress, displayed_progress)
				* step(0.0001, displayed_progress)
			);
			float edge_distance = abs(
				path_progress - displayed_progress
			);
			edge_distance = min(edge_distance, 1.0 - edge_distance);
			float leading_edge = 1.0 - smoothstep(
				0.0,
				0.035,
				edge_distance
			);
			vec3 completed_color = mix(
				progress_turquoise.rgb,
				progress_cyan.rgb,
				wave
			);
			completed_color = mix(
				completed_color,
				progress_aquamarine.rgb,
				smoothstep(0.62, 1.0, noise) * 0.55
			);
			completed_color *= mix(0.92, 1.12, wave);
			completed_color = mix(
				completed_color,
				vec3(0.58, 1.32, 1.28),
				leading_edge * 0.78
			);
			COLOR = vec4(
				mix(idle_color * 0.72, completed_color, completed),
				1.0
			);
		}
	}
}
