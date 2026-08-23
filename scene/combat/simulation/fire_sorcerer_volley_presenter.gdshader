shader_type canvas_item;
render_mode unshaded;

// INSTANCE_CUSTOM.r: authoritative fly age in seconds.
// INSTANCE_CUSTOM.g: normalized effect progress.
// INSTANCE_CUSTOM.b: EffectKind (NONE=0, IMPACT=1, EXPIRE=2).
const float ATLAS_COLUMNS = 4.0;
const float ATLAS_ROWS = 4.0;
const float FLY_FRAMES_PER_SECOND = 12.0;

varying vec3 volley_visual_data;

void vertex() {
	volley_visual_data = INSTANCE_CUSTOM.rgb;
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
	vec2 atlas_uv = vec2(
		(UV.x + atlas_column) / ATLAS_COLUMNS,
		(UV.y + atlas_row) / ATLAS_ROWS
	);
	COLOR = texture(TEXTURE, atlas_uv) * COLOR;
}
