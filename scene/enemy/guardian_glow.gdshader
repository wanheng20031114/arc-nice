shader_type canvas_item;

uniform bool blink_enabled = false;
uniform float blink_speed : hint_range(1.0, 30.0) = 12.0;
uniform float hidden_ratio : hint_range(0.0, 1.0) = 0.5;

uniform bool guardian_glow_enabled = true;
uniform float guardian_glow_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec2 guardian_glow_center = vec2(0.5, 0.44);
uniform float guardian_glow_spread_pixels : hint_range(1.0, 12.0) = 8.0;
uniform float guardian_glow_center_fade_radius : hint_range(0.2, 0.75) = 0.52;
uniform vec4 guardian_glow_core_color : source_color = vec4(0.36, 0.96, 1.0, 0.92);
uniform vec4 guardian_glow_edge_color : source_color = vec4(0.05, 0.52, 1.0, 0.68);
uniform float guardian_body_light : hint_range(0.0, 1.0) = 0.38;

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
		float center_fade = 1.0 - smoothstep(
			guardian_glow_center_fade_radius * 0.74,
			guardian_glow_center_fade_radius,
			distance_from_center
		);
		float frame_edge_fade = (
			smoothstep(0.0, 0.08, UV.x)
			* smoothstep(0.0, 0.08, UV.y)
			* smoothstep(0.0, 0.08, 1.0 - UV.x)
			* smoothstep(0.0, 0.08, 1.0 - UV.y)
		);

		float spread = max(guardian_glow_spread_pixels, 1.0);
		vec2 near_offset = TEXTURE_PIXEL_SIZE * spread * 0.24;
		vec2 mid_offset = TEXTURE_PIXEL_SIZE * spread * 0.52;
		vec2 far_offset = TEXTURE_PIXEL_SIZE * spread * 0.82;
		vec2 outer_offset = TEXTURE_PIXEL_SIZE * spread;

		float glow_near = 0.0;
		glow_near = max(glow_near, texture(TEXTURE, UV + vec2(near_offset.x, 0.0)).a);
		glow_near = max(glow_near, texture(TEXTURE, UV + vec2(-near_offset.x, 0.0)).a);
		glow_near = max(glow_near, texture(TEXTURE, UV + vec2(0.0, near_offset.y)).a);
		glow_near = max(glow_near, texture(TEXTURE, UV + vec2(0.0, -near_offset.y)).a);
		glow_near = max(glow_near, texture(TEXTURE, UV + near_offset).a);
		glow_near = max(glow_near, texture(TEXTURE, UV - near_offset).a);
		glow_near = max(glow_near, texture(TEXTURE, UV + vec2(near_offset.x, -near_offset.y)).a);
		glow_near = max(glow_near, texture(TEXTURE, UV + vec2(-near_offset.x, near_offset.y)).a);

		float glow_mid = 0.0;
		glow_mid = max(glow_mid, texture(TEXTURE, UV + vec2(mid_offset.x, 0.0)).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV + vec2(-mid_offset.x, 0.0)).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV + vec2(0.0, mid_offset.y)).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV + vec2(0.0, -mid_offset.y)).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV + mid_offset).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV - mid_offset).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV + vec2(mid_offset.x, -mid_offset.y)).a);
		glow_mid = max(glow_mid, texture(TEXTURE, UV + vec2(-mid_offset.x, mid_offset.y)).a);

		float glow_far = 0.0;
		glow_far = max(glow_far, texture(TEXTURE, UV + vec2(far_offset.x, 0.0)).a);
		glow_far = max(glow_far, texture(TEXTURE, UV + vec2(-far_offset.x, 0.0)).a);
		glow_far = max(glow_far, texture(TEXTURE, UV + vec2(0.0, far_offset.y)).a);
		glow_far = max(glow_far, texture(TEXTURE, UV + vec2(0.0, -far_offset.y)).a);
		glow_far = max(glow_far, texture(TEXTURE, UV + far_offset).a);
		glow_far = max(glow_far, texture(TEXTURE, UV - far_offset).a);
		glow_far = max(glow_far, texture(TEXTURE, UV + vec2(far_offset.x, -far_offset.y)).a);
		glow_far = max(glow_far, texture(TEXTURE, UV + vec2(-far_offset.x, far_offset.y)).a);

		float glow_outer = 0.0;
		glow_outer = max(glow_outer, texture(TEXTURE, UV + vec2(outer_offset.x, 0.0)).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV + vec2(-outer_offset.x, 0.0)).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV + vec2(0.0, outer_offset.y)).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV + vec2(0.0, -outer_offset.y)).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV + outer_offset).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV - outer_offset).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV + vec2(outer_offset.x, -outer_offset.y)).a);
		glow_outer = max(glow_outer, texture(TEXTURE, UV + vec2(-outer_offset.x, outer_offset.y)).a);
		float silhouette_glow = max(
			max(glow_near * 0.92, glow_mid * 0.58),
			max(glow_far * 0.32, glow_outer * 0.16)
		);
		float core_light = 1.0 - smoothstep(0.0, 0.20, distance_from_center);
		float glow = clamp(
			pow(silhouette_glow, 1.22) * center_fade * frame_edge_fade,
			0.0,
			1.0
		) * guardian_glow_strength;

		vec3 glow_rgb = mix(
			guardian_glow_edge_color.rgb,
			guardian_glow_core_color.rgb,
			clamp(glow_near * 0.62 + core_light * 0.44, 0.0, 1.0)
		);
		float glow_alpha = glow * mix(guardian_glow_edge_color.a, guardian_glow_core_color.a, core_light);
		float background_glow = glow_alpha * (1.0 - texture_color.a);

		if (background_glow > 0.0) {
			color.rgb = glow_rgb;
			color.a = max(color.a, background_glow);
		}

		if (texture_color.a > 0.0) {
			float body_glow = max(glow_near * 0.55, core_light * 0.26) * texture_color.a;
			color.rgb = min(
				color.rgb
				+ glow_rgb * body_glow * guardian_body_light
				+ guardian_glow_core_color.rgb * core_light * texture_color.a * 0.16,
				vec3(1.0)
			);
			color.a = max(color.a, texture_color.a * COLOR.a);
		}
	}

	COLOR = color;
}
