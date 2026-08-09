extends RefCounted
class_name CombatFlowState

## Stable combat-flow wire values. These values are part of protocol v50 and
## must not be reordered when mode-specific flow implementations are split.
enum State {
	PRE_WAVE = 0,
	WAVE_ACTIVE = 1,
	INTERMISSION = 2,
	VICTORY = 3,
	DEFEAT = 4,
	BOSS_INTRO = 5,
	BOSS_ACTIVE = 6,
	FATE_INTERLUDE = 7,
}


static func is_terminal(state: State) -> bool:
	return state == State.VICTORY or state == State.DEFEAT


static func is_wave_state(state: State) -> bool:
	return state in [
		State.PRE_WAVE,
		State.WAVE_ACTIVE,
		State.INTERMISSION,
		State.VICTORY,
		State.DEFEAT,
	]
