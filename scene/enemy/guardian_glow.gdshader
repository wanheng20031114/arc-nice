shader_type canvas_item;

uniform bool blink_enabled = false;
uniform float blink_speed : hint_range(1.0, 30.0) = 12.0;
uniform float hidden_ratio : hint_range(0.0, 1.0) = 0.5;

uniform bool guardian_glow_enabled = true;
uniform float guardian_glow_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec2 guardian_glow_center = vec2(0.5, 0.44);
uniform float guardian_glow_outer_radius : hint_range(0.05, 0.5) = 0.46;
uniform float guardian_glow_mid_radius : hint_range(0.02, 0.45) = 0.30;
uniform float guardian_glow_core_radius : hint_range(0.0, 0.3) = 0.13;
uniform vec4 guardian_glow_core_color : source_color = vec4(0.36, 0.96, 1.0, 0.92);
uniform vec4 guardian_glow_edge_color : source_color = vec4(0.05, 0.52, 1.0, 0.68);
uniform float guardian_body_light : hint_range(0.0, 1.0) = 0.30;

void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 color = texture_color * COLOR;
	float sprite_visible = 1.0;

	if (blink_enabled) {
		float blink_phase = fract(TIME * blink_speed);
		if (blink_phase < hidden_ratio) {
			color.a = 0.0;
			sprite_visible = 0.0;
		}
	}

	if (guardian_glow_enabled && guardian_glow_strength > 0.0 && sprite_visible > 0.0) {
		vec2 center_delta = UV - guardian_glow_center;
		center_delta.x *= TEXTURE_PIXEL_SIZE.y / TEXTURE_PIXEL_SIZE.x;
		float distance_from_center = length(center_delta);

		float outer_radius = max(guardian_glow_outer_radius, 0.001);
		float mid_radius = min(guardian_glow_mid_radius, outer_radius - 0.001);
		float core_radius = min(guardian_glow_core_radius, mid_radius - 0.001);

		float outer_falloff = 1.0 - smoothstep(mid_radius, outer_radius, distance_from_center);
		float mid_falloff = 1.0 - smoothstep(core_radius, mid_radius, distance_from_center);
		float core_falloff = 1.0 - smoothstep(0.0, core_radius, distance_from_center);
		float pulse = 0.90 + 0.10 * sin(TIME * 2.8);
		float glow = clamp(
			pow(outer_falloff, 2.15) * 0.72
			+ pow(mid_falloff, 1.45) * 0.34
			+ core_falloff * 0.18,
			0.0,
			1.0
		) * guardian_glow_strength * pulse;

		vec3 glow_rgb = mix(guardian_glow_edge_color.rgb, guardian_glow_core_color.rgb, clamp(mid_falloff + core_falloff * 0.35, 0.0, 1.0));
		float glow_alpha = glow * mix(guardian_glow_edge_color.a, guardian_glow_core_color.a, core_falloff);
		float background_glow = glow_alpha * (1.0 - texture_color.a);

		if (background_glow > 0.0) {
			color.rgb = glow_rgb;
			color.a = max(color.a, background_glow);
		}

		if (texture_color.a > 0.0) {
			float body_glow = glow * texture_color.a;
			color.rgb = min(
				color.rgb
				+ glow_rgb * body_glow * guardian_body_light
				+ guardian_glow_core_color.rgb * core_falloff * texture_color.a * 0.12,
				vec3(1.0)
			);
			color.a = max(color.a, texture_color.a * COLOR.a);
		}
	}

	COLOR = color;
}
