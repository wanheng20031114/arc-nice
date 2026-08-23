shader_type canvas_item;
render_mode unshaded, blend_add;

// INSTANCE_CUSTOM.r is normalized hit age. A compact procedural flash keeps
// every authoritative hit in one authored MultiMesh without per-hit nodes.
varying float hit_age;

void vertex() {
	hit_age = clamp(INSTANCE_CUSTOM.r, 0.0, 1.0);
}

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float radial = 1.0 - smoothstep(0.05, 0.72, length(centered));
	float horizontal = 1.0 - smoothstep(0.02, 0.16, abs(centered.y));
	float vertical = 1.0 - smoothstep(0.02, 0.16, abs(centered.x));
	float spark = max(radial, max(horizontal, vertical) * (1.0 - length(centered)));
	float fade = 1.0 - smoothstep(0.0, 1.0, hit_age);
	vec3 tint = mix(vec3(1.0, 0.88, 0.42), vec3(1.0, 0.42, 0.12), hit_age);
	COLOR = vec4(tint * spark * fade, spark * fade);
}
