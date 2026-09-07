extends RefCounted
class_name VehicleRunProgress

## Run-local progression and scoring. A completed wave can settle only once;
## changing scene or retrying creates a new instance instead of reusing globals.
const ATTACK_PER_SERVICE := 4
const HEALTH_PER_SERVICE := 10
const REPAIR_HEALTH_RATIO := 0.25
const RECORD_PATH := "user://vehicle_records.cfg"

var cleared_waves := 0
var kills := 0
var score := 0
var combat_seconds := 0.0
var wave_seconds := 0.0
var wave_health_loss := 0
var total_health_loss := 0
var last_wave_bonus := 0
var finished := false
var victory := false
var best_score := 0
var best_cleared_waves := 0
var best_victory_seconds := 0.0


func load_records(path: String = RECORD_PATH) -> Error:
	var config := ConfigFile.new()
	var error := config.load(path)
	if error != OK:
		return error
	best_score = maxi(int(config.get_value("records", "best_score", 0)), 0)
	best_cleared_waves = clampi(int(config.get_value("records", "best_cleared_waves", 0)), 0, 12)
	best_victory_seconds = maxf(float(config.get_value("records", "best_victory_seconds", 0.0)), 0.0)
	return OK


func begin_wave() -> void:
	wave_seconds = 0.0
	wave_health_loss = 0
	last_wave_bonus = 0


func advance_time(delta: float) -> void:
	if finished:
		return
	var safe_delta := maxf(delta, 0.0)
	combat_seconds += safe_delta
	wave_seconds += safe_delta


func record_kill() -> void:
	if not finished:
		kills += 1
		score += 10


func record_health_loss(amount: int) -> void:
	if not finished:
		wave_health_loss += maxi(amount, 0)
		total_health_loss += maxi(amount, 0)


func complete_wave(wave_number: int) -> bool:
	if finished or wave_number > 12 or wave_number != cleared_waves + 1:
		return false
	cleared_waves = wave_number
	last_wave_bonus = 100
	if wave_seconds <= get_par_seconds(wave_number):
		last_wave_bonus += 100
	if wave_health_loss == 0:
		last_wave_bonus += 100
	score += last_wave_bonus
	return true


func get_service_bonuses() -> Dictionary:
	var services := mini(cleared_waves, 11)
	return {
		"attack_damage": services * ATTACK_PER_SERVICE,
		"max_health": services * HEALTH_PER_SERVICE,
	}


func finish(won: bool) -> bool:
	if finished:
		return false
	finished = true
	victory = won
	if won:
		score += 500
	best_score = maxi(best_score, score)
	best_cleared_waves = maxi(best_cleared_waves, cleared_waves)
	if won and (best_victory_seconds <= 0.0 or combat_seconds < best_victory_seconds):
		best_victory_seconds = combat_seconds
	return true


func save_records(path: String = RECORD_PATH) -> Error:
	var config := ConfigFile.new()
	config.set_value("records", "best_score", best_score)
	config.set_value("records", "best_cleared_waves", best_cleared_waves)
	config.set_value("records", "best_victory_seconds", best_victory_seconds)
	return config.save(path)


func get_rank() -> String:
	if not victory:
		return "突围未完成"
	if score >= 8200:
		return "S · 王牌驾驶员"
	if score >= 7400:
		return "A · 精英驾驶员"
	return "B · 突围完成"


func get_result_text() -> String:
	var text := "%s\n得分 %d  ·  击破 %d  ·  战斗 %s\n完成 %d / 12 波  ·  耐久损失 %d\n最佳得分 %d  ·  最远 %d / 12 波" % [
		get_rank(), score, kills, format_time(combat_seconds), cleared_waves,
		total_health_loss, best_score, best_cleared_waves,
	]
	if best_victory_seconds > 0.0:
		text += "\n最快通关 " + format_time(best_victory_seconds)
	return text


static func get_par_seconds(wave_number: int) -> float:
	return 45.0 + maxf(float(wave_number - 1), 0.0) * 8.0


static func format_time(seconds: float) -> String:
	var whole_seconds := maxi(floori(seconds), 0)
	return "%02d:%02d" % [whole_seconds / 60, whole_seconds % 60]
