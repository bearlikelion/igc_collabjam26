class_name GameMenu
extends CanvasLayer

# Full-screen menu overlay owning the meta-game states: title, pause, win.
# Lives as a direct child of the level root with process_mode ALWAYS so it
# keeps running while SceneTree.paused freezes the world underneath.
#
# Contexts:
#   TITLE  - first boot of the session only (see _skip_title below)
#   PAUSED - toggled by the "pause" action (Escape / controller Start)
#   ENDED  - shown when the departure cinematic finishes with the player
#            boarded; the fail path keeps its existing auto-reload in
#            Train._play_fail_and_reset and never reaches a menu
#
# The menu owns the mouse mode: visible while open, recaptured on close.
# Controller navigation rides the built-in ui_up / ui_down / ui_accept
# actions (dpad, left stick, A button), so the only custom action is "pause".

enum MenuState { HIDDEN, TITLE, PAUSED, ENDED }

# Survives reload_current_scene (statics live on the script, not the scene):
# the title only shows on the first boot of the session. Every later reload
# (Play Again, R-reset, missed-train fail) starts the run immediately.
static var _skip_title: bool = false

var _state: MenuState = MenuState.HIDDEN
var _train: Train

@onready var _title_label: Label = %TitleLabel
@onready var _byline_label: Label = %TitleLabel2
@onready var _start_button: Button = %StartButton
@onready var _resume_button: Button = %ResumeButton
@onready var _play_again_button: Button = %PlayAgainButton
@onready var _exit_button: Button = %ExitButton


# Wire buttons and the train's cinematic signal, then either show the title
# (first boot) or start hidden with the world running.
func _ready() -> void:
	_start_button.pressed.connect(_close)
	_resume_button.pressed.connect(_close)
	_play_again_button.pressed.connect(_on_play_again_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_train = get_tree().get_first_node_in_group("train") as Train
	if _train != null:
		_train.cinematic_finished.connect(_on_cinematic_finished)
	if _skip_title:
		_close()
	else:
		_skip_title = true
		_open(MenuState.TITLE)


# Meta-input: the "pause" action toggles the pause menu. TITLE and ENDED are
# modal, so Escape/Start does nothing there; the buttons are the only exits.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause"):
		return
	if _state == MenuState.HIDDEN:
		_open(MenuState.PAUSED)
	elif _state == MenuState.PAUSED:
		_close()
	get_viewport().set_input_as_handled()


# Show the overlay in the given context: pause the world, free the mouse,
# swap which buttons are visible, and focus the primary action so controller
# navigation works immediately.
func _open(state: MenuState) -> void:
	_state = state
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	match state:
		MenuState.TITLE:
			_title_label.text = "Metro Macarena"
		MenuState.PAUSED:
			_title_label.text = "PAUSED"
		MenuState.ENDED:
			_title_label.text = "YOU CAUGHT THE TRAIN!"
	_byline_label.visible = state == MenuState.TITLE
	_start_button.visible = state == MenuState.TITLE
	_resume_button.visible = state == MenuState.PAUSED
	_play_again_button.visible = state != MenuState.TITLE
	var primary: Button = _start_button
	if state == MenuState.PAUSED:
		primary = _resume_button
	elif state == MenuState.ENDED:
		primary = _play_again_button
	primary.grab_focus()


# Hide the overlay and hand control back to the game: unpause the tree and
# recapture the mouse for first-person look. Also the boot path when the
# title is skipped, which keeps a reload-while-paused from freezing the run.
func _close() -> void:
	_state = MenuState.HIDDEN
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Fresh run. Restore time_scale first: it survives reload_current_scene and
# a leftover shuffle bullet-time would carry into the new run (same guard as
# the R-reset in metro_movement.gd). Unpause before reloading so the new
# scene does not load into a frozen tree.
func _on_play_again_pressed() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_exit_pressed() -> void:
	get_tree().quit()


# Win path only: the fail path reloads from Train._play_fail_and_reset.
func _on_cinematic_finished() -> void:
	var player: Pawn = get_tree().get_first_node_in_group("player") as Pawn
	if _train != null and player != null and _train.is_boarded(player):
		_open(MenuState.ENDED)
