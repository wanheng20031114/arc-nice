shader_type canvas_item;
render_mode unshaded;

uniform vec4 base_rail_color : source_color = vec4(0.86, 0.89, 0.88, 0.82);
uniform vec4 reachable_rail_color : source_color = vec4(1.0, 0.84, 0.52, 0.98);
// 一轮完整的“静止 → 上浮 → 静止 → 下浮 → 静止”节奏。
// 周期刻意偏慢，避免轨道出现持续抖动或扫光感。
uniform float wave_cycle_seconds : hint_range(2.0, 8.0) = 4.8;
uniform float wave_amplitude_pixels : hint_range(0.0, 2.0) = 1.0;
// 两张 64/24px 的原始轨道图均以 25% 缩至路线世界尺寸。
// 保留为参数，以便之后替换轨道分辨率时同步维护每个分段的统一锚点。
uniform float source_to_world_scale : hint_range(0.1, 1.0) = 0.25;

varying vec4 rail_signal;

float hash21(vec2 value) {
	return fract(sin(dot(value, vec2(127.1, 311.7))) * 43758.5453123);
}


float get_paused_pixel_offset(float cycle_phase) {
	// 离散像素状态而非正弦曲线：每段只会整体停在 0、+1、0、-1、0。
	// 因此相邻分段可能处于不同高度，但单个分段的四个顶点绝不会形成斜线。
	if (cycle_phase < 0.24) {
		return 0.0;
	}
	if (cycle_phase < 0.43) {
		return wave_amplitude_pixels;
	}
	if (cycle_phase < 0.68) {
		return 0.0;
	}
	if (cycle_phase < 0.87) {
		return -wave_amplitude_pixels;
	}
	return 0.0;
}


void vertex() {
	rail_signal = COLOR;
	float is_wavy = step(0.5, COLOR.b);
	float is_vertical = step(0.5, COLOR.g);
	// 每段轨道均由独立的 draw_texture_rect 绘制。UV / TEXTURE_PIXEL_SIZE
	// 是原图像素坐标；换算为世界尺寸后再反推左上角，保证四个顶点获得
	// 同一个锚点与相位。此前直接使用原图坐标会让同一片四角不同步而倾斜。
	vec2 source_pixel_position = UV / TEXTURE_PIXEL_SIZE;
	vec2 tile_origin = VERTEX - source_pixel_position * source_to_world_scale;
	float cycle_phase = fract(
		TIME / wave_cycle_seconds + hash21(floor(tile_origin))
	);
	float pixel_offset = get_paused_pixel_offset(cycle_phase);
	// 横轨沿 Y 轴浮动；竖轨沿 X 轴浮动。每个图块只做法线方向平移。
	vec2 motion_axis = mix(vec2(0.0, 1.0), vec2(1.0, 0.0), is_vertical);
	VERTEX += motion_axis * pixel_offset * is_wavy;
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
