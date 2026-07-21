shader_type canvas_item;
render_mode unshaded;

// Generic, AK and SMG rounds are numerous enough that separate core and halo
// sprites become a render-thread bottleneck. Keep their pixel-art body, HDR
// emission and a restrained analytic halo in one shared draw. WorldEnvironment
// glow can extend that halo where the active renderer supports it.
uniform float highlight_threshold : hint_range(0.0, 1.0) = 0.38;
uniform float highlight_softness : hint_range(0.001, 0.5) = 0.22;
uniform float emission_strength : hint_range(0.0, 2.0) = 0.58;
uniform vec4 emission_tint : source_color = vec4(1.0, 0.72, 0.28, 1.0);
uniform float quad_expansion : hint_range(1.0, 2.5) = 1.75;
uniform float halo_opacity : hint_range(0.0, 0.3) = 0.085;

varying vec4 vertex_color;

void vertex() {
	vertex_color = COLOR;
	VERTEX *= quad_expansion;
}

void fragment() {
	vec2 region_size = max(REGION_RECT.zw, vec2(0.000001));
	vec2 halo_uv = (UV - REGION_RECT.xy) / region_size;
	vec2 source_local_uv = (
		(halo_uv - vec2(0.5)) * quad_expansion + vec2(0.5)
	);
	vec2 source_uv = REGION_RECT.xy + source_local_uv * region_size;
	float inside_source = (
		step(0.0, source_local_uv.x)
		* step(source_local_uv.x, 1.0)
		* step(0.0, source_local_uv.y)
		* step(source_local_uv.y, 1.0)
	);
	vec4 source = texture(TEXTURE, source_uv) * vertex_color * inside_source;
	float peak = max(source.r, max(source.g, source.b));
	float highlight = smoothstep(
		highlight_threshold - highlight_softness,
		highlight_threshold + highlight_softness,
		peak
	);
	vec3 tinted_source = source.rgb * mix(vec3(1.0), emission_tint.rgb, 0.42);
	float emission_gain = emission_strength * mix(0.24, 1.0, highlight);
	vec3 body_color = source.rgb + tinted_source * emission_gain;

	// A very low-alpha analytic halo occupies the padding created in vertex().
	// It guarantees a readable spatial falloff even when a platform's glow
	// threshold suppresses bloom from very small (4-16 px) projectiles.
	float halo_distance = length((halo_uv - vec2(0.5)) * 2.0);
	float halo = 1.0 - smoothstep(0.18, 1.0, halo_distance);
	float halo_alpha = halo * halo_opacity * (1.0 - source.a);
	vec3 halo_color = emission_tint.rgb * 1.18;

	COLOR = vec4(
		mix(halo_color, body_color, source.a),
		max(source.a, halo_alpha)
	);
}
