shader_type canvas_item;

uniform bool blink_enabled = false;
uniform float blink_speed : hint_range(1.0, 30.0) = 12.0;
uniform float hidden_ratio : hint_range(0.0, 1.0) = 0.5;
uniform float dodge_effect_strength : hint_range(0.0, 1.0) = 0.0;
uniform float dodge_sweep : hint_range(-0.4, 1.4) = 0.0;
uniform vec4 dodge_color : source_color = vec4(0.42, 0.95, 1.0, 1.0);
uniform vec4 dodge_flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float dodge_outline_width : hint_range(1.0, 6.0) = 3.0;
uniform bool guardian_glow_enabled = false;
uniform float guardian_glow_strength : hint_range(0.0, 1.0) = 0.0;
uniform float guardian_glow_radius : hint_range(0.05, 0.75) = 0.52;
uniform float guardian_glow_core_radius : hint_range(0.0, 0.5) = 0.08;
uniform vec2 guardian_glow_center = vec2(0.5, 0.54);
uniform vec4 guardian_glow_color : source_color = vec4(0.12, 0.75, 1.0, 0.78);

void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 color = texture_color * COLOR;
	float sprite_visibility = 1.0;
	 
	if (blink_enabled) {
		float blink_phase = fract(TIME * blink_speed);
		if (blink_phase < hidden_ratio) {
			color.a = 0.0;
			sprite_visibility = 0.0;
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

	if (guardian_glow_enabled && guardian_glow_strength > 0.0) {
		vec2 center_delta = UV - guardian_glow_center;
		center_delta.x *= TEXTURE_PIXEL_SIZE.y / TEXTURE_PIXEL_SIZE.x;
		float distance_from_center = length(center_delta);
		float radius = max(guardian_glow_radius, guardian_glow_core_radius + 0.001);
		float pulse = 0.84 + 0.16 * sin(TIME * 3.2);
		float radial_falloff = 1.0 - smoothstep(guardian_glow_core_radius, radius, distance_from_center);
		float center_bloom = 1.0 - smoothstep(0.0, max(guardian_glow_core_radius, 0.001), distance_from_center);
		float aura = clamp(pow(radial_falloff, 1.65) + center_bloom * 0.28, 0.0, 1.0);
		aura *= guardian_glow_strength * pulse * sprite_visibility;
		float background_glow = aura * (1.0 - texture_color.a) * guardian_glow_color.a;
		if (background_glow > 0.0) {
			color.rgb = mix(color.rgb, guardian_glow_color.rgb, background_glow);
			color.a = max(color.a, background_glow * 0.72);
		}
		if (texture_color.a > 0.0) {
			float body_light = aura * texture_color.a * 0.16;
			color.rgb = min(color.rgb + guardian_glow_color.rgb * body_light, vec3(1.0));
			color.a = max(color.a, texture_color.a * COLOR.a * sprite_visibility);
		}
	}
	
	COLOR = color ;
}

//void light() {
//	// Called for every pixel for every light affecting the CanvasItem.
//	// Uncomment to replace the default light processing function with this one.
//}
