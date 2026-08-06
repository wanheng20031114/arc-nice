extends Node
class_name CraftingResearchStateProvider

signal research_state_changed


func get_completed_global_research_ids() -> Array[StringName]:
	var completed_ids: Array[StringName] = []
	return completed_ids
