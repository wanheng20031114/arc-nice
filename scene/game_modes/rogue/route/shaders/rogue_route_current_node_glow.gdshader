shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec4 beacon_color : source_color = vec4(1.0, 0.73, 0.28, 1.0);
uniform float hdr_energy : hint_range(1.0, 6.0) = 3.2;
uniform float strength : hint_range(0.0, 1.0) = 0.40;
uniform float pulse_speed : hint_range(0.0, 4.0) = 0.70;
uniform float pulse_amount : hint_range(0.0, 0.5) = 0.06;


float pixel_rect(vec2 pixel, vec2 minimum, vec2 maximum) {
	return step(minimum.x, pixel.x)
		* step(pixel.x, maximum.x)
		* step(minimum.y, pixel.y)
		* step(pixel.y, maximum.y);
}


void fragment() {
	// 当前节点不再铺一层实心雾圈：仅绘制四角括号与四向短标记。
	// 这些最外侧像素用 HDR 能量交给场景的低强度 glow 做极小范围外溢。
	vec2 pixel = floor(UV * 44.0);
	float top_left = max(
		pixel_rect(pixel, vec2(3.0, 3.0), vec2(11.0, 4.0)),
		pixel_rect(pixel, vec2(3.0, 3.0), vec2(4.0, 11.0))
	);
	float top_right = max(
		pixel_rect(pixel, vec2(32.0, 3.0), vec2(40.0, 4.0)),
		pixel_rect(pixel, vec2(39.0, 3.0), vec2(40.0, 11.0))
	);
	float bottom_left = max(
		pixel_rect(pixel, vec2(3.0, 39.0), vec2(11.0, 40.0)),
		pixel_rect(pixel, vec2(3.0, 32.0), vec2(4.0, 40.0))
	);
	float bottom_right = max(
		pixel_rect(pixel, vec2(32.0, 39.0), vec2(40.0, 40.0)),
		pixel_rect(pixel, vec2(39.0, 32.0), vec2(40.0, 40.0))
	);
	float corner_brackets = max(
		max(top_left, top_right),
		max(bottom_left, bottom_right)
	);
	float cardinal_marks = max(
		max(
			pixel_rect(pixel, vec2(20.0, 0.0), vec2(23.0, 1.0)),
			pixel_rect(pixel, vec2(20.0, 42.0), vec2(23.0, 43.0))
		),
		max(
			pixel_rect(pixel, vec2(0.0, 20.0), vec2(1.0, 23.0)),
			pixel_rect(pixel, vec2(42.0, 20.0), vec2(43.0, 23.0))
		)
	);
	float pulse = 1.0 + sin(TIME * pulse_speed * 6.28318530718) * pulse_amount;
	float alpha = clamp(
		(corner_brackets * 0.82 + cardinal_marks * 0.42) * strength * pulse,
		0.0,
		1.0
	);
	COLOR = vec4(beacon_color.rgb * hdr_energy, alpha) * COLOR;
}
