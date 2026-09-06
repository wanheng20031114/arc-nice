extends RefCounted
class_name PvpRules

## All weapon and economy values are owned by the host, never supplied by clients.
const PLAYER_HEALTH := 100
const MOVE_SPEED := 100.0
const BULLET_SPEED := 500.0
const BULLET_LIFETIME := 2.4
const START_MONEY := 4000
const MAX_MONEY := 16000
const AK_PRICE := 2700
const BUY_SECONDS := 15.0
const ROUND_SECONDS := 90.0
const RESULT_SECONDS := 5.0
const WIN_SCORE := 7
const PICKUP_DISTANCE := 28.0
const WEAPONS := {
	"deagle": {"name": "沙漠之鹰", "body_damage": 25, "head_damage": 100,
		"magazine": 7, "reserve": 35, "fire_interval": 0.28, "reload_seconds": 1.8},
	"ak": {"name": "AK-47", "body_damage": 20, "head_damage": 100,
		"magazine": 30, "reserve": 90, "fire_interval": 0.10, "reload_seconds": 2.2},
}

static func new_weapon(weapon: String) -> Dictionary:
	assert(WEAPONS.has(weapon))
	return {"ammo": int(WEAPONS[weapon].magazine), "reserve": int(WEAPONS[weapon].reserve)}

static func damage(weapon: String, headshot: bool) -> int:
	assert(WEAPONS.has(weapon))
	return int(WEAPONS[weapon].head_damage if headshot else WEAPONS[weapon].body_damage)

static func opposite_team(team: String) -> String:
	return "T" if team == "CT" else "CT"
