shader_type canvas_item;
render_mode unshaded;

const float LOGICAL_PIXELS = 16.0;
const float MAX_REVEALED_PIXELS = 48.0;

varying vec4 instance_data;

vec3 vegetation_color(float palette_index) {
	if (palette_index < 0.5) {
		return vec3(0.388235, 0.678431, 0.180392);
	}
	if (palette_index < 1.5) {
		return vec3(0.435294, 0.737255, 0.203922);
	}
	if (palette_index < 2.5) {
		return vec3(0.474510, 0.780392, 0.215686);
	}
	return vec3(0.482353, 0.788235, 0.219608);
}

void vertex() {
	instance_data = INSTANCE_CUSTOM;
}

vec2 feistel_step(vec2 state, float round_key, float round_index) {
	float round_value = mod(
		state.y * state.y * 5.0
		+ state.y * (round_key * 2.0 + 1.0)
		+ round_key * 7.0
		+ round_index * 3.0,
		16.0
	);
	return vec2(state.y, mod(state.x + round_value, 16.0));
}

float pixel_reveal_rank(vec2 pixel, float seed_a, float seed_b) {
	vec2 state = pixel;
	state = feistel_step(state, mod(seed_a, 16.0), 0.0);
	state = feistel_step(state, floor(seed_a / 16.0), 1.0);
	state = feistel_step(state, mod(seed_b, 16.0), 2.0);
	state = feistel_step(state, floor(seed_b / 16.0), 3.0);
	return state.y * 16.0 + state.x;
}

void fragment() {
	vec2 pixel = min(floor(UV * LOGICAL_PIXELS), vec2(LOGICAL_PIXELS - 1.0));
	float seed_a = floor(instance_data.g * 256.0);
	float seed_b = floor(instance_data.b * 128.0);
	float reveal_rank = pixel_reveal_rank(pixel, seed_a, seed_b);
	float reveal_count = floor(clamp(instance_data.r, 0.0, 1.0) * MAX_REVEALED_PIXELS + 0.0001);
	if (reveal_rank >= reveal_count) {
		discard;
	}
	float palette_index = mod(reveal_rank + floor(seed_a * 0.25), 4.0);
	COLOR = vec4(vegetation_color(palette_index), 1.0);
}
