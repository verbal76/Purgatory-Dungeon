extends Node
## GameClock / BuffManager lifecycle regressions.

var _fails: int = 0
var _checks: int = 0
var _run_ended_count: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	GameClock.run_ended.connect(func(): _run_ended_count += 1)

	# --- run_ended fires exactly once per run -----------------------------------
	GameClock.start_run()
	GameClock.current_day = GameClock.max_days          # state after the final day's buff pick
	GameClock.resume()                                    # BuffManager calls this after the pick
	_check(_run_ended_count == 1, "final-day resume emits run_ended once (%d)" % _run_ended_count)
	_check(GameClock._paused, "clock stays stopped after the run ends")
	GameClock._on_tick()                                  # the Timer is still cycling
	GameClock.resume()                                    # e.g. a late chest buff pick
	GameClock._on_tick()
	_check(_run_ended_count == 1, "late ticks/resumes do not re-fire run_ended (%d)" % _run_ended_count)
	_check(GameClock.current_day == GameClock.max_days, "no extra days after the run ended (day %d)" % GameClock.current_day)

	# A new run can end again.
	GameClock.start_run()
	GameClock.current_day = GameClock.max_days - 1
	GlobalRunData.debug_no_buffs = true
	GameClock.advance_day()
	GlobalRunData.debug_no_buffs = false
	_check(_run_ended_count == 2, "a new run ends (and signals) again (%d)" % _run_ended_count)

	# --- Legendary mode keeps the day's progress, and the next run is normal -------
	GameClock.start_run()
	GameClock._timer.start(GameClock.seconds_per_day)
	await get_tree().create_timer(0.6).timeout
	var left_before: float = GameClock._timer.time_left
	GameClock.enter_legendary_mode()
	_check(GameClock._timer.time_left <= left_before + 0.05, "entering Legendary mode does not restart the day timer (%.2f -> %.2f)" % [left_before, GameClock._timer.time_left])
	_check(GameClock.legendary_mode and GameClock.max_days == 99999, "legendary state set")
	GameClock.start_run()
	_check(not GameClock.legendary_mode and GameClock.max_days == 30, "next run is not legendary")

	# --- BuffManager.reset clears queued chest picks --------------------------------
	BuffManager._queued_picks = 3
	BuffManager.reset()
	_check(BuffManager._queued_picks == 0, "reset clears queued picks")
	_check(not BuffManager.is_picking(), "not picking after reset")

	GameClock.hide_hud()
	print("test_clock_buffs: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
