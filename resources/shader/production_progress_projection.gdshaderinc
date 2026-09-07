// All production borders share one gameplay clock update per rendered frame.
// Each building publishes this bounded projection only when its state changes.
global uniform float production_visual_time;
instance uniform float progress_value : hint_range(0.0, 1.0) = 0.0;
// x: target ratio, y: gameplay epoch, z: seconds until the next logic sample.
instance uniform vec3 progress_projection = vec3(0.0);

float production_displayed_progress() {
	float fraction = clamp(
		(production_visual_time - progress_projection.y) / max(progress_projection.z, 0.001),
		0.0, 1.0
	);
	return mix(progress_value, progress_projection.x, fraction);
}
