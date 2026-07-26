extends RefCounted
class_name CombatAttackRegistry

## Stable IDs allowed in an untrusted player-hit claim. Host-only contact,
## hitscan and area attacks never need a client claim and intentionally have no
## wire ID. Values are explicit so a protocol build cannot silently reorder them.
enum PlayerHitWireId {
	INVALID = 0,
	YUANSHI_FIRE_PROJECTILE = 1,
	CAPOO_AK47_BULLET = 2,
	CAPOO_SMG_BULLET = 3,
	CAPOO_RPG_ROCKET = 4,
	CAPOO_MAGE_FIREBALL = 5,
	FIRE_SORCERER_FIREBALL_A = 6,
	FIRE_SORCERER_FIREBALL_B = 7,
	FIRE_SORCERER_FIREBALL_C = 8,
	FIRE_SORCERER_ELITE_FIREBALL_A = 9,
	FIRE_SORCERER_ELITE_FIREBALL_B = 10,
	FIRE_SORCERER_ELITE_FIREBALL_C = 11,
	FROST_SORCERER_ICE_SPIKE = 12,
	LINGLAN_SKILL1 = 13,
	LINGLAN_SKILL2_ROCKET = 14,
	LINGLAN_SKILL3_ORB = 15,
	LINGLAN_SKILL4_ORB = 16,
}

const FIRE_SORCERER_VOLLEY := &"fire_sorcerer_fireball_volley"
const FIRE_SORCERER_ELITE_VOLLEY := &"fire_sorcerer_elite_fireball_volley"
const FIRE_SLIME_TOUCH := &"fire_slime_touch"
const FROST_SLIME_TOUCH := &"frost_slime_touch"
const FROST_SORCERER_ICE_SPIKE := &"frost_sorcerer_ice_spike"
const FIRE_SLIME_BURN_DURATION_SECONDS := 3.0
const FIRE_SLIME_BURN_TICK_DAMAGE := 10
const FIRE_SORCERER_CONFIG: FireSorcererConfig = preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const FIRE_SORCERER_ELITE_CONFIG: FireSorcererConfig = preload(
	"res://resources/config/enemies/fire_sorcerer_elite.tres"
)


static func encode_player_hit_source(source_type: StringName) -> int:
	match source_type:
		&"yuanshi_fire_projectile":
			return PlayerHitWireId.YUANSHI_FIRE_PROJECTILE
		&"capoo_ak47_bullet":
			return PlayerHitWireId.CAPOO_AK47_BULLET
		&"capoo_smg_bullet":
			return PlayerHitWireId.CAPOO_SMG_BULLET
		&"capoo_rpg_rocket":
			return PlayerHitWireId.CAPOO_RPG_ROCKET
		&"capoo_mage_fireball":
			return PlayerHitWireId.CAPOO_MAGE_FIREBALL
		&"fire_sorcerer_fireball_a":
			return PlayerHitWireId.FIRE_SORCERER_FIREBALL_A
		&"fire_sorcerer_fireball_b":
			return PlayerHitWireId.FIRE_SORCERER_FIREBALL_B
		&"fire_sorcerer_fireball_c":
			return PlayerHitWireId.FIRE_SORCERER_FIREBALL_C
		&"fire_sorcerer_elite_fireball_a":
			return PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_A
		&"fire_sorcerer_elite_fireball_b":
			return PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_B
		&"fire_sorcerer_elite_fireball_c":
			return PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_C
		&"frost_sorcerer_ice_spike":
			return PlayerHitWireId.FROST_SORCERER_ICE_SPIKE
		&"linglan_skill1":
			return PlayerHitWireId.LINGLAN_SKILL1
		&"linglan_skill2_rocket":
			return PlayerHitWireId.LINGLAN_SKILL2_ROCKET
		&"linglan_skill3_orb":
			return PlayerHitWireId.LINGLAN_SKILL3_ORB
		&"linglan_skill4_orb":
			return PlayerHitWireId.LINGLAN_SKILL4_ORB
		_:
			return PlayerHitWireId.INVALID


static func decode_player_hit_source(wire_id: int) -> StringName:
	match wire_id:
		PlayerHitWireId.YUANSHI_FIRE_PROJECTILE:
			return &"yuanshi_fire_projectile"
		PlayerHitWireId.CAPOO_AK47_BULLET:
			return &"capoo_ak47_bullet"
		PlayerHitWireId.CAPOO_SMG_BULLET:
			return &"capoo_smg_bullet"
		PlayerHitWireId.CAPOO_RPG_ROCKET:
			return &"capoo_rpg_rocket"
		PlayerHitWireId.CAPOO_MAGE_FIREBALL:
			return &"capoo_mage_fireball"
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_A:
			return &"fire_sorcerer_fireball_a"
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_B:
			return &"fire_sorcerer_fireball_b"
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_C:
			return &"fire_sorcerer_fireball_c"
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_A:
			return &"fire_sorcerer_elite_fireball_a"
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_B:
			return &"fire_sorcerer_elite_fireball_b"
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_C:
			return &"fire_sorcerer_elite_fireball_c"
		PlayerHitWireId.FROST_SORCERER_ICE_SPIKE:
			return &"frost_sorcerer_ice_spike"
		PlayerHitWireId.LINGLAN_SKILL1:
			return &"linglan_skill1"
		PlayerHitWireId.LINGLAN_SKILL2_ROCKET:
			return &"linglan_skill2_rocket"
		PlayerHitWireId.LINGLAN_SKILL3_ORB:
			return &"linglan_skill3_orb"
		PlayerHitWireId.LINGLAN_SKILL4_ORB:
			return &"linglan_skill4_orb"
		_:
			return &""


static func get_certificate_projectile_type(wire_id: int) -> StringName:
	match wire_id:
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_A, \
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_B, \
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_C:
			return FIRE_SORCERER_VOLLEY
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_A, \
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_B, \
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_C:
			return FIRE_SORCERER_ELITE_VOLLEY
		_:
			return decode_player_hit_source(wire_id)


static func get_damage_type(wire_id: int) -> int:
	match wire_id:
		PlayerHitWireId.CAPOO_MAGE_FIREBALL, \
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_A, \
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_B, \
		PlayerHitWireId.FIRE_SORCERER_FIREBALL_C, \
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_A, \
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_B, \
		PlayerHitWireId.FIRE_SORCERER_ELITE_FIREBALL_C, \
		PlayerHitWireId.FROST_SORCERER_ICE_SPIKE, \
		PlayerHitWireId.LINGLAN_SKILL3_ORB, \
		PlayerHitWireId.LINGLAN_SKILL4_ORB:
			return CombatTypes.DamageType.MAGIC
		PlayerHitWireId.INVALID:
			return -1
		_:
			return CombatTypes.DamageType.PHYSICAL


static func is_ranged(wire_id: int) -> bool:
	return wire_id != PlayerHitWireId.INVALID


static func get_burn_family(source_type: StringName) -> StringName:
	if source_type == FIRE_SLIME_TOUCH:
		return FIRE_SLIME_TOUCH
	match source_type:
		&"fire_sorcerer_fireball_a", \
		&"fire_sorcerer_fireball_b", \
		&"fire_sorcerer_fireball_c", \
		FIRE_SORCERER_VOLLEY:
			return FIRE_SORCERER_VOLLEY
		&"fire_sorcerer_elite_fireball_a", \
		&"fire_sorcerer_elite_fireball_b", \
		&"fire_sorcerer_elite_fireball_c", \
		FIRE_SORCERER_ELITE_VOLLEY:
			return FIRE_SORCERER_ELITE_VOLLEY
		_:
			return &""


static func get_burn_duration(source_type: StringName) -> float:
	match get_burn_family(source_type):
		FIRE_SLIME_TOUCH:
			return FIRE_SLIME_BURN_DURATION_SECONDS
		FIRE_SORCERER_VOLLEY:
			return FIRE_SORCERER_CONFIG.burn_duration
		FIRE_SORCERER_ELITE_VOLLEY:
			return FIRE_SORCERER_ELITE_CONFIG.burn_duration
		_:
			return 0.0


static func get_burn_tick_damage(source_type: StringName) -> int:
	match get_burn_family(source_type):
		FIRE_SLIME_TOUCH:
			return FIRE_SLIME_BURN_TICK_DAMAGE
		FIRE_SORCERER_VOLLEY:
			return FIRE_SORCERER_CONFIG.burn_level
		FIRE_SORCERER_ELITE_VOLLEY:
			return FIRE_SORCERER_ELITE_CONFIG.burn_level
		_:
			return 0


static func applies_cold(source_type: StringName) -> bool:
	return (
		source_type == FROST_SLIME_TOUCH
		or source_type == FROST_SORCERER_ICE_SPIKE
	)
