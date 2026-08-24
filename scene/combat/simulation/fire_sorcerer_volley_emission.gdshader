shader_type canvas_item;
render_mode blend_add, unshaded;

// Additive copy of the authored volley frame. It shares the base MultiMesh,
// so transforms, animation state and visible-prefix writes remain single-copy.
const float ATLAS_COLUMNS = 4.0;
const float ATLAS_ROWS = 4.0;
const float FLY_FRAMES_PER_SECOND = 12.0;

varying vec3 volley_visual_data;
varying vec4 emission_modulate;

void vertex() {
	volley_visual_data = INSTANCE_CUSTOM.rgb;
	emission_modulate = COLOR;
}

void fragment() {
	float visual_age = max(volley_visual_data.r, 0.0);
	float effect_progress = clamp(volley_visual_data.g, 0.0, 1.0);
	float effect_kind = floor(volley_visual_data.b + 0.5);
	float atlas_row = 0.0;
	float atlas_column = mod(
		floor(visual_age * FLY_FRAMES_PER_SECOND),
		ATLAS_COLUMNS
	);
	if (effect_kind > 0.5) {
		atlas_row = effect_kind < 1.5 ? 2.0 : 3.0;
		atlas_column = min(
			floor(effect_progress * ATLAS_COLUMNS),
			ATLAS_COLUMNS - 1.0
		);
	}
	vec2 frame_half_texel = vec2(
		TEXTURE_PIXEL_SIZE.x * ATLAS_COLUMNS * 0.5,
		TEXTURE_PIXEL_SIZE.y * ATLAS_ROWS * 0.5
	);
	vec2 frame_uv = clamp(
		UV,
		frame_half_texel,
		vec2(1.0) - frame_half_texel
	);
	vec2 atlas_uv = vec2(
		(frame_uv.x + atlas_column) / ATLAS_COLUMNS,
		(frame_uv.y + atlas_row) / ATLAS_ROWS
	);
	COLOR = texture(TEXTURE, atlas_uv) * emission_modulate;
}
