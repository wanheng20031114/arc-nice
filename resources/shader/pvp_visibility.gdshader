shader_type canvas_item;
render_mode unshaded;

uniform sampler2D scene_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform sampler2D shadow_mask : repeat_disable, filter_nearest;
uniform float shadow_brightness : hint_range(0.0, 0.4) = 0.19;
uniform bool hdr_linear_space = false;

vec3 to_srgb(vec3 color) {
	return mix(color * 12.92, 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), color));
}

vec3 to_linear(vec3 color) {
	return mix(color / 12.92, pow((color + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), color));
}

void fragment() {
	vec3 scene = textureLod(scene_texture, SCREEN_UV, 0.0).rgb;
	float hidden = texture(shadow_mask, SCREEN_UV).a;
	vec3 perceptual_scene = hdr_linear_space ? to_srgb(scene) : scene;
	float gray = dot(perceptual_scene, vec3(0.2126, 0.7152, 0.0722));
	vec3 shadow = vec3(gray * shadow_brightness) + vec3(0.014, 0.017, 0.021);
	shadow = hdr_linear_space ? to_linear(shadow) : shadow;
	COLOR = vec4(mix(scene, shadow, hidden), 1.0);
}
