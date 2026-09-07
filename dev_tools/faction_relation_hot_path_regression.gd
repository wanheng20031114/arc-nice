extends SceneTree

class OriginalRelations extends CombatRelationService:
	func is_hostile(source_faction: int, target_faction: int) -> bool:
		if not is_valid_faction(source_faction) or not is_valid_faction(target_faction):
			return false
		return (_hostile_masks[source_faction] & (1 << target_faction)) != 0


var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)


func _run() -> void:
	var current := CombatRelationService.new()
	var original := OriginalRelations.new()
	var ids: Array[int] = [-9223372036854775807, -1, 32, 33, 9223372036854775807]
	for faction in 32:
		ids.append(faction)
	for pass_index in 3:
		for source in ids:
			for target in ids:
				_check(current.is_hostile(source, target) == original.is_hostile(source, target), "Directed matrix and invalid ID parity")
		for source in ids:
			for target in ids:
				var enabled := pass_index == 0
				_check(current.set_hostile(source, target, enabled) == original.set_hostile(source, target, enabled), "Same-frame relation mutation parity")
		_check(current.get_revision() == original.get_revision(), "Revision changes remain exact")
		if pass_index == 1:
			current.reset_default_relations()
			original.reset_default_relations()
	var timing := []
	var accepted := 0
	for pass_index in 4:
		var service: CombatRelationService = original if pass_index == 0 or pass_index == 3 else current
		service.reset_default_relations()
		var started := Time.get_ticks_usec()
		for query in 200000:
			accepted += int(service.is_hostile(2, 1))
			accepted += int(service.is_hostile(2, 2))
			accepted += int(service.is_hostile(1, 32))
		timing.append({"original": pass_index == 0 or pass_index == 3, "usec": Time.get_ticks_usec() - started})
	_check(accepted == 800000, "Benchmark consumes the exact relation results")
	print("FACTION_HOT_PATH ", JSON.stringify({"checks": checks, "failures": failures, "queries_per_pass": 600000, "abba": timing}))
	quit(0 if failures.is_empty() else 1)
