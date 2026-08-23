shader_type canvas_item;
render_mode blend_add, unshaded;

uniform sampler2D fireball_atlas : source_color, filter_nearest;
uniform int layer_kind = 0;
uniform float atlas_row = 0.0;
uniform vec4 effect_tint : source_color = vec4(1.0);
uniform float effect_strength = 1.0;

varying vec4 fireball_data;

void vertex() {
	fireball_data = INSTANCE_CUSTOM;
}

void fragment() {
	if (layer_kind == 1) {
		vec2 point = (UV - vec2(0.5)) * 2.0;
		float radius = dot(point, point);
		float pulse = 0.9 + 0.1 * sin(fireball_data.g * 6.2831853);
		float alpha = exp(-radius * 4.5) * effect_tint.a * pulse;
		COLOR = vec4(effect_tint.rgb * effect_strength * alpha, alpha);
	} else {
		float frame = floor(clamp(fireball_data.r, 0.0, 0.9999) * 6.0);
		vec2 atlas_uv = vec2(
			(UV.x + frame) / 6.0,
			(UV.y + atlas_row) * 0.5
		);
		vec4 source = texture(fireball_atlas, atlas_uv);
		float peak = max(source.r, max(source.g, source.b));
		float mask = smoothstep(0.28, 0.62, peak);
		COLOR = vec4(
			source.rgb * effect_tint.rgb * effect_strength * mask,
			source.a * effect_tint.a
		);
	}
}
