shader_type canvas_item;

uniform sampler2D explosion_atlas : source_color, filter_nearest;

varying vec4 explosion_data;

void vertex() {
	explosion_data = INSTANCE_CUSTOM;
}

void fragment() {
	float frame = floor(clamp(explosion_data.r, 0.0, 0.9999) * 8.0);
	vec2 atlas_uv = vec2((UV.x + frame) * 0.125, UV.y);
	COLOR = texture(explosion_atlas, atlas_uv);
}
