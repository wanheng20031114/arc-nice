shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float grayscale_strength : hint_range(0.0, 1.0) = 0.34;
uniform float center_darkness : hint_range(0.0, 0.2) = 0.025;
uniform float edge_darkness : hint_range(0.0, 1.0) = 0.68;
uniform float corner_darkness : hint_range(0.0, 0.4) = 0.15;
uniform float edge_width : hint_range(0.05, 0.5) = 0.3;

void fragment() {
	vec4 screen_color = textureLod(screen_texture, SCREEN_UV, 0.0);
	float luminance = dot(screen_color.rgb, vec3(0.299, 0.587, 0.114));
	vec3 gray_color = vec3(luminance);
	float aspect_ratio = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 0.000001);
	vec2 edge_distances = min(UV, vec2(1.0) - UV);
	edge_distances.x *= aspect_ratio;
	float edge_distance = min(edge_distances.x, edge_distances.y);
	float edge_mask = 1.0 - smoothstep(0.0, edge_width, edge_distance);
	vec2 centered_uv = abs(UV * 2.0 - vec2(1.0));
	float corner_mask = smoothstep(0.2, 0.88, centered_uv.x * centered_uv.y);
	float peripheral_mask = clamp(edge_mask * 0.88 + corner_mask * 0.18, 0.0, 1.0);
	float desaturation = grayscale_strength * intensity * (0.08 + peripheral_mask * 0.92);
	vec3 desaturated = mix(screen_color.rgb, gray_color, desaturation);
	float darkness = intensity * clamp(
		center_darkness + edge_darkness * edge_mask + corner_darkness * corner_mask,
		0.0,
		0.88
	);
	COLOR = vec4(desaturated * (1.0 - darkness), screen_color.a);
}
