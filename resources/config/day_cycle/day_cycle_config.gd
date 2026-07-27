extends Resource
class_name DayCycleConfig

@export_range(1, 64, 1) var waves_per_day := 4
@export_range(1, 64, 1) var night_start_wave_in_day := 3


func is_valid() -> bool:
	return (
		waves_per_day > 0
		and night_start_wave_in_day > 0
		and night_start_wave_in_day <= waves_per_day
	)


func get_day_number(wave_number: int) -> int:
	var safe_wave := maxi(wave_number, 1)
	return floori(float(safe_wave - 1) / float(waves_per_day)) + 1


func get_wave_in_day(wave_number: int) -> int:
	return posmod(maxi(wave_number, 1) - 1, waves_per_day) + 1


func is_night_wave(wave_number: int) -> bool:
	return get_wave_in_day(wave_number) >= night_start_wave_in_day


func is_day_end_wave(wave_number: int) -> bool:
	return get_wave_in_day(wave_number) == waves_per_day


func is_night_intermission_after_wave(completed_wave_number: int) -> bool:
	var wave_in_day := get_wave_in_day(completed_wave_number)
	return (
		wave_in_day >= night_start_wave_in_day
		and wave_in_day < waves_per_day
	)
