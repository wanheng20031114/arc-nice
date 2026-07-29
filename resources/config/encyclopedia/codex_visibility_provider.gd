extends RefCounted
class_name CodexVisibilityProvider


## Override this method when encounter/acquisition progress is introduced.
## The first release deliberately reveals every registered entry.
func get_state(_section: int, _entry_id: StringName) -> int:
	return CodexVisibilityState.REVEALED
