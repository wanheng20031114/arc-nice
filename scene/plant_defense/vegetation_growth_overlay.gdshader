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

void fragment() {
	vec2 pixel = min(floor(UV * LOGICAL_PIXELS), vec2(LOGICAL_PIXELS - 1.0));
	float pixel_index = pixel.y * LOGICAL_PIXELS + pixel.x;
	float offset = floor(instance_data.g * 256.0);
	float odd_multiplier = floor(instance_data.b * 128.0) * 2.0 + 1.0;
	float reveal_rank = mod(pixel_index * odd_multiplier + offset, 256.0);
	float reveal_count = floor(clamp(instance_data.r, 0.0, 1.0) * MAX_REVEALED_PIXELS + 0.0001);
	if (reveal_rank >= reveal_count) {
		discard;
	}
	float palette_index = mod(reveal_rank + floor(offset * 0.25), 4.0);
	COLOR = vec4(vegetation_color(palette_index), 1.0);
}
