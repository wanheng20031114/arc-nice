shader_type canvas_item;

uniform bool blink_enabled = false;
uniform float blink_speed : hint_range(1.0, 30.0) = 12.0;
uniform float hidden_ratio : hint_range(0.0, 1.0) = 0.5;
uniform float dodge_effect_strength : hint_range(0.0, 1.0) = 0.0;
uniform float dodge_sweep : hint_range(-0.4, 1.4) = 0.0;
uniform vec4 dodge_color : source_color = vec4(0.42, 0.95, 1.0, 1.0);
uniform vec4 dodge_flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float dodge_outline_width : hint_range(1.0, 6.0) = 3.0;
uniform float slow_overlay_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 slow_overlay_color : source_color = vec4(0.55, 0.86, 1.0, 1.0);

void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 color = texture_color * COLOR;

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
		color.a = max(color.a, texture_color.a * COLOR.a);
	}

	if (slow_overlay_strength > 0.0 && texture_color.a > 0.0) {
		float mask = clamp(slow_overlay_strength * texture_color.a, 0.0, 1.0);
		color.rgb = mix(color.rgb, slow_overlay_color.rgb, mask);
		color.rgb = min(color.rgb + slow_overlay_color.rgb * mask * 0.08, vec3(1.0));
		color.a = max(color.a, texture_color.a * COLOR.a);
	}

	COLOR = color;
}
