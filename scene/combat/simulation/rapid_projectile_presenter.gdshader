shader_type canvas_item;
render_mode unshaded;

// INSTANCE_CUSTOM.r is authoritative projectile age in seconds. The presenter
// updates it together with the transform; the shader selects the original
// three-frame 24x8 AK atlas at the authored 16 FPS rate.
varying float projectile_age_seconds;

void vertex() {
	projectile_age_seconds = max(INSTANCE_CUSTOM.r, 0.0);
}

void fragment() {
	float frame_index = mod(floor(projectile_age_seconds * 16.0), 3.0);
	vec2 atlas_uv = vec2((UV.x + frame_index) / 3.0, UV.y);
	COLOR = texture(TEXTURE, atlas_uv) * COLOR;
}
