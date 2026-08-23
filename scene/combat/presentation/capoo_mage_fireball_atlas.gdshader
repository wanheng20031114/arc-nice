shader_type canvas_item;

uniform sampler2D fireball_atlas : source_color, filter_nearest;
uniform float atlas_row = 0.0;

varying vec4 fireball_data;

void vertex() {
	fireball_data = INSTANCE_CUSTOM;
}

void fragment() {
	float frame = floor(clamp(fireball_data.r, 0.0, 0.9999) * 6.0);
	vec2 atlas_uv = vec2((UV.x + frame) / 6.0, (UV.y + atlas_row) * 0.5);
	COLOR = texture(fireball_atlas, atlas_uv);
}
