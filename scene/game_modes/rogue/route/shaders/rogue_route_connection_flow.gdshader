shader_type canvas_item;
render_mode unshaded;

uniform vec4 base_rail_color : source_color = vec4(0.86, 0.89, 0.88, 0.82);
uniform vec4 reachable_rail_color : source_color = vec4(1.0, 0.84, 0.52, 0.98);
uniform float wave_frequency : hint_range(0.1, 3.0) = 0.85;
uniform float wave_amplitude_pixels : hint_range(0.0, 2.0) = 1.0;

varying vec4 rail_signal;

float hash21(vec2 value) {
	return fract(sin(dot(value, vec2(127.1, 311.7))) * 43758.5453123);
}


void vertex() {
	rail_signal = COLOR;
	float is_wavy = step(0.5, COLOR.b);
	// 每段轨道都是单独的原生 draw_texture_rect 调用；反推其左上角，
	// 便能让同一根线的不同 16px 段拥有固定频率、不同相位的整数像素起伏。
	vec2 tile_origin = VERTEX - UV / TEXTURE_PIXEL_SIZE;
	float phase = TIME * wave_frequency * 6.28318530718
		+ hash21(floor(tile_origin)) * 6.28318530718;
	float pixel_offset = floor(sin(phase) * wave_amplitude_pixels + 0.5);
	VERTEX.y += pixel_offset * is_wavy;
}

void fragment() {
	vec4 rail_texture = texture(TEXTURE, UV);
	float is_reachable = step(0.5, rail_signal.r);
	vec4 rail_color = mix(base_rail_color, reachable_rail_color, is_reachable);
	COLOR = vec4(
		rail_texture.rgb * rail_color.rgb,
		rail_texture.a * rail_color.a
	);
}
