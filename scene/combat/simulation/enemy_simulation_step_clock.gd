extends RefCounted

## Advances only when the coordinator actually enters gameplay phases. A paused
## SceneTree (or a rejected contact preflight) contributes no simulation step.
## Store one epoch per change of delta, never one allocation per ordinary tick.
var tick := 0
var delta := 0.0
var epoch_ticks: Array[int] = []
var epoch_deltas: Array[float] = []


func advance(step_delta: float) -> void:
	tick += 1
	delta = maxf(step_delta, 0.0)
	if epoch_deltas.is_empty() or epoch_deltas[-1] != delta:
		epoch_ticks.append(tick)
		epoch_deltas.append(delta)
