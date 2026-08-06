extends "res://scene/multiplayer/mp_game.gd"
class_name RogueCombatMultiplayerTestSession

## Lightweight typed MultiplayerGameplaySession fixture for the Rogue combat
## coordinator state-machine smoke. It suppresses MpGame's ordinary scene-tree
## lifecycle while retaining its complete gameplay-session contract.

var activation_result := false
var activation_calls := 0
var suspended_peers: Array[PackedInt32Array] = []
var configured_roster := PackedInt32Array()
var game_runtime: CombatRuntimeBase = null


func _ready() -> void:
	set_process(false)
	set_physics_process(false)


func _exit_tree() -> void:
	if (
		game_runtime != null
		and is_instance_valid(game_runtime)
		and game_runtime.get_parent() == null
	):
		game_runtime.free()
	game_runtime = null


func _process(_delta: float) -> void:
	pass


func _physics_process(_delta: float) -> void:
	pass


func configure_embedded_participant_roster(
	peer_ids: PackedInt32Array
) -> bool:
	configured_roster = peer_ids.duplicate()
	return not configured_roster.is_empty()


func activate_embedded_runtime() -> bool:
	activation_calls += 1
	return activation_result


func get_game_runtime() -> CombatRuntimeBase:
	return game_runtime


func suspend_embedded_participant_for_current_combat(
	peer_id: int,
	previous_peer_id: int = -1
) -> bool:
	suspended_peers.append(PackedInt32Array([
		peer_id,
		previous_peer_id,
	]))
	return true
