shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.78, 0.18);
uniform float pulse = 1.0;
uniform float inner_radius = 0.0;
uniform float outer_softness = 1.0;

varying vec2 local_unit_position;

void vertex() {
	local_unit_position = VERTEX;
}

void fragment() {
	float distance_from_center = length(local_unit_position);
	float radial_alpha = 1.0 - smoothstep(inner_radius, outer_softness, distance_from_center);
	COLOR = vec4(tint.rgb, tint.a * radial_alpha * pulse);
}
