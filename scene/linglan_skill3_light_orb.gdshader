shader_type canvas_item;
render_mode unshaded, blend_add;

uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.78, 0.65);
uniform float pulse = 1.0;

void fragment() {
	COLOR = tint * pulse;
}
