extends CapooAK47
class_name CompatHandoffCapooAK47Harness

## Records the real shared family runner boundary without replacing any authored
## state-machine behavior. Used to prove an in-tick LAYERED -> COMPAT handoff
## executes once as individual on the old frame and once as scheduled next frame.

var runner_records: Array[Dictionary] = []


func _run_authoritative_physics_step(delta: float) -> void:
	runner_records.append({
		"physics_frame": Engine.get_physics_frames(),
		"centralized": is_centrally_simulated(),
	})
	super._run_authoritative_physics_step(delta)
