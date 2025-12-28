extends Node2D

## 游戏初始化器
## 负责初始化死亡管理器和死亡UI

var death_manager: DeathManager = null
var death_ui: DeathUI = null
var tutorial_ui: CanvasLayer = null
var player: CharacterBody2D = null
var floor_layer: TileMapLayer = null
var current_mode: BaseGameMode = null
var victory_triggered: bool = false

# ========= Flow Guard（发行中项目止血：避免流程协程/状态卡死） =========
var flow_in_progress: bool = false
var flow_wave_number: int = 0

const FLOW_WAIT_REVIVE_TIMEOUT_SEC: float = 15.0
const FLOW_WAIT_RESCUING_TIMEOUT_SEC: float = 12.0

func _ready() -> void:
	# 等待场景完全加载
	await get_tree().process_frame
	
	# 确保GameState处于正确的初始状态（防止从ESC菜单或死亡UI进入时状态残留）
	if GameState.current_state != GameState.State.NONE and GameState.current_state != GameState.State.GAME_INITIALIZING:
		print("[GameInitializer] 检测到GameState状态异常: %s，重置状态机" % GameState.current_state)
		GameState.reset()
	
	# 设置游戏初始化状态
	GameState.change_state(GameState.State.GAME_INITIALIZING)
	
	# 重置本局新纪录标志
	LeaderboardManager.reset_session_new_record()
	
	# 播放战斗BGM
	BGMManager.play_bgm("fight")
	print("[GameInitializer] 开始播放战斗BGM")
	
	# 查找玩家
	player = get_tree().get_first_node_in_group("player")
	if not player:
		push_error("[GameInitializer] 找不到玩家！")
		return
	
	# 查找floor_layer
	floor_layer = get_tree().get_first_node_in_group("floor_layer")
	if not floor_layer:
		push_warning("[GameInitializer] 找不到floor_layer，复活位置可能不正常")
	
	# 创建死亡UI
	_create_death_ui()
	
	# 创建死亡管理器
	_create_death_manager()
	
	# 创建ESC菜单管理器
	_create_esc_menu_manager()
	
	# 创建说话管理器
	_create_speech_manager()
	
	# 设置胜利条件检测
	_setup_victory_detection()
	
	# 统一设置游戏流程监听
	_setup_game_flow()
	
	# 显示教程界面（如果需要）
	await _show_tutorial_if_needed()
	
	# 启动游戏计时器
	if GameMain.current_session:
		GameMain.current_session.start_timer()
		print("[GameInitializer] 游戏计时器已启动")
	
	print("[GameInitializer] 游戏初始化完成")

## 显示教程界面（如果需要）
func _show_tutorial_if_needed() -> void:
	# 检查是否需要显示教程
	if not SaveManager.should_show_tutorial():
		print("[GameInitializer] 用户已选择不再显示教程")
		return
	
	# 加载教程UI场景
	var tutorial_scene = load("res://scenes/UI/tutorial_ui.tscn")
	if not tutorial_scene:
		push_warning("[GameInitializer] 无法加载教程UI场景，跳过教程显示")
		return
	
	tutorial_ui = tutorial_scene.instantiate()
	
	# 设置为暂停时可处理
	tutorial_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	
	# 添加到场景树（添加到root以确保在最上层）
	get_tree().root.add_child(tutorial_ui)
	
	# 暂停游戏（显示教程时暂停）
	get_tree().paused = true
	
	print("[GameInitializer] 教程UI已显示，等待玩家确认...")
	
	# 等待教程关闭信号
	if tutorial_ui.has_signal("tutorial_closed"):
		await tutorial_ui.tutorial_closed
	else:
		# 如果没有信号，等待节点被销毁
		await tutorial_ui.tree_exited
	
	# 恢复游戏
	get_tree().paused = false
	tutorial_ui = null
	
	print("[GameInitializer] 教程已关闭，游戏正式开始")

## 创建死亡UI
func _create_death_ui() -> void:
	var death_ui_scene = load("res://scenes/UI/death_ui.tscn")
	if not death_ui_scene:
		push_error("[GameInitializer] 无法加载死亡UI场景！")
		return
	
	death_ui = death_ui_scene.instantiate()
	
	# 设置为暂停时可处理（重要！）
	death_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	
	get_tree().root.add_child(death_ui)
	
	print("[GameInitializer] 死亡UI已创建")

## 创建死亡管理器
func _create_death_manager() -> void:
	death_manager = DeathManager.new()
	add_child(death_manager)
	
	# 设置引用
	death_manager.set_player(player)
	death_manager.set_death_ui(death_ui)
	
	if floor_layer:
		death_manager.set_floor_layer(floor_layer)
	
	print("[GameInitializer] 死亡管理器已创建")

## 创建ESC菜单管理器
func _create_esc_menu_manager() -> void:
	var esc_manager = Node.new()
	esc_manager.name = "ESCMenuManager"
	esc_manager.set_script(load("res://Scripts/UI/esc_menu_manager.gd"))
	add_child(esc_manager)
	print("[GameInitializer] ESC菜单管理器已创建")

## 创建说话管理器
func _create_speech_manager() -> void:
	var speech_manager_script = load("res://Scripts/managers/speech_manager.gd")
	if not speech_manager_script:
		push_error("[GameInitializer] 无法加载说话管理器脚本！")
		return
	
	var speech_manager = speech_manager_script.new()
	speech_manager.name = "SpeechManager"
	add_child(speech_manager)
	speech_manager.add_to_group("speech_manager")
	print("[GameInitializer] 说话管理器已创建")
	
	# 等待一帧后，主动注册所有Player和Ghost
	var scene_tree = get_tree()
	if scene_tree == null:
		return
	await scene_tree.process_frame
	
	# await后重新检查
	if not is_inside_tree():
		return
	_register_all_speakers(speech_manager)

## 注册所有说话者到SpeechManager
func _register_all_speakers(speech_manager: SpeechManager) -> void:
	# 安全检查
	if not is_inside_tree():
		return
	
	# 注册Player
	if player and is_instance_valid(player):
		if speech_manager.has_method("register_speaker"):
			speech_manager.register_speaker(player)
			print("[GameInitializer] Player已注册到SpeechManager")
	
	# 注册所有Ghost
	var scene_tree = get_tree()
	if scene_tree == null:
		return
	var ghosts = scene_tree.get_nodes_in_group("ghost")
	for ghost in ghosts:
		if ghost and is_instance_valid(ghost):
			if speech_manager.has_method("register_speaker"):
				speech_manager.register_speaker(ghost)
				print("[GameInitializer] Ghost已注册到SpeechManager: ", ghost.name)

## 应用模式的初始资源配置
func _apply_initial_resources(mode: BaseGameMode) -> void:
	if not mode:
		return
	
	# 设置初始gold（即使为0也设置，确保覆盖之前的值）
	GameMain.gold = mode.initial_gold
	if mode.initial_gold > 0:
		print("[GameInitializer] 应用初始gold: %d" % mode.initial_gold)
	
	# 设置初始masterkey（即使为0也设置，确保覆盖之前的值）
	GameMain.master_key = mode.initial_master_key
	if mode.initial_master_key > 0:
		print("[GameInitializer] 应用初始masterkey: %d" % mode.initial_master_key)

## 设置胜利条件检测
func _setup_victory_detection() -> void:
	# 获取当前模式
	var mode_id = GameMain.current_mode_id
	if mode_id.is_empty():
		mode_id = "survival"  # 默认为生存模式
	
	current_mode = ModeRegistry.get_mode(mode_id)
	if not current_mode:
		push_error("[GameInitializer] 无法获取游戏模式: %s" % mode_id)
		return
	
	print("[GameInitializer] 设置胜利检测 | 模式: %s | 条件: %s" % [current_mode.mode_name, current_mode.victory_condition_type])
	
	# 应用模式的初始资源配置
	_apply_initial_resources(current_mode)
	
	# 根据胜利条件类型连接相应信号
	match current_mode.victory_condition_type:
		"keys":
			# 钥匙胜利条件：监听金币变化
			if not GameMain.gold_changed.is_connected(_on_resource_changed):
				GameMain.gold_changed.connect(_on_resource_changed)
			print("[GameInitializer] 已连接金币变化信号用于胜利检测")
		"waves":
			# 波次胜利条件：已在 _setup_game_flow 中统一处理，这里不再连接 wave_ended
			print("[GameInitializer] 波次胜利检测已委托给 _setup_game_flow")

## 资源变化回调（用于钥匙胜利条件）
func _on_resource_changed(_new_val: int, _change: int) -> void:
	_check_victory()

# 已废弃，由 _on_wave_flow_step 接管
# func _on_wave_ended(_wave_number: int) -> void:

## 统一设置游戏流程监听
func _setup_game_flow() -> void:
	# 等待波次系统就绪
	var scene_tree = get_tree()
	if scene_tree == null:
		return
	await scene_tree.process_frame
	
	# await后重新检查
	if not is_inside_tree():
		return
	scene_tree = get_tree()
	if scene_tree == null:
		return
	
	var wave_manager = scene_tree.get_first_node_in_group("wave_manager")
	
	if wave_manager:
		# 监听商店关闭信号
		var shop = scene_tree.get_first_node_in_group("upgrade_shop")
		if shop:
			if not shop.has_signal("shop_closed"):
				push_error("[GameInitializer] 商店没有shop_closed信号")
			elif not shop.shop_closed.is_connected(_on_shop_closed):
				shop.shop_closed.connect(_on_shop_closed)
				print("[GameInitializer] 已连接商店关闭信号")

		# 连接到我们新的主流程控制函数
		if wave_manager.has_signal("wave_completed"):
			if not wave_manager.wave_completed.is_connected(_on_wave_flow_step):
				wave_manager.wave_completed.connect(_on_wave_flow_step)
				print("[GameInitializer] 已接管波次流程控制")

	# 监听复活信号（用于流程补偿/兜底；实现放到后续 todo）
	var dm = scene_tree.get_first_node_in_group("death_manager")
	if dm and dm.has_signal("player_revived"):
		if not dm.player_revived.is_connected(_on_player_revived_flow_reconcile):
			dm.player_revived.connect(_on_player_revived_flow_reconcile)
			print("[GameInitializer] 已连接 player_revived（用于流程兜底）")


func _reset_flow_guard() -> void:
	flow_in_progress = false
	flow_wave_number = 0


func _has_visible_rescue_ui() -> bool:
	var tree = get_tree()
	if tree == null:
		return false
	var nodes = tree.get_nodes_in_group("rescue_ui")
	for n in nodes:
		if n and is_instance_valid(n) and n.visible:
			return true
	return false

## 核心流程控制函数：波次结束后的统筹安排
func _on_wave_flow_step(wave_number: int) -> void:
	# 安全检查：确保节点仍在树中
	if not is_inside_tree():
		return

	# 幂等保护：同一波只允许一个流程实例运行
	if flow_in_progress:
		if flow_wave_number == wave_number:
			print("[FlowGuard] wave=%d 流程已在运行，忽略重复触发" % wave_number)
			return
		else:
			print("[FlowGuard] 流程已在运行（wave=%d），忽略新的 wave_completed=%d" % [flow_wave_number, wave_number])
			return
	flow_in_progress = true
	flow_wave_number = wave_number
	
	print("[Flow] 波次 %d 结束，开始流程结算..." % wave_number)

	# 结束态保护：
	# - 胜利流程里会 force_end_wave 清场，可能误触发 wave_completed
	# - 退出/重开流程里 SceneCleanup 会清敌，可能误触发 wave_completed
	# 这些情况下不应该写入/上传排行榜或最高波次。
	if victory_triggered \
	or GameState.current_state == GameState.State.GAME_VICTORY \
	or GameState.current_state == GameState.State.GAME_OVER:
		print("[FlowGuard] 忽略结束态的 wave_completed=%d（避免误写记录）" % wave_number)
		_reset_flow_guard()
		return
	
	# 1. 状态检查：如果玩家已经死了，等待复活而不是直接终止
	if GameState.current_state == GameState.State.PLAYER_DEAD:
		print("[Flow] 玩家已死亡，等待复活...")
		# 找到死亡管理器并等待复活信号
		var scene_tree_dead = get_tree()
		if scene_tree_dead == null:
			return
		var dm = scene_tree_dead.get_first_node_in_group("death_manager")
		if dm and dm.has_signal("player_revived"):
			# 使用字典来避免闭包变量捕获问题
			var state = {"revive_or_quit": false, "quit_game": false}
			
			# 创建一个临时的等待逻辑
			var revive_callback = func(): state.revive_or_quit = true
			var quit_callback = func(): 
				state.revive_or_quit = true
				state.quit_game = true
			
			dm.player_revived.connect(revive_callback, CONNECT_ONE_SHOT)
			if dm.has_signal("game_over"):
				dm.game_over.connect(quit_callback, CONNECT_ONE_SHOT)
			
			# 等待任一信号（带超时，避免无限卡死）
			var start_ms = Time.get_ticks_msec()
			while not state.revive_or_quit:
				scene_tree_dead = get_tree()
				if scene_tree_dead == null:
					_reset_flow_guard()
					return
				await scene_tree_dead.process_frame
				if not is_inside_tree():
					_reset_flow_guard()
					return
				if (Time.get_ticks_msec() - start_ms) > int(FLOW_WAIT_REVIVE_TIMEOUT_SEC * 1000.0):
					print("[FlowGuard] 等待复活超时(%.1fs)，终止本次流程 wave=%d（避免卡死）" % [FLOW_WAIT_REVIVE_TIMEOUT_SEC, wave_number])
					_reset_flow_guard()
					return
			
			# 如果玩家选择放弃，终止流程
			if state.quit_game:
				print("[Flow] 玩家放弃游戏，终止流程")
				_reset_flow_guard()
				return
			
			print("[Flow] 玩家已复活，继续流程结算...")
		else:
			# 如果找不到死亡管理器或没有复活信号，直接返回
			print("[Flow] 无法等待复活信号，终止流程")
			_reset_flow_guard()
			return

	# 到这里说明本次 wave_completed 是“有效结算”（没有放弃、也不是结束态误触发）
	# 每波完成时更新记录（统一在此处处理，避免在多处重复）
	SaveManager.try_update_best_wave(GameMain.current_mode_id, wave_number)
	if GameMain.current_mode_id == "multi":
		LeaderboardManager.try_update_multi_record(wave_number, SaveManager.get_total_death_count())
	elif GameMain.current_mode_id == "survival":
		# Survival：wave 优先判定；但要防止 session 被 reset 后 elapsed_time 变 0，覆盖出错
		if GameMain.current_session == null:
			print("[FlowGuard] current_session 为空，跳过 survival 记录更新 wave=%d" % wave_number)
		else:
			var elapsed_time := GameMain.current_session.get_elapsed_time()
			var death_count := SaveManager.get_total_death_count()
			
			# 计时器有效性检查：未启动/被重置时通常为 0
			var timer_started := true
			if "_timer_start_time" in GameMain.current_session:
				timer_started = float(GameMain.current_session._timer_start_time) > 0.0
			if (not timer_started) or elapsed_time <= 0.0:
				print("[FlowGuard] elapsed_time 异常(%.2f, started=%s)，跳过 survival 记录更新 wave=%d" % [elapsed_time, str(timer_started), wave_number])
			else:
				LeaderboardManager.try_update_survival_record(wave_number, elapsed_time, death_count)

	# 2. 进入清扫阶段（捡东西时间），也就是你想要的延迟
	GameState.change_state(GameState.State.WAVE_CLEARING)
	var delay_time = 2.0 # 可以在这里调整延迟秒数
	print("[Flow] 进入捡落物时间 (%.1f秒)" % delay_time)
	
	# 安全创建计时器
	var scene_tree_delay = get_tree()
	if scene_tree_delay == null:
		return
	await scene_tree_delay.create_timer(delay_time).timeout
	
	# await后重新检查节点状态
	if not is_inside_tree():
		return
	
	# 3. 再次检查死亡（防止延迟期间暴毙）
	if GameState.current_state == GameState.State.PLAYER_DEAD:
		_reset_flow_guard()
		return

	# 4. 胜利检测 (仅针对Wave类型，Key类型由资源回调处理)
	if current_mode and current_mode.victory_condition_type == "waves":
		if current_mode.check_victory_condition():
			# Survival 二阶段：阶段1达成时不切场景，弹覆盖层胜利UI，点Next继续从31波
			if _should_trigger_survival_stage_clear(wave_number):
				print("[Flow] Survival 阶段1达成：弹出结算覆盖层，等待 Next 继续")
				_trigger_survival_stage_clear()
				_reset_flow_guard()
				return
			
			print("[Flow] 触发胜利！")
			_trigger_victory()
			_reset_flow_guard()
			return

	# 5. 既没死也没赢 -> 打开商店
	print("[Flow] 进入商店阶段")
	await _open_shop_flow()

	# 注意：flow_guard 会在商店关闭回调中释放；如果商店压根没打开，会在 _open_shop_flow 内释放

## 打开商店的统一入口
func _open_shop_flow() -> void:
	# 安全检查
	if not is_inside_tree():
		_reset_flow_guard()
		return
	
	# 如果正在救援：必须等待救援结束再开商店
	# 注意：RESCUING 会导致 get_tree().paused = true；不要用会被暂停影响的 create_timer()
	var rescuing_start_ms = Time.get_ticks_msec()
	while GameState.current_state == GameState.State.RESCUING:
		print("[Flow] 玩家正在救援中，等待救援结束再打开商店...")
		await GameState.state_changed
		if not is_inside_tree():
			_reset_flow_guard()
			return
		if (Time.get_ticks_msec() - rescuing_start_ms) > int(FLOW_WAIT_RESCUING_TIMEOUT_SEC * 1000.0):
			# 只有在救援UI不可见时才强制恢复，避免误伤玩家正在操作
			if not _has_visible_rescue_ui():
				print("[FlowGuard] RESCUING 超时(%.1fs)且救援UI不可见，强制恢复到 WAVE_CLEARING 并继续开商店" % FLOW_WAIT_RESCUING_TIMEOUT_SEC)
				GameState.change_state(GameState.State.WAVE_CLEARING)
				break
			else:
				# UI仍可见：继续等待，但重置计时避免刷屏
				rescuing_start_ms = Time.get_ticks_msec()

	# 进入SHOPPING前先验证商店节点存在，避免“切到SHOPPING后 call_group 找不到商店 → 永久paused”
	var scene_tree_shop = get_tree()
	if scene_tree_shop == null:
		print("[FlowGuard] SceneTree为空，终止开店流程")
		_reset_flow_guard()
		return
	var shop = scene_tree_shop.get_first_node_in_group("upgrade_shop")
	if not shop or not is_instance_valid(shop):
		print("[FlowGuard] 找不到 upgrade_shop，跳过商店并强制开始下一波（避免卡死）")
		GameState.change_state(GameState.State.WAVE_CLEARING)
		var wave_manager = scene_tree_shop.get_first_node_in_group("wave_manager")
		if wave_manager and wave_manager.has_method("start_next_wave"):
			wave_manager.start_next_wave()
		_reset_flow_guard()
		return

	GameState.change_state(GameState.State.SHOPPING)
	# 通知商店打开
	scene_tree_shop.call_group("upgrade_shop", "open_shop")

## Survival 二阶段：是否应触发“阶段1结算覆盖层”
func _should_trigger_survival_stage_clear(wave_number: int) -> bool:
	if GameMain.current_mode_id != "survival":
		return false
	
	if not GameMain.current_session or not ("survival_stage" in GameMain.current_session):
		return false
	
	var stage := int(GameMain.current_session.survival_stage)
	if stage != 1:
		return false
	
	if not current_mode:
		return false
	
	var v1 := int(current_mode.victory_waves)
	var v2 := int(current_mode.victory2_waves)
	if v2 <= v1:
		return false
	
	# 仅在达到阶段1目标时触发
	return wave_number >= v1

## Survival 二阶段：触发“阶段1结算覆盖层”，等待 Next 继续
func _trigger_survival_stage_clear() -> void:
	if not is_inside_tree():
		return
	
	var tree = get_tree()
	if tree == null:
		return
	
	# 暂停游戏（并手动暂停计时器：GameState.GAME_PAUSED 默认不会暂停计时器）
	GameState.change_state(GameState.State.GAME_PAUSED)
	if GameMain.current_session:
		GameMain.current_session.pause_timer()
	
	var victory_scene = load("res://scenes/UI/victory_ui.tscn")
	if not victory_scene:
		push_error("[GameInitializer] 无法加载VictoryUI场景（阶段1结算覆盖层）")
		GameState.change_state(GameState.State.WAVE_CLEARING)
		if GameMain.current_session:
			GameMain.current_session.resume_timer()
		return
	
	var ui = victory_scene.instantiate()
	# 暂停期间也可交互
	ui.process_mode = Node.PROCESS_MODE_ALWAYS

	# 用 CanvasLayer 包一层：确保在屏幕空间、层级在最上方、布局不受场景变换影响
	var overlay_layer := CanvasLayer.new()
	overlay_layer.name = "VictoryOverlayLayer"
	overlay_layer.layer = 100
	overlay_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child(overlay_layer)

	# 标记为“阶段1结算覆盖层”（必须在 add_child 前设置，确保 _ready() 里能读到）
	if ui is VictoryUI:
		(ui as VictoryUI).is_stage_clear = true
	else:
		# 兜底：即使类型识别失败，也尽量写入属性
		ui.set("is_stage_clear", true)
	
	# 监听 Next：切换到阶段2并开始下一波（从31开始）
	if ui.has_signal("next_pressed"):
		ui.next_pressed.connect(func():
			# 切换阶段
			if GameMain.current_session and ("survival_stage" in GameMain.current_session):
				GameMain.current_session.survival_stage = 2
				GameMain.current_session.resume_timer()
			
			# 关闭覆盖层UI
			if overlay_layer and is_instance_valid(overlay_layer):
				overlay_layer.queue_free()
			
			# 恢复游戏并开下一波
			GameState.change_state(GameState.State.WAVE_CLEARING)
			var t = get_tree()
			if t == null:
				return
			var wave_manager = t.get_first_node_in_group("wave_manager")
			if wave_manager and wave_manager.has_method("start_next_wave"):
				wave_manager.start_next_wave()
		, CONNECT_ONE_SHOT)
	else:
		push_warning("[GameInitializer] VictoryUI 缺少 next_pressed 信号，无法继续到阶段2")

	# 最后再加入场景树，触发 _ready()
	overlay_layer.add_child(ui)

	# 强制全屏锚点（避免某些情况下 Control 未正确铺满）
	if ui is Control:
		var c := ui as Control
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.offset_left = 0
		c.offset_top = 0
		c.offset_right = 0
		c.offset_bottom = 0

## 商店关闭回调
func _on_shop_closed() -> void:
	# 安全检查
	if not is_inside_tree():
		return
	
	print("[Flow] 商店已关闭，准备下一波")
	
	# 切换到空闲/清扫状态，准备下一波
	GameState.change_state(GameState.State.WAVE_CLEARING)
	
	# 直接开始下一波（延迟由WaveSystem内部处理）
	var scene_tree = get_tree()
	if scene_tree == null:
		return
	var wave_manager = scene_tree.get_first_node_in_group("wave_manager")
	if wave_manager and wave_manager.has_method("start_next_wave"):
		wave_manager.start_next_wave()
	
	_reset_flow_guard()


# TODO（revive-reconcile）：先占位，后续在第二个 todo 中完善逻辑
func _on_player_revived_flow_reconcile() -> void:
	# 复活兜底：如果本波已清空但没有进入商店/下一波，补触发一次流程
	if not is_inside_tree():
		return
	if victory_triggered:
		return
	if flow_in_progress:
		return
	
	# 这些状态下不做补偿，避免重复/干扰
	if GameState.current_state == GameState.State.SHOPPING:
		return
	if GameState.current_state == GameState.State.GAME_VICTORY or GameState.current_state == GameState.State.GAME_OVER:
		return
	if GameState.current_state == GameState.State.RESCUING:
		return
	
	var tree = get_tree()
	if tree == null:
		return
	
	var wave_manager = tree.get_first_node_in_group("wave_manager")
	if not wave_manager:
		return
	
	var wave_number: int = 0
	if GameMain.current_session:
		wave_number = int(GameMain.current_session.current_wave)
	elif "current_wave" in wave_manager:
		wave_number = int(wave_manager.current_wave)
	
	if wave_number <= 0:
		return
	
	# 优先使用 WaveSystemV3 的 status_info（若存在）
	var status: Dictionary = {}
	if wave_manager.has_method("get_status_info"):
		status = wave_manager.get_status_info()
	
	var total_enemies: int = 0
	var spawned: int = 0
	var active_count: int = -1
	var status_wave: int = wave_number
	
	if not status.is_empty():
		status_wave = int(status.get("wave", wave_number))
		total_enemies = int(status.get("total_enemies", 0))
		spawned = int(status.get("spawned", 0))
		active_count = int(status.get("active", -1))
	else:
		# 兼容性：从属性读取（UI也用这些）
		if "enemies_total_this_wave" in wave_manager:
			total_enemies = int(wave_manager.enemies_total_this_wave)
		if "enemies_spawned_this_wave" in wave_manager:
			spawned = int(wave_manager.enemies_spawned_this_wave)
		# active_enemies 只在 V3 存在
		if "active_enemies" in wave_manager:
			active_count = int((wave_manager.active_enemies as Array).size())
	
	# 只在“当前波”且“看起来已经清空”时触发
	if status_wave != wave_number:
		return
	
	var cleared_by_ui = (total_enemies > 0 and spawned >= total_enemies and active_count == 0)
	if not cleared_by_ui:
		return
	
	print("[FlowGuard] 复活补偿：检测到 wave=%d 已清空(total=%d spawned=%d active=%d)，尝试推进流程" % [wave_number, total_enemies, spawned, active_count])
	
	# 1) 如果波次仍被视为“进行中”，先用 wave_system.force_end_wave 触发 wave_completed（更正宗）
	if "is_wave_in_progress" in wave_manager and bool(wave_manager.is_wave_in_progress):
		if wave_manager.has_method("force_end_wave"):
			print("[FlowGuard] 复活补偿：调用 wave_manager.force_end_wave() 重新触发完成判定")
			wave_manager.force_end_wave()
			return
	
	# 2) 否则直接补走一次流程（幂等锁会兜底避免重复）
	print("[FlowGuard] 复活补偿：直接调用 _on_wave_flow_step(%d) 补开商店" % wave_number)
	_on_wave_flow_step(wave_number)

## 检查胜利条件
func _check_victory() -> void:
	if victory_triggered:
		print("[GameInitializer] 胜利已触发，跳过检查")
		return
	
	if not current_mode:
		print("[GameInitializer] 当前模式为空，跳过胜利检查")
		return
	
	print("[GameInitializer] 检查胜利条件...")
	var victory = current_mode.check_victory_condition()
	print("[GameInitializer] 胜利条件检查结果: %s" % victory)
	
	if victory:
		victory_triggered = true
		print("[GameInitializer] ========== 触发胜利！==========")
		_trigger_victory()
	else:
		print("[GameInitializer] 未达成胜利条件")

## 触发胜利
func _trigger_victory() -> void:
	# 安全检查
	if not is_inside_tree():
		return
	
	print("[GameInitializer] 达成胜利条件！准备切换到胜利场景...")
	
	# 停止游戏计时器
	if GameMain.current_session:
		GameMain.current_session.stop_timer()
	
	# 获取当前波次（胜利时的最终波次）
	# Survival 二阶段：使用动态目标波数（阶段2为 victory2_waves）
	var victory_wave = current_mode.get_victory_waves_target() if current_mode else 30
	
	# 更新排行榜记录（Survival 模式在胜利时更新，使用 wave 优先判定）
	if GameMain.current_mode_id == "survival":
		var elapsed_time = GameMain.current_session.get_elapsed_time() if GameMain.current_session else 0.0
		var death_count = SaveManager.get_total_death_count()
		var is_new_record = LeaderboardManager.try_update_survival_record(victory_wave, elapsed_time, death_count)
		if is_new_record:
			print("[GameInitializer] Survival 模式新纪录！波次: %d, 时间: %.2f秒" % [victory_wave, elapsed_time])
	
	# 注意：最高波次记录已在 _on_wave_flow_step 中统一处理
	
	# 设置胜利状态（暂停游戏）
	GameState.change_state(GameState.State.GAME_VICTORY)
	
	# 清场（可选：消灭所有敌人）
	var scene_tree = get_tree()
	if scene_tree == null:
		return
	var wave_manager = scene_tree.get_first_node_in_group("wave_manager")
	if wave_manager and wave_manager.has_method("force_end_wave"):
		wave_manager.force_end_wave()
	
	# 等待1秒（如需求所述）
	scene_tree = get_tree()
	if scene_tree == null:
		return
	await scene_tree.create_timer(1.0).timeout
	
	# await后重新检查
	if not is_inside_tree():
		return
	
	# 加载胜利UI场景
	var victory_scene = load("res://scenes/UI/victory_ui.tscn")
	if victory_scene:
		# 使用安全的场景切换（保留玩家信息，用于显示职业海报等）
		await SceneCleanupManager.change_scene_to_packed_safely_keep_player_info(victory_scene)
	else:
		push_error("[GameInitializer] 无法加载胜利UI场景！")
