extends CanvasLayer
class_name ESCMenu

## ESC暂停菜单
## 提供继续游戏和返回主菜单功能

## 信号
signal resume_requested
signal main_menu_requested

## 按钮节点引用
@onready var resume_button: TextureButton = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ButtonsContainer/ResumeButton
@onready var restart_button: TextureButton = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ButtonsContainer/restart
@onready var main_menu_button: TextureButton = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ButtonsContainer/MainMenuButton
@onready var background: ColorRect = $Background

## Label节点引用
@onready var resume_label: Label = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ButtonsContainer/ResumeButton/resumeLabel
@onready var restart_label: Label = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ButtonsContainer/restart/restartLabel
@onready var main_menu_label: Label = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer/ButtonsContainer/MainMenuButton/mainmenuLabel

## 记录显示节点引用
@onready var record_container: Control = $CenterContainer/PanelContainer/record
@onready var now_record_label: Label = $CenterContainer/PanelContainer/record/nowRecord
@onready var history_record_label: Label = $CenterContainer/PanelContainer/record/histroyRecord
@onready var new_record_sign: Control = $CenterContainer/PanelContainer/record/newRecordSign

## 颜色常量
const COLOR_NORMAL := Color.BLACK
const COLOR_HIGHLIGHT := Color.WHITE

## 延迟恢复时间（秒）
const RESTORE_DELAY := 0.5

## 选中按钮的背景纹理
var _choosed_texture: Texture2D

## 本局开始时的历史记录（用于判断新纪录）
var _initial_best_wave: int = -1  # -1 表示无记录
var _initial_best_time: float = INF
var _initial_record_saved: bool = false  # 是否已保存初始记录

## 延迟恢复的Tween引用（用于中断）
var _restore_tween: Tween = null

## 隐藏动画Tween引用（避免 await 在未被持有时中断）
var _hide_tween: Tween = null

func _ready() -> void:
	# 添加到组（用于场景清理）
	add_to_group("esc_menu")
	
	# 设置为暂停时也能处理（关键！）
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# 设置层级，确保遮挡死亡UI（死亡UI默认为1）
	layer = 200
	
	# 初始隐藏
	hide()
	
	# 初始隐藏新纪录标志
	if new_record_sign:
		new_record_sign.visible = false
	
	# 加载选中状态的背景纹理
	_choosed_texture = load("res://assets/UI/esc_ui/btn-esc-choosed.png")
	
	# 连接按钮的鼠标进入/移出信号
	_setup_button_signals()
	
	print("[ESC Menu] 菜单已初始化")

## 设置按钮信号连接
func _setup_button_signals() -> void:
	# ResumeButton的鼠标事件
	if resume_button:
		resume_button.mouse_entered.connect(_on_resume_mouse_entered)
	
	# restart按钮的鼠标事件
	if restart_button:
		restart_button.mouse_entered.connect(_on_restart_mouse_entered)
		restart_button.mouse_exited.connect(_on_restart_mouse_exited)
	
	# MainMenuButton的鼠标事件
	if main_menu_button:
		main_menu_button.mouse_entered.connect(_on_main_menu_mouse_entered)
		main_menu_button.mouse_exited.connect(_on_main_menu_mouse_exited)

## 鼠标进入ResumeButton
func _on_resume_mouse_entered() -> void:
	# 取消延迟恢复（如果有）
	_cancel_restore_delay()
	
	# 立即恢复ResumeButton激活状态
	_restore_resume_button()
	
	# 确保其他按钮的label为黑色
	if restart_label:
		restart_label.add_theme_color_override("font_color", COLOR_NORMAL)
	if main_menu_label:
		main_menu_label.add_theme_color_override("font_color", COLOR_NORMAL)

## 取消延迟恢复（进入其他按钮时调用）
func _cancel_restore_delay() -> void:
	if _restore_tween and _restore_tween.is_valid():
		_restore_tween.kill()
		_restore_tween = null

## 恢复ResumeButton为激活状态
func _restore_resume_button() -> void:
	if resume_button:
		resume_button.texture_normal = _choosed_texture
	if resume_label:
		resume_label.add_theme_color_override("font_color", COLOR_HIGHLIGHT)

## 启动延迟恢复ResumeButton
func _start_restore_delay() -> void:
	# 先取消之前的延迟（如果有）
	_cancel_restore_delay()
	
	# 创建新的延迟Tween
	_restore_tween = create_tween()
	_restore_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)  # 暂停时也能运行
	_restore_tween.tween_callback(_restore_resume_button).set_delay(RESTORE_DELAY)

## 鼠标进入restart按钮
func _on_restart_mouse_entered() -> void:
	# 取消延迟恢复（中断之前的延迟）
	_cancel_restore_delay()
	
	# restart按钮激活：label变白
	if restart_label:
		restart_label.add_theme_color_override("font_color", COLOR_HIGHLIGHT)
	# ResumeButton失去激活：texture_normal清空，label变黑
	if resume_button:
		resume_button.texture_normal = null
	if resume_label:
		resume_label.add_theme_color_override("font_color", COLOR_NORMAL)

## 鼠标移出restart按钮
func _on_restart_mouse_exited() -> void:
	# restart按钮恢复：label变黑
	if restart_label:
		restart_label.add_theme_color_override("font_color", COLOR_NORMAL)
	# 延迟0.5秒后恢复ResumeButton激活状态
	_start_restore_delay()

## 鼠标进入MainMenuButton
func _on_main_menu_mouse_entered() -> void:
	# 取消延迟恢复（中断之前的延迟）
	_cancel_restore_delay()
	
	# MainMenuButton激活：label变白
	if main_menu_label:
		main_menu_label.add_theme_color_override("font_color", COLOR_HIGHLIGHT)
	# ResumeButton失去激活：texture_normal清空，label变黑
	if resume_button:
		resume_button.texture_normal = null
	if resume_label:
		resume_label.add_theme_color_override("font_color", COLOR_NORMAL)

## 鼠标移出MainMenuButton
func _on_main_menu_mouse_exited() -> void:
	# MainMenuButton恢复：label变黑
	if main_menu_label:
		main_menu_label.add_theme_color_override("font_color", COLOR_NORMAL)
	# 延迟0.5秒后恢复ResumeButton激活状态
	_start_restore_delay()

## 显示菜单
func show_menu() -> void:
	print("[ESC Menu] 准备打开菜单")
	
	# 暂停游戏 - 由 GameState 管理
	# get_tree().paused = true
	
	# 联机模式下不暂停整个场景，只显示菜单
	if GameMain.current_mode_id == "online":
		get_tree().paused = false
		if restart_button:
			restart_button.visible = false
			restart_button.disabled = true

	# 显示菜单
	show()
	visible = true
	
	# 重置为默认状态：ResumeButton激活，其他按钮正常
	_reset_to_default_state()
	
	# 更新记录显示
	_update_record_display()
	
	# 聚焦到继续按钮
	if resume_button:
		resume_button.grab_focus()
	
	# 播放淡入动画
	_play_show_animation()
	
	print("[ESC Menu] 菜单已打开，游戏已暂停")

## 重置为默认状态
func _reset_to_default_state() -> void:
	# 取消任何延迟恢复
	_cancel_restore_delay()
	
	# ResumeButton激活状态：有背景，白字
	if resume_button:
		resume_button.texture_normal = _choosed_texture
	if resume_label:
		resume_label.add_theme_color_override("font_color", COLOR_HIGHLIGHT)
	
	# restart按钮正常状态：无背景，黑字
	if restart_label:
		restart_label.add_theme_color_override("font_color", COLOR_NORMAL)
	
	# MainMenuButton正常状态：无背景，黑字
	if main_menu_label:
		main_menu_label.add_theme_color_override("font_color", COLOR_NORMAL)

## 隐藏菜单
func hide_menu() -> void:
	print("[ESC Menu] 准备关闭菜单")
	# 取消之前的隐藏动画（如果有）
	if _hide_tween and _hide_tween.is_valid():
		_hide_tween.kill()
		_hide_tween = null
	
	# 如果没有背景或背景无效，直接隐藏
	if not background or not is_instance_valid(background):
		hide()
		print("[ESC Menu] 菜单已关闭（无动画）")
		return
	
	# 背景淡出（暂停时也能运行）
	_hide_tween = create_tween()
	_hide_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_hide_tween.tween_property(background, "modulate:a", 0.0, 0.15)
	_hide_tween.finished.connect(func ():
		# 隐藏菜单
		hide()
		_hide_tween = null
		print("[ESC Menu] 菜单已关闭")
	, CONNECT_ONE_SHOT)

## 播放显示动画
func _play_show_animation() -> void:
	if background:
		# 背景淡入
		background.modulate.a = 0
		var tween = create_tween()
		tween.tween_property(background, "modulate:a", 0.7, 0.2)

## 播放隐藏动画
func _play_hide_animation() -> void:
	if background:
		# 背景淡出
		var tween = create_tween()
		tween.tween_property(background, "modulate:a", 0.0, 0.15)
		await tween.finished

## 继续游戏按钮
func _on_resume_pressed() -> void:
	print("[ESC Menu] 玩家选择继续游戏")
	hide_menu()
	# 在隐藏完成后再发resume（避免菜单残留遮挡造成“没恢复”的错觉）
	if _hide_tween and _hide_tween.is_valid():
		_hide_tween.finished.connect(func(): resume_requested.emit(), CONNECT_ONE_SHOT)
	else:
		resume_requested.emit()

## 返回主菜单按钮
func _on_main_menu_pressed() -> void:
	print("[ESC Menu] 玩家选择返回主菜单")
	_return_to_main_menu()
	# 显示确认对话框（可选）
	#if await _show_confirmation():
		#_return_to_main_menu()
	#else:
		#print("[ESC Menu] 玩家取消返回主菜单")

## 显示确认对话框
#func _show_confirmation() -> bool:
	## 简化版：直接返回true
	## 如果需要确认对话框，可以在这里实现
	#return true

## 返回主菜单
func _return_to_main_menu() -> void:
	# 恢复游戏（必须在切换场景前）
	get_tree().paused = false

	# 联机模式主动断开网络连接
	_stop_connection()

	# 停止计时器（最高波次记录已在波次完成时统一处理）
	_stop_timer_on_exit()
	
	# 发送信号
	main_menu_requested.emit()
	
	print("[ESC Menu] 正在返回主菜单...")
	
	# 使用SceneCleanupManager安全切换场景（会清理所有游戏对象：Ghost、掉落物、敌人、子弹、墓碑、特效等）
	SceneCleanupManager.change_scene_safely("res://scenes/UI/main_title.tscn")

## 处理ESC键输入（关闭菜单）
func _input(event: InputEvent) -> void:
	# 只有在菜单可见时才响应ESC键关闭
	if event.is_action_pressed("ui_cancel") and visible:
		_on_resume_pressed()
		get_viewport().set_input_as_handled()


func _on_restart_pressed() -> void:
	# 恢复游戏（必须在切换场景前）
	get_tree().paused = false
	
	# 停止计时器（最高波次记录已在波次完成时统一处理）
	_stop_timer_on_exit()
	
	# 发送信号
	main_menu_requested.emit()
	
	print("[ESC Menu] 正在返回职业选择...")
	
	# 使用SceneCleanupManager安全切换场景（会清理所有游戏对象并重置GameState，同时保留模式信息）
	SceneCleanupManager.change_scene_safely_keep_mode("res://scenes/UI/Class_choose.tscn")

## 退出游戏时停止计时器
## 注意：最高波次记录已在 game_initializer._on_wave_flow_step 中统一处理
func _stop_timer_on_exit() -> void:
	if GameMain.current_session:
		GameMain.current_session.stop_timer()

## 保存本局开始时的初始记录（仅在第一次调用时保存）
func _save_initial_record() -> void:
	if _initial_record_saved:
		return
	
	var mode_id = GameMain.current_mode_id
	if mode_id.is_empty():
		mode_id = "survival"
	
	if mode_id == "survival":
		var record = LeaderboardManager.get_survival_record()
		if not record.is_empty():
			_initial_best_wave = record.get("best_wave", 30)
			_initial_best_time = record.get("completion_time_seconds", INF)
	else:
		var record = LeaderboardManager.get_multi_record()
		if not record.is_empty():
			_initial_best_wave = record.get("best_wave", 0)
			_initial_best_time = INF  # Multi模式不比较时间
	
	_initial_record_saved = true
	print("[ESC Menu] 已保存本局初始记录: wave=%d, time=%.2f" % [_initial_best_wave, _initial_best_time])

## 更新记录显示
func _update_record_display() -> void:
	# 首次显示时保存初始记录
	_save_initial_record()
	
	var mode_id = GameMain.current_mode_id
	if mode_id.is_empty():
		mode_id = "survival"
	
	# 获取当前已完成的波次（不是正在进行的波次）
	var completed_waves: int = 0
	if GameMain.current_session:
		completed_waves = GameMain.current_session.current_wave - 1
		if completed_waves < 0:
			completed_waves = 0
	
	# 获取当前游戏时间
	var elapsed_time: float = 0.0
	if GameMain.current_session:
		elapsed_time = GameMain.current_session.get_elapsed_time()
	
	if mode_id == "survival":
		_update_survival_record_display(completed_waves, elapsed_time)
	else:
		_update_multi_record_display(completed_waves)

## 更新 Survival 模式记录显示
func _update_survival_record_display(completed_waves: int, elapsed_time: float) -> void:
	# 使用本局开始时保存的初始记录进行比较
	var best_wave: int = _initial_best_wave
	var best_time: float = _initial_best_time
	
	# 更新当前纪录标签
	if now_record_label:
		var time_str = _format_time_chinese(elapsed_time)
		now_record_label.text = "当前纪录：Wave %d  /  %s" % [completed_waves, time_str]
	
	# 更新历史最佳标签
	if history_record_label:
		if best_wave < 0:
			history_record_label.text = "历史最佳：--"
		else:
			var best_time_str = _format_time_chinese(best_time)
			history_record_label.text = "历史最佳：Wave %d  /  %s" % [best_wave, best_time_str]
	
	# 判断是否为新纪录（与本局开始时的记录比较）
	if new_record_sign:
		var is_new_record = false
		if completed_waves > 0:
			if best_wave < 0:
				# 无历史记录，当前即为新纪录
				is_new_record = true
			elif completed_waves > best_wave:
				# 已完成波次更高
				is_new_record = true
			elif completed_waves == best_wave and elapsed_time < best_time:
				# 波次相同但时间更短
				is_new_record = true
		new_record_sign.visible = is_new_record

## 更新 Multi 模式记录显示
func _update_multi_record_display(completed_waves: int) -> void:
	# 使用本局开始时保存的初始记录进行比较
	var best_wave: int = _initial_best_wave
	
	# 更新当前纪录标签（Multi模式不显示时间）
	if now_record_label:
		now_record_label.text = "当前纪录：Wave %d" % completed_waves
	
	# 更新历史最佳标签
	if history_record_label:
		if best_wave < 0:
			history_record_label.text = "历史最佳：--"
		else:
			history_record_label.text = "历史最佳：Wave %d" % best_wave
	
	# 判断是否为新纪录（与本局开始时的记录比较）
	if new_record_sign:
		var is_new_record = false
		if completed_waves > 0:
			if best_wave < 0:
				# 无历史记录，当前即为新纪录
				is_new_record = true
			elif completed_waves > best_wave:
				# 已完成波次更高
				is_new_record = true
		new_record_sign.visible = is_new_record

## 格式化时间为中文格式 "XX分XX秒XX"
func _format_time_chinese(seconds: float) -> String:
	var total_seconds = int(seconds)
	var centiseconds = int((seconds - total_seconds) * 100)
	var mins = total_seconds / 60
	var secs = total_seconds % 60
	return "%d分%02d秒%02d" % [mins, secs, centiseconds]

func _stop_connection() -> void:
	# 联机模式主动断开网络连接
	if GameMain.current_mode_id == "online":
		if NetworkManager.has_method("stop_network"):
			print("[ESC Menu] 停止网络连接")
			NetworkManager.stop_network()
		else:
			print("[ESC Menu] 未找到 NetworkManager 或缺少 stop_network 方法")
