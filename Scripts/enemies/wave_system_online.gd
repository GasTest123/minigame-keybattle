extends Node
class_name WaveSystemOnline

## 新的波次系统 Online - Phase优化版
## 设计原则：
## 1. 直接追踪敌人实例，不依赖计数
## 2. 清晰的状态机
## 3. 信号驱动的通信
## 4. 支持多阶段(Phase)刷怪
## 5. 支持min/max活跃怪物数量控制
## 6. 从JSON配置文件加载波次配置

## ========== 状态定义 ==========
enum WaveState {
	IDLE,           # 空闲，等待开始
	SPAWNING,       # 正在生成敌人
	FIGHTING,       # 战斗中（生成完毕，等待击杀）
	WAVE_COMPLETE,  # 本波完成，准备显示商店
	SHOP_OPEN,      # 商店开启中
}

## ========== 配置 ==========
const DEFAULT_MIN_ALIVE_ENEMIES: int = 3    # 默认场上最少活跃怪物数
const DEFAULT_MAX_ALIVE_ENEMIES: int = 100  # 默认场上最大活跃怪物数

var wave_configs: Array = []  # 波次配置
var total_waves: int = 0
var current_wave: int = 0
var current_state: WaveState = WaveState.IDLE
var wave_config_id: String = "online"  # 当前使用的配置ID

## ========== 敌人追踪 ==========
var active_enemies: Array = []  # 当前存活的敌人实例列表（直接引用）
var total_enemies_this_wave: int = 0
var spawned_enemies_this_wave: int = 0
var killed_enemies_this_wave: int = 0  # 用于统计击杀数
var failed_spawns_this_wave: int = 0  # 生成失败次数

## ========== Phase追踪 ==========
var current_phase_index: int = 0           # 当前phase索引
var phase_spawned_count: int = 0           # 当前phase已刷怪数量
var global_spawn_index: int = 0            # 整个wave的累计刷怪序号
var current_phase_enemy_list: Array = []   # 当前phase的待刷怪列表
var all_phases_complete: bool = false      # 是否所有phase都刷完了

## ========== 兼容性属性（供UI等外部访问）==========
## 为了兼容旧代码，提供这些属性的访问
var enemies_killed_this_wave: int:
	get:
		return killed_enemies_this_wave

var enemies_total_this_wave: int:
	get:
		return total_enemies_this_wave

var enemies_spawned_this_wave: int:
	get:
		return spawned_enemies_this_wave

## ========== 信号 ==========
signal wave_started(wave_number: int)
signal wave_completed(wave_number: int)
signal all_waves_completed()
signal state_changed(new_state: WaveState)
signal enemy_killed(wave_number: int, killed: int, total: int)  # 兼容UI

## ========== 引用 ==========
var enemy_spawner: Node = null  # 敌人生成器

## 每波商店倒计时配置（数组索引对应波数-1，超出数组范围使用最后一个值）
## 例如：第1波用第0项
var shop_countdown_per_wave: Array[int] = [20, 20, 18, 18, 18, 16, 16, 16, 14, 14, 14, 12, 12, 12, 10]
var _shop_timer: Timer = null
var _shop_remaining_seconds: int = 0

## 结算冻结：用于阻断“暂停也会跑”的倒计时 tick 等逻辑
var match_ended: bool = false

func _is_network_server() -> bool:
	return NetworkManager.is_server()

func _ready() -> void:
	# 添加到 wave_manager 组，以便其他系统能找到（兼容性）
	if not is_in_group("wave_manager"):
		add_to_group("wave_manager")
	if not is_in_group("wave_system"):
		add_to_group("wave_system")
	
	# 延后初始化：从当前模式读取 wave_config_id 并加载波次配置
	call_deferred("_initialize_from_mode")

	if _shop_timer == null:
		_shop_timer = Timer.new()
		_shop_timer.one_shot = true
		_shop_timer.wait_time = float(_get_shop_countdown_seconds())
		add_child(_shop_timer)
		_shop_timer.timeout.connect(_on_shop_timer_timeout)

## 延后初始化：从当前模式读取 wave_config_id 并加载波次配置
func _initialize_from_mode() -> void:
	# 从当前模式获取配置ID（如果有）
	var mode_id = GameMain.current_mode_id
	if mode_id and not mode_id.is_empty():
		var mode = ModeRegistry.get_mode(mode_id)
		if mode:
			wave_config_id = str(mode.wave_config_id)
			print("[WaveSystem Online] 从模式获取配置ID: ", wave_config_id, " (模式: ", mode_id, ")")
		else:
			push_warning("[WaveSystem Online] 模式 %s 不存在或ModeRegistry未就绪，使用默认配置: %s" % [str(mode_id), str(wave_config_id)])
	else:
		print("[WaveSystem Online] 未设置模式ID，使用默认配置: ", wave_config_id)
	
	_initialize_waves()

## 初始化波次配置
func _initialize_waves() -> void:
	# 从JSON加载配置
	load_wave_config(wave_config_id)

## 加载波次配置
func load_wave_config(config_id: String) -> void:
	wave_config_id = config_id
	wave_configs.clear()
	
	print("[WaveSystem Online] 开始加载波次配置: ", config_id)
	
	# 使用WaveConfigLoader加载配置
	var config_data = WaveConfigLoader.load_config(config_id)
	
	if config_data.is_empty():
		push_error("[WaveSystem Online] 配置加载失败，使用默认配置")
		_create_fallback_config()
		return
	
	# 转换JSON配置为内部格式
	for wave_data in config_data.waves:
		var wave_config = _convert_wave_config(wave_data)
		wave_configs.append(wave_config)
	
	print("[WaveSystem Online] 配置加载完成：", wave_configs.size(), " 波")
	if wave_configs.size() > 0:
		print("[WaveSystem Online] 第1波配置：", wave_configs[0])
	if wave_configs.size() >= 10:
		print("[WaveSystem Online] 第10波配置：", wave_configs[9])

	total_waves = wave_configs.size()
	if config_data.has("total_waves") and config_data.total_waves > 0:
		total_waves = min(total_waves, config_data.total_waves)
	
## 转换波次配置（从JSON格式到内部格式）- 支持新的Phase格式
func _convert_wave_config(wave_data: Dictionary) -> Dictionary:
	var config = {
		"wave_number": wave_data.wave,
	}
	
	# 检测是否是新格式（有spawn_phases）
	if wave_data.has("spawn_phases"):
		# 新格式：多阶段刷怪
		var base_config = wave_data.get("base_config", {})
		config["hp_growth"] = base_config.get("hp_growth", 0.0)
		config["damage_growth"] = base_config.get("damage_growth", 0.0)
		config["min_alive_enemies"] = base_config.get("min_alive_enemies", DEFAULT_MIN_ALIVE_ENEMIES)
		config["max_alive_enemies"] = base_config.get("max_alive_enemies", DEFAULT_MAX_ALIVE_ENEMIES)
		
		# 转换spawn_phases
		var phases = []
		for phase_data in wave_data.spawn_phases:
			var spawn_per_time = int(phase_data.get("spawn_per_time", 1))
			if spawn_per_time <= 0:
				spawn_per_time = 1
			
			var spawn_interval = float(phase_data.get("spawn_interval", 2.0))
			if spawn_interval < 0.0:
				spawn_interval = 0.0
			
			var total_count = int(phase_data.get("total_count", 10))
			if total_count < 0:
				total_count = 0
			
			var enemy_types_raw = phase_data.get("enemy_types", {"creeper": 1.0})
			var enemy_types: Dictionary = enemy_types_raw if (enemy_types_raw is Dictionary) else {"creeper": 1.0}
			if enemy_types.is_empty():
				enemy_types = {"creeper": 1.0}
			
			var phase = {
				"spawn_per_time": spawn_per_time,
				"spawn_interval": spawn_interval,
				"total_count": total_count,
				"enemy_types": enemy_types
			}
			phases.append(phase)
		config["spawn_phases"] = phases
		
		# 计算总敌人数
		var total: int = 0
		for phase in phases:
			total += int(phase.total_count)
		
		# 处理BOSS配置
		var boss_cfg = wave_data.get("boss_config", {})
		var boss_count: int = int(boss_cfg.get("count", 0))
		if boss_count < 0:
			boss_count = 0
		var boss_id = boss_cfg.get("enemy_id", "")
		config["boss_config"] = {
			"count": boss_count,
			"enemy_id": boss_id
		}
		total += boss_count
		
		config["total_enemies"] = total
		
		# special_spawns保持不变
		if wave_data.has("special_spawns"):
			config["special_spawns"] = wave_data.special_spawns
		
		config["is_phase_format"] = true
	else:
		# 旧格式：兼容处理，转换为单phase格式
		config["hp_growth"] = wave_data.get("hp_growth", 0.0)
		config["damage_growth"] = wave_data.get("damage_growth", 0.0)
		config["min_alive_enemies"] = DEFAULT_MIN_ALIVE_ENEMIES
		config["max_alive_enemies"] = DEFAULT_MAX_ALIVE_ENEMIES
		
		# 处理敌人配比
		var total_count = wave_data.get("total_count", 10)
		var enemy_ratios = wave_data.get("enemies", {})
		var spawn_interval = wave_data.get("spawn_interval", 0.4)
		
		# 转换为单phase
		var phase = {
			"spawn_per_time": 1,
			"spawn_interval": spawn_interval,
			"total_count": total_count,
			"enemy_types": enemy_ratios
		}
		config["spawn_phases"] = [phase]
		
		# 处理BOSS配置
		var boss_cfg = wave_data.get("boss_config", {})
		var boss_count: int = int(boss_cfg.get("count", 0))
		if boss_count < 0:
			boss_count = 0
		var boss_id: String = str(boss_cfg.get("enemy_id", ""))
		config["boss_config"] = {
			"count": boss_count,
			"enemy_id": boss_id
		}
		
		# 计算总敌人数
		config["total_enemies"] = int(total_count) + boss_count
		
		# special_spawns保持不变
		if wave_data.has("special_spawns"):
			config["special_spawns"] = wave_data.special_spawns
		
		config["is_phase_format"] = false
	
	return config

## 创建后备配置（当JSON加载失败时）
func _create_fallback_config() -> void:
	for wave in range(30):
		var wave_number = wave + 1
		var config = {
			"wave_number": wave_number,
			"hp_growth": wave * 0.05,
			"damage_growth": wave * 0.05,
			"min_alive_enemies": 3,
			"max_alive_enemies": 20,
			"spawn_phases": [
				{
					"spawn_per_time": 2,
					"spawn_interval": 2.0,
					"total_count": 10 + wave * 3,
					"enemy_types": {
						"creeper": 0.6,
						"creeper_fast": 0.3,
						"jug2": 0.1
					}
				}
			],
			"boss_config": {
				"count": 0,
				"enemy_id": ""
			},
			"total_enemies": 10 + wave * 3,
			"is_phase_format": true
		}
		wave_configs.append(config)
	print("[WaveSystem Online] 使用后备配置：", wave_configs.size(), " 波")

## 设置敌人生成器
func set_enemy_spawner(spawner: Node) -> void:
	enemy_spawner = spawner
	print("[WaveSystem Online] 设置生成器：", spawner.name)

## 开始游戏（第一波）
func start_game() -> void:
	if not _is_network_server():
		push_warning("[WaveSystem Online] 非服务器节点，忽略开始游戏")
		return

	if current_state != WaveState.IDLE:
		push_warning("[WaveSystem Online] 游戏已经开始，忽略")
		return
	
	print("[WaveSystem Online] 开始游戏")
	start_next_wave()

## 开始下一波 (仅服务器端调用)
func start_next_wave() -> void:
	# 状态检查
	if current_state != WaveState.IDLE and current_state != WaveState.WAVE_COMPLETE:
		push_warning("[WaveSystem Online] 波次进行中，不能开始新波次")
		return
	
	# 检查是否还有波次
	if current_wave >= wave_configs.size():
		_change_state_local(WaveState.IDLE)
		all_waves_completed.emit()
		print("[WaveSystem Online] ===== 所有波次完成！=====")
		return
	
	# 清理上一波的数据
	_cleanup_wave_data(false)
	
	# 开始新波次
	current_wave += 1
	var config = wave_configs[current_wave - 1]
	
	# 设置总敌人数
	total_enemies_this_wave = config.get("total_enemies", 0)
	spawned_enemies_this_wave = 0
	killed_enemies_this_wave = 0
	failed_spawns_this_wave = 0
	
	# 重置Phase状态
	current_phase_index = 0
	phase_spawned_count = 0
	global_spawn_index = 0
	current_phase_enemy_list.clear()
	all_phases_complete = false
	
	# 广播波次开始
	_broadcast_wave_start()

## 敌人生成成功的回调（由生成器调用）
func on_enemy_spawned(enemy: Node) -> void:
	if current_state != WaveState.SPAWNING and current_state != WaveState.FIGHTING:
		return
	
	spawned_enemies_this_wave += 1
	register_enemy_instance(enemy)
	
	# 广播状态更新
	if _is_network_server():
		_broadcast_wave_status()

## 敌人生成失败的回调（由生成器调用）
func on_enemy_spawn_failed(enemy_id: String = "") -> void:
	if current_state != WaveState.SPAWNING and current_state != WaveState.FIGHTING:
		return
	
	spawned_enemies_this_wave += 1
	failed_spawns_this_wave += 1
	
	# 失败视为"已击杀"
	killed_enemies_this_wave += 1
	enemy_killed.emit(current_wave, killed_enemies_this_wave, total_enemies_this_wave)
	
	push_warning("[WaveSystem Online] 敌人生成失败计入进度：%s (%d/%d)" % [enemy_id, spawned_enemies_this_wave, total_enemies_this_wave])
	
	if _is_network_server():
		_broadcast_wave_status()

## 敌人"跳过生成"的回调
func on_enemy_spawn_skipped(enemy_id: String = "", reason: String = "") -> void:
	if current_state != WaveState.SPAWNING and current_state != WaveState.FIGHTING:
		return
	
	spawned_enemies_this_wave += 1
	killed_enemies_this_wave += 1
	enemy_killed.emit(current_wave, killed_enemies_this_wave, total_enemies_this_wave)
	
	if reason == "":
		push_warning("[WaveSystem Online] 敌人跳过生成计入进度：%s (%d/%d)" % [enemy_id, spawned_enemies_this_wave, total_enemies_this_wave])
	else:
		push_warning("[WaveSystem Online] 敌人跳过生成计入进度：%s (%s) (%d/%d)" % [enemy_id, reason, spawned_enemies_this_wave, total_enemies_this_wave])
	
	if _is_network_server():
		_broadcast_wave_status()

## 所有Phase刷怪完成的回调（由生成器调用）
func on_all_phases_complete() -> void:
	all_phases_complete = true
	print("[WaveSystem Online] ========== 所有Phase刷怪完成 ==========")
	
	# 转换到战斗状态
	if current_state == WaveState.SPAWNING:
		_change_state_local(WaveState.FIGHTING)
		if _is_network_server():
			_broadcast_wave_status()
	
	# 检查是否波次完成
	_check_wave_complete()

## 获取当前活跃敌人数量
func get_active_enemy_count() -> int:
	_cleanup_invalid_enemies()
	return active_enemies.size()

## 敌人死亡回调
func _on_enemy_died(enemy_ref: Node) -> void:
	_remove_enemy(enemy_ref)

## 敌人被移除（queue_free）
func _on_enemy_removed(enemy_ref: Node) -> void:
	_remove_enemy(enemy_ref)

## 从追踪列表中移除敌人
func _remove_enemy(enemy_ref: Node) -> void:
	if not enemy_ref:
		return
	_untrack_enemy_instance(enemy_ref)
	if _is_network_server():
		_server_register_enemy_kill(enemy_ref)

func _untrack_enemy_instance(enemy_ref: Node) -> void:
	var index := active_enemies.find(enemy_ref)
	if index != -1:
		active_enemies.remove_at(index)
	if enemy_ref and enemy_ref.tree_exiting.is_connected(_on_enemy_removed):
		enemy_ref.tree_exiting.disconnect(_on_enemy_removed)
	if enemy_ref and enemy_ref.has_signal("enemy_killed") and enemy_ref.enemy_killed.is_connected(_on_enemy_died):
		enemy_ref.enemy_killed.disconnect(_on_enemy_died)
	print("[WaveSystem Online] 敌人移除 | 当前存活：", active_enemies.size())

func _server_register_enemy_kill(enemy_ref: Node) -> void:
	killed_enemies_this_wave = min(killed_enemies_this_wave + 1, total_enemies_this_wave)
	print("[WaveSystem Online] 敌人被击杀 | 击杀：", killed_enemies_this_wave, " 剩余：", total_enemies_this_wave - killed_enemies_this_wave)
	
	# 发出击杀信号
	enemy_killed.emit(current_wave, killed_enemies_this_wave, total_enemies_this_wave)
	
	_broadcast_wave_status()
	
	# 检查波次是否完成
	_check_wave_complete()

## 检查波次是否完成
func _check_wave_complete() -> void:
	if not _is_network_server():
		return
	
	# 只在所有phase都刷完的情况下检查
	if not all_phases_complete:
		return
	
	if current_state != WaveState.FIGHTING:
		return
	
	# 清理无效引用
	_cleanup_invalid_enemies()
	
	# 检查是否所有敌人都被清除
	if active_enemies.is_empty():
		_server_on_wave_completed()

func _server_on_wave_completed() -> void:
	print("[WaveSystem Online] ========== 第 ", current_wave, " 波完成！==========")
	print("[WaveSystem Online] 已生成：", spawned_enemies_this_wave, " 目标：", total_enemies_this_wave)
	_change_state_local(WaveState.WAVE_COMPLETE)
	_broadcast_wave_status()
	
	# 最后一波完成：直接通关结算（玩家胜利），不再进入商店
	if total_waves > 0 and current_wave >= total_waves:
		all_waves_completed.emit()
		return
	
	call_deferred("_show_shop")

## 清理无效的敌人引用
func _cleanup_invalid_enemies() -> void:
	var valid_enemies = []
	for enemy in active_enemies:
		if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
			valid_enemies.append(enemy)
	active_enemies = valid_enemies

## 显示商店
func _show_shop() -> void:
	if current_state != WaveState.WAVE_COMPLETE:
		return
	
	if _is_network_server():
		rpc(&"rpc_show_shop")

@rpc("authority", "call_local")
func rpc_show_shop() -> void:
	if current_state != WaveState.WAVE_COMPLETE:
		_change_state_local(WaveState.WAVE_COMPLETE)
	await _open_shop_sequence()


func _open_shop_sequence() -> void:
	if current_state != WaveState.WAVE_COMPLETE:
		return
	
	# 延迟2秒再打开商店
	print("[WaveSystem Online] 波次完成，2秒后打开商店...")
	
	var tree = get_tree()
	if tree == null:
		return
	
	await tree.create_timer(2.0).timeout
	
	tree = get_tree()
	if tree == null:
		return
	
	# 检查玩家是否死亡
	var death_manager = tree.get_first_node_in_group("death_manager")
	if death_manager and death_manager.get("is_dead"):
		print("[WaveSystem Online] 玩家死亡，延迟打开商店")
		if death_manager.has_signal("player_revived"):
			await death_manager.player_revived
		
		tree = get_tree()
		if tree == null:
			return
		
		print("[WaveSystem Online] 玩家已复活，继续打开商店")
	
	_change_state_local(WaveState.SHOP_OPEN)
	print("[WaveSystem Online] ========== 打开商店 ==========")
	
	# 暂停游戏
	tree.paused = true
	
	# 查找商店
	var shop = tree.get_first_node_in_group("upgrade_shop")
	if shop and shop.has_method("open_shop"):
		var seconds := _get_shop_countdown_seconds()
		if shop.has_method("set_close_button_enabled"):
			shop.call("set_close_button_enabled", false)
		if shop.has_method("update_close_button_text"):
			shop.call("update_close_button_text", str(seconds))

		if shop.has_signal("shop_closed"):
			if not shop.shop_closed.is_connected(_on_shop_closed):
				shop.shop_closed.connect(_on_shop_closed)
		
		if death_manager:
			var player = death_manager.get("player")
			if player and player.visible:
				shop.open_shop()
		else:
			shop.open_shop()
	else:
		push_warning("[WaveSystem Online] 未找到商店，直接进入下一波")
		_on_shop_closed()

	if _is_network_server():
		_start_shop_countdown()

## 商店关闭回调
func _on_shop_closed() -> void:
	if current_state != WaveState.SHOP_OPEN:
		return
	
	if _shop_timer:
		_shop_timer.stop()
	print("[WaveSystem Online] ========== 商店关闭 ==========")
	
	var tree = get_tree()
	if tree and tree.paused:
		tree.paused = false
	
	_change_state_local(WaveState.IDLE)
	
	tree = get_tree()
	if tree == null:
		return
	
	await tree.create_timer(1.0).timeout
	
	tree = get_tree()
	if tree == null:
		return
	
	if current_wave < wave_configs.size():
		start_next_wave()
	else:
		all_waves_completed.emit()


func _get_shop_countdown_seconds() -> int:
	if shop_countdown_per_wave.is_empty():
		return 15
	var index := current_wave - 1
	if index < 0:
		index = 0
	if index >= shop_countdown_per_wave.size():
		index = shop_countdown_per_wave.size() - 1
	return shop_countdown_per_wave[index]


func _start_shop_countdown() -> void:
	if not _is_network_server():
		return
	var seconds := _get_shop_countdown_seconds()
	if seconds <= 0:
		_close_shop_due_to_timeout()
		return
	if _shop_timer == null:
		_shop_timer = Timer.new()
		_shop_timer.one_shot = true
		_shop_timer.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_shop_timer)
		_shop_timer.timeout.connect(_on_shop_timer_timeout)
	_shop_timer.wait_time = float(seconds)
	_shop_timer.start()
	_shop_remaining_seconds = seconds
	_update_close_button_text(_shop_remaining_seconds)
	rpc("rpc_shop_countdown_started", seconds)
	_start_countdown_tick()
	print("[WaveSystem Online] 倒计时启动 (总时长=%d 秒)" % seconds)

func _on_shop_timer_timeout() -> void:
	if match_ended:
		return
	if _is_network_server():
		print("[WaveSystem Online] 倒计时Timer到期, 调用关闭")
		_close_shop_due_to_timeout()

func _start_countdown_tick() -> void:
	if match_ended:
		return
	if not _is_network_server():
		return
	if current_state != WaveState.SHOP_OPEN:
		print("[WaveSystem Online] 倒计时tick：当前状态非SHOP_OPEN，终止 tick")
		return
	_shop_remaining_seconds -= 1
	if _shop_remaining_seconds <= 0:
		_update_close_button_text(0)
		_close_shop_due_to_timeout()
		return
	_update_close_button_text(_shop_remaining_seconds)
	rpc("rpc_update_shop_countdown", _shop_remaining_seconds)
	get_tree().create_timer(1.0, true).timeout.connect(_start_countdown_tick)

func _close_shop_due_to_timeout() -> void:
	if current_state != WaveState.SHOP_OPEN:
		print("[WaveSystem Online] _close_shop_due_to_timeout：当前状态 %d，跳过" % current_state)
		return
	print("[WaveSystem Online] 商店倒计时结束，服务器关闭商店")
	_shop_remaining_seconds = 0
	_update_close_button_text(0)
	_close_shop_ui()
	rpc(&"rpc_force_close_shop")

@rpc("authority", "call_local")
func rpc_shop_countdown_started(seconds: int) -> void:
	print("[WaveSystem Online] 商店倒计时开始：%d 秒" % seconds)
	_update_close_button_text(seconds)

@rpc("authority", "call_local")
func rpc_force_close_shop() -> void:
	print("[WaveSystem Online] 接收服务器商店关闭指令（当前状态=%d）" % current_state)
	_close_shop_ui()

@rpc("authority", "call_local")
func rpc_update_shop_countdown(value: int) -> void:
	_update_close_button_text(value)

func _update_close_button_text(value: int) -> void:
	var shop = get_tree().get_first_node_in_group("upgrade_shop")
	if not shop:
		return
	if value <= 0:
		if shop.has_method("set_close_button_enabled"):
			shop.call("set_close_button_enabled", true)
		if shop.has_method("update_close_button_text"):
			shop.call("update_close_button_text", "关闭")
	else:
		if shop.has_method("set_close_button_enabled"):
			shop.call("set_close_button_enabled", false)
		if shop.has_method("update_close_button_text"):
			var text = "剩余%d秒" % value
			shop.call("update_close_button_text", text)

func _close_shop_ui() -> void:
	var shop = get_tree().get_first_node_in_group("upgrade_shop")
	if shop and shop.has_method("close_shop"):
		print("[WaveSystem Online] 调用 UpgradeShop.close_shop()")
		shop.call("close_shop")
	else:
		print("[WaveSystem Online] 未找到可关闭的 UpgradeShop")

func _broadcast_wave_start() -> void:
	if not _is_network_server():
		return
	var payload := {
		"current_wave": current_wave,
		"state": int(WaveState.SPAWNING),
		"total_enemies": total_enemies_this_wave,
		"spawned_enemies": spawned_enemies_this_wave,
		"killed_enemies": killed_enemies_this_wave
	}
	rpc("rpc_set_wave_start", payload)

func _broadcast_wave_status() -> void:
	if not _is_network_server():
		return
	var payload := {
		"current_wave": current_wave,
		"state": int(current_state),
		"total_enemies": total_enemies_this_wave,
		"spawned_enemies": spawned_enemies_this_wave,
		"killed_enemies": killed_enemies_this_wave
	}
	rpc("rpc_set_wave_status", payload)

func register_enemy_instance(enemy: Node) -> void:
	if not enemy:
		return
	active_enemies.append(enemy)
	if enemy.has_signal("enemy_killed"):
		if not enemy.enemy_killed.is_connected(_on_enemy_died):
			enemy.enemy_killed.connect(_on_enemy_died)
	enemy.tree_exiting.connect(_on_enemy_removed.bind(enemy))
	print("[WaveSystem Online] 敌人生成 | 当前存活：", active_enemies.size())

func broadcast_status_to_peer(peer_id: int) -> void:
	if not _is_network_server():
		return
	var payload := {
		"current_wave": current_wave,
		"state": int(current_state),
		"total_enemies": total_enemies_this_wave,
		"spawned_enemies": spawned_enemies_this_wave,
		"killed_enemies": killed_enemies_this_wave
	}
	rpc_id(peer_id, "rpc_set_wave_status", payload)

@rpc("authority", "call_local")
func rpc_set_wave_start(payload: Dictionary) -> void:
	_cleanup_wave_data(false)
	_apply_wave_status(payload)
	_change_state_local(WaveState.SPAWNING)

	if _is_network_server():
		var config = wave_configs[current_wave - 1]
		
		print("\n[WaveSystem Online] ========== 第 ", current_wave, " 波开始 ==========")
		print("[WaveSystem Online] 目标敌人数：", total_enemies_this_wave)
		print("[WaveSystem Online] HP成长率：", config.get("hp_growth", 0.0) * 100, "%")
		print("[WaveSystem Online] 伤害成长率：", config.get("damage_growth", 0.0) * 100, "%")
		print("[WaveSystem Online] Phase数量：", config.get("spawn_phases", []).size())
		
		# 请求生成器开始生成
		if enemy_spawner and enemy_spawner.has_method("spawn_wave_phases"):
			enemy_spawner.spawn_wave_phases(config, self)
		elif enemy_spawner and enemy_spawner.has_method("spawn_wave"):
			enemy_spawner.spawn_wave(config)
		else:
			push_error("[WaveSystem Online] 敌人生成器未设置或没有生成方法")

@rpc("authority", "call_local")
func rpc_set_wave_status(payload: Dictionary) -> void:
	_apply_wave_status(payload)

func _apply_wave_status(payload: Dictionary) -> void:
	var previous_wave := current_wave
	if payload.has("current_wave"):
		current_wave = int(payload["current_wave"])
	if payload.has("state"):
		var state_val := int(payload["state"])
		if state_val >= 0 and state_val < WaveState.size():
			_change_state_local(WaveState.values()[state_val])
	if payload.has("total_enemies"):
		total_enemies_this_wave = int(payload["total_enemies"])
	if payload.has("spawned_enemies"):
		spawned_enemies_this_wave = int(payload["spawned_enemies"])
	if payload.has("killed_enemies"):
		killed_enemies_this_wave = int(payload["killed_enemies"])
	if current_wave != previous_wave:
		wave_started.emit(current_wave)
	enemy_killed.emit(current_wave, killed_enemies_this_wave, total_enemies_this_wave)

## 清理波次数据
func _cleanup_wave_data(reset_counts: bool = true) -> void:
	# 清理上一波的敌人引用
	for enemy in active_enemies:
		if is_instance_valid(enemy):
			if enemy.has_signal("enemy_killed") and enemy.enemy_killed.is_connected(_on_enemy_died):
				enemy.enemy_killed.disconnect(_on_enemy_died)
			if enemy.tree_exiting.is_connected(_on_enemy_removed):
				enemy.tree_exiting.disconnect(_on_enemy_removed)
	
	active_enemies.clear()
	
	if reset_counts:
		spawned_enemies_this_wave = 0
		total_enemies_this_wave = 0
		killed_enemies_this_wave = 0
		failed_spawns_this_wave = 0
		_broadcast_wave_status()
	
	# 重置Phase状态
	current_phase_index = 0
	phase_spawned_count = 0
	global_spawn_index = 0
	current_phase_enemy_list.clear()
	all_phases_complete = false

## 强制结束当前波（调试用）
func force_end_wave() -> void:
	print("[WaveSystem Online] 强制结束当前波")
	all_phases_complete = true
	active_enemies.clear()
	_check_wave_complete()

## 获取当前波次配置
func get_current_wave_config() -> Dictionary:
	if current_wave == 0 or current_wave > wave_configs.size():
		return {}
	return wave_configs[current_wave - 1]

## 获取状态信息（用于调试）
func get_status_info() -> Dictionary:
	return {
		"wave": current_wave,
		"state": current_state,
		"total_enemies": total_enemies_this_wave,
		"spawned": spawned_enemies_this_wave,
		"active": active_enemies.size(),
		"active_valid": _count_valid_enemies(),
		"current_phase": current_phase_index,
		"all_phases_complete": all_phases_complete
	}

## 改变状态
func _change_state_local(new_state: WaveState) -> void:
	if current_state == new_state:
		return
	
	var state_names = ["IDLE", "SPAWNING", "FIGHTING", "WAVE_COMPLETE", "SHOP_OPEN"]
	print("[WaveSystem Online] 状态变化：", state_names[current_state], " -> ", state_names[new_state])
	
	current_state = new_state
	state_changed.emit(new_state)
	if new_state == WaveState.WAVE_COMPLETE:
		wave_completed.emit(current_wave)
	if new_state == WaveState.SPAWNING:
		wave_started.emit(current_wave)

## 统计有效的敌人数量
func _count_valid_enemies() -> int:
	var count = 0
	for enemy in active_enemies:
		if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
			count += 1
	return count

func set_match_ended(value: bool) -> void:
	match_ended = value
	if match_ended:
		if _shop_timer:
			_shop_timer.stop()
