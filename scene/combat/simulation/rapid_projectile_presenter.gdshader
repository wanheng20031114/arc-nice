shader_type canvas_item;
render_mode unshaded;

// INSTANCE_CUSTOM.r is authoritative projectile age in seconds. Static
// materials configure each family's authored atlas cadence.
uniform float frame_count : hint_range(1.0, 16.0, 1.0) = 3.0;
uniform float animation_fps : hint_range(0.0, 60.0, 0.1) = 16.0;
varying float projectile_age_seconds;

void vertex() {
	projectile_age_seconds = max(INSTANCE_CUSTOM.r, 0.0);
}

void fragment() {
	float safe_frame_count = max(frame_count, 1.0);
	float frame_index = mod(
		floor(projectile_age_seconds * animation_fps),
		safe_frame_count
	);
	vec2 atlas_uv = vec2(
		(UV.x + frame_index) / safe_frame_count,
		UV.y
	);
	COLOR = texture(TEXTURE, atlas_uv) * COLOR;
}
