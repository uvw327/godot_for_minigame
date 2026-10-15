extends SceneTree
## Round-trip and safety tests for `core/persistence.gd`.
##
## The persistence layer is a ConfigFile on disk. To keep the test from
## writing into the real `res://.minigame/` tree, the suite redirects the
## module's file paths to a temporary directory via `set_test_paths`.
## `validate_persisted_output_dir` still runs against the live project root
## so the `OutputGuard` integration is verified for real.

const Persistence = preload("res://addons/godot_mini_game/core/persistence.gd")
const Exporter = preload("res://addons/godot_mini_game/exporter.gd")

var _failed := false
var _root := OS.get_temp_dir().path_join(
	"godot-mini-game-persistence-%d-%d" % [
		OS.get_process_id(), Time.get_ticks_usec(),
	]
)
var _config_dir := ""
var _config_file := ""


func _assert_true(value: bool, message: String) -> void:
	if not value:
		push_error(message)
		_failed = true


func _assert_eq(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		push_error("%s: expected %s, got %s" % [message, str(expected), str(actual)])
		_failed = true


func _read_cfg(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


## Persists a state via save_project_state and reloads it. Returns the
## reloaded dictionary.
func _round_trip(state: Dictionary) -> Dictionary:
	var err := Persistence.save_project_state(state)
	_assert_true(err == OK, "save_project_state should succeed: %s" % error_string(err))
	return Persistence.load_project_state()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	# A real `--export-pack` run (see exporter_smoke_test) briefly loads the
	# editor, whose export dock writes the default state to the live
	# res://.minigame/export.cfg on `_exit_tree`. Snapshot the real file so we
	# can assert our overridden writes leave it byte-for-byte untouched, rather
	# than assuming it never exists in the first place.
	var real_cfg_present_before := FileAccess.file_exists(Persistence.CONFIG_FILE)
	var real_cfg_content_before := _read_cfg(Persistence.CONFIG_FILE)
	DirAccess.make_dir_recursive_absolute(_root)
	_config_dir = _root.path_join("minigame-config")
	_config_file = _config_dir.path_join("export.cfg")
	# Redirect the persistence module to the temp directory so the test never
	# touches the real res://.minigame/ tree.
	Persistence.set_test_paths(_config_dir, _config_file)

	# ── Defaults (no file yet) ───────────────────────────────────────
	var defaults := Persistence.load_project_state()
	_assert_eq(defaults.get(Persistence.KEY_PLATFORM), "", "missing file must yield empty platform")
	_assert_eq(defaults.get(Persistence.KEY_APPID), "", "missing file must yield empty appid")
	_assert_eq(defaults.get(Persistence.KEY_ORIENTATION), "", "missing file must yield empty orientation")
	_assert_eq(defaults.get(Persistence.KEY_PRESET), "", "missing file must yield empty preset")
	_assert_eq(defaults.get(Persistence.KEY_OUTPUT_DIR), "", "missing file must yield empty output_dir")
	_assert_eq(defaults.get(Persistence.KEY_TIMEOUT), Persistence.DEFAULT_TIMEOUT_SECONDS, "missing file must yield default timeout")

	# ── Round-trip: every field preserved ───────────────────────────
	var state := {
		Persistence.KEY_PLATFORM: "douyin",
		Persistence.KEY_APPID: "wx-12345",
		Persistence.KEY_ORIENTATION: "landscape",
		Persistence.KEY_PRESET: "MiniGame",
		Persistence.KEY_OUTPUT_DIR: "build/douyin",
		Persistence.KEY_TIMEOUT: 1234.0,
	}
	var reloaded := _round_trip(state)
	_assert_eq(reloaded.get(Persistence.KEY_PLATFORM), "douyin", "platform must round-trip")
	_assert_eq(reloaded.get(Persistence.KEY_APPID), "wx-12345", "appid must round-trip")
	_assert_eq(reloaded.get(Persistence.KEY_ORIENTATION), "landscape", "orientation must round-trip")
	_assert_eq(reloaded.get(Persistence.KEY_PRESET), "MiniGame", "preset must round-trip")
	_assert_eq(reloaded.get(Persistence.KEY_OUTPUT_DIR), "build/douyin", "output_dir must round-trip")
	_assert_eq(reloaded.get(Persistence.KEY_TIMEOUT), 1234.0, "timeout must round-trip")

	# ── Invalid platform / orientation fall back to empty ───────────
	var invalid_platform := _round_trip({
		Persistence.KEY_PLATFORM: "facebook",
		Persistence.KEY_ORIENTATION: "diagonal",
		Persistence.KEY_TIMEOUT: 50.0,
	})
	_assert_eq(invalid_platform.get(Persistence.KEY_PLATFORM), "", "unknown platform must be discarded")
	_assert_eq(invalid_platform.get(Persistence.KEY_ORIENTATION), "", "unknown orientation must be discarded")
	_assert_eq(invalid_platform.get(Persistence.KEY_TIMEOUT), 50.0, "valid timeout must survive")

	# ── Malformed timeout falls back to default ─────────────────────
	var bad_timeout := _round_trip({
		Persistence.KEY_TIMEOUT: "not-a-number",
	})
	_assert_eq(bad_timeout.get(Persistence.KEY_TIMEOUT), Persistence.DEFAULT_TIMEOUT_SECONDS, "string timeout must fall back to default")
	var negative_timeout := _round_trip({
		Persistence.KEY_TIMEOUT: -1.0,
	})
	_assert_eq(negative_timeout.get(Persistence.KEY_TIMEOUT), Persistence.DEFAULT_TIMEOUT_SECONDS, "negative timeout must fall back to default")
	var zero_timeout := _round_trip({
		Persistence.KEY_TIMEOUT: 0.0,
	})
	_assert_eq(zero_timeout.get(Persistence.KEY_TIMEOUT), Persistence.DEFAULT_TIMEOUT_SECONDS, "zero timeout must fall back to default")

	# ── relativize_output_dir: inside project → relative ────────────
	var project_root := ProjectSettings.globalize_path("res://").simplify_path()
	var inside := project_root.path_join("build/wechat")
	_assert_eq(
		Persistence.relativize_output_dir(inside, project_root),
		"build/wechat",
		"path inside project root must become project-relative (forward slashes)",
	)

	# ── relativize_output_dir: outside project → stays absolute ─────
	var outside := _root.path_join("external-output")
	DirAccess.make_dir_recursive_absolute(outside)
	_assert_eq(
		Persistence.relativize_output_dir(outside, project_root),
		outside,
		"path outside project root must stay absolute (native form)",
	)

	# ── relativize_output_dir: empty inputs pass through ────────────
	_assert_eq(Persistence.relativize_output_dir("", project_root), "", "empty path must pass through")
	_assert_eq(Persistence.relativize_output_dir("/some/path", ""), "/some/path", "missing project root must pass through")

	# ── resolve_output_dir: relative value joined to project root ───
	var resolved_relative := Persistence.resolve_output_dir("build/douyin", project_root)
	_assert_eq(
		resolved_relative,
		project_root.path_join("build/douyin"),
		"relative output_dir must resolve against project root",
	)
	# An absolute value is returned as-is.
	var absolute_input := _root.path_join("abs-output")
	DirAccess.make_dir_recursive_absolute(absolute_input)
	_assert_eq(
		Persistence.resolve_output_dir(absolute_input, project_root),
		absolute_input,
		"absolute output_dir must resolve to itself",
	)

	# ── validate_persisted_output_dir: project-internal path rejected
	#    (OutputGuard refuses output inside the Godot project).
	# ─────────────────────────────────────────────────────────────────
	var internal := project_root.path_join("some_output")
	DirAccess.make_dir_recursive_absolute(internal)
	_assert_eq(
		Exporter.validate_persisted_output_dir("some_output", project_root),
		"",
		"output directory inside the project must be rejected by OutputGuard",
	)

	# ── validate_persisted_output_dir: empty value yields empty ─────
	_assert_eq(
		Exporter.validate_persisted_output_dir("", project_root),
		"",
		"empty persisted value must yield empty",
	)

	# ── ensure_project_files creates .gdignore and example ──────────
	Persistence.ensure_project_files()
	_assert_true(
		FileAccess.file_exists(_config_dir.path_join(".gdignore")),
		"ensure_project_files must create .gdignore in the overridden dir",
	)
	_assert_true(
		FileAccess.file_exists(_config_dir.path_join("export.cfg.example")),
		"ensure_project_files must create export.cfg.example in the overridden dir",
	)

	# ── save_project_state writes a readable cfg at the override path
	#    (the real res://.minigame/ tree must remain untouched).
	# ─────────────────────────────────────────────────────────────────
	var save_state := {
		Persistence.KEY_PLATFORM: "tiktok",
		Persistence.KEY_APPID: "tt-key",
		Persistence.KEY_ORIENTATION: "portrait",
		Persistence.KEY_PRESET: "MiniGame",
		Persistence.KEY_OUTPUT_DIR: "",
		Persistence.KEY_TIMEOUT: 300.0,
	}
	_round_trip(save_state)
	var on_disk := _read_cfg(_config_file)
	_assert_true(on_disk.contains("[export]"), "saved cfg must contain the [export] section")
	_assert_true(on_disk.contains('platform="tiktok"'), "saved cfg must contain the platform value")
	_assert_true(on_disk.contains('appid="tt-key"'), "saved cfg must contain the appid value")
	_assert_true(on_disk.contains('timeout_seconds=300'), "saved cfg must contain the timeout value")
	_assert_eq(
		FileAccess.file_exists(Persistence.CONFIG_FILE),
		real_cfg_present_before,
		"the real res://.minigame/export.cfg must remain untouched when overridden",
	)
	_assert_eq(
		_read_cfg(Persistence.CONFIG_FILE),
		real_cfg_content_before,
		"the real res://.minigame/export.cfg must keep its contents when overridden",
	)

	# Restore the default paths so any later code in this process is not
	# affected, then clean up the temp tree.
	Persistence.set_test_paths("", "")
	var cleaner := Exporter.new()
	cleaner._rm_rf(_root)
	# Remove the project-internal fixture directory the validate_persisted
	# test created so the test leaves the project tree clean.
	cleaner._rm_rf(internal)

	if _failed:
		quit(1)
		return
	print("persistence_roundtrip_test.gd: ok")
	quit(0)
