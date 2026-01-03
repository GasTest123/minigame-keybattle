extends Node

## 网络玩家管理器
## 负责在线模式下玩家的创建、同步和管理

const PLAYER_SCENE := preload("res://scenes/players/player_online.tscn")

## 玩家出生点位置数组（最多支持4名玩家）
const SPAWN_POSITIONS := [
	Vector2(600, 600),    # 位置1：左上
	Vector2(1600, 600),   # 位置2：右上
	Vector2(600, 1300),   # 位置3：左下
	Vector2(1600, 1300),  # 位置4：右下
]
const SPAWN_POSITION := Vector2(1000, 950)  # 默认出生点（备用）

## 职业列表: boss 职业固定，其他职业可随机分配给 player/impostor
const BOSS_CLASS := "boss"  # boss 专用职业
const PLAYER_CLASSES := ["betty", "warrior", "ranger", "mage", "balanced"]  # player/impostor 可用的职业

## 角色列表: boss, impostor, player
const ROLE_BOSS := "boss"
const ROLE_PLAYER := "player"
const ROLE_IMPOSTOR := "impostor"

## 初始最大血量（直接设置，会覆盖职业默认血量）
const INIT_MAX_HP_BOSS := 100
const INIT_MAX_HP_PLAYER := 100
const INIT_MAX_HP_IMPOSTOR := 100

## 初始钥匙数量
const INIT_GOLD_BOSS := 30
const INIT_GOLD_PLAYER := 30
const INIT_GOLD_IMPOSTOR := 30
const INIT_MASTER_KEY_BOSS := 12
const INIT_MASTER_KEY_PLAYER := 6
const INIT_MASTER_KEY_IMPOSTOR := 6

## 初始武器 (武器ID数组)
const INIT_WEAPONS_BOSS := []
const INIT_WEAPONS_PLAYER := ["dagger", "machine_gun"]
const INIT_WEAPONS_IMPOSTOR := ["dagger", "machine_gun"]
# ["dagger", "machine_gun", "homing_missile", "arcane_missile"]

## 默认角色分配列表: 3 player, 1 boss | 2 player, 1 boss, 1 impostor
const DEFAULT_ROLES := [ROLE_PLAYER, ROLE_BOSS, ROLE_PLAYER, ROLE_PLAYER] # 不包含 ROLE_IMPOSTOR
var enable_role_impostor: bool = false  # 是否启用 ROLE_IMPOSTOR

## 复活费用
const REVIVE_COST_MASTER_KEY := 2  # 复活消耗的 master_key 数量

## 救援费用
const RESCUE_COST_MASTER_KEY := 0  # 救援消耗的 master_key 数量

var players: Dictionary = {}  # peer_id -> PlayerCharacter
var local_player: PlayerCharacter = null
var local_peer_id: int = 0

## 结算
const VICTORY_UI_ONLINE_SCENE := preload("res://scenes/UI/victory_ui_online.tscn")
const _MATCH_END_DELAY_SECONDS := 5.0
var _online_match_ended: bool = false
var _match_end_scheduled: bool = false
var _pending_match_end_result: String = ""
var _pending_match_end_detail: String = ""
var _match_frozen: bool = false

## 结算保底检测（服务器）：每隔一段时间检查是否应触发结算
## - 从游戏开始就启动
## - 商店打开（SHOP_OPEN）时跳过
const _MATCH_WATCHDOG_INTERVAL_SECONDS := 2.0
var _match_watchdog: Timer = null

## 服务器摄像机（服务器用于观察游戏）
var _server_camera: Camera2D = null
var _following_peer_id: int = 0  # 当前跟随的玩家 peer_id

## 获取服务器当前追踪的玩家 peer_id（客户端返回 0）
func get_following_peer_id() -> int:
	if not NetworkManager.is_server():
		return 0
	return _following_peer_id

## Impostor 叛变状态
var impostor_betrayed: bool = false  # 是否已叛变
var impostor_peer_id: int = 0  # Impostor 的 peer_id

## 叛变信号
signal impostor_betrayal_triggered(impostor_peer_id: int)

func _ready() -> void:
	local_peer_id = NetworkManager.get_peer_id()
	print("[NetworkPlayerManager] Ready, peer_id=%d" % local_peer_id)
	
	# 检测是否启用 impostor
	var args: PackedStringArray = OS.get_cmdline_args()
	if args.has("--server") and args.has("--impostor"):
		enable_role_impostor = true
		print("[NetworkPlayerManager] 启动参数检测到 --impostor：已启用 impostor")
	
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	NetworkManager.network_stopped.connect(_on_network_stopped)


func _process(delta: float) -> void:
	# 服务器摄像机跟随当前客户端
	if _server_camera and _following_peer_id != 0:
		var player = get_player_by_peer_id(_following_peer_id)
		if player and is_instance_valid(player):
			_server_camera.global_position = player.global_position
	
	# 子弹状态同步（服务器权威，客户端仅展示）
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		_bullet_sync_accum += delta
		if _bullet_sync_accum >= _BULLET_SYNC_INTERVAL_SECONDS:
			_bullet_sync_accum = 0.0
			_server_broadcast_bullet_states()


func _unhandled_input(event: InputEvent) -> void:
	# 只有服务器才能切换视角
	if not NetworkManager.is_server() or GameMain.current_mode_id != "online":
		return
	
	# 按 Tab 键切换跟随的玩家
	if event.is_action_pressed("ui_focus_next"):  # Tab 键
		_switch_to_next_player()
		get_viewport().set_input_as_handled()


## 切换到下一个玩家
func _switch_to_next_player() -> void:
	if players.size() == 0:
		return
	
	# 获取所有有效的 peer_id 列表并排序
	var peer_ids: Array = []
	for peer_id in players.keys():
		var player = players[peer_id]
		if player and is_instance_valid(player):
			peer_ids.append(peer_id)
	
	if peer_ids.size() == 0:
		return
	
	peer_ids.sort()
	
	# 找到当前跟随的玩家在列表中的位置
	var current_index = peer_ids.find(_following_peer_id)
	
	# 切换到下一个（循环）
	var next_index = (current_index + 1) % peer_ids.size()
	_following_peer_id = peer_ids[next_index]
	
	var player = get_player_by_peer_id(_following_peer_id)
	var player_name = player.display_name if player else "Unknown"
	print("[NetworkPlayerManager] 切换跟随: peer_id=%d, name=%s" % [_following_peer_id, player_name])


## ==================== 公共接口 ====================

## 初始化在线模式（由 GameInitializerOnline 调用）
func init_online_mode() -> void:
	# 新一局联网：必须重置上一局结算状态，否则会导致无法购买/无法造成伤害等
	_reset_online_match_state()
	if NetworkManager.is_server():
		_setup_server_camera()
		_server_setup_match_end_hooks.call_deferred()
		# 保底结算检测：服务器从初始化在线模式时就启动（波次系统尚未创建时会自动跳过）
		_start_match_watchdog()
	else:
		# 客户端请求服务器创建玩家
		_request_spawn_player()


## 获取指定 peer_id 的玩家
func get_player_by_peer_id(peer_id: int) -> PlayerCharacter:
	if players.has(peer_id):
		var player = players[peer_id]
		if player and is_instance_valid(player):
			return player
	return null


## 注册本地玩家（仅单机模式使用，联网模式使用 player_online）
func register_local_player(player: Node) -> void:
	if GameMain.current_mode_id == "online":
		# 在线模式不使用此方法
		if player and is_instance_valid(player):
			player.queue_free()
		return
	
	# 单机模式（使用原版 PlayerCharacter）
	local_peer_id = NetworkManager.get_peer_id()
	local_player = null  # 单机模式不使用 local_player
	# 单机模式不需要注册到 players 字典


## ==================== 服务器端 ====================

## 设置服务器摄像机
func _setup_server_camera() -> void:
	# 禁用场景中的所有摄像机
	for cam in get_tree().get_nodes_in_group("camera"):
		if cam is Camera2D:
			cam.enabled = false
	
	# 创建服务器摄像机
	_server_camera = Camera2D.new()
	_server_camera.name = "ServerCamera"
	_server_camera.zoom = Vector2(0.9, 0.9)
	_server_camera.position_smoothing_enabled = true
	_server_camera.position_smoothing_speed = 5.0
	_server_camera.enabled = true
	# 服务器摄像机初始位置为所有出生点的中心
	_server_camera.global_position = Vector2(1200, 950)
	
	var scene_root = get_tree().current_scene
	if scene_root:
		scene_root.add_child(_server_camera)
		_server_camera.make_current()
	
	print("[NetworkPlayerManager] 服务器摄像机已创建")


## 服务器：处理客户端的 spawn 请求
@rpc("any_peer", "reliable")
func rpc_request_spawn(display_name: String) -> void:
	if not NetworkManager.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	print("[NetworkPlayerManager] 收到 spawn 请求: peer_id=%d, name=%s" % [peer_id, display_name])
	
	if players.has(peer_id) and is_instance_valid(players[peer_id]):
		print("[NetworkPlayerManager] 玩家已存在，跳过")
		return
	
	_server_create_player(peer_id, display_name)


## 服务器：创建玩家节点（使用默认 skin/class，游戏开始时会重新分配）
func _server_create_player(peer_id: int, display_name: String) -> void:
	var parent = _get_players_parent()
	if not parent:
		push_error("[NetworkPlayerManager] 找不到 Players 父节点")
		return
	
	var new_player: PlayerCharacter = PLAYER_SCENE.instantiate()
	
	new_player.name = "player_%d" % peer_id
	new_player.peer_id = peer_id
	new_player.display_name = display_name if display_name != "" else "Player %d" % peer_id
	new_player.player_class_id = "player1"  # 默认，游戏开始时会分配
	
	# 根据当前玩家数量分配出生点
	var spawn_index = players.size() % SPAWN_POSITIONS.size()
	new_player.position = SPAWN_POSITIONS[spawn_index]
	print("[NetworkPlayerManager] 分配出生点: peer_id=%d, index=%d, pos=%s" % [peer_id, spawn_index, str(new_player.position)])
	
	parent.add_child(new_player, true)
	new_player.set_multiplayer_authority(peer_id)
	
	# 服务器端配置为远程玩家（服务器观察所有客户端玩家）
	new_player.configure_as_remote()
	new_player.mark_sync_completed()  # 服务器端立即显示
	
	# 更新武器的 owner_peer_id（关键：服务器上的武器需要知道它属于哪个客户端）
	_update_weapons_owner_peer_id(new_player)
	
	# 禁用摄像机（服务器使用自己的摄像机）
	var cam = new_player.get_node_or_null("Camera2D")
	if cam:
		cam.enabled = false
	
	players[peer_id] = new_player
	
	if _following_peer_id == 0:
		_following_peer_id = peer_id
	
	print("[NetworkPlayerManager] 服务器创建玩家完成: peer_id=%d, pos=%s" % [peer_id, str(new_player.global_position)])


## ==================== 客户端端 ====================

## 客户端：请求服务器创建玩家
func _request_spawn_player() -> void:
	local_peer_id = NetworkManager.get_peer_id()
	var display_name = _get_display_name()
	
	print("[NetworkPlayerManager] 客户端请求 spawn: name=%s" % display_name)
	rpc_id(1, "rpc_request_spawn", display_name)


## 客户端：MultiplayerSpawner 同步回调
func on_player_spawned(node: Node) -> void:
	if not node is PlayerCharacter:
		return
	
	# 服务器不处理（服务器在 _server_create_player 中已处理）
	if NetworkManager.is_server():
		return
	
	var player: PlayerCharacter = node as PlayerCharacter
	
	# 从节点名称解析 peer_id
	var peer_id = _parse_peer_id_from_name(player.name)
	if peer_id == 0:
		print("[NetworkPlayerManager] 无法解析 peer_id: %s" % player.name)
		return
	
	local_peer_id = NetworkManager.get_peer_id()
	var is_local = (peer_id == local_peer_id)
	
	print("[NetworkPlayerManager] 收到玩家同步: peer_id=%d, is_local=%s" % [peer_id, str(is_local)])
	
	# 设置基本属性
	player.peer_id = peer_id
	player.set_multiplayer_authority(peer_id)
	
	if is_local:
		# 本地玩家
		local_player = player
		_setup_local_player(player)
	else:
		# 远程玩家
		_setup_remote_player(player)
	
	players[peer_id] = player


## 服务器：游戏开始时为所有玩家分配身份（由 GameInitializerOnline 调用）
## 分配规则: 4名玩家 = 1 boss + 1 impostor + 2 player
## boss 的 class 固定，player/impostor 随机分配 class
func assign_player_identities() -> void:
	if not NetworkManager.is_server():
		return
	
	print("[NetworkPlayerManager] 开始分配玩家身份")
	
	# 重置叛变状态
	impostor_betrayed = false
	impostor_peer_id = 0
	
	# 获取所有玩家的 peer_id 并随机打乱（随机分配角色）
	var peer_ids: Array = players.keys()
	peer_ids.shuffle()
	
	# 准备 player/impostor 可用的职业（随机打乱，不重复分配）
	var player_classes = PLAYER_CLASSES.duplicate()
	player_classes.shuffle()
	
	# 使用默认角色列表
	var roles: Array = DEFAULT_ROLES.duplicate()
	
	# 如果启用 ROLE_IMPOSTOR，将最后一个角色改为 ROLE_IMPOSTOR
	if enable_role_impostor and roles.size() > 0:
		roles[roles.size() - 1] = ROLE_IMPOSTOR
	
	# 如果当前只有一个玩家，则是分配 player
	if peer_ids.size() == 1:
		roles = [ROLE_PLAYER]
	
	# 为每个玩家分配 role 和 class
	for i in range(peer_ids.size()):
		var peer_id = peer_ids[i]
		var role_id = roles[i] if i < roles.size() else ROLE_PLAYER
		var class_id: String
		
		# boss 角色使用固定职业，其他角色从打乱后的列表中依次取出（不重复）
		if role_id == ROLE_BOSS:
			class_id = BOSS_CLASS
		else:
			if player_classes.size() > 0:
				class_id = player_classes.pop_front()  # 取出并移除，保证不重复
			else:
				class_id = PLAYER_CLASSES[0]  # 备用：如果职业不够用
		
		# 记录 impostor 的 peer_id
		if role_id == ROLE_IMPOSTOR:
			impostor_peer_id = peer_id
		
		# 根据角色确定初始钥匙数量、武器和最大血量
		var init_gold: int
		var init_master_key: int
		var init_weapons: Array
		var init_max_hp: int
		match role_id:
			ROLE_BOSS:
				init_gold = INIT_GOLD_BOSS
				init_master_key = INIT_MASTER_KEY_BOSS
				init_weapons = INIT_WEAPONS_BOSS.duplicate()
				init_max_hp = INIT_MAX_HP_BOSS
			ROLE_IMPOSTOR:
				init_gold = INIT_GOLD_IMPOSTOR
				init_master_key = INIT_MASTER_KEY_IMPOSTOR
				init_weapons = INIT_WEAPONS_IMPOSTOR.duplicate()
				init_max_hp = INIT_MAX_HP_IMPOSTOR
			_:  # ROLE_PLAYER 或其他
				init_gold = INIT_GOLD_PLAYER
				init_master_key = INIT_MASTER_KEY_PLAYER
				init_weapons = INIT_WEAPONS_PLAYER.duplicate()
				init_max_hp = INIT_MAX_HP_PLAYER
		
		# 广播给所有客户端（包括服务器自己，通过 call_local）
		# 注意：不要在这里直接操作 player，因为 rpc_assign_identity 使用了 call_local
		# 服务器也会收到并处理，避免重复操作
		rpc("rpc_assign_identity", peer_id, class_id, role_id, init_gold, init_master_key, init_weapons, init_max_hp)
		print("[NetworkPlayerManager] 分配身份: peer_id=%d, class=%s, role=%s, gold=%d, master_key=%d, max_hp=%d" % [peer_id, class_id, role_id, init_gold, init_master_key, init_max_hp])


## 客户端：接收服务器分配的身份（广播给所有客户端）
@rpc("authority", "call_local", "reliable")
func rpc_assign_identity(peer_id: int, class_id: String, role_id: String, init_gold: int = INIT_GOLD_PLAYER, init_master_key: int = INIT_MASTER_KEY_PLAYER, init_weapons: Array = [], init_max_hp: int = 0) -> void:
	print("[NetworkPlayerManager] 收到身份分配: peer_id=%d, class=%s, role=%s, gold=%d, master_key=%d, max_hp=%d" % [peer_id, class_id, role_id, init_gold, init_master_key, init_max_hp])
	
	# 查找对应的玩家（可能需要等待 MultiplayerSpawner 同步完成）
	var player = get_player_by_peer_id(peer_id)
	if not player:
		# 等待玩家被创建（最多等待 2 秒）
		var wait_time = 0.0
		while not player and wait_time < 2.0:
			await get_tree().create_timer(0.1).timeout
			wait_time += 0.1
			player = get_player_by_peer_id(peer_id)
		
		if not player:
			push_warning("[NetworkPlayerManager] 等待超时: 找不到 peer_id=%d 的玩家" % peer_id)
			return
		
		print("[NetworkPlayerManager] 等待 %.1f 秒后找到玩家 peer_id=%d" % [wait_time, peer_id])
	
	# 更新玩家的身份
	player.player_class_id = class_id
	player.player_role_id = role_id
	
	# 使用 CombatStats 设置初始血量（在 chooseClass 之前准备好）
	# 这样 chooseClass -> attribute_manager.recalculate() 时会使用正确的血量
	_setup_player_initial_stats(player, class_id, init_max_hp)
	
	# 设置初始钥匙数量（只有本地玩家设置，然后通过 MultiplayerSynchronizer 同步给其他人）
	# 这和 HP 的处理方式一致：本地玩家是 authority，修改后自动同步
	if player.is_local_player:
		player.gold = init_gold
		player.master_key = init_master_key
		print("[NetworkPlayerManager] 本地玩家设置初始钥匙: gold=%d, master_key=%d" % [init_gold, init_master_key])
	
	# 为所有玩家添加初始武器（本地和远程都需要显示武器）
	if init_weapons.size() > 0 and player.has_method("add_initial_weapons"):
		await player.add_initial_weapons(init_weapons)  # 使用 await 等待武器添加完成
		print("[NetworkPlayerManager] 玩家 %d 添加初始武器: %s" % [peer_id, str(init_weapons)])
		# 武器添加后更新 owner_peer_id（关键！）
		_update_weapons_owner_peer_id(player)
	
	# boss 角色禁用武器（boss 不能攻击怪物）
	if role_id == ROLE_BOSS and player.has_method("disable_weapons"):
		player.disable_weapons()
	
	# 如果是远程玩家且还未显示，现在可以显示了
	if not player.is_local_player and not player._sync_completed:
		player.mark_sync_completed()
	
	# 记录 impostor 的 peer_id（客户端也需要知道）
	if role_id == ROLE_IMPOSTOR:
		impostor_peer_id = peer_id
	
	print("[NetworkPlayerManager] 玩家身份已更新: peer_id=%d, class=%s, role=%s" % [peer_id, class_id, role_id])


## 设置玩家初始属性（使用 CombatStats 管理血量）
## 直接设置 base_stats.max_hp 为指定值，而不是累加
func _setup_player_initial_stats(player: PlayerCharacter, class_id: String, init_max_hp: int) -> void:
	# 先选择职业（这会设置 attribute_manager.base_stats）
	player.chooseClass(class_id)
	
	# 如果指定了初始血量，覆盖职业默认值
	if init_max_hp > 0 and player.attribute_manager and player.attribute_manager.base_stats:
		var class_max_hp = player.attribute_manager.base_stats.max_hp
		player.attribute_manager.base_stats.max_hp = init_max_hp
		player.attribute_manager.recalculate()  # 重新计算会更新 player.max_hp
		
		# 只有本地玩家需要设置 now_hp（会通过 MultiplayerSynchronizer 同步）
		if player.is_local_player:
			player.now_hp = player.max_hp
		
		print("[NetworkPlayerManager] 设置玩家 %d 初始血量: class_default=%d, init_max_hp=%d, final_max_hp=%d (is_local=%s)" % [
			player.peer_id, class_max_hp, init_max_hp, player.max_hp, player.is_local_player
		])
	else:
		# 降级处理：没有 attribute_manager 时直接设置
		if init_max_hp > 0:
			player.max_hp = init_max_hp
			if player.is_local_player:
				player.now_hp = player.max_hp
			print("[NetworkPlayerManager] 设置玩家 %d 初始血量(降级): max_hp=%d" % [player.peer_id, init_max_hp])


## 配置本地玩家
func _setup_local_player(player: PlayerCharacter) -> void:
	# 如果位置无效（0,0），根据玩家数量分配出生点
	if player.global_position == Vector2.ZERO or player.global_position.length() < 10:
		var spawn_index = players.size() % SPAWN_POSITIONS.size()
		player.global_position = SPAWN_POSITIONS[spawn_index]
		print("[NetworkPlayerManager] 修正本地玩家位置到: index=%d, pos=%s" % [spawn_index, str(player.global_position)])
	
	player.configure_as_local()
	
	# 游戏开始前禁止移动
	player.canMove = false
	player.stop = true
	
	# 应用职业
	if player.player_class_id != "":
		player.chooseClass(player.player_class_id)
	if player.name_label and player.display_name != "":
		player.name_label.text = player.display_name
	
	# 更新武器的 owner_peer_id（武器的 _ready 可能在 peer_id 设置之前执行）
	_update_weapons_owner_peer_id(player)
	
	print("[NetworkPlayerManager] 本地玩家配置完成: %s, pos=%s (移动已禁用，等待游戏开始)" % [player.display_name, str(player.global_position)])


## 配置远程玩家
func _setup_remote_player(player: PlayerCharacter) -> void:
	player.configure_as_remote()
	
	# 游戏开始前禁止移动（远程玩家也要禁用，虽然实际控制在本地端）
	player.canMove = false
	player.stop = true
	
	print("[NetworkPlayerManager] 远程玩家配置完成: peer_id=%d (移动已禁用)" % player.peer_id)


## 更新玩家武器的 owner_peer_id
func _update_weapons_owner_peer_id(player: PlayerCharacter) -> void:
	var weapons_node = player.get_node_or_null("now_weapons")
	if not weapons_node:
		return
	
	for weapon in weapons_node.get_children():
		if weapon.has_method("set_owner_player"):
			weapon.set_owner_player(player)
	
	print("[NetworkPlayerManager] 更新武器 owner_peer_id: %d" % player.peer_id)


## ==================== 掉落物系统 ====================

var _drop_id_counter: int = 1

## 服务器：生成掉落物并同步给所有客户端
## source_peer_id: 掉落物的来源玩家（玩家死亡掉落时使用，0 表示无来源限制）
func spawn_drop(item_name: String, pos: Vector2, item_scale: Vector2 = Vector2(4, 4), source_peer_id: int = 0) -> void:
	if not NetworkManager.is_server():
		return
	
	var drop_id = _drop_id_counter
	_drop_id_counter += 1
	
	# 服务器本地生成
	_create_drop_item(item_name, pos, item_scale, drop_id, source_peer_id)
	
	# 广播给所有客户端
	rpc("rpc_spawn_drop", item_name, pos, item_scale, drop_id, source_peer_id)
	
	if source_peer_id > 0:
		print("[NetworkPlayerManager] 生成掉落物: %s, drop_id=%d, source_peer=%d" % [item_name, drop_id, source_peer_id])
	else:
		print("[NetworkPlayerManager] 生成掉落物: %s, drop_id=%d" % [item_name, drop_id])


## 客户端：接收服务器生成的掉落物
@rpc("authority", "call_remote", "reliable")
func rpc_spawn_drop(item_name: String, pos: Vector2, item_scale: Vector2, drop_id: int, source_peer_id: int = 0) -> void:
	_create_drop_item(item_name, pos, item_scale, drop_id, source_peer_id)


## 创建掉落物实例
func _create_drop_item(item_name: String, pos: Vector2, item_scale: Vector2, drop_id: int, source_peer_id: int = 0) -> void:
	if not GameMain.drop_item_scene_online_obj:
		push_error("[NetworkPlayerManager] drop_item_scene_online_obj 不存在")
		return
	
	GameMain.drop_item_scene_online_obj.gen_drop_item({
		"ani_name": item_name,
		"position": pos,
		"scale": item_scale,
		"drop_id": drop_id,
		"source_peer_id": source_peer_id
	})


## 服务器：给玩家奖励资源
## 通知客户端（authority）修改，然后 MultiplayerSynchronizer 自动同步给服务器和其他客户端
func award_player_resource(peer_id: int, item_type: String, amount: int = 1) -> void:
	if not NetworkManager.is_server():
		return
	
	# 如果是发给服务器自己（peer_id = 1），服务器不需要处理
	if peer_id == 1:
		print("[NetworkPlayerManager] 警告: peer_id=1 是服务器，服务器不收集资源")
		return
	
	var player = get_player_by_peer_id(peer_id)
	if not player or not is_instance_valid(player):
		print("[NetworkPlayerManager] 警告: 找不到玩家 peer_id=%d" % peer_id)
		return
	
	# 通知客户端（authority）修改属性，MultiplayerSynchronizer 会自动同步给服务器和其他人
	if player.has_method("rpc_add_resource"):
		player.rpc_id(peer_id, "rpc_add_resource", item_type, amount)
		print("[NetworkPlayerManager] 通知客户端 %d 添加资源: %s x%d" % [peer_id, item_type, amount])


## 服务器：通知掉落物已被拾取
func notify_drop_collected(drop_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	print("[NetworkPlayerManager] 通知删除掉落物 drop_id=%d" % drop_id)
	
	# 广播给所有客户端（使用 call_local 确保服务器也执行）
	rpc("rpc_drop_collected", drop_id)


## 所有端：处理掉落物被拾取
@rpc("authority", "call_local", "reliable")
func rpc_drop_collected(drop_id: int) -> void:
	var peer_id = NetworkManager.get_peer_id()
	print("[NetworkPlayerManager] 删除掉落物 drop_id=%d (peer_id=%d, is_server=%s)" % [drop_id, peer_id, NetworkManager.is_server()])
	
	# 查找并删除对应的掉落物
	var drop_name = "drop_item_%d" % drop_id
	var drops = get_tree().get_nodes_in_group("network_drop")
	print("[NetworkPlayerManager] 当前 network_drop 组中有 %d 个物品" % drops.size())
	
	var found = false
	for drop in drops:
		var d_id = drop.get_meta("drop_id") if drop.has_meta("drop_id") else -1
		print("[NetworkPlayerManager] 检查物品: name=%s, meta_drop_id=%d" % [drop.name, d_id])
		if drop.name == drop_name or d_id == drop_id:
			drop.queue_free()
			print("[NetworkPlayerManager] 找到并删除掉落物: %s" % drop.name)
			found = true
			break
	
	if not found:
		print("[NetworkPlayerManager] 警告: 未找到 drop_id=%d 的掉落物!" % drop_id)


## ==================== 玩家死亡掉落 ====================

## 掉落物随机偏移范围
const DROP_OFFSET_RANGE: float = 50.0

## 服务器：玩家死亡时掉落身上所有的 gold
## client_gold: 客户端发送的当前 gold 数量（避免 MultiplayerSynchronizer 同步延迟问题）
## -1 表示客户端未提供（兼容旧版本）
func _drop_player_gold(peer_id: int, death_position: Vector2, client_gold: int = -1) -> void:
	if not NetworkManager.is_server():
		return
	
	var player = get_player_by_peer_id(peer_id)
	if not player or not is_instance_valid(player):
		print("[NetworkPlayerManager] _drop_player_gold: 找不到玩家 peer_id=%d" % peer_id)
		return
	
	# 优先使用客户端发送的 gold 数量（避免 MultiplayerSynchronizer 同步延迟）
	# 注意：0 也是合法值，不能用 >0 判断是否“有传”
	# 如果客户端没有发送（兼容旧版本），则使用服务器上同步的值
	var drop_gold_count: int = client_gold if client_gold >= 0 else int(player.gold)
	
	if drop_gold_count <= 0:
		print("[NetworkPlayerManager] 玩家 peer_id=%d 没有 gold 可掉落 (client=%d, server=%d)" % [peer_id, client_gold, int(player.gold)])
		return
	
	print("[NetworkPlayerManager] 玩家死亡掉落 gold | peer_id=%d, gold=%d (client_gold=%d)" % [peer_id, drop_gold_count, client_gold])
	
	# 通知客户端设置 gold = 0（使用绝对值，避免增量操作导致的不一致）
	if player.has_method("rpc_set_resource"):
		player.rpc_id(peer_id, "rpc_set_resource", "gold", 0)
	
	# 广播掉落数量给所有客户端（用于 UI 显示）
	rpc("rpc_broadcast_player_drop", peer_id, drop_gold_count)
	
	# 在死亡位置生成对应数量的 gold 掉落物（带来源标记，来源玩家不能拾取）
	for i in range(drop_gold_count):
		# 添加随机偏移，避免所有 gold 重叠
		var offset = Vector2(
			randf_range(-DROP_OFFSET_RANGE, DROP_OFFSET_RANGE),
			randf_range(-DROP_OFFSET_RANGE, DROP_OFFSET_RANGE)
		)
		var drop_pos = death_position + offset
		
		# 生成掉落物，标记来源 peer_id（该玩家不能拾取自己掉落的物品）
		spawn_drop("gold", drop_pos, Vector2(4, 4), peer_id)
	
	print("[NetworkPlayerManager] 生成 %d 个 gold 掉落物 | peer_id=%d, pos=%s (来源玩家不能拾取)" % [drop_gold_count, peer_id, str(death_position)])


## 广播：通知所有客户端玩家掉落了多少钥匙
@rpc("authority", "call_local", "reliable")
func rpc_broadcast_player_drop(peer_id: int, drop_count: int) -> void:
	var player = get_player_by_peer_id(peer_id)
	var player_name = player.display_name if player and "display_name" in player else "玩家 %d" % peer_id
	print("[NetworkPlayerManager] 玩家 %s 死亡掉落 %d 个钥匙" % [player_name, drop_count])


## ==================== 死亡系统 ====================

## 客户端请求复活（发送到服务器）
@rpc("any_peer", "call_remote", "reliable")
func request_revive() -> void:
	if not NetworkManager.is_server():
		return
	if is_match_frozen():
		return
	
	var requester_peer_id = multiplayer.get_remote_sender_id()
	print("[NetworkPlayerManager] 收到复活请求: peer_id=%d" % requester_peer_id)
	
	var player = get_player_by_peer_id(requester_peer_id)
	if not player or not is_instance_valid(player):
		print("[NetworkPlayerManager] 复活失败: 找不到玩家 peer_id=%d" % requester_peer_id)
		rpc_id(requester_peer_id, "rpc_revive_result", false, "找不到玩家")
		return
	
	# 检查玩家是否已死亡
	if player.now_hp > 0:
		print("[NetworkPlayerManager] 复活失败: 玩家未死亡 peer_id=%d" % requester_peer_id)
		rpc_id(requester_peer_id, "rpc_revive_result", false, "玩家未死亡")
		return
	
	# 检查 master_key 是否足够（从 MultiplayerSynchronizer 同步的值）
	if player.master_key < REVIVE_COST_MASTER_KEY:
		print("[NetworkPlayerManager] 复活失败: master_key 不足 peer_id=%d (需要 %d, 拥有 %d)" % [requester_peer_id, REVIVE_COST_MASTER_KEY, player.master_key])
		rpc_id(requester_peer_id, "rpc_revive_result", false, "生命钥匙不足")
		# 服务器：可能全员死亡且都无法复活（例如最后一人尝试复活失败）
		_server_try_end_match("revive_failed_not_enough_key")
		return
	
	# 通知客户端扣除 master_key，由客户端修改后通过 MultiplayerSynchronizer 同步
	if player.has_method("rpc_add_resource"):
		player.rpc_id(requester_peer_id, "rpc_add_resource", "master_key", -REVIVE_COST_MASTER_KEY)
		print("[NetworkPlayerManager] 通知客户端扣除 master_key (复活): peer_id=%d, cost=%d" % [requester_peer_id, REVIVE_COST_MASTER_KEY])
	
	# 执行复活
	_server_revive_player(requester_peer_id)
	
	print("[NetworkPlayerManager] 玩家复活成功: peer_id=%d, 消耗 %d master_key" % [requester_peer_id, REVIVE_COST_MASTER_KEY])


## 服务器执行复活
func _server_revive_player(peer_id: int) -> void:
	var player = get_player_by_peer_id(peer_id)
	if not player or not is_instance_valid(player):
		return
	
	# 恢复满血（HP 可能由属性系统计算得出：base_stats -> final_stats）
	var full_hp := _get_player_full_hp(player)
	# 修复：服务器端立即同步 now_hp，避免短时间内仍被视为死亡（影响拾取等逻辑）
	if "now_hp" in player:
		player.now_hp = full_hp
	# 复活后恢复武器（Boss 不使用武器系统）
	if ("player_role_id" in player) and str(player.player_role_id) != ROLE_BOSS:
		if player.has_method("enable_weapons"):
			player.enable_weapons()
	
	# 服务器本地也需要看到复活特效/无敌（作为观战/跟随视角）。
	# 注意：rpc_show_revive_effect 使用 call_remote，默认不会在调用方（服务器）本地执行。
	if player.has_method("start_revive_invincibility"):
		player.start_revive_invincibility()
	
	# 通知客户端执行复活（客户端会修改 now_hp，然后 MultiplayerSynchronizer 同步）
	player.rpc_id(peer_id, "rpc_revive", full_hp)
	
	# 广播给所有其他客户端，让他们也看到复活效果
	for client_peer_id in multiplayer.get_peers():
		if client_peer_id != peer_id:
			player.rpc_id(client_peer_id, "rpc_show_revive_effect", peer_id)
	
	# 移除墓碑
	remove_grave_for_player(peer_id)
	_force_pickup_overlapping_drops.call_deferred(peer_id)
	
	# 通知请求者复活成功
	rpc_id(peer_id, "rpc_revive_result", true, "复活成功")
	
	# 延迟一帧后重新检查所有武器的攻击目标（等待 now_hp 同步完成）
	_recheck_weapons_for_revived_player.call_deferred(player)


## 获取玩家满血值（优先走 AttributeManager.final_stats.max_hp）
func _get_player_full_hp(player: PlayerCharacter) -> int:
	if not player or not is_instance_valid(player):
		return 0
	player.attribute_manager.recalculate()
	var hp := player.attribute_manager.final_stats.max_hp
	return hp


## 服务器：复活后如果已经站在掉落物范围内，主动触发一次拾取飞向逻辑
## 原因：Area2D 的 area_entered 不会在“本来就重叠”的情况下触发，需要手动补触发。
func _force_pickup_overlapping_drops(peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	# 关键：等待 1 个物理帧，确保 Area2D 的重叠列表已更新（否则 overlap 可能为 0）
	await get_tree().physics_frame
	
	var player = get_player_by_peer_id(peer_id)
	if not player or not is_instance_valid(player):
		return
	# 复活后应能拾取（至少对非来源掉落），死亡状态直接跳过
	if ("now_hp" in player) and int(player.now_hp) <= 0:
		return
	var area: Area2D = player.get_node_or_null("drop_item_area")
	if not area:
		return
	var overlaps = area.get_overlapping_areas()
	var triggered := 0
	for a in overlaps:
		if not a or not is_instance_valid(a):
			continue
		if not (a.is_in_group("network_drop") or a.is_in_group("drop_item")):
			continue
		if a.has_method("start_moving_for_player"):
			a.start_moving_for_player(peer_id)
			triggered += 1


## 客户端：接收复活结果
@rpc("authority", "call_remote", "reliable")
func rpc_revive_result(success: bool, message: String) -> void:
	print("[NetworkPlayerManager] 复活结果: success=%s, message=%s" % [success, message])
	
	# 通知本地玩家
	if local_player and is_instance_valid(local_player):
		if local_player.has_method("on_revive_result"):
			local_player.on_revive_result(success, message)


## 服务器：重新检查所有武器的攻击目标（玩家复活后调用）
## 包括：1) PvP 目标（双向） 2) 复活玩家武器范围内的怪物
func _recheck_weapons_for_revived_player(revived_player: Node) -> void:
	if not NetworkManager.is_server():
		return
	
	if not revived_player or not is_instance_valid(revived_player):
		return
	
	var revived_peer_id = revived_player.get("peer_id")
	var revived_role = revived_player.get("player_role_id")
	print("[NetworkPlayerManager] 复活后重新检查武器: peer_id=%d, role=%s" % [revived_peer_id, revived_role])
	
	# 获取复活玩家的武器
	var revived_weapons_node = revived_player.get_node_or_null("now_weapons")
	
	# ========== 1. 检查复活玩家的武器是否可以攻击怪物 ==========
	if revived_weapons_node:
		var enemies = get_tree().get_nodes_in_group("enemy")
		for weapon in revived_weapons_node.get_children():
			_try_add_enemies_to_weapon(weapon, enemies)
	
	# ========== 2. 检查 PvP 目标（双向） ==========
	for peer_id in players.keys():
		var other_player = players[peer_id]
		if not other_player or not is_instance_valid(other_player):
			continue
		
		# 跳过复活的玩家自己
		if other_player == revived_player:
			continue
		
		# 跳过死亡的玩家
		if other_player.now_hp <= 0:
			continue
		
		var other_role = other_player.get("player_role_id")
		
		# 检查角色关系是否允许互相攻击
		if not can_attack_each_other(revived_role, other_role):
			continue
		
		# 方向1：其他玩家的武器 -> 复活的玩家
		var other_weapons_node = other_player.get_node_or_null("now_weapons")
		if other_weapons_node:
			for weapon in other_weapons_node.get_children():
				_try_add_target_to_weapon(weapon, revived_player)
		
		# 方向2：复活的玩家的武器 -> 其他玩家
		if revived_weapons_node:
			for weapon in revived_weapons_node.get_children():
				_try_add_target_to_weapon(weapon, other_player)


## 尝试将怪物添加到武器的攻击列表
func _try_add_enemies_to_weapon(weapon: Node, enemies: Array) -> void:
	if not "attack_enemies" in weapon:
		return
	
	var attack_range = weapon.get_range() if weapon.has_method("get_range") else 200.0
	
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		
		# 跳过已在列表中的
		if weapon.attack_enemies.has(enemy):
			continue
		
		# 检查距离
		var distance = weapon.global_position.distance_to(enemy.global_position)
		if distance <= attack_range:
			weapon.attack_enemies.append(enemy)
	
	if weapon.has_method("sort_enemy"):
		weapon.sort_enemy()


## 尝试将目标添加到武器的攻击列表（用于 PvP）
func _try_add_target_to_weapon(weapon: Node, target: Node) -> void:
	if not "attack_enemies" in weapon:
		return
	
	# 检查目标是否已在列表中
	if weapon.attack_enemies.has(target):
		return
	
	# 检查距离是否在攻击范围内
	var attack_range = weapon.get_range() if weapon.has_method("get_range") else 200.0
	var distance = weapon.global_position.distance_to(target.global_position)
	
	if distance <= attack_range:
		weapon.attack_enemies.append(target)
		if weapon.has_method("sort_enemy"):
			weapon.sort_enemy()


## ==================== 工具方法 ====================

func _get_players_parent() -> Node:
	var scene_root = get_tree().current_scene
	if scene_root:
		var players_node = scene_root.get_node_or_null("Players")
		if players_node:
			return players_node
	return null


func _get_display_name() -> String:
	var name = SaveManager.get_player_name()
	if name == null or str(name).strip_edges() == "":
		name = "Player %d" % local_peer_id
	return name


func _parse_peer_id_from_name(node_name: String) -> int:
	var parts = node_name.split("_")
	if parts.size() >= 2:
		return int(parts[-1])
	return 0


## ==================== 网络事件 ====================

func _on_peer_disconnected(peer_id: int) -> void:
	if GameMain.current_mode_id != "online":
		return
	
	if players.has(peer_id):
		var player = players[peer_id]
		if player and is_instance_valid(player):
			player.queue_free()
		players.erase(peer_id)
	
	# 更新摄像机跟随目标
	if NetworkManager.is_server() and peer_id == _following_peer_id:
		_following_peer_id = 0
		for pid in players.keys():
			if is_instance_valid(players[pid]):
				_following_peer_id = pid
				break

	# 服务器：所有客户端都断开后，自动返回关卡选择
	if NetworkManager.is_server() and multiplayer.get_peers().is_empty():
		call_deferred("_server_return_to_level_select")
		return

	# 服务器：玩家离开也可能触发“无人可复活”
	_server_try_end_match("peer_disconnected")


func _on_server_disconnected() -> void:
	if GameMain.current_mode_id != "online":
		return
	_cleanup()
	await SceneCleanupManager.change_scene_safely("res://scenes/UI/level_select.tscn")


func _server_return_to_level_select() -> void:
	if not NetworkManager.is_server():
		return
	# 二次确认：仍然没有任何客户端
	if not multiplayer.get_peers().is_empty():
		return
	# 停止 host 并返回关卡选择
	if NetworkManager and NetworkManager.has_method("stop_network"):
		NetworkManager.stop_network()
	await SceneCleanupManager.change_scene_safely("res://scenes/UI/level_select.tscn")


func _on_network_stopped() -> void:
	_cleanup()


func _cleanup() -> void:
	for peer_id in players.keys():
		var player = players[peer_id]
		if is_instance_valid(player):
			player.queue_free()
	players.clear()
	local_player = null
	
	if _server_camera and is_instance_valid(_server_camera):
		_server_camera.queue_free()
		_server_camera = null
	_following_peer_id = 0
	
	# 清理结算状态（避免下一局继承冻结）
	_reset_online_match_state()
	
	# 清理结算 UI（如果还在）
	for ui in get_tree().get_nodes_in_group("victory_ui_online"):
		if ui and is_instance_valid(ui):
			ui.queue_free()


## ==================== 武器攻击效果同步系统 ====================

## ==================== 玩家子弹：服务器权威模拟 + 客户端展示同步 ====================

const _BULLET_SYNC_INTERVAL_SECONDS := 0.05 # 20Hz，不可靠同步位置/朝向
var _bullet_sync_accum: float = 0.0
var _bullet_instance_seq: int = 0

## 服务器：instance_id -> 子弹节点（权威碰撞/伤害）
var _server_bullets: Dictionary = {}
## 客户端：instance_id -> 视觉子弹节点（仅展示）
var _client_bullets: Dictionary = {}

func _server_make_bullet_instance_id(owner_peer_id: int) -> String:
	_bullet_instance_seq += 1
	return "%d_%d_%d" % [owner_peer_id, Time.get_ticks_usec(), _bullet_instance_seq]

## 服务器：广播子弹状态（仅同步“非直线/会变轨迹”的子弹）
func _server_broadcast_bullet_states() -> void:
	if _server_bullets.is_empty():
		return
	
	var states: Array = []
	for instance_id in _server_bullets.keys():
		var b = _server_bullets[instance_id]
		if not is_instance_valid(b):
			_server_bullets.erase(instance_id)
			continue
		
		# 仅同步会变轨迹的子弹（追踪/弹跳/波浪/螺旋等）
		var needs_sync := true
		if "movement_type" in b:
			needs_sync = int(b.movement_type) != int(BulletData.MovementType.STRAIGHT)
		if not needs_sync:
			continue
		
		states.append([instance_id, b.global_position, b.rotation])
	
	if states.is_empty():
		return
	
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "rpc_sync_bullet_states", states)


@rpc("any_peer", "call_remote", "unreliable")
func rpc_sync_bullet_states(states: Array) -> void:
	# 客户端：应用服务器状态（插值由 bullet.gd 自己处理）
	for s in states:
		if not (s is Array) or s.size() < 3:
			continue
		var instance_id: String = str(s[0])
		var pos: Vector2 = s[1]
		var rot: float = float(s[2])
		
		var bullet = _client_bullets.get(instance_id, null)
		if bullet and is_instance_valid(bullet):
			if bullet.has_method("apply_network_state"):
				bullet.apply_network_state(pos, rot)
			else:
				bullet.global_position = pos
				bullet.rotation = rot


## 服务器：子弹销毁/消失时广播给客户端移除
func _server_broadcast_bullet_despawn(instance_id: String) -> void:
	if not NetworkManager.is_server():
		return
	if instance_id == "":
		return
	
	# 去重：已经广播过就不再重复
	if _server_bullets.has(instance_id):
		_server_bullets.erase(instance_id)
	
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "rpc_despawn_bullet", instance_id)


## 服务器：对外暴露的 despawn（bullet.gd 在命中/寿命到期时调用）
func server_despawn_bullet(instance_id: String) -> void:
	_server_broadcast_bullet_despawn(instance_id)


@rpc("any_peer", "call_remote", "reliable")
func rpc_despawn_bullet(instance_id: String) -> void:
	var bullet = _client_bullets.get(instance_id, null)
	if bullet and is_instance_valid(bullet):
		bullet.queue_free()
	_client_bullets.erase(instance_id)


## 服务器：bullet.gd 在退出树时回调（用于把“命中提前消失”等同步给客户端）
func server_notify_bullet_freed(instance_id: String) -> void:
	if not NetworkManager.is_server():
		return
	if instance_id == "":
		return
	
	# 如果还在表里，说明未广播，补发 despawn
	if _server_bullets.has(instance_id):
		_server_broadcast_bullet_despawn(instance_id)


## ========== 枪口特效同步 ==========
## 统一策略：
## - RANGED：复用子弹 spawn 事件，客户端本地播放枪口特效（与每颗子弹一一对应）
## - MAGIC：复用 rpc_magic_cast/execute 事件，客户端本地播放枪口特效

## 服务器广播子弹生成
## 服务器处理碰撞和伤害，客户端只显示视觉效果
func broadcast_spawn_bullet(start_pos: Vector2, direction: Vector2, damage: int, is_critical: bool, owner_peer_id: int, bullet_id: String, pierce_count: int) -> void:
	if not NetworkManager.is_server():
		return
	
	# 获取子弹数据
	var bullet_data = BulletDatabase.get_bullet(bullet_id)
	if not bullet_data:
		push_error("[NetworkPlayerManager] 找不到子弹数据: %s" % bullet_id)
		return
	
	var instance_id := _server_make_bullet_instance_id(owner_peer_id)

	# 枪口特效尺寸修正：客户端播放枪口时需要使用武器的全局缩放（否则会比挂在武器上更大）
	var muzzle_parent_scale := Vector2.ONE
	var player_for_scale = get_player_by_peer_id(owner_peer_id)
	if player_for_scale:
		var weapons_node_for_scale = player_for_scale.get_node_or_null("now_weapons")
		if weapons_node_for_scale:
			for w in weapons_node_for_scale.get_children():
				if w is BaseWeapon and w.weapon_data and w.weapon_data.behavior_type == WeaponData.BehaviorType.RANGED:
					muzzle_parent_scale = w.global_scale
					break
	
	# 服务器本地生成（有碰撞检测，处理伤害）
	_spawn_bullet_server(start_pos, direction, damage, is_critical, owner_peer_id, bullet_data, pierce_count, instance_id)
	
	# 广播给所有客户端（只显示视觉效果）
	var peers = multiplayer.get_peers()
	for peer_id in peers:
		rpc_id(peer_id, "rpc_spawn_bullet_visual", start_pos, direction, is_critical, owner_peer_id, bullet_id, instance_id, muzzle_parent_scale)


@rpc("any_peer", "call_remote", "reliable")
func rpc_spawn_bullet_visual(start_pos: Vector2, direction: Vector2, is_critical: bool, owner_peer_id: int, bullet_id: String, instance_id: String, muzzle_parent_scale: Vector2) -> void:
	# 客户端只创建视觉子弹（无碰撞检测）
	_spawn_bullet_client(start_pos, direction, is_critical, owner_peer_id, bullet_id, instance_id, muzzle_parent_scale)


## 服务器创建子弹（有碰撞检测，处理伤害）
func _spawn_bullet_server(start_pos: Vector2, direction: Vector2, damage: int, is_critical: bool, owner_peer_id: int, bullet_data: BulletData, pierce_count: int, instance_id: String) -> void:
	var bullet_scene = preload("res://scenes/bullets/bullet.tscn")
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# 记录 instance_id，服务器用于后续同步/销毁广播
	if instance_id != "":
		_server_bullets[instance_id] = bullet
	
	# 获取玩家属性和武器数据（用于特殊效果）
	var weapon_data = null
	var player_stats = null
	var special_effects = []
	var calculation_type = WeaponData.CalculationType.RANGED
	
	var player = get_player_by_peer_id(owner_peer_id)
	if player:
		var weapons_node = player.get_node_or_null("now_weapons")
		if weapons_node and weapons_node.get_child_count() > 0:
			for w in weapons_node.get_children():
				if w is BaseWeapon and w.weapon_data and w.weapon_data.behavior_type == WeaponData.BehaviorType.RANGED:
					weapon_data = w.weapon_data
					player_stats = w.player_stats
					if w.behavior:
						special_effects = w.behavior.special_effects
						calculation_type = w.behavior.calculation_type
					break
	
	# 配置子弹参数（与单机模式一致）
	var start_params = {
		"position": start_pos,
		"direction": direction,
		"speed": bullet_data.speed,
		"damage": damage,
		"is_critical": is_critical,
		"player_stats": player_stats,
		"special_effects": special_effects,
		"calculation_type": calculation_type,
		"pierce_count": pierce_count,
		"bullet_data": bullet_data,
		"owner_peer_id": owner_peer_id,
		"instance_id": instance_id,
		"is_network_driven": false,
	}
	
	# 使用与单机模式相同的初始化方法
	if bullet.has_method("start_with_config"):
		bullet.start_with_config(start_params)
	else:
		bullet.start(start_pos, direction, bullet_data.speed, damage, is_critical, player_stats, weapon_data, owner_peer_id)


## 客户端创建视觉子弹（有碰撞检测用于消失，但不处理伤害）
func _spawn_bullet_client(start_pos: Vector2, direction: Vector2, is_critical: bool, owner_peer_id: int, bullet_id: String, instance_id: String, muzzle_parent_scale: Vector2) -> void:
	var bullet_scene = preload("res://scenes/bullets/bullet.tscn")
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# 获取子弹数据（用于正确的外观）
	var bullet_data = BulletDatabase.get_bullet(bullet_id)
	var is_network_driven := bullet_data != null and int(bullet_data.movement_type) != int(BulletData.MovementType.STRAIGHT)

	# 复用“子弹 spawn”事件播放枪口特效（与每颗子弹一一对应）
	_client_play_muzzle_from_bullet_spawn(start_pos, direction, bullet_data, muzzle_parent_scale)
	
	# 标记为客户端视觉子弹（碰撞时只消失，不处理伤害）
	bullet.is_visual_only = true
	
	# 记录 instance_id，客户端用于应用服务器同步/销毁
	if instance_id != "":
		_client_bullets[instance_id] = bullet
	
	# 配置子弹参数（客户端只需要外观相关的数据）
	var start_params = {
		"position": start_pos,
		"direction": direction,
		"speed": bullet_data.speed if bullet_data else 500.0,
		"damage": 0,  # 客户端不处理伤害
		"is_critical": is_critical,
		"player_stats": null,
		"special_effects": [],
		"calculation_type": WeaponData.CalculationType.RANGED,
		"pierce_count": 0,
		"bullet_data": bullet_data,
		"owner_peer_id": owner_peer_id,
		"instance_id": instance_id,
		"is_network_driven": is_network_driven,
	}
	
	# 使用与单机模式相同的初始化方法
	if bullet.has_method("start_with_config"):
		bullet.start_with_config(start_params)
	else:
		bullet.start(start_pos, direction, bullet_data.speed if bullet_data else 500.0, 0, is_critical, null, null, owner_peer_id)


## 客户端：基于子弹 spawn 事件播放枪口特效（保持与原“挂在武器 shoot_pos 上”一致的尺寸/旋转链路）
func _client_play_muzzle_from_bullet_spawn(start_pos: Vector2, direction: Vector2, bullet_data: BulletData, muzzle_parent_scale: Vector2) -> void:
	if not bullet_data:
		return
	if bullet_data.muzzle_effect_scene_path == "" or bullet_data.muzzle_effect_ani_name == "":
		return
	
	var parent_root: Node = get_tree().current_scene
	if not (parent_root is Node2D):
		return
	
	var anchor := Node2D.new()
	anchor.name = "muzzle_anchor"
	anchor.global_position = start_pos
	anchor.global_rotation = direction.angle()
	anchor.scale = muzzle_parent_scale if muzzle_parent_scale != Vector2.ZERO else Vector2.ONE
	(parent_root as Node2D).add_child(anchor)
	
	CombatEffectManager.play_muzzle_flash(
		bullet_data.muzzle_effect_scene_path,
		bullet_data.muzzle_effect_ani_name,
		anchor,
		bullet_data.muzzle_effect_offset,
		anchor.global_rotation,
		bullet_data.muzzle_effect_scale
	)
	
	get_tree().create_timer(1.0).timeout.connect(func():
		if is_instance_valid(anchor):
			anchor.queue_free()
	)


## 服务器广播近战攻击动画
func broadcast_melee_attack(owner_peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	# 广播给所有客户端
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "rpc_melee_attack", owner_peer_id)


@rpc("any_peer", "call_remote", "reliable")
func rpc_melee_attack(owner_peer_id: int) -> void:
	var player = get_player_by_peer_id(owner_peer_id)
	if not player:
		return
	
	var weapons_node = player.get_node_or_null("now_weapons")
	if not weapons_node:
		return
	
	for weapon in weapons_node.get_children():
		if weapon is BaseWeapon and weapon.weapon_data and weapon.weapon_data.behavior_type == WeaponData.BehaviorType.MELEE:
			# 直接触发近战行为的攻击动画
			if weapon.behavior and weapon.behavior is MeleeBehavior:
				var melee_behavior = weapon.behavior as MeleeBehavior
				melee_behavior.is_attacking = true
				melee_behavior.attack_timer = melee_behavior.get_attack_interval()
				melee_behavior.damaged_enemies.clear()
			break


## 服务器广播魔法攻击开始（有延迟的施法）
func broadcast_magic_cast(target_pos: Vector2, radius: float, delay: float, owner_peer_id: int, weapon_name: String, indicator_texture_path: String = "", indicator_color: Color = Color(1.0, 1.0, 1.0, 0.8)) -> void:
	if not NetworkManager.is_server():
		return
	
	# 广播给所有客户端
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "rpc_magic_cast", target_pos, radius, delay, owner_peer_id, weapon_name, indicator_texture_path, indicator_color)


@rpc("any_peer", "call_remote", "reliable")
func rpc_magic_cast(target_pos: Vector2, radius: float, delay: float, _owner_peer_id: int, weapon_name: String, indicator_texture_path: String, indicator_color: Color) -> void:
	# 客户端：播放枪口特效（使用本地武器节点，保证尺寸/旋转一致）
	_client_play_magic_muzzle(_owner_peer_id, weapon_name, target_pos)
	
	# 客户端显示施法指示器
	if radius > 0:
		_show_explosion_indicator_client(target_pos, radius, delay, indicator_texture_path, indicator_color)
	
	# 延迟后播放爆炸效果
	if delay > 0:
		await get_tree().create_timer(delay).timeout
	
	# 播放爆炸特效
	if weapon_name != "":
		CombatEffectManager.play_explosion(weapon_name, target_pos)


## 服务器广播魔法攻击执行（无延迟）
func broadcast_magic_execute(target_pos: Vector2, radius: float, owner_peer_id: int, weapon_name: String, indicator_texture_path: String = "", indicator_color: Color = Color(1.0, 1.0, 1.0, 0.8)) -> void:
	if not NetworkManager.is_server():
		return
	
	# 广播给所有客户端
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "rpc_magic_execute", target_pos, radius, owner_peer_id, weapon_name, indicator_texture_path, indicator_color)


@rpc("any_peer", "call_remote", "reliable")
func rpc_magic_execute(target_pos: Vector2, radius: float, _owner_peer_id: int, weapon_name: String, indicator_texture_path: String, indicator_color: Color) -> void:
	# 客户端：播放枪口特效（使用本地武器节点，保证尺寸/旋转一致）
	_client_play_magic_muzzle(_owner_peer_id, weapon_name, target_pos)
	
	# 显示短暂指示器
	if radius > 0:
		_show_explosion_indicator_client(target_pos, radius, 0.1, indicator_texture_path, indicator_color)
	
	# 播放爆炸特效
	if weapon_name != "":
		CombatEffectManager.play_explosion(weapon_name, target_pos)


## 客户端显示爆炸指示器
func _show_explosion_indicator_client(pos: Vector2, radius: float, duration: float, texture_path: String = "", color: Color = Color(1.0, 1.0, 1.0, 0.8)) -> void:
	var indicator_script = preload("res://Scripts/weapons/explosion_indicator.gd")
	var indicator = Node2D.new()
	indicator.set_script(indicator_script)
	get_tree().root.add_child(indicator)
	indicator._ready()
	indicator.global_position = pos
	
	# 设置自定义纹理
	if texture_path != "" and indicator.has_method("set_texture"):
		var texture = load(texture_path) as Texture2D
		if texture:
			indicator.set_texture(texture)
	
	if indicator.has_method("show_at"):
		indicator.show_at(pos, radius, color, duration)


## 客户端：基于魔法事件播放枪口特效（不用额外 RPC）
func _client_play_magic_muzzle(caster_peer_id: int, weapon_name: String, target_pos: Vector2) -> void:
	if caster_peer_id <= 0 or weapon_name == "":
		return
	
	var player = get_player_by_peer_id(caster_peer_id)
	if not player:
		return
	
	var weapons_node = player.get_node_or_null("now_weapons")
	if not weapons_node:
		return
	
	# 找到对应的 MAGIC 武器（用 weapon_name 匹配）
	for weapon in weapons_node.get_children():
		if not (weapon is BaseWeapon):
			continue
		var w := weapon as BaseWeapon
		if not w.weapon_data:
			continue
		if w.weapon_data.behavior_type != WeaponData.BehaviorType.MAGIC:
			continue
		if w.weapon_data.weapon_name != weapon_name:
			continue
		
		var shoot_pos = w.get_node_or_null("shoot_pos")
		if not (shoot_pos is Node2D):
			return
		var sp := shoot_pos as Node2D
		
		# magic muzzle 参数来自 weapon_data.behavior_params（本地一致）
		var params = w.weapon_data.get_behavior_params()
		var scene_path: String = str(params.get("muzzle_effect_scene_path", ""))
		var ani_name: String = str(params.get("muzzle_effect_ani_name", ""))
		if scene_path == "" or ani_name == "":
			return
		
		var local_offset: Vector2 = params.get("muzzle_effect_offset", Vector2.ZERO)
		var scale_val: float = float(params.get("muzzle_effect_scale", 1.0))
		
		var dir := (target_pos - sp.global_position).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.RIGHT
		var rot := dir.angle()
		
		CombatEffectManager.play_muzzle_flash(scene_path, ani_name, sp, local_offset, rot, scale_val)
		return


## ==================== PvP 玩家间攻击系统 ====================

## 检查目标是否是有效的 PvP 目标（供 base_weapon 调用）
## 攻击规则：
## 1. Boss 和非 Boss 永远可以互相攻击
## 2. 叛变后：Impostor 和 Player 可以互相攻击
func is_valid_pvp_target(attacker_peer_id: int, target: Node2D) -> bool:
	if GameMain.current_mode_id != "online":
		return false
	
	# 目标必须是玩家
	if not target.is_in_group("player"):
		return false
	
	# 不能攻击自己
	var target_peer_id = target.get("peer_id")
	if target_peer_id == attacker_peer_id:
		return false
	
	# 目标已死亡，不能攻击
	var target_hp = target.get("now_hp")
	if target_hp != null and target_hp <= 0:
		return false
	
	# 获取攻击者
	var attacker = get_player_by_peer_id(attacker_peer_id)
	if not attacker:
		print("[NetworkPlayerManager] is_valid_pvp_target: 找不到攻击者 peer_id=%d" % attacker_peer_id)
		return false
	
	# 攻击者已死亡，不能攻击
	if attacker.now_hp <= 0:
		return false
	
	var attacker_role = attacker.get("player_role_id")
	var target_role = target.get("player_role_id")
	
	# 使用统一的攻击规则检查
	var result = can_attack_each_other(attacker_role, target_role)
	if result:
		print("[NetworkPlayerManager] is_valid_pvp_target: 允许攻击 attacker=%d(%s) -> target=%d(%s)" % [
			attacker_peer_id, attacker_role, target_peer_id, target_role
		])
	return result


## 处理近战武器碰撞（范围内检测可攻击玩家）
## 返回命中的玩家数组（用于应用特效）
func handle_melee_collision(attacker_peer_id: int, attack_pos: Vector2, hit_range: float, damage: int) -> Array:
	var hit_players: Array = []
	
	if GameMain.current_mode_id != "online":
		return hit_players
	
	var attacker = get_player_by_peer_id(attacker_peer_id)
	if not attacker:
		return hit_players
	
	var attacker_role = attacker.get("player_role_id")
	
	for player_peer_id in players.keys():
		var target_player = players[player_peer_id]
		if not target_player or not is_instance_valid(target_player):
			continue
		
		# 跳过自己
		if player_peer_id == attacker_peer_id:
			continue
		
		var target_role = target_player.get("player_role_id")
		
		# 检查是否可以攻击
		if not can_attack_each_other(attacker_role, target_role):
			continue
		
		# 检查距离
		var distance = attack_pos.distance_to(target_player.global_position)
		if distance > hit_range:
			continue
		
		hit_players.append(target_player)
		print("[NetworkPlayerManager] 近战 PvP 攻击: attacker=%d(%s), target=%d(%s), damage=%d" % [
			attacker_peer_id, attacker_role, player_peer_id, target_role, damage
		])
		
		# 服务器直接处理伤害
		_apply_pvp_damage(attacker_peer_id, player_peer_id, damage)
	
	return hit_players


## 子弹碰撞结果
enum BulletHitResult {
	IGNORE = 0,       # 忽略碰撞，继续飞行（如碰到自己）
	DESTROY = 1,      # 销毁子弹（视觉效果或无效目标）
	HIT_PLAYER = 2,   # 命中玩家（服务器已处理伤害）
	HIT_ENEMY = 3,    # 命中敌人（需要处理伤害）
}


## 统一处理子弹碰撞
## 参数:
##   owner_peer_id: 子弹发射者的 peer_id
##   body: 碰撞到的物体
##   damage: 伤害值
##   is_critical: 是否暴击
##   is_visual_only: 是否为客户端视觉子弹
## 返回: BulletHitResult
func handle_bullet_collision(owner_peer_id: int, body: Node2D, damage: int, is_critical: bool, is_visual_only: bool) -> int:
	# 检查是否碰到玩家
	if body.is_in_group("player"):
		var target_peer_id = body.get("peer_id")
		
		# 碰到自己，忽略碰撞
		if target_peer_id == owner_peer_id:
			return BulletHitResult.IGNORE
		
		# 客户端视觉子弹：只消失，不处理伤害
		if is_visual_only:
			return BulletHitResult.DESTROY
		
		# 服务器：检查 PvP 攻击
		if GameMain.current_mode_id == "online":
			var shooter = get_player_by_peer_id(owner_peer_id)
			if not shooter:
				return BulletHitResult.DESTROY
			
			var shooter_role = shooter.get("player_role_id")
			var target_role = body.get("player_role_id")
			
			# 检查是否可以攻击
			if not can_attack_each_other(shooter_role, target_role):
				return BulletHitResult.IGNORE  # 不能攻击，忽略碰撞
			
			print("[NetworkPlayerManager] 子弹 PvP 命中: shooter=%d(%s), target=%d(%s), damage=%d" % [
				owner_peer_id, shooter_role, target_peer_id, target_role, damage
			])
			
			# 服务器处理伤害
			_apply_pvp_damage(owner_peer_id, target_peer_id, damage)
			return BulletHitResult.HIT_PLAYER
		
		return BulletHitResult.DESTROY
	
	# 检查是否碰到敌人
	if body.is_in_group("enemy"):
		# 客户端视觉子弹：只消失，不处理伤害
		if is_visual_only:
			return BulletHitResult.DESTROY
		
		# 返回命中敌人，让 bullet.gd 处理伤害和特效
		return BulletHitResult.HIT_ENEMY
	
	# 其他碰撞，销毁子弹
	return BulletHitResult.DESTROY


## 处理魔法武器爆炸碰撞（范围内检测可攻击玩家）
## 返回命中的玩家数组（用于应用特效）
func handle_explosion_collision(caster_peer_id: int, explosion_pos: Vector2, radius: float, base_damage: int, damage_multiplier: float = 1.0) -> Array:
	var hit_players: Array = []
	
	if GameMain.current_mode_id != "online":
		return hit_players
	
	var caster = get_player_by_peer_id(caster_peer_id)
	if not caster:
		return hit_players
	
	var caster_role = caster.get("player_role_id")
	
	for player_peer_id in players.keys():
		var target_player = players[player_peer_id]
		if not target_player or not is_instance_valid(target_player):
			continue
		
		# 跳过自己
		if player_peer_id == caster_peer_id:
			continue
		
		var target_role = target_player.get("player_role_id")
		
		# 检查是否可以攻击
		if not can_attack_each_other(caster_role, target_role):
			continue
		
		# 检查距离
		var distance = explosion_pos.distance_to(target_player.global_position)
		if distance > radius:
			continue
		
		# 根据距离计算伤害
		var explosion_damage_mult = 1.0 - (distance / radius) * 0.5
		var final_damage = int(base_damage * explosion_damage_mult * damage_multiplier)
		
		hit_players.append(target_player)
		print("[NetworkPlayerManager] 爆炸 PvP 命中: caster=%d(%s), target=%d(%s), damage=%d" % [
			caster_peer_id, caster_role, player_peer_id, target_role, final_damage
		])
		
		# 服务器直接处理伤害
		_apply_pvp_damage(caster_peer_id, player_peer_id, final_damage)
	
	return hit_players


## 公开接口：处理 PvP 伤害（服务器直接调用，用于武器行为）
func apply_pvp_damage(attacker_peer_id: int, target_peer_id: int, damage: int) -> void:
	if not NetworkManager.is_server():
		return
	_apply_pvp_damage(attacker_peer_id, target_peer_id, damage)

## 内部函数：处理 PvP 伤害（服务器调用）
func _apply_pvp_damage(attacker_peer_id: int, target_peer_id: int, damage: int) -> void:
	var attacker = get_player_by_peer_id(attacker_peer_id)
	var target = get_player_by_peer_id(target_peer_id)
	
	if not attacker or not target:
		return
	
	# 检查攻击者或目标是否已死亡
	if attacker.now_hp <= 0:
		return
	if target.now_hp <= 0:
		return
	
	var attacker_role = attacker.get("player_role_id")
	var target_role = target.get("player_role_id")
	
	# 使用统一的攻击规则检查
	var is_valid_attack = can_attack_each_other(attacker_role, target_role)
	
	if not is_valid_attack:
		print("[NetworkPlayerManager] 无效的 PvP 攻击: attacker_role=%s, target_role=%s" % [attacker_role, target_role])
		return
	
	print("[NetworkPlayerManager] PvP 攻击: attacker=%d(%s) -> target=%d(%s), damage=%d" % [
		attacker_peer_id, attacker_role, target_peer_id, target_role, damage
	])
	
	# 造成伤害
	if target.has_method("player_hurt"):
		target.player_hurt(damage)


## RPC：处理玩家攻击玩家（客户端发送给服务器，如 Boss 玩家攻击）
@rpc("any_peer", "call_remote", "reliable")
func rpc_player_attack_player(attacker_peer_id: int, target_peer_id: int, damage: int) -> void:
	# 只有服务器处理伤害
	if not NetworkManager.is_server():
		return
	
	_apply_pvp_damage(attacker_peer_id, target_peer_id, damage)


## ==================== Impostor 叛变系统 ====================

## 检查本地玩家是否是 Impostor
func is_local_player_impostor() -> bool:
	return local_player and local_player.player_role_id == ROLE_IMPOSTOR


## 检查是否可以叛变（只有 Impostor 且未叛变才能触发）
func can_betray() -> bool:
	return is_local_player_impostor() and not impostor_betrayed


## Impostor 触发叛变（由客户端调用）
func trigger_betrayal() -> void:
	if not can_betray():
		return
	
	print("[NetworkPlayerManager] Impostor 请求叛变")
	# 发送叛变请求给服务器
	rpc_id(1, "rpc_request_betrayal")


## 服务器：处理叛变请求
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_betrayal() -> void:
	if not NetworkManager.is_server():
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	
	# 验证发送者是 Impostor
	if sender_id != impostor_peer_id:
		print("[NetworkPlayerManager] 非法叛变请求: sender=%d, impostor=%d" % [sender_id, impostor_peer_id])
		return
	
	# 验证尚未叛变
	if impostor_betrayed:
		print("[NetworkPlayerManager] 已经叛变过了")
		return
	
	# 执行叛变
	_execute_betrayal()


## 服务器：执行叛变
func _execute_betrayal() -> void:
	impostor_betrayed = true
	print("[NetworkPlayerManager] Impostor 叛变成功！peer_id=%d" % impostor_peer_id)
	
	# 广播叛变消息给所有客户端
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "rpc_betrayal_notification", impostor_peer_id)
	
	# 服务器本地也执行
	_on_betrayal_confirmed(impostor_peer_id)
	
	# 发送信号
	impostor_betrayal_triggered.emit(impostor_peer_id)


## 客户端：接收叛变通知
@rpc("any_peer", "call_remote", "reliable")
func rpc_betrayal_notification(betrayer_peer_id: int) -> void:
	_on_betrayal_confirmed(betrayer_peer_id)


## 叛变确认后的处理（服务器和客户端都执行）
func _on_betrayal_confirmed(betrayer_peer_id: int) -> void:
	impostor_betrayed = true
	impostor_peer_id = betrayer_peer_id
	
	print("[NetworkPlayerManager] 收到叛变通知！Impostor peer_id=%d" % betrayer_peer_id)
	
	# 获取 Impostor 玩家
	var impostor = get_player_by_peer_id(betrayer_peer_id)
	if impostor and is_instance_valid(impostor):
		# 可以在这里添加视觉效果，如改变名字颜色等
		if impostor.has_method("on_betrayal"):
			impostor.on_betrayal()
	
	# 显示叛变提示
	var impostor_name = "未知"
	if impostor:
		impostor_name = impostor.display_name
	
	FloatingText.create_floating_text(
		Vector2(get_viewport().get_visible_rect().size.x / 2, 200),
		"⚠ %s 叛变了！" % impostor_name,
		Color(1.0, 0.5, 0.0, 1.0),  # 橙色
		true
	)


## 检查两个角色是否可以互相攻击
func can_attack_each_other(attacker_role: String, target_role: String) -> bool:
	# Boss 和非 Boss 永远可以互相攻击
	if attacker_role == ROLE_BOSS and target_role != ROLE_BOSS:
		return true
	if attacker_role != ROLE_BOSS and target_role == ROLE_BOSS:
		return true
	
	# 叛变后：Impostor、Player、Boss 三方混战
	if impostor_betrayed:
		# Impostor 和 Player 可以互相攻击
		if attacker_role == ROLE_IMPOSTOR and target_role == ROLE_PLAYER:
			return true
		if attacker_role == ROLE_PLAYER and target_role == ROLE_IMPOSTOR:
			return true
	
	return false


## 检查两个玩家（通过 peer_id）是否可以互相攻击
func can_attack_each_other_by_peer(attacker_peer_id: int, target_peer_id: int) -> bool:
	var attacker = get_player_by_peer_id(attacker_peer_id)
	var target = get_player_by_peer_id(target_peer_id)
	
	if not attacker or not target:
		return false
	
	var attacker_role = attacker.get("player_role_id")
	var target_role = target.get("player_role_id")
	
	return can_attack_each_other(attacker_role, target_role)


## ==================== 升级商店系统 ====================

## Boss 可购买的升级类型（对Boss有效的非武器类型）
## Boss的冲刺攻击和技能攻击现已使用属性系统，支持异常效果触发
const BOSS_ALLOWED_UPGRADE_TYPES := [
	UpgradeData.UpgradeType.HP_MAX,           # HP上限
	UpgradeData.UpgradeType.MOVE_SPEED,       # 移动速度
	UpgradeData.UpgradeType.HEAL_HP,          # 恢复HP
	UpgradeData.UpgradeType.DAMAGE_REDUCTION, # 防御力/减伤
	UpgradeData.UpgradeType.LUCK,             # 幸运（影响商店品质）
	UpgradeData.UpgradeType.KEY_PICKUP_RANGE, # 钥匙拾取范围
	UpgradeData.UpgradeType.STATUS_CHANCE,    # 异常触发概率（影响冲刺减速、技能燃烧）
	UpgradeData.UpgradeType.STATUS_DURATION,  # 异常持续时间
	UpgradeData.UpgradeType.STATUS_EFFECT,    # 异常效果强度
]


## 检查玩家是否可以使用商店
func can_use_shop(peer_id: int) -> bool:
	var player = get_player_by_peer_id(peer_id)
	if not player:
		return false
	return true


## 检查升级类型是否对 Boss 可用
func is_upgrade_allowed_for_boss(upgrade_type: int) -> bool:
	return upgrade_type in BOSS_ALLOWED_UPGRADE_TYPES


## 客户端请求购买升级
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_purchase(upgrade_type: int, upgrade_name: String, cost: int, weapon_id: String, custom_value: float, stats_data: Dictionary) -> void:
	if not NetworkManager.is_server():
		return
	if is_match_frozen():
		return

	var sender_id = multiplayer.get_remote_sender_id()
	var player = get_player_by_peer_id(sender_id)
	
	if not player:
		print("[NetworkPlayerManager] 购买失败: 找不到玩家 peer_id=%d" % sender_id)
		rpc_id(sender_id, "rpc_purchase_result", false, "找不到玩家")
		return
	
	# 检查是否是 Boss
	var role = player.get("player_role_id")
	if role == ROLE_BOSS:
		# Boss 只能购买血量和移动速度相关的升级
		if not is_upgrade_allowed_for_boss(upgrade_type):
			print("[NetworkPlayerManager] 购买失败: Boss 不能购买此类型升级 (type=%d)" % upgrade_type)
			rpc_id(sender_id, "rpc_purchase_result", false, "Boss 不能购买此升级")
			return
	
	# 检查钥匙是否足够（从 MultiplayerSynchronizer 同步的值）
	if player.gold < cost:
		print("[NetworkPlayerManager] 购买失败: 钥匙不足 (需要 %d, 拥有 %d)" % [cost, player.gold])
		rpc_id(sender_id, "rpc_purchase_result", false, "钥匙不足")
		return
	
	print("[NetworkPlayerManager] 处理购买请求: peer_id=%d, upgrade=%s, cost=%d, gold=%d" % [sender_id, upgrade_name, cost, player.gold])
	
	# 通知客户端扣除 gold，由客户端修改后通过 MultiplayerSynchronizer 同步
	if player.has_method("rpc_add_resource"):
		player.rpc_id(sender_id, "rpc_add_resource", "gold", -cost)
	
	# 根据升级类型应用效果
	_apply_upgrade_on_server(sender_id, upgrade_type, upgrade_name, weapon_id, custom_value, stats_data)
	
	# 通知购买成功
	rpc_id(sender_id, "rpc_purchase_result", true, "购买成功")


## 客户端请求刷新商店
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_shop_refresh(cost: int) -> void:
	if not NetworkManager.is_server():
		return
	if is_match_frozen():
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var player = get_player_by_peer_id(sender_id)
	
	if not player:
		print("[NetworkPlayerManager] 刷新失败: 找不到玩家 peer_id=%d" % sender_id)
		rpc_id(sender_id, "rpc_refresh_result", false, "找不到玩家")
		return
	
	# 检查钥匙是否足够（从 MultiplayerSynchronizer 同步的值）
	if player.gold < cost:
		print("[NetworkPlayerManager] 刷新失败: 钥匙不足 (需要 %d, 拥有 %d)" % [cost, player.gold])
		rpc_id(sender_id, "rpc_refresh_result", false, "钥匙不足")
		return
	
	print("[NetworkPlayerManager] 处理刷新请求: peer_id=%d, cost=%d, gold=%d" % [sender_id, cost, player.gold])
	
	# 通知客户端扣除 gold，由客户端修改后通过 MultiplayerSynchronizer 同步
	if player.has_method("rpc_add_resource"):
		player.rpc_id(sender_id, "rpc_add_resource", "gold", -cost)
	
	# 通知刷新成功
	rpc_id(sender_id, "rpc_refresh_result", true, "刷新成功")


## 客户端：刷新商店结果
@rpc("authority", "call_remote", "reliable")
func rpc_refresh_result(success: bool, message: String) -> void:
	print("[NetworkPlayerManager] 刷新结果: success=%s, message=%s" % [success, message])
	
	# 通知商店 UI 处理结果
	var upgrade_shop = get_tree().get_first_node_in_group("upgrade_shop")
	if upgrade_shop and upgrade_shop.has_method("on_refresh_result"):
		upgrade_shop.on_refresh_result(success, message)


## 服务器端应用升级效果
func _apply_upgrade_on_server(peer_id: int, upgrade_type: int, upgrade_name: String, weapon_id: String, custom_value: float, stats_data: Dictionary) -> void:
	var player = get_player_by_peer_id(peer_id)
	if not player:
		return
	
	match upgrade_type:
		UpgradeData.UpgradeType.HEAL_HP:
			_server_apply_heal(peer_id, custom_value)
		UpgradeData.UpgradeType.NEW_WEAPON:
			_server_apply_new_weapon(peer_id, weapon_id)
		UpgradeData.UpgradeType.WEAPON_LEVEL_UP:
			_server_apply_weapon_level_up(peer_id, weapon_id)
		_:
			# 属性升级
			_server_apply_attribute_upgrade(peer_id, stats_data)
	
	print("[NetworkPlayerManager] 升级已应用: peer_id=%d, type=%d, name=%s" % [peer_id, upgrade_type, upgrade_name])


## 服务器应用治疗效果
func _server_apply_heal(peer_id: int, heal_amount: float) -> void:
	var amount = int(heal_amount) if heal_amount > 0 else 10
	# 通知客户端恢复血量
	var player = get_player_by_peer_id(peer_id)
	if player and player.has_method("rpc_heal"):
		# 必须从 player 节点发起 RPC，确保命中客户端对应的 player 节点上的 rpc_heal
		# 如果从 NetworkPlayerManager 发起，会尝试调用客户端的 NetworkPlayerManager.rpc_heal（通常不存在），导致治疗无效
		player.rpc_id(peer_id, "rpc_heal", amount)
		print("[NetworkPlayerManager] 治疗: peer_id=%d, amount=%d" % [peer_id, amount])


## 服务器应用新武器
func _server_apply_new_weapon(peer_id: int, weapon_id: String) -> void:
	# 广播给所有客户端添加武器
	rpc("rpc_add_weapon", peer_id, weapon_id)
	print("[NetworkPlayerManager] 新武器: peer_id=%d, weapon=%s" % [peer_id, weapon_id])


## 服务器应用武器升级
func _server_apply_weapon_level_up(peer_id: int, weapon_id: String) -> void:
	# 广播给所有客户端升级武器
	rpc("rpc_upgrade_weapon", peer_id, weapon_id)
	print("[NetworkPlayerManager] 武器升级: peer_id=%d, weapon=%s" % [peer_id, weapon_id])


## 服务器应用属性升级
func _server_apply_attribute_upgrade(peer_id: int, stats_data: Dictionary) -> void:
	# 广播给所有客户端应用属性升级
	rpc("rpc_apply_stats_upgrade", peer_id, stats_data)
	print("[NetworkPlayerManager] 属性升级: peer_id=%d, stats=%s" % [peer_id, str(stats_data)])


## 客户端：购买结果
@rpc("authority", "call_remote", "reliable")
func rpc_purchase_result(success: bool, message: String) -> void:
	print("[NetworkPlayerManager] 购买结果: success=%s, message=%s" % [success, message])
	
	# 通知商店 UI 处理结果
	var upgrade_shop = get_tree().get_first_node_in_group("upgrade_shop")
	if upgrade_shop and upgrade_shop.has_method("on_purchase_result"):
		upgrade_shop.on_purchase_result(success, message)


## 所有客户端：添加武器
@rpc("authority", "call_local", "reliable")
func rpc_add_weapon(peer_id: int, weapon_id: String) -> void:
	var player = get_player_by_peer_id(peer_id)
	if not player:
		return
	
	var weapons_node = player.get_node_or_null("now_weapons")
	if weapons_node and weapons_node.has_method("add_weapon"):
		await weapons_node.add_weapon(weapon_id, 1)  # 使用 await 等待武器添加完成
		# 新武器添加后更新 owner_peer_id
		_update_weapons_owner_peer_id(player)
		print("[NetworkPlayerManager] 玩家 %d 添加武器: %s" % [peer_id, weapon_id])


## 所有客户端：升级武器
@rpc("authority", "call_local", "reliable")
func rpc_upgrade_weapon(peer_id: int, weapon_id: String) -> void:
	var player = get_player_by_peer_id(peer_id)
	if not player:
		return
	
	var weapons_node = player.get_node_or_null("now_weapons")
	if weapons_node and weapons_node.has_method("get_lowest_level_weapon_of_type"):
		var weapon = weapons_node.get_lowest_level_weapon_of_type(weapon_id)
		if weapon and weapon.has_method("upgrade_level"):
			weapon.upgrade_level()
			print("[NetworkPlayerManager] 玩家 %d 武器升级: %s" % [peer_id, weapon_id])


## 所有客户端：应用属性升级
@rpc("authority", "call_local", "reliable")
func rpc_apply_stats_upgrade(peer_id: int, stats_data: Dictionary) -> void:
	var player = get_player_by_peer_id(peer_id)
	if not player:
		return
	
	# 只有本地玩家实际应用属性（然后通过 MultiplayerSynchronizer 同步）
	if player.is_local_player:
		_apply_stats_to_player(player, stats_data)
		print("[NetworkPlayerManager] 本地玩家应用属性升级: %s" % str(stats_data))


## 应用属性到玩家
func _apply_stats_to_player(player: PlayerCharacter, stats_data: Dictionary) -> void:
	# 检查是否使用新属性系统
	if player.has_node("AttributeManager"):
		var attr_manager = player.get_node("AttributeManager")
		var modifier = AttributeModifier.new()
		modifier.modifier_type = AttributeModifier.ModifierType.UPGRADE
		modifier.modifier_id = "upgrade_" + str(Time.get_ticks_msec())
		
		# 从 stats_data 创建 CombatStats（增量模式，需要清零默认值）
		var stats = CombatStats.new()
		# ⭐ 清零默认值，避免意外累加
		stats.max_hp = 0
		stats.speed = 0.0
		stats.crit_damage = 0.0
		
		# 只设置传入的属性值
		for key in stats_data.keys():
			if key in stats:
				stats.set(key, stats_data[key])
		
		modifier.stats_delta = stats
		attr_manager.add_permanent_modifier(modifier)
		print("[NetworkPlayerManager] 应用属性升级到 AttributeManager: %s" % str(stats_data))
	else:
		# 降级方案：直接修改玩家属性
		if stats_data.has("max_hp") and stats_data["max_hp"] != 0:
			player.max_hp += int(stats_data["max_hp"])
		if stats_data.has("speed") and stats_data["speed"] != 0:
			player.speed += stats_data["speed"]
		print("[NetworkPlayerManager] 应用属性升级（降级方案）: %s" % str(stats_data))


## ==================== 敌人冲刺指示器同步系统 ====================

## 客户端存储的冲刺指示器 {enemy_id: Node2D}
var _client_charge_indicators: Dictionary = {}

## 客户端缓存的纹理/动画帧资源
var _charge_indicator_cache: Dictionary = {}

## 服务器广播显示冲刺指示器
## texture_path: 静态纹理路径（如果使用静态纹理）
## sprite_frames_path: 动画帧资源路径（如果使用动画）
## animation_name: 动画名称
func broadcast_show_charge_indicator(enemy_node_path: String, enemy_pos: Vector2, target_pos: Vector2, indicator_scale: Vector2, texture_path: String, sprite_frames_path: String, animation_name: String) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_show_charge_indicator", enemy_node_path, enemy_pos, target_pos, indicator_scale, texture_path, sprite_frames_path, animation_name)


## 服务器广播更新冲刺指示器
func broadcast_update_charge_indicator(enemy_node_path: String, enemy_pos: Vector2, target_pos: Vector2) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_update_charge_indicator", enemy_node_path, enemy_pos, target_pos)


## 服务器广播隐藏冲刺指示器
func broadcast_hide_charge_indicator(enemy_node_path: String) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_hide_charge_indicator", enemy_node_path)


## 客户端显示冲刺指示器
@rpc("authority", "call_remote", "reliable")
func rpc_show_charge_indicator(enemy_node_path: String, enemy_pos: Vector2, target_pos: Vector2, indicator_scale: Vector2, texture_path: String, sprite_frames_path: String, animation_name: String) -> void:
	var indicator: Node2D = null
	
	# 根据资源类型创建不同的指示器
	if sprite_frames_path != "":
		# 使用动画帧（AnimatedSprite2D）
		var sprite_frames: SpriteFrames = null
		if _charge_indicator_cache.has(sprite_frames_path):
			sprite_frames = _charge_indicator_cache[sprite_frames_path]
		else:
			sprite_frames = load(sprite_frames_path) as SpriteFrames
			if sprite_frames:
				_charge_indicator_cache[sprite_frames_path] = sprite_frames
		
		if sprite_frames:
			var animated_sprite = AnimatedSprite2D.new()
			animated_sprite.sprite_frames = sprite_frames
			animated_sprite.centered = false
			
			# 计算偏移（垂直居中）
			if sprite_frames.has_animation(animation_name):
				var frame_texture = sprite_frames.get_frame_texture(animation_name, 0)
				if frame_texture:
					animated_sprite.offset = Vector2(0, -frame_texture.get_height() / 2.0)
			
			indicator = animated_sprite
			
			# 播放动画
			if sprite_frames.has_animation(animation_name):
				animated_sprite.play(animation_name)
	else:
		# 使用静态纹理（Sprite2D）
		var texture: Texture2D = null
		var path_to_load = texture_path if texture_path != "" else "res://assets/skill_indicator/charging-range-rect.png"
		
		if _charge_indicator_cache.has(path_to_load):
			texture = _charge_indicator_cache[path_to_load]
		else:
			texture = load(path_to_load) as Texture2D
			if texture:
				_charge_indicator_cache[path_to_load] = texture
		
		var sprite = Sprite2D.new()
		sprite.texture = texture
		sprite.centered = false
		if texture:
			sprite.offset = Vector2(0, -texture.get_height() / 2.0)
		
		indicator = sprite
	
	if not indicator:
		push_error("[NetworkPlayerManager] 无法创建冲刺指示器")
		return
	
	# 通用设置
	indicator.z_index = -1
	indicator.scale = indicator_scale
	indicator.top_level = true
	
	get_tree().root.add_child(indicator)
	
	# 设置位置和朝向
	indicator.global_position = enemy_pos
	var dir = (target_pos - enemy_pos).normalized()
	indicator.rotation = dir.angle()
	
	# 存储指示器
	_client_charge_indicators[enemy_node_path] = indicator


## 客户端更新冲刺指示器
@rpc("authority", "call_remote", "unreliable")
func rpc_update_charge_indicator(enemy_node_path: String, enemy_pos: Vector2, target_pos: Vector2) -> void:
	if not _client_charge_indicators.has(enemy_node_path):
		return
	
	var indicator = _client_charge_indicators[enemy_node_path]
	if not is_instance_valid(indicator):
		_client_charge_indicators.erase(enemy_node_path)
		return
	
	# 更新位置和朝向
	indicator.global_position = enemy_pos
	var dir = (target_pos - enemy_pos).normalized()
	indicator.rotation = dir.angle()


## 客户端隐藏冲刺指示器
@rpc("authority", "call_remote", "reliable")
func rpc_hide_charge_indicator(enemy_node_path: String) -> void:
	if not _client_charge_indicators.has(enemy_node_path):
		return
	
	var indicator = _client_charge_indicators[enemy_node_path]
	if is_instance_valid(indicator):
		indicator.queue_free()
	_client_charge_indicators.erase(enemy_node_path)


## ==================== 敌人爆炸指示器同步系统 ====================

## 客户端存储的爆炸指示器 {enemy_path: Sprite2D}
var _client_explode_indicators: Dictionary = {}

## 爆炸范围指示器纹理
var _explode_range_texture: Texture2D = null

## 服务器广播显示爆炸范围指示器
func broadcast_show_explode_indicator(enemy_node_path: String, enemy_pos: Vector2, explosion_range: float) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_show_explode_indicator", enemy_node_path, enemy_pos, explosion_range)


## 服务器广播更新爆炸范围指示器位置
func broadcast_update_explode_indicator(enemy_node_path: String, enemy_pos: Vector2) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_update_explode_indicator", enemy_node_path, enemy_pos)


## 服务器广播隐藏爆炸范围指示器
func broadcast_hide_explode_indicator(enemy_node_path: String) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_hide_explode_indicator", enemy_node_path)


## 服务器广播敌人闪烁效果
func broadcast_enemy_flash(enemy_node_path: String, is_flashing: bool) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_enemy_flash", enemy_node_path, is_flashing)


## 客户端设置敌人闪烁效果
@rpc("authority", "call_remote", "unreliable")
func rpc_enemy_flash(enemy_node_path: String, is_flashing: bool) -> void:
	var enemy = get_node_or_null(enemy_node_path)
	if not enemy:
		return
	
	var sprite = enemy.get_node_or_null("AnimatedSprite2D")
	if not sprite or not sprite.material:
		return
	
	if is_flashing:
		# 黄色闪烁
		sprite.material.set_shader_parameter("flash_color", Color(0.826, 0.766, 0.0, 1.0))
		sprite.material.set_shader_parameter("flash_opacity", 1.0)
	else:
		# 恢复正常
		sprite.material.set_shader_parameter("flash_color", Color(1.0, 1.0, 1.0, 1.0))
		sprite.material.set_shader_parameter("flash_opacity", 0.0)


## 服务器广播播放爆炸特效
func broadcast_explode_fx(pos: Vector2, sprite_frames_path: String, animation_name: String, fx_scale: Vector2) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_play_explode_fx", pos, sprite_frames_path, animation_name, fx_scale)


## 服务器广播通用爆炸效果
func broadcast_enemy_explosion(pos: Vector2, effect_scale: float) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_play_enemy_explosion", pos, effect_scale)


## 客户端显示爆炸范围指示器
@rpc("authority", "call_remote", "reliable")
func rpc_show_explode_indicator(enemy_node_path: String, enemy_pos: Vector2, explosion_range: float) -> void:
	# 加载范围指示器纹理
	if not _explode_range_texture:
		_explode_range_texture = load("res://assets/skill_indicator/explosion_range_circle.png")
	
	if not _explode_range_texture:
		push_error("[NetworkPlayerManager] 无法加载爆炸范围指示器纹理")
		return
	
	var indicator = Sprite2D.new()
	indicator.texture = _explode_range_texture
	
	# 根据 explosion_range 调整缩放
	var target_diameter = explosion_range * 2
	var texture_size = _explode_range_texture.get_size().x
	if texture_size > 0:
		indicator.scale = Vector2.ONE * (target_diameter / texture_size)
	
	indicator.z_index = 1
	indicator.modulate = Color(1.0, 0.0, 0.0, 0.5)  # 红色，50%透明度
	indicator.global_position = enemy_pos
	
	get_tree().root.add_child(indicator)
	_client_explode_indicators[enemy_node_path] = indicator


## 客户端更新爆炸范围指示器位置
@rpc("authority", "call_remote", "unreliable")
func rpc_update_explode_indicator(enemy_node_path: String, enemy_pos: Vector2) -> void:
	if not _client_explode_indicators.has(enemy_node_path):
		return
	
	var indicator = _client_explode_indicators[enemy_node_path]
	if is_instance_valid(indicator):
		indicator.global_position = enemy_pos


## 客户端隐藏爆炸范围指示器
@rpc("authority", "call_remote", "reliable")
func rpc_hide_explode_indicator(enemy_node_path: String) -> void:
	if not _client_explode_indicators.has(enemy_node_path):
		return
	
	var indicator = _client_explode_indicators[enemy_node_path]
	if is_instance_valid(indicator):
		indicator.queue_free()
	_client_explode_indicators.erase(enemy_node_path)


## 客户端播放爆炸特效
@rpc("authority", "call_remote", "reliable")
func rpc_play_explode_fx(pos: Vector2, sprite_frames_path: String, animation_name: String, fx_scale: Vector2) -> void:
	if sprite_frames_path == "":
		return
	
	var sprite_frames = load(sprite_frames_path) as SpriteFrames
	if not sprite_frames:
		return
	
	if not sprite_frames.has_animation(animation_name):
		return
	
	# 创建特效节点
	var fx_node = AnimatedSprite2D.new()
	fx_node.sprite_frames = sprite_frames
	fx_node.global_position = pos
	fx_node.scale = fx_scale
	fx_node.z_index = 10
	
	get_tree().root.add_child(fx_node)
	fx_node.play(animation_name)
	
	# 计算动画时长并清理
	var frame_count = sprite_frames.get_frame_count(animation_name)
	var fps = sprite_frames.get_animation_speed(animation_name)
	if fps <= 0:
		fps = 5.0
	var duration = frame_count / fps
	
	get_tree().create_timer(duration + 0.1).timeout.connect(func():
		if is_instance_valid(fx_node):
			fx_node.queue_free()
	)


## 客户端播放通用爆炸效果
@rpc("authority", "call_remote", "reliable")
func rpc_play_enemy_explosion(pos: Vector2, effect_scale: float) -> void:
	CombatEffectManager.play_enemy_explosion(pos, effect_scale)
	CameraShake.shake(0.3, 15.0)


## ==================== 敌人子弹同步系统 ====================

## 敌人子弹场景缓存
var _enemy_bullet_scene_cache: Dictionary = {}

## 获取敌人子弹场景（带缓存）
func _get_enemy_bullet_scene(scene_path: String) -> PackedScene:
	if scene_path == "":
		scene_path = "res://scenes/bullets/enemy_bullet.tscn"
	
	if not _enemy_bullet_scene_cache.has(scene_path):
		var scene = load(scene_path) as PackedScene
		if scene:
			_enemy_bullet_scene_cache[scene_path] = scene
		else:
			push_error("[NetworkPlayerManager] 无法加载敌人子弹场景: " + scene_path)
			# 回退到默认场景
			if scene_path != "res://scenes/bullets/enemy_bullet.tscn":
				return _get_enemy_bullet_scene("res://scenes/bullets/enemy_bullet.tscn")
			return null
	
	return _enemy_bullet_scene_cache.get(scene_path)

## 服务器广播敌人子弹生成
## owner_peer_id: 子弹所有者的 peer_id（用于 boss 玩家技能，排除自己）
## special_effects: 特殊效果配置数组（可选，用于Boss技能触发异常）
## player_stats: 攻击者属性（可选，用于异常效果计算）
func broadcast_enemy_bullet(start_pos: Vector2, direction: Vector2, speed: float, damage: int, bullet_id: String = "basic", bullet_scene_path: String = "", owner_peer_id: int = 0, special_effects: Array = [], player_stats: CombatStats = null) -> void:
	if not NetworkManager.is_server():
		return
	
	# 服务器本地生成（有碰撞检测，处理伤害）
	_spawn_enemy_bullet_server(start_pos, direction, speed, damage, bullet_id, bullet_scene_path, owner_peer_id, special_effects, player_stats)
	
	# 广播给所有客户端（只显示视觉效果）
	rpc("rpc_spawn_enemy_bullet_visual", start_pos, direction, speed, bullet_id, bullet_scene_path, owner_peer_id)


## 客户端接收敌人子弹
@rpc("authority", "call_remote", "reliable")
func rpc_spawn_enemy_bullet_visual(start_pos: Vector2, direction: Vector2, speed: float, bullet_id: String, bullet_scene_path: String, owner_peer_id: int = 0) -> void:
	_spawn_enemy_bullet_client(start_pos, direction, speed, bullet_id, bullet_scene_path, owner_peer_id)


## 服务器创建敌人子弹（有碰撞检测，处理伤害）
func _spawn_enemy_bullet_server(start_pos: Vector2, direction: Vector2, speed: float, damage: int, bullet_id: String, bullet_scene_path: String, owner_peer_id: int = 0, special_effects: Array = [], player_stats: CombatStats = null) -> void:
	var bullet_scene = _get_enemy_bullet_scene(bullet_scene_path)
	if not bullet_scene:
		push_error("[NetworkPlayerManager] 无法加载敌人子弹场景")
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# 设置子弹朝向
	bullet.rotation = direction.angle()
	
	# 设置子弹所有者（用于 boss 玩家技能，排除自己）
	if "owner_peer_id" in bullet:
		bullet.owner_peer_id = owner_peer_id
	
	# 设置特殊效果（用于Boss技能触发异常）
	if not special_effects.is_empty() and "special_effects" in bullet:
		bullet.special_effects = special_effects
	
	# 设置攻击者属性（用于异常效果计算）
	if player_stats and "player_stats" in bullet:
		bullet.player_stats = player_stats
	
	# 初始化子弹
	if bullet.has_method("start"):
		bullet.start(start_pos, direction, speed, damage)
	elif bullet.has_method("initialize_with_data"):
		var bullet_data = EnemyBulletDatabase.get_bullet_data(bullet_id) if EnemyBulletDatabase else null
		if bullet_data:
			var data_copy = bullet_data.duplicate()
			data_copy.damage = damage
			data_copy.speed = speed
			bullet.initialize_with_data(start_pos, direction, data_copy)
		else:
			bullet.start(start_pos, direction, speed, damage)


## 客户端创建敌人子弹（只显示视觉效果，无伤害）
func _spawn_enemy_bullet_client(start_pos: Vector2, direction: Vector2, speed: float, bullet_id: String, bullet_scene_path: String, owner_peer_id: int = 0) -> void:
	var bullet_scene = _get_enemy_bullet_scene(bullet_scene_path)
	if not bullet_scene:
		push_error("[NetworkPlayerManager] 无法加载敌人子弹场景")
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# 设置子弹朝向
	bullet.rotation = direction.angle()
	
	# 标记为视觉子弹（如果子弹脚本支持）
	if "is_visual_only" in bullet:
		bullet.is_visual_only = true
	
	# 设置子弹所有者（用于 boss 玩家技能，排除自己）
	if "owner_peer_id" in bullet:
		bullet.owner_peer_id = owner_peer_id
	
	# 初始化子弹（客户端伤害设为0）
	if bullet.has_method("start"):
		bullet.start(start_pos, direction, speed, 0)  # 伤害为0
	elif bullet.has_method("initialize_with_data"):
		var bullet_data = EnemyBulletDatabase.get_bullet_data(bullet_id) if EnemyBulletDatabase else null
		if bullet_data:
			var data_copy = bullet_data.duplicate()
			data_copy.damage = 0  # 客户端不处理伤害
			data_copy.speed = speed
			bullet.initialize_with_data(start_pos, direction, data_copy)
		else:
			bullet.start(start_pos, direction, speed, 0)


## ==================== Boss技能动画同步系统 ====================

## 客户端 Boss 特效节点缓存 { enemy_path: fx_node }
var _client_boss_fx_nodes: Dictionary = {}

## 服务器广播 Boss 技能开始（准备阶段）
func broadcast_boss_skill_start(enemy: Node, skill_anim: String, fx_sprite_frames_path: String, fx_animation_name: String, fx_offset: Vector2, fx_scale: Vector2, fx_above_boss: bool) -> void:
	if not NetworkManager.is_server():
		return
	
	var enemy_path = str(enemy.get_path())
	rpc("rpc_boss_skill_start", enemy_path, skill_anim, fx_sprite_frames_path, fx_animation_name, fx_offset, fx_scale, fx_above_boss)


## 客户端接收 Boss 技能开始
@rpc("authority", "call_remote", "reliable")
func rpc_boss_skill_start(enemy_path: String, skill_anim: String, fx_sprite_frames_path: String, fx_animation_name: String, fx_offset: Vector2, fx_scale: Vector2, fx_above_boss: bool) -> void:
	var enemy = get_node_or_null(enemy_path)
	if not enemy:
		return
	
	# 播放技能动画
	if skill_anim != "":
		var sprite = enemy.get_node_or_null("AnimatedSprite2D")
		if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation(skill_anim):
			sprite.play(skill_anim)
	
	# 显示特效
	if fx_sprite_frames_path != "" and fx_animation_name != "":
		var fx_sprite_frames = load(fx_sprite_frames_path) as SpriteFrames
		if fx_sprite_frames and fx_sprite_frames.has_animation(fx_animation_name):
			var fx_node = AnimatedSprite2D.new()
			fx_node.sprite_frames = fx_sprite_frames
			fx_node.position = fx_offset
			fx_node.scale = fx_scale
			fx_node.z_index = 10 if fx_above_boss else -1
			enemy.add_child(fx_node)
			fx_node.play(fx_animation_name)
			
			# 缓存特效节点
			_client_boss_fx_nodes[enemy_path] = fx_node


## 服务器广播 Boss 技能结束（清理特效）
func broadcast_boss_skill_end(enemy: Node) -> void:
	if not NetworkManager.is_server():
		return
	
	var enemy_path = str(enemy.get_path())
	rpc("rpc_boss_skill_end", enemy_path)


## 客户端接收 Boss 技能结束
@rpc("authority", "call_remote", "reliable")
func rpc_boss_skill_end(enemy_path: String) -> void:
	# 清理特效节点
	if _client_boss_fx_nodes.has(enemy_path):
		var fx_node = _client_boss_fx_nodes[enemy_path]
		if is_instance_valid(fx_node):
			fx_node.queue_free()
		_client_boss_fx_nodes.erase(enemy_path)
	
	# 恢复行走动画
	var enemy = get_node_or_null(enemy_path)
	if enemy:
		var sprite = enemy.get_node_or_null("AnimatedSprite2D")
		if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("walk"):
			sprite.play("walk")


## ==================== 联网模式墓碑系统 ====================

## 墓碑场景
var _grave_online_scene: PackedScene = preload("res://scenes/players/grave_online.tscn")

## 当前存在的墓碑 { peer_id: GraveOnline }
var _online_graves: Dictionary = {}

## 已处理过死亡掉落的玩家（防止重复掉落）
var _death_drop_processed: Dictionary = {}  # peer_id -> true

## 客户端通知服务器玩家死亡
## client_gold: 客户端发送的当前 gold 数量（避免 MultiplayerSynchronizer 同步延迟问题）
## -1 表示客户端未提供（兼容旧版本）
@rpc("any_peer", "call_remote", "reliable")
func rpc_notify_player_death(dead_peer_id: int, death_position: Vector2, client_gold: int = -1) -> void:
	if not NetworkManager.is_server():
		return
	if is_match_frozen():
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	# 验证发送者是否是死亡的玩家本身
	if sender_id != dead_peer_id:
		print("[NetworkPlayerManager] 死亡通知验证失败: sender=%d, dead_peer=%d" % [sender_id, dead_peer_id])
		return
	
	print("[NetworkPlayerManager] 收到玩家死亡通知: peer_id=%d, pos=%s, client_gold=%d" % [dead_peer_id, str(death_position), client_gold])

	# 关键修复：客户端的 now_hp 同步到服务器可能有延迟。
	# 如果这里不立即把服务器侧 now_hp 置 0，结算检查会误判“还有玩家存活”，导致不进入结算。
	var dead_player = get_player_by_peer_id(dead_peer_id)
	if dead_player and is_instance_valid(dead_player) and ("now_hp" in dead_player):
		dead_player.now_hp = 0
		# 服务器侧也要禁用武器（否则可能继续自动攻击/残留逻辑）
		if dead_player.has_method("disable_weapons"):
			dead_player.disable_weapons()
	
	# 掉落玩家身上的所有 gold（只执行一次，使用客户端发送的 gold 数量）
	if not _death_drop_processed.has(dead_peer_id):
		_death_drop_processed[dead_peer_id] = true
		_drop_player_gold(dead_peer_id, death_position, client_gold)
	else:
		print("[NetworkPlayerManager] 玩家 %d 已处理过死亡掉落，跳过" % dead_peer_id)
	
	# 生成墓碑（显示死亡位置）
	spawn_grave_for_player(dead_peer_id, death_position)
	
	# 服务器：检查是否满足 Boss 胜利条件
	_server_try_end_match("player_death")


## 服务器：玩家死亡时生成墓碑（没有钥匙时）
func spawn_grave_for_player(peer_id: int, death_position: Vector2) -> void:
	if not NetworkManager.is_server():
		return
	
	var player = get_player_by_peer_id(peer_id)
	if not player:
		print("[NetworkPlayerManager] spawn_grave_for_player: 找不到玩家 peer_id=%d" % peer_id)
		return
	
	# 检查是否已有墓碑
	if _online_graves.has(peer_id):
		print("[NetworkPlayerManager] 玩家 %d 已有墓碑，跳过" % peer_id)
		return
	
	var display_name = player.display_name if player.display_name != "" else "Player %d" % peer_id
	var role_id = player.player_role_id if "player_role_id" in player else ""
	
	print("[NetworkPlayerManager] 生成墓碑: peer_id=%d, name=%s, role=%s, pos=%s" % [peer_id, display_name, role_id, str(death_position)])
	
	# 服务器本地生成墓碑
	_create_grave_local(peer_id, death_position, display_name, role_id)
	
	# 广播给所有客户端
	rpc("rpc_spawn_grave", peer_id, death_position, display_name, role_id)
	
	# Boss 墓碑：启动自动复活计时器
	if role_id == ROLE_BOSS:
		_start_boss_auto_revive_timer(peer_id)


## 所有客户端：生成墓碑
@rpc("authority", "call_local", "reliable")
func rpc_spawn_grave(peer_id: int, position: Vector2, display_name: String, role_id: String = "") -> void:
	# 服务器已经在 spawn_grave_for_player 中创建了
	if NetworkManager.is_server():
		return
	
	_create_grave_local(peer_id, position, display_name, role_id)


## 本地创建墓碑
func _create_grave_local(peer_id: int, position: Vector2, display_name: String, role_id: String = "") -> void:
	# 检查是否已有墓碑
	if _online_graves.has(peer_id) and is_instance_valid(_online_graves[peer_id]):
		print("[NetworkPlayerManager] 墓碑已存在: peer_id=%d" % peer_id)
		return
	
	var grave = _grave_online_scene.instantiate()
	grave.global_position = position
	
	# 获取父节点（Players 节点或场景根节点）
	var parent = _get_players_parent()
	if not parent:
		parent = get_tree().root
	parent.add_child(grave)
	
	# 设置墓碑数据（包含角色类型）
	grave.setup(peer_id, display_name, role_id)
	
	# 记录墓碑
	_online_graves[peer_id] = grave
	
	print("[NetworkPlayerManager] 墓碑创建完成: peer_id=%d, pos=%s" % [peer_id, str(position)])


## 服务器：执行复活
func _revive_player_from_grave(peer_id: int) -> void:
	var player = get_player_by_peer_id(peer_id)
	if not player:
		return
	
	# 计算满血量
	var full_hp := _get_player_full_hp(player)
	# 修复：服务器端立即同步 now_hp，避免短时间内仍被视为死亡（影响拾取等逻辑）
	if "now_hp" in player:
		player.now_hp = full_hp
	
	print("[NetworkPlayerManager] 复活玩家: peer_id=%d, hp=%d" % [peer_id, full_hp])
	
	# 通知客户端执行复活
	rpc_id(peer_id, "rpc_execute_grave_revive", full_hp)
	
	# 广播给其他客户端显示复活特效
	for client_peer_id in multiplayer.get_peers():
		if client_peer_id != peer_id:
			if player.has_method("rpc_show_revive_effect"):
				player.rpc_id(client_peer_id, "rpc_show_revive_effect", peer_id)
	
	# 移除墓碑
	remove_grave_for_player(peer_id)
	_force_pickup_overlapping_drops.call_deferred(peer_id)


## 客户端：执行墓碑复活
@rpc("authority", "call_remote", "reliable")
func rpc_execute_grave_revive(full_hp: int) -> void:
	if not local_player:
		return
	if is_match_frozen():
		return
	
	print("[NetworkPlayerManager] 客户端执行墓碑复活: hp=%d" % full_hp)
	
	# 调用玩家的复活方法
	if local_player.has_method("rpc_revive"):
		local_player.rpc_revive(full_hp)


## 服务器：移除玩家的墓碑
func remove_grave_for_player(peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	print("[NetworkPlayerManager] 移除墓碑: peer_id=%d" % peer_id)
	
	# 清除死亡掉落标记，允许下次死亡再掉落
	_death_drop_processed.erase(peer_id)
	
	# 本地移除
	_remove_grave_local(peer_id)
	
	# 广播给所有客户端
	rpc("rpc_remove_grave", peer_id)


## 所有客户端：移除墓碑
@rpc("authority", "call_local", "reliable")
func rpc_remove_grave(peer_id: int) -> void:
	# 服务器已经在 remove_grave_for_player 中移除了
	if NetworkManager.is_server():
		return
	
	_remove_grave_local(peer_id)


## 本地移除墓碑
func _remove_grave_local(peer_id: int) -> void:
	if _online_graves.has(peer_id):
		var grave = _online_graves[peer_id]
		if is_instance_valid(grave):
			grave.cleanup()
		_online_graves.erase(peer_id)
		print("[NetworkPlayerManager] 墓碑已移除: peer_id=%d" % peer_id)


## 清理所有墓碑
func clear_all_graves() -> void:
	for peer_id in _online_graves.keys():
		var grave = _online_graves[peer_id]
		if is_instance_valid(grave):
			grave.cleanup()
	_online_graves.clear()
	print("[NetworkPlayerManager] 所有墓碑已清理")


## ==================== 墓碑救援系统 ====================

## 服务器：广播开始救援（只发一次，客户端根据剩余时间自己计算进度）
## remaining_time_ms: 剩余救援时间（毫秒），确保所有客户端进度同步
func broadcast_grave_rescue_start(grave_peer_id: int, remaining_time_ms: int) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_grave_rescue_start", grave_peer_id, remaining_time_ms)


## 所有客户端：开始救援显示（之后客户端根据剩余时间自己计算进度）
@rpc("authority", "call_local", "reliable")
func rpc_grave_rescue_start(grave_peer_id: int, remaining_time_ms: int) -> void:
	if is_match_frozen():
		return
	if _online_graves.has(grave_peer_id) and is_instance_valid(_online_graves[grave_peer_id]):
		_online_graves[grave_peer_id].start_rescue_display(remaining_time_ms)


## 服务器：广播停止救援（玩家离开范围时）
func broadcast_grave_rescue_stop(grave_peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_grave_rescue_stop", grave_peer_id)


## 所有客户端：停止救援显示
@rpc("authority", "call_local", "reliable")
func rpc_grave_rescue_stop(grave_peer_id: int) -> void:
	if is_match_frozen():
		return
	if _online_graves.has(grave_peer_id) and is_instance_valid(_online_graves[grave_peer_id]):
		_online_graves[grave_peer_id].stop_rescue_display()


## 服务器：处理墓碑救援完成
func handle_grave_rescue(dead_peer_id: int, rescuer_peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	if is_match_frozen():
		return
	
	var dead_player = get_player_by_peer_id(dead_peer_id)
	var rescuer = get_player_by_peer_id(rescuer_peer_id)
	
	if not dead_player or not rescuer:
		print("[NetworkPlayerManager] 救援失败: 找不到玩家 dead=%d, rescuer=%d" % [dead_peer_id, rescuer_peer_id])
		return
	
	# 检查救援者的生命钥匙（从 MultiplayerSynchronizer 同步的值）
	if rescuer.master_key < RESCUE_COST_MASTER_KEY:
		print("[NetworkPlayerManager] 救援失败: 救援者生命钥匙不足 rescuer=%d (需要 %d, 拥有 %d)" % [rescuer_peer_id, RESCUE_COST_MASTER_KEY, rescuer.master_key])
		# 广播停止救援显示
		broadcast_grave_rescue_stop(dead_peer_id)
		return
	
	print("[NetworkPlayerManager] 执行墓碑救援: dead=%d, rescuer=%d" % [dead_peer_id, rescuer_peer_id])
	
	# 通知客户端扣除 master_key，由客户端修改后通过 MultiplayerSynchronizer 同步
	if RESCUE_COST_MASTER_KEY > 0:
		if rescuer.has_method("rpc_add_resource"):
			rescuer.rpc_id(rescuer_peer_id, "rpc_add_resource", "master_key", -RESCUE_COST_MASTER_KEY)
			print("[NetworkPlayerManager] 通知客户端扣除 master_key (救援): peer_id=%d, cost=%d" % [rescuer_peer_id, RESCUE_COST_MASTER_KEY])
	
	# 执行复活
	_server_revive_player(dead_peer_id)
	
	# 显示救援成功提示给救援者
	rpc_id(rescuer_peer_id, "rpc_show_rescue_success", dead_player.display_name)
	
	print("[NetworkPlayerManager] 墓碑救援成功: dead=%d 被 rescuer=%d 救援，消耗 %d 生命钥匙" % [dead_peer_id, rescuer_peer_id, RESCUE_COST_MASTER_KEY])


## 客户端：显示救援成功提示
@rpc("authority", "call_remote", "reliable")
func rpc_show_rescue_success(rescued_player_name: String) -> void:
	if is_match_frozen():
		return
	# 显示浮动文字
	if local_player and is_instance_valid(local_player):
		FloatingText.create_floating_text(
			local_player.global_position + Vector2(0, -60),
			"救援 %s 成功!" % rescued_player_name,
			Color(0.3, 1.0, 0.3),
			true
		)
		print("[NetworkPlayerManager] 救援成功: %s" % rescued_player_name)


## ==================== Boss 自动复活相关 ====================

## Boss 自动复活时间（秒）
const BOSS_AUTO_REVIVE_TIME: float = 15.0

## 服务器：启动 Boss 自动复活计时器
func _start_boss_auto_revive_timer(peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	var grave = _online_graves.get(peer_id)
	if not grave or not is_instance_valid(grave):
		print("[NetworkPlayerManager] _start_boss_auto_revive_timer: 找不到墓碑 peer_id=%d" % peer_id)
		return
	
	# 调用墓碑的自动复活计时器（墓碑会通过 broadcast_boss_auto_revive_start 广播）
	grave.start_boss_auto_revive_timer()
	
	print("[NetworkPlayerManager] Boss 自动复活计时器已启动 | peer_id=%d, %.1f秒后自动复活" % [peer_id, BOSS_AUTO_REVIVE_TIME])


## 服务器：广播 Boss 自动复活开始
func broadcast_boss_auto_revive_start(grave_peer_id: int, remaining_time_ms: int) -> void:
	if not NetworkManager.is_server():
		return
	
	rpc("rpc_boss_auto_revive_start", grave_peer_id, remaining_time_ms)


## 所有客户端：Boss 自动复活开始
@rpc("authority", "call_local", "reliable")
func rpc_boss_auto_revive_start(grave_peer_id: int, remaining_time_ms: int) -> void:
	# 服务器已在 start_boss_auto_revive_timer 中处理
	if NetworkManager.is_server():
		return
	
	var grave = _online_graves.get(grave_peer_id)
	if grave and is_instance_valid(grave):
		grave.start_boss_auto_revive_display(remaining_time_ms)
		print("[NetworkPlayerManager] 客户端收到 Boss 自动复活开始 | peer_id=%d, remaining_ms=%d" % [grave_peer_id, remaining_time_ms])


## 服务器：Boss 自动复活（不消耗钥匙）
func _server_revive_player_auto(peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	
	var player = get_player_by_peer_id(peer_id)
	if not player or not is_instance_valid(player):
		print("[NetworkPlayerManager] _server_revive_player_auto: 找不到玩家 peer_id=%d" % peer_id)
		return
	
	# 检查是否还有墓碑（可能玩家已经用钥匙复活了）
	if not _online_graves.has(peer_id):
		print("[NetworkPlayerManager] _server_revive_player_auto: 玩家 %d 已复活或墓碑不存在" % peer_id)
		return
	
	print("[NetworkPlayerManager] Boss 自动复活 | peer_id=%d" % peer_id)
	
	# 恢复满血（HP 可能由属性系统计算得出：base_stats -> final_stats）
	var full_hp := _get_player_full_hp(player)
	# 修复：服务器端立即同步 now_hp，避免短时间内仍被视为死亡（影响拾取等逻辑）
	if "now_hp" in player:
		player.now_hp = full_hp
	
	# 通知客户端执行复活
	player.rpc_id(peer_id, "rpc_revive", full_hp)
	
	# 广播给所有其他客户端，让他们也看到复活效果
	for client_peer_id in multiplayer.get_peers():
		if client_peer_id != peer_id:
			if player.has_method("rpc_show_revive_effect"):
				player.rpc_id(client_peer_id, "rpc_show_revive_effect", peer_id)
	
	# 移除墓碑
	remove_grave_for_player(peer_id)
	_force_pickup_overlapping_drops.call_deferred(peer_id)
	
	# 延迟一帧后重新检查所有武器的攻击目标（等待 now_hp 同步完成）
	_recheck_weapons_for_revived_player.call_deferred(player)
	
	# 通知 Boss 复活成功
	rpc_id(peer_id, "rpc_revive_result", true, "自动复活成功")


## ==================== 联网结算（服务器权威） ====================

func is_match_frozen() -> bool:
	return _online_match_ended or _match_frozen


func _reset_online_match_state() -> void:
	_online_match_ended = false
	_match_end_scheduled = false
	_pending_match_end_result = ""
	_pending_match_end_detail = ""
	# 本地解冻，同时恢复 WaveSystemOnline 的 match_ended
	rpc_set_match_frozen(false)
	_stop_match_watchdog()


func _start_match_watchdog() -> void:
	if not NetworkManager.is_server():
		return
	if GameMain.current_mode_id != "online":
		return
	if _online_match_ended:
		return
	if _match_watchdog and is_instance_valid(_match_watchdog):
		# 已在运行
		return
	_match_watchdog = Timer.new()
	_match_watchdog.name = "MatchWatchdog"
	_match_watchdog.one_shot = false
	_match_watchdog.wait_time = _MATCH_WATCHDOG_INTERVAL_SECONDS
	# 不依赖暂停状态（即使未来又改回 paused 也能跑）
	_match_watchdog.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_match_watchdog)
	_match_watchdog.timeout.connect(_on_match_watchdog_timeout)
	_match_watchdog.start()


func _stop_match_watchdog() -> void:
	if _match_watchdog and is_instance_valid(_match_watchdog):
		_match_watchdog.stop()
		_match_watchdog.queue_free()
	_match_watchdog = null


func _on_match_watchdog_timeout() -> void:
	if not NetworkManager.is_server():
		_stop_match_watchdog()
		return
	if GameMain.current_mode_id != "online":
		_stop_match_watchdog()
		return
	if _online_match_ended:
		_stop_match_watchdog()
		return
	
	var ws := _get_wave_system_online()
	if ws == null:
		return

	# 游戏未开始（尚未进入第1波）时，不允许触发任何结算
	if "current_wave" in ws and int(ws.current_wave) <= 0:
		return
	
	# 商店打开时跳过（此阶段不希望触发结算判定）
	if "current_state" in ws and int(ws.current_state) == int(WaveSystemOnline.WaveState.SHOP_OPEN):
		return
	
	# 保底：统一从一个入口做判定与结算（避免分散逻辑）
	if _server_try_end_match("watchdog"):
		_stop_match_watchdog()


## 服务器：绑定波次系统信号（通关 -> 玩家胜利）
func _server_setup_match_end_hooks() -> void:
	if not NetworkManager.is_server():
		return
	if GameMain.current_mode_id != "online":
		return
	
	var attempts := 0
	while attempts < 40:
		await get_tree().create_timer(0.25).timeout
		var ws = get_tree().get_first_node_in_group("wave_manager")
		# 在线模式 now_enemies_online 会把 WaveSystemOnline 加进 wave_manager 组
		if ws and is_instance_valid(ws) and ws is WaveSystemOnline:
			if ws.has_signal("all_waves_completed"):
				if not ws.all_waves_completed.is_connected(_on_all_waves_completed):
					ws.all_waves_completed.connect(_on_all_waves_completed)
			print("[NetworkPlayerManager] 已连接在线波次 all_waves_completed")
			return
		attempts += 1
	
	push_warning("[NetworkPlayerManager] 未找到 WaveSystemOnline，无法绑定结算信号")


func _on_all_waves_completed() -> void:
	if not NetworkManager.is_server():
		return
	# 统一走结算入口：避免重复维护 players/impostor/boss 的判定与 guard
	_server_try_end_match("all_waves_completed")


func _get_wave_system_online() -> WaveSystemOnline:
	var ws = get_tree().get_first_node_in_group("wave_manager")
	if ws and is_instance_valid(ws) and ws is WaveSystemOnline:
		return ws as WaveSystemOnline
	return null


func _get_total_waves(ws: WaveSystemOnline) -> int:
	if ws == null:
		return 0
	# 优先使用 WaveSystemOnline.total_waves getter（已统一）
	if "total_waves" in ws:
		return int(ws.total_waves)
	# 兜底：兼容旧实现/异常情况下直接从配置数推断
	if "wave_configs" in ws and ws.wave_configs is Array:
		return int((ws.wave_configs as Array).size())
	return 0


## 服务器：检查 Player 胜利条件
func _server_check_player_win(ws: WaveSystemOnline) -> bool:
	# 保底：只要到了最后一波，并且“所有怪都清空且 phase 已完成”或已进入 WAVE_COMPLETE/IDLE，就认为通关
	if ws == null:
		return false
	var total_waves := _get_total_waves(ws)
	if total_waves <= 0:
		return false
	if int(ws.current_wave) < total_waves:
		return false
	
	var state := int(ws.current_state) if ("current_state" in ws) else -1
	# 0..4 对应 WaveState enum（IDLE/SPAWNING/FIGHTING/WAVE_COMPLETE/SHOP_OPEN）
	if state == int(WaveSystemOnline.WaveState.WAVE_COMPLETE):
		return true
	if state == int(WaveSystemOnline.WaveState.IDLE):
		# 可能是 all_waves_completed 后回到 IDLE
		return true
	
	# 还在战斗/生成中：如果 phase 已完成并且当前存活敌人为空，则视为已完成
	var phases_done := bool(ws.all_phases_complete) if ("all_phases_complete" in ws) else false
	var enemies_empty := false
	if "active_enemies" in ws and ws.active_enemies is Array:
		enemies_empty = (ws.active_enemies as Array).is_empty()
	if phases_done and enemies_empty:
		return true
	
	return false


## 服务器：通关后决出胜者的阵营（返回获胜的 role_id）
## 规则：通关所有波次后，如果 impostor 已叛变 && impostor 活着 && 没有任何 player 活着，则 impostor 获胜。
## 注意：即使 player 有足够钥匙可复活但没有选择复活，也按“当下状态”判定为内鬼胜利（只看 now_hp）。
func _server_resolve_clear_waves_winner_role(ws: WaveSystemOnline) -> String:
	# 默认：玩家阵营胜利
	if ws == null:
		return ROLE_PLAYER
	# 内鬼未叛变时仍属于“玩家阵营”
	if not impostor_betrayed or impostor_peer_id <= 0:
		return ROLE_PLAYER
	
	var impostor = get_player_by_peer_id(impostor_peer_id)
	if not impostor or not is_instance_valid(impostor):
		return ROLE_PLAYER
	if not (("player_role_id" in impostor) and str(impostor.player_role_id) == ROLE_IMPOSTOR):
		return ROLE_PLAYER
	var impostor_alive := (("now_hp" in impostor) and int(impostor.now_hp) > 0)
	if not impostor_alive:
		return ROLE_PLAYER
	
	# 当前是否还有任意 player 存活（只看当下 hp）
	for pid in players.keys():
		var p = players[pid]
		if not p or not is_instance_valid(p):
			continue
		if ("player_role_id" in p) and str(p.player_role_id) == ROLE_PLAYER:
			var hp := int(p.now_hp) if ("now_hp" in p) else 0
			if hp > 0:
				return ROLE_PLAYER
	
	return ROLE_IMPOSTOR


## 服务器：检查 Boss 胜利条件
func _server_check_boss_win(ws: WaveSystemOnline) -> bool:
	if ws == null:
		return false
	
	# 只有在“通关之前”才允许 Boss 胜利
	var tw := _get_total_waves(ws)
	# 注意：current_wave == total_waves 可能仍处于“最后一波进行中”，此时 Boss 胜利应当仍然可能触发。
	# 因此这里只在 current_wave > total_waves（理论上不应发生）时才认为已越界完成。
	if tw > 0 and ws.current_wave > tw:
		return false
	
	# 统计：是否还有任意非 Boss 玩家存活 / 或者有能力复活
	var any_alive := false
	var any_can_revive := false
	var non_boss_count := 0
	
	for pid in players.keys():
		var p = players[pid]
		if not p or not is_instance_valid(p):
			continue
		# 排除 Boss
		if "player_role_id" in p and str(p.player_role_id) == ROLE_BOSS:
			continue
		
		non_boss_count += 1
		var hp := int(p.now_hp) if "now_hp" in p else 0
		if hp > 0:
			any_alive = true
			break
		
		var mk := int(p.master_key) if "master_key" in p else 0
		if mk >= REVIVE_COST_MASTER_KEY:
			any_can_revive = true
	
	# 没有任何非 Boss 玩家时，不触发结算（例如玩家全断线/未正常生成）
	if non_boss_count <= 0:
		return false
	
	return (not any_alive) and (not any_can_revive)


## 服务器：统一检查并触发结算（保持 Player/Boss 判定风格一致）
func _server_try_end_match(trigger: String = "") -> bool:
	if _online_match_ended:
		return false
	if not NetworkManager.is_server():
		return false
	if GameMain.current_mode_id != "online":
		return false
	# 冻结后不重复判定，避免二次结算/重复 RPC
	if is_match_frozen():
		return false
	
	var ws := _get_wave_system_online()
	if ws == null:
		return false
	
	# 游戏未开始（尚未进入第1波）时，不允许触发任何结算
	if "current_wave" in ws and int(ws.current_wave) <= 0:
		return false
	
	# 商店打开时跳过（此阶段不希望触发结算判定）
	if "current_state" in ws and int(ws.current_state) == int(WaveSystemOnline.WaveState.SHOP_OPEN):
		return false
	
	if _server_check_boss_win(ws):
		_server_end_match("boss_win", "Boss 击败了所有玩家，且无人拥有足够生命钥匙复活。")
		return true
	
	if _server_check_player_win(ws):
		var winner_role := _server_resolve_clear_waves_winner_role(ws)
		if winner_role == ROLE_IMPOSTOR:
			_server_end_match("impostor_win", "通关后内鬼仍存活，且所有玩家均已死亡。")
		else:
			_server_end_match("players_win", "成功通关所有波次！")
		return true
	
	return false


func _server_end_match(result: String, detail: String) -> void:
	if _online_match_ended:
		return
	_online_match_ended = true
	print("[NetworkPlayerManager] 结算触发: %s | %s" % [result, detail])
	# 进入结算立刻清理 watchdog，避免重复进入结算/重复检查
	_stop_match_watchdog()
	_server_freeze_match_end()
	_pending_match_end_result = result
	_pending_match_end_detail = detail
	if not _match_end_scheduled:
		_match_end_scheduled = true
		_server_broadcast_match_end_after_delay.call_deferred()


func _server_freeze_match_end() -> void:
	if not NetworkManager.is_server():
		return
	if _match_frozen:
		return
	_match_frozen = true
	# 立刻冻结（包含服务器自己）
	for client_peer_id in multiplayer.get_peers():
		rpc_id(client_peer_id, "rpc_set_match_frozen", true)
	rpc_set_match_frozen(true)


func _server_broadcast_match_end_after_delay() -> void:
	if not NetworkManager.is_server():
		return
	# 和波次结束打开商店一致：给一点缓冲时间，让节奏更舒服
	await get_tree().create_timer(_MATCH_END_DELAY_SECONDS, true).timeout
	# 广播到所有客户端（以及服务器自己）
	for client_peer_id in multiplayer.get_peers():
		rpc_id(client_peer_id, "rpc_show_online_result", _pending_match_end_result, _pending_match_end_detail)
	# 服务器本地也展示
	rpc_show_online_result(_pending_match_end_result, _pending_match_end_detail)


@rpc("authority", "call_local", "reliable")
func rpc_show_online_result(result: String, detail: String) -> void:
	# 隐藏商店（不要调用 close_shop，避免触发 shop_closed 推进波次）
	var shop = get_tree().get_first_node_in_group("upgrade_shop")
	if shop and is_instance_valid(shop):
		shop.visible = false
		shop.process_mode = Node.PROCESS_MODE_DISABLED
	
	# 结算时不暂停：允许玩家移动/观察，只是冻结伤害与拾取等玩法逻辑
	get_tree().paused = false
	
	# 创建/显示结算 UI
	var existing = get_tree().get_first_node_in_group("victory_ui_online")
	var ui: VictoryUIOnline = null
	if existing and existing is VictoryUIOnline:
		ui = existing as VictoryUIOnline
	else:
		ui = VICTORY_UI_ONLINE_SCENE.instantiate()
		ui.add_to_group("victory_ui_online")
		get_tree().root.add_child(ui)
	
	ui.show_result(result, detail)


@rpc("authority", "call_local", "reliable")
func rpc_set_match_frozen(frozen: bool) -> void:
	_match_frozen = frozen
	var shop = get_tree().get_first_node_in_group("upgrade_shop")
	if shop and is_instance_valid(shop):
		if frozen:
			shop.visible = false
			shop.process_mode = Node.PROCESS_MODE_DISABLED
		else:
			# 解冻：恢复正常处理（保持隐藏，等 WaveSystemOnline 打开时再显示）
			shop.visible = false
			shop.process_mode = Node.PROCESS_MODE_INHERIT
	
	# 同步 WaveSystemOnline 的结算冻结标记
	var ws = get_tree().get_first_node_in_group("wave_manager")
	if ws and is_instance_valid(ws) and ws.has_method("set_match_ended"):
		ws.call("set_match_ended", frozen)
	
	if frozen:
		# 隐藏商店并禁用输入（玩法冻结）
		# 不暂停：允许移动/观察；冻结通过各逻辑入口的 is_match_frozen() 早退实现
		get_tree().paused = false
	else:
		get_tree().paused = false
