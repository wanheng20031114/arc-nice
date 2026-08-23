shader_type canvas_item;

uniform sampler2D rocket_atlas : source_color, filter_nearest;

varying vec4 rocket_data;

void vertex() {
	rocket_data = INSTANCE_CUSTOM;
}

void fragment() {
	float frame = floor(clamp(rocket_data.r, 0.0, 0.9999) * 4.0);
	vec2 atlas_uv = vec2((UV.x + frame) * 0.25, UV.y);
	COLOR = texture(rocket_atlas, atlas_uv);
}
