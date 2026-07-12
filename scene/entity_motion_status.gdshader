shader_type canvas_item;

uniform bool blink_enabled = false;
uniform float blink_speed : hint_range(1.0, 30.0) = 12.0;
uniform float hidden_ratio : hint_range(0.0, 1.0) = 0.5;
uniform float dodge_effect_strength : hint_range(0.0, 1.0) = 0.0;
uniform float dodge_sweep : hint_range(-0.4, 1.4) = 0.0;
uniform vec4 dodge_color : source_color = vec4(0.42, 0.95, 1.0, 1.0);
uniform vec4 dodge_flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float dodge_outline_width : hint_range(1.0, 6.0) = 3.0;
uniform float dash_effect_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec2 dash_direction = vec2(1.0, 0.0);
uniform vec4 dash_color : source_color = vec4(0.12, 1.45, 1.3, 1.0);
uniform float dash_trail_pixels : hint_range(1.0, 8.0) = 4.0;
instance uniform float slow_overlay_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 slow_overlay_color : source_color = vec4(0.55, 0.86, 1.0, 1.0);
instance uniform float burn_overlay_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 burn_overlay_color : source_color = vec4(1.0, 0.56, 0.18, 0.46);
uniform float burn_edge_width : hint_range(1.0, 5.0) = 2.0;
instance uniform float bleed_overlay_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 bleed_overlay_color : source_color = vec4(0.95, 0.02, 0.08, 0.58);
uniform float bleed_outline_width : hint_range(1.0, 5.0) = 2.0;
uniform float revive_glow_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 revive_glow_color : source_color = vec4(3.2, 3.2, 3.2, 1.0);
uniform float revive_glow_outline_width : hint_range(1.0, 8.0) = 4.5;

void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 color = COLOR;

	if (blink_enabled && color.a > 0.0) {
		float blink_phase = fract(TIME * blink_speed);
		if (blink_phase < hidden_ratio) {
			color.a = 0.0;
		}
	}

	if (dodge_effect_strength > 0.0) {
		vec2 outline_offset = TEXTURE_PIXEL_SIZE * dodge_outline_width;
		float neighbor_alpha = 0.0;
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(outline_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(outline_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(0.0, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(0.0, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + outline_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - outline_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(outline_offset.x, -outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(-outline_offset.x, outline_offset.y)).a);
		float outline_mask = max(neighbor_alpha - texture_color.a, 0.0) * dodge_effect_strength;
		if (outline_mask > 0.0) {
			color.rgb = mix(color.rgb, dodge_color.rgb, outline_mask);
			color.a = max(color.a, outline_mask * 0.9);
		}
	}

	if (dodge_effect_strength > 0.0 && texture_color.a > 0.0) {
		float sweep = 1.0 - smoothstep(0.0, 0.2, abs(UV.x - dodge_sweep));
		float rim = smoothstep(0.14, 0.02, min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y)));
		float pulse = 0.65 + 0.35 * sin(TIME * 44.0);
		float mask = clamp(sweep * 1.15 + rim * 0.75 + pulse * 0.18, 0.0, 1.0) * dodge_effect_strength;
		color.rgb = mix(color.rgb, dodge_flash_color.rgb, mask * 0.42);
		color.rgb = min(color.rgb + dodge_color.rgb * mask * 0.45, vec3(1.0));
		color.a = max(color.a, COLOR.a);
	}

	if (dash_effect_strength > 0.0) {
		vec2 direction = dash_direction;
		if (length(direction) < 0.001) {
			direction = vec2(1.0, 0.0);
		} else {
			direction = normalize(direction);
		}
		vec2 trail_offset = direction * TEXTURE_PIXEL_SIZE * dash_trail_pixels;
		float trail_alpha = 0.0;
		trail_alpha = max(trail_alpha, texture(TEXTURE, clamp(UV + trail_offset * 0.45, vec2(0.0), vec2(1.0))).a * 0.9);
		trail_alpha = max(trail_alpha, texture(TEXTURE, clamp(UV + trail_offset * 0.9, vec2(0.0), vec2(1.0))).a * 0.62);
		trail_alpha = max(trail_alpha, texture(TEXTURE, clamp(UV + trail_offset * 1.35, vec2(0.0), vec2(1.0))).a * 0.36);
		float trail_mask = max(trail_alpha - texture_color.a, 0.0) * dash_effect_strength;
		if (trail_mask > 0.0) {
			color.rgb = mix(color.rgb, dash_color.rgb, min(trail_mask * 1.2, 1.0));
			color.a = max(color.a, trail_mask * 0.76);
		}
		if (texture_color.a > 0.0) {
			vec2 perpendicular = vec2(-direction.y, direction.x);
			float scan = 0.5 + 0.5 * sin(dot(UV - vec2(0.5), perpendicular) * 72.0 - TIME * 54.0);
			float leading_edge = clamp(dot(UV - vec2(0.5), direction) + 0.58, 0.0, 1.0);
			float body_mask = dash_effect_strength * texture_color.a * (0.22 + scan * 0.16 + leading_edge * 0.24);
			color.rgb = mix(color.rgb, dash_color.rgb, min(body_mask * 0.5, 1.0));
			color.rgb += dash_color.rgb * body_mask * 0.34;
			color.a = max(color.a, COLOR.a);
		}
	}

	if (slow_overlay_strength > 0.0 && texture_color.a > 0.0) {
		float mask = clamp(slow_overlay_strength * texture_color.a, 0.0, 1.0);
		color.rgb = mix(color.rgb, slow_overlay_color.rgb, mask);
		color.rgb = min(color.rgb + slow_overlay_color.rgb * mask * 0.08, vec3(1.0));
		color.a = max(color.a, COLOR.a);
	}

	if (burn_overlay_strength > 0.0 && texture_color.a > 0.0) {
		vec2 edge_offset = TEXTURE_PIXEL_SIZE * burn_edge_width;
		float min_neighbor_alpha = 1.0;
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV + vec2(edge_offset.x, 0.0)).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV - vec2(edge_offset.x, 0.0)).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV + vec2(0.0, edge_offset.y)).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV - vec2(0.0, edge_offset.y)).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV + edge_offset).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV - edge_offset).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV + vec2(edge_offset.x, -edge_offset.y)).a);
		min_neighbor_alpha = min(min_neighbor_alpha, texture(TEXTURE, UV + vec2(-edge_offset.x, edge_offset.y)).a);
		float inner_edge = clamp(texture_color.a * (1.0 - min_neighbor_alpha), 0.0, 1.0);
		float cycle = 0.62 + 0.38 * sin(TIME * 5.6 + UV.y * 18.0 + UV.x * 5.0);
		float gradient = clamp((0.12 + inner_edge * 0.88) * cycle, 0.0, 1.0);
		float mask = clamp(burn_overlay_strength * burn_overlay_color.a * gradient, 0.0, 1.0);
		color.rgb = mix(color.rgb, burn_overlay_color.rgb, mask);
		color.rgb = min(color.rgb + burn_overlay_color.rgb * mask * 0.05, vec3(1.0));
		color.a = max(color.a, COLOR.a);
	}

	if (bleed_overlay_strength > 0.0) {
		float pulse = 0.86 + 0.14 * sin(TIME * 9.0);
		vec2 outline_offset = TEXTURE_PIXEL_SIZE * bleed_outline_width * pulse;
		vec2 inner_edge_offset = TEXTURE_PIXEL_SIZE;
		float neighbor_alpha = 0.0;
		float inner_min_alpha = 1.0;
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(outline_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(outline_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(0.0, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(0.0, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + outline_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - outline_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(outline_offset.x, -outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(-outline_offset.x, outline_offset.y)).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV + vec2(inner_edge_offset.x, 0.0)).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV - vec2(inner_edge_offset.x, 0.0)).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV + vec2(0.0, inner_edge_offset.y)).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV - vec2(0.0, inner_edge_offset.y)).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV + inner_edge_offset).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV - inner_edge_offset).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV + vec2(inner_edge_offset.x, -inner_edge_offset.y)).a);
		inner_min_alpha = min(inner_min_alpha, texture(TEXTURE, UV + vec2(-inner_edge_offset.x, inner_edge_offset.y)).a);
		float outer_mask = max(neighbor_alpha - texture_color.a, 0.0) * bleed_overlay_strength;
		if (outer_mask > 0.0) {
			color.rgb = mix(color.rgb, bleed_overlay_color.rgb, min(outer_mask * 1.4, 1.0));
			color.a = max(color.a, outer_mask * bleed_overlay_color.a);
		}
		if (texture_color.a > 0.0) {
			float inner_edge_mask = smoothstep(0.9, 0.15, inner_min_alpha);
			float edge_mask = clamp(texture_color.a * inner_edge_mask * bleed_overlay_strength * 0.22, 0.0, 1.0);
			color.rgb = mix(color.rgb, bleed_overlay_color.rgb, edge_mask);
			color.rgb = min(color.rgb + bleed_overlay_color.rgb * edge_mask * 0.04, vec3(1.0));
			color.a = max(color.a, COLOR.a);
		}
	}

	vec4 pre_revive_color = color;
	if (revive_glow_strength > 0.0) {
		float pulse = 0.92 + 0.08 * sin(TIME * 18.0);
		vec2 outline_offset = TEXTURE_PIXEL_SIZE * revive_glow_outline_width * pulse;
		vec2 inner_offset = outline_offset * 0.55;
		float neighbor_alpha = 0.0;
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(outline_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(outline_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(0.0, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(0.0, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + outline_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - outline_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(outline_offset.x, -outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(-outline_offset.x, outline_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(inner_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(inner_offset.x, 0.0)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(0.0, inner_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - vec2(0.0, inner_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + inner_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV - inner_offset).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(inner_offset.x, -inner_offset.y)).a);
		neighbor_alpha = max(neighbor_alpha, texture(TEXTURE, UV + vec2(-inner_offset.x, inner_offset.y)).a);
		float outline_mask = max(neighbor_alpha - texture_color.a, 0.0) * revive_glow_strength;
		if (outline_mask > 0.0) {
			color.rgb += revive_glow_color.rgb * outline_mask;
			color.a = max(color.a, outline_mask * revive_glow_color.a);
		}
		if (texture_color.a > 0.0) {
			color = pre_revive_color;
		}
	}

	COLOR = color;
}
