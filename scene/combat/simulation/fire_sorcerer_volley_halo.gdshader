shader_type canvas_item;
render_mode blend_add, unshaded;

// The legacy halo was a 256px radial texture scaled to 19.2px (normal) or
// 20.48px (elite). Scaling only mesh-local vertices preserves every shared
// MultiMesh transform while reproducing that authored diameter.
uniform float halo_size_ratio : hint_range(0.1, 1.0, 0.01) = 0.6;

varying vec4 halo_modulate;

void vertex() {
	halo_modulate = COLOR;
	VERTEX *= halo_size_ratio;
}

void fragment() {
	COLOR = texture(TEXTURE, UV) * halo_modulate;
}
