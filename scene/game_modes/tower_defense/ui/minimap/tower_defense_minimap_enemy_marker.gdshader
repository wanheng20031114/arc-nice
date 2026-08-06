shader_type canvas_item;
render_mode unshaded;


void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	if (dot(centered_uv, centered_uv) > 1.0) {
		discard;
	}
}
