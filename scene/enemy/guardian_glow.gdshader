shader_type canvas_item;

uniform bool guardian_glow_enabled = true;
uniform float guardian_glow_strength : hint_range(0.0, 1.0) = 0.42;
uniform vec2 guardian_glow_center = vec2(0.5, 0.46);
uniform float guardian_glow_radius : hint_range(0.1, 0.9) = 0.46;
uniform float guardian_glow_softness : hint_range(0.02, 0.5) = 0.28;
uniform vec4 guardian_glow_core_color : source_color = vec4(0.32, 0.88, 1.0, 0.42);
uniform vec4 guardian_glow_edge_color : source_color = vec4(0.04, 0.36, 0.78, 0.0);
uniform float guardian_body_light : hint_range(0.0, 1.0) = 0.18;

void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 color = texture_color * COLOR;

	if (guardian_glow_enabled && guardian_glow_strength > 0.0) {
		vec2 delta = UV - guardian_glow_center;
		float distance_from_center = length(delta);
		float inner_radius = max(guardian_glow_radius - guardian_glow_softness, 0.0);
		float outer_radius = guardian_glow_radius;
		float radial = 1.0 - smoothstep(inner_radius, outer_radius, distance_from_center);
		float core = 1.0 - smoothstep(0.0, inner_radius * 0.62, distance_from_center);
		float frame_edge_fade = (
			smoothstep(0.0, 0.10, UV.x)
			* smoothstep(0.0, 0.10, UV.y)
			* smoothstep(0.0, 0.10, 1.0 - UV.x)
			* smoothstep(0.0, 0.10, 1.0 - UV.y)
		);
		float soft_glow = pow(clamp(radial, 0.0, 1.0), 1.85) * frame_edge_fade * guardian_glow_strength;
		vec3 glow_rgb = mix(guardian_glow_edge_color.rgb, guardian_glow_core_color.rgb, clamp(core + radial * 0.18, 0.0, 1.0));
		float glow_alpha = soft_glow * mix(guardian_glow_edge_color.a, guardian_glow_core_color.a, clamp(core + radial * 0.35, 0.0, 1.0));

		if (texture_color.a < 1.0) {
			float background_alpha = glow_alpha * (1.0 - texture_color.a);
			color.rgb = mix(glow_rgb, color.rgb, texture_color.a);
			color.a = max(color.a, background_alpha);
		}

		if (texture_color.a > 0.0) {
			float body_light = soft_glow * texture_color.a * guardian_body_light;
			color.rgb = min(color.rgb + glow_rgb * body_light, vec3(1.0));
			color.a = max(color.a, texture_color.a * COLOR.a);
		}
	}

	COLOR = color;
}
