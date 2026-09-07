extends RefCounted

## Diagnostic state has no dependency on the Enemy inheritance graph. Keeping
## static storage on StoneGolem retains that graph during Godot 4.6.2 shutdown
## when a sibling/base enemy script was loaded first. The independent owner
## preserves shared counters without retaining any gameplay script or node.
static var enabled := false
static var counters := {
	"slam_query_calls": 0,
	"slam_query_usec": 0,
	"slam_total_usec": 0,
	"slam_query_results": 0,
	"slam_unique_targets": 0,
	"slam_damage_dispatches": 0,
	"slam_physics_queries": 0,
}
