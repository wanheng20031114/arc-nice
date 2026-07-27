shader_type canvas_item;
render_mode unshaded;

uniform vec4 idle_copper : source_color = vec4(0.42, 0.23, 0.09, 1.0);
uniform vec4 idle_shadow : source_color = vec4(0.12, 0.105, 0.09, 1.0);
uniform vec4 progress_amber : source_color = vec4(1.0, 0.62, 0.16, 1.0);
uniform float pulse_speed : hint_range(0.25, 4.0, 0.05) = 1.4;

instance uniform bool working_active = false;
instance uniform float progress_value : hint_range(0.0, 1.0) = 0.0;
instance uniform float noise_seed = 0.0;
instance uniform vec4 environment_tint : source_color = vec4(1.0);


float machine_hash(vec2 pixel) {
	return fract(
		sin(dot(pixel + vec2(noise_seed * 17.0, noise_seed * 31.0), vec2(83.17, 241.53)))
		* 15427.913
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
		float grain = machine_hash(floor(pixel));
		float pulse = sin(TIME * pulse_speed + grain * TAU + noise_seed * TAU) * 0.5 + 0.5;
		vec3 idle_color = mix(idle_shadow.rgb, idle_copper.rgb, mix(grain, pulse, 0.22));
		idle_color *= environment_tint.rgb;
		COLOR = vec4(idle_color, 1.0);
		if (working_active) {
			float path_progress = clockwise_progress(pixel);
			float completed = step(path_progress, progress_value);
			float leading_edge = 1.0 - smoothstep(0.0, 0.03, abs(path_progress - progress_value));
			vec3 completed_color = progress_amber.rgb * mix(0.88, 1.08, pulse);
			completed_color = mix(completed_color, vec3(1.0, 0.88, 0.56), leading_edge * 0.75);
			COLOR = vec4(mix(idle_color * 0.7, completed_color, completed), 1.0);
		}
	}
}
