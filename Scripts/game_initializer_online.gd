extends Node2D

## 在线游戏初始化器
## 负责等待玩家加入、倒计时和开始游戏

const MAX_PLAYERS := 4
const COUNTDOWN_SECONDS := 5  # 房间倒计时
const ROLE_INTRO_SECONDS := 10  # 角色介绍倒计时

var room_ui: RoomUIOnline = null
var role_ui: RoleUIOnline = null
var is_game_started: bool = false
var is_counting_down: bool = false
var is_role_intro: bool = false  # 是否正在显示角色介绍
var connected_players: Array = []
var player: PlayerCharacter = null

var _multiplayer_spawner: MultiplayerSpawner = null

func _ready() -> void:
	await get_tree().process_frame
	
	print("[GameInitializerOnline] 初始化开始, is_server=%s" % str(NetworkManager.is_server()))
	
	# 查找并连接 MultiplayerSpawner
	_setup_multiplayer_spawner()
	
	# 创建等待UI
	_create_room_ui()
	
	# 初始化网络玩家管理器
	NetworkPlayerManager.init_online_mode()
	
	# 服务器开始玩家检查循环
	if NetworkManager.is_server():
		_start_player_check_loop()


## 设置 MultiplayerSpawner
func _setup_multiplayer_spawner() -> void:
	_multiplayer_spawner = get_tree().get_first_node_in_group("multiplayer_spawner")
	if not _multiplayer_spawner:
		var scene_root = get_tree().current_scene
		if scene_root:
			_multiplayer_spawner = scene_root.get_node_or_null("MultiplayerSpawner")
	
	if _multiplayer_spawner:
		print("[GameInitializerOnline] 找到 MultiplayerSpawner")
		if _multiplayer_spawner.has_signal("spawned"):
			_multiplayer_spawner.spawned.connect(_on_player_spawned)
	else:
		push_warning("[GameInitializerOnline] 未找到 MultiplayerSpawner")


## MultiplayerSpawner 回调
func _on_player_spawned(node: Node) -> void:
	NetworkPlayerManager.on_player_spawned(node)


## ==================== 房间UI ====================

func _create_room_ui() -> void:
	var scene = load("res://scenes/UI/room_ui_online.tscn")
	if not scene:
		push_error("[GameInitializerOnline] 无法加载等待UI")
		return
	
	room_ui = scene.instantiate()
	room_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(room_ui)
	
	if room_ui:
		room_ui.force_start_requested.connect(_on_force_start)
	
	print("[GameInitializerOnline] 等待UI已创建")


func _update_room_ui(count: int) -> void:
	if not room_ui:
		return
	
	if room_ui.status_label:
		room_ui.status_label.text = "游戏即将开始..." if is_counting_down else "%d/%d 玩家" % [count, MAX_PLAYERS]
	
	if room_ui.player_list:
		for child in room_ui.player_list.get_children():
			child.queue_free()
		for p in connected_players:
			var label = Label.new()
			label.text = "🎮 " + str(p.display_name)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label.add_theme_font_size_override("font_size", 24)
			room_ui.player_list.add_child(label)


func _update_countdown_ui(seconds: int) -> void:
	if not room_ui:
		return
	
	if room_ui.title_label:
		room_ui.title_label.text = "游戏将在 %d 秒后开始!" % seconds
	
	if room_ui.status_label:
		room_ui.status_label.text = "准备好了吗？"


## ==================== 玩家检查 ====================

func _start_player_check_loop() -> void:
	while not is_game_started:
		await get_tree().create_timer(0.5).timeout
		if is_game_started:
			break
		_check_player_count()


func _check_player_count() -> void:
	var count = NetworkPlayerManager.players.size()
	
	# 更新玩家列表
	connected_players.clear()
	for peer_id in NetworkPlayerManager.players.keys():
		var p = NetworkPlayerManager.players[peer_id]
		if p and is_instance_valid(p):
			connected_players.append({
				"peer_id": peer_id,
				"display_name": p.display_name if p.display_name != "" else "Player %d" % peer_id
			})
	
	_update_room_ui(count)
	
	# 广播到客户端
	if NetworkManager.is_server():
		var data = []
		for p in connected_players:
			data.append({"peer_id": p.peer_id, "display_name": p.display_name})
		rpc("rpc_update_player_list", data)
	
	# 满员开始倒计时
	if count >= MAX_PLAYERS and not is_counting_down:
		_start_countdown()


@rpc("authority", "call_local", "reliable")
func rpc_update_player_list(data: Array) -> void:
	connected_players.clear()
	for p in data:
		connected_players.append(p)
	_update_room_ui(connected_players.size())


## ==================== 倒计时 ====================

func _start_countdown() -> void:
	if is_counting_down:
		return
	
	is_counting_down = true
	print("[GameInitializerOnline] 开始倒计时")
	
	if NetworkManager.is_server():
		rpc("rpc_start_countdown")
	
	_run_countdown()


func _on_force_start() -> void:
	if NetworkManager.is_server() and not is_game_started:
		if NetworkPlayerManager.players.size() > 0:
			_start_countdown()


@rpc("authority", "call_local", "reliable")
func rpc_start_countdown() -> void:
	if not is_counting_down:
		is_counting_down = true
		_run_countdown()


func _run_countdown() -> void:
	for i in range(COUNTDOWN_SECONDS, 0, -1):
		if not is_counting_down:
			return
		
		_update_countdown_ui(i)
		
		if NetworkManager.is_server():
			rpc("rpc_update_countdown", i)
		
		await get_tree().create_timer(1.0).timeout
	
	_prestart_game()


@rpc("authority", "call_local", "reliable")
func rpc_update_countdown(seconds: int) -> void:
	_update_countdown_ui(seconds)


## ==================== 游戏预开始（分配身份 + 角色介绍） ====================

func _prestart_game() -> void:
	if is_game_started:
		return
	
	is_game_started = true
	print("[GameInitializerOnline] 等待室倒计时结束，准备分配身份")
	
	if room_ui:
		room_ui.queue_free()
		room_ui = null
	
	if NetworkManager.is_server():
		# 为所有玩家分配身份（skin 和 class）
		NetworkPlayerManager.assign_player_identities()
		
		# 等待一帧让身份同步完成
		await get_tree().process_frame
		
		# 通知所有客户端显示角色介绍
		rpc("rpc_show_role_intro")
		
		# 服务器开始角色介绍倒计时
		_start_role_intro_countdown()


@rpc("authority", "call_local", "reliable")
func rpc_start_game() -> void:
	if room_ui:
		room_ui.queue_free()
		room_ui = null


## ==================== 角色介绍 ====================

func _create_role_ui() -> void:
	var scene = load("res://scenes/UI/role_ui_online.tscn")
	if not scene:
		push_error("[GameInitializerOnline] 无法加载角色介绍 UI")
		return
	
	role_ui = scene.instantiate()
	role_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(role_ui)
	
	print("[GameInitializerOnline] 角色介绍 UI 已创建")


@rpc("authority", "call_local", "reliable")
func rpc_show_role_intro() -> void:
	print("[GameInitializerOnline] 显示角色介绍")
	is_role_intro = true
	
	# 创建角色介绍 UI
	_create_role_ui()
	
	# 获取本地玩家信息
	var local_player = NetworkPlayerManager.local_player
	if local_player:
		var role_id = local_player.player_role_id if local_player.player_role_id else "player"
		var sprite_frames = local_player.playerAni.sprite_frames if local_player.playerAni else null
		
		if role_ui:
			role_ui.show_role_intro(role_id, sprite_frames)
	else:
		push_warning("[GameInitializerOnline] 本地玩家未找到")


func _start_role_intro_countdown() -> void:
	print("[GameInitializerOnline] 开始角色介绍倒计时")
	
	for i in range(ROLE_INTRO_SECONDS, 0, -1):
		if not is_role_intro:
			return
		
		# 广播倒计时给所有客户端
		rpc("rpc_update_role_intro_countdown", i)
		
		await get_tree().create_timer(1.0).timeout
	
	# 倒计时结束，开始游戏
	rpc("rpc_role_intro_finished")
	_start_game()


@rpc("authority", "call_local", "reliable")
func rpc_update_role_intro_countdown(seconds: int) -> void:
	if role_ui:
		role_ui.update_countdown(seconds)


@rpc("authority", "call_local", "reliable")
func rpc_role_intro_finished() -> void:
	print("[GameInitializerOnline] 角色介绍结束")
	is_role_intro = false
	
	if role_ui:
		role_ui.force_close()
		role_ui.queue_free()
		role_ui = null
	
	# 非服务器端开始游戏
	if not NetworkManager.is_server():
		_start_game()


## ==================== 游戏开始 ====================

func _start_game() -> void:
	print("[GameInitializerOnline] 游戏开始！")
	
	if NetworkPlayerManager.local_player:
		player = NetworkPlayerManager.local_player
		# 启用本地玩家的移动
		player.canMove = true
		player.stop = false
		print("[GameInitializerOnline] 玩家移动已启用: %s" % player.display_name)
	
	if NetworkManager.is_server():
		var now_enemies = get_tree().get_first_node_in_group("enemy_spawner")
		var wave_system = now_enemies.get_wave_manager()
		if wave_system:
			print("[GameInitializerOnline] 启动波次系统")
			await get_tree().create_timer(2.0).timeout
			# DEBUG: 开始刷怪
			wave_system.start_game()
