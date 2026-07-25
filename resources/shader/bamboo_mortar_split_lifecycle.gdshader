shader_type canvas_item;

// Both complementary mortar layers share one packed regular uniform. Godot's
// Compatibility renderer reserves 16 global-buffer slots for every CanvasItem
// that uses any instance uniform, so bamboo mortars instead share this default
// material while operational and duplicate it only during a 0.7 s transition.
//
// lifecycle_state:
// x = construction progress
// y = construction-front strength
// z = removal progress, or -1.0 while removal is disabled
// w = two exact integer noise indices packed as x_index * 1024 + y_index
uniform vec4 lifecycle_state = vec4(1.0, 0.0, -1.0, 0.0);
// x = burn overlay strength, y = bleed overlay strength. Keeping both in one
// regular uniform preserves the Compatibility renderer's zero-instance-slot
// contract; an affected mortar temporarily owns one duplicated material.
uniform vec2 damage_status_strength = vec2(0.0);

uniform sampler2D lifecycle_noise : repeat_enable, filter_nearest;
uniform vec4 burn_overlay_color : source_color = vec4(1.0, 0.56, 0.18, 0.46);
uniform float burn_edge_width : hint_range(1.0, 5.0) = 2.0;
uniform vec4 bleed_overlay_color : source_color = vec4(0.95, 0.02, 0.08, 0.58);
uniform float bleed_outline_width : hint_range(1.0, 5.0) = 2.0;

varying vec2 lifecycle_world_position;
varying float lifecycle_origin_world_y;

const float EFFECT_TOP_LOCAL_Y = -15.0;
const float EFFECT_BOTTOM_LOCAL_Y = 16.0;
const float NOISE_INDEX_STRIDE = 1024.0;
const float NOISE_X_DENOMINATOR = 997.0;
const float NOISE_Y_DENOMINATOR = 991.0;


void vertex() {
	mat4 model_to_canvas = CANVAS_MATRIX * MODEL_MATRIX;
	vec2 canvas_origin = model_to_canvas[3].xy;
	vec2 snapped_origin = floor(canvas_origin + vec2(0.5));
	mat2 canvas_basis = mat2(model_to_canvas[0].xy, model_to_canvas[1].xy);
	VERTEX += inverse(canvas_basis) * (snapped_origin - canvas_origin);

	lifecycle_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	lifecycle_origin_world_y = MODEL_MATRIX[3].y;
}


void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 result = COLOR;
	float burn_overlay_strength = clamp(damage_status_strength.x, 0.0, 1.0);
	float bleed_overlay_strength = clamp(damage_status_strength.y, 0.0, 1.0);

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
		result.rgb = mix(result.rgb, burn_overlay_color.rgb, mask);
		result.rgb = min(result.rgb + burn_overlay_color.rgb * mask * 0.05, vec3(1.0));
		result.a = max(result.a, COLOR.a);
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
			result.rgb = mix(result.rgb, bleed_overlay_color.rgb, min(outer_mask * 1.4, 1.0));
			result.a = max(result.a, outer_mask * bleed_overlay_color.a);
		}
		if (texture_color.a > 0.0) {
			float inner_edge_mask = smoothstep(0.9, 0.15, inner_min_alpha);
			float edge_mask = clamp(texture_color.a * inner_edge_mask * bleed_overlay_strength * 0.22, 0.0, 1.0);
			result.rgb = mix(result.rgb, bleed_overlay_color.rgb, edge_mask);
			result.rgb = min(result.rgb + bleed_overlay_color.rgb * edge_mask * 0.04, vec3(1.0));
			result.a = max(result.a, COLOR.a);
		}
	}

	float build_progress = clamp(lifecycle_state.x, 0.0, 1.0);
	float front_strength = clamp(lifecycle_state.y, 0.0, 1.0);
	if (build_progress < 0.9999 || front_strength > 0.0001) {
		float top_y = lifecycle_origin_world_y + EFFECT_TOP_LOCAL_Y;
		float bottom_y = lifecycle_origin_world_y + EFFECT_BOTTOM_LOCAL_Y;
		float build_front_y = mix(bottom_y, top_y, build_progress);
		float revealed = step(build_front_y, lifecycle_world_position.y);
		float front_distance = abs(
			lifecycle_world_position.y - build_front_y
		);
		float build_front = 1.0 - smoothstep(
			0.35,
			1.65,
			front_distance
		);
		build_front *= front_strength;
		result.rgb = mix(result.rgb, vec3(3.2), build_front * 0.92);
		result.a *= max(revealed, build_front);
	}

	float removal_progress = lifecycle_state.z;
	if (removal_progress >= 0.0) {
		float encoded_noise = max(lifecycle_state.w, 0.0);
		float noise_x_index = floor(
			encoded_noise / NOISE_INDEX_STRIDE
		);
		float noise_y_index = (
			encoded_noise
			- noise_x_index * NOISE_INDEX_STRIDE
		);
		vec2 noise_offset = vec2(
			noise_x_index / NOISE_X_DENOMINATOR,
			noise_y_index / NOISE_Y_DENOMINATOR
		);
		vec2 noise_uv = lifecycle_world_position / 64.0 + noise_offset;
		float noise_value = texture(lifecycle_noise, noise_uv).r;
		float dissolve_threshold = mix(
			-0.08,
			1.08,
			clamp(removal_progress, 0.0, 1.0)
		);
		float remaining = noise_value - dissolve_threshold;
		float keep_pixel = step(0.0, remaining);
		float dissolve_edge = keep_pixel * (
			1.0 - smoothstep(0.0, 0.055, remaining)
		);
		result.rgb = mix(
			result.rgb,
			vec3(1.15, 1.18, 1.12),
			dissolve_edge * 0.9
		);
		result.a *= keep_pixel;
	}

	COLOR = result;
}
