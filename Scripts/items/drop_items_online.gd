extends Area2D
class_name DropItemOnline

## 联网模式掉落物品
## 架构：
## - 服务器负责：生成、判断拾取、奖励资源、通知删除
## - 客户端负责：显示、动画、移动效果
## - 所有玩家（player, boss, impostor）都可以拾取

## ==================== 配置 ====================
var speed: float = 600.0  # 移动速度
var pickup_distance: float = 30.0  # 拾取距离

## ==================== 状态 ====================
var is_moving: bool = false  # 是否正在移动向玩家
var is_collected: bool = false  # 是否已被拾取
var target_player: Node2D = null  # 目标玩家（最近的玩家）

## ==================== 掉落物品属性 ====================
var drop_id: int = -1  # 唯一标识
var item_type: String = "gold"  # 物品类型：gold, masterkey
var source_peer_id: int = 0  # 掉落物来源玩家（0 表示无来源限制，如怪物掉落）

## ==================== 静态计数器 ====================
static var _next_id: int = 0


func _ready() -> void:
	# 初始隐藏
	hide()
	set_collision_layer_value(5, false)
	
	# 读取 meta 数据
	if has_meta("drop_id_override"):
		drop_id = int(get_meta("drop_id_override"))
		remove_meta("drop_id_override")
	else:
		drop_id = _next_id
		_next_id += 1
	
	if has_meta("item_type"):
		item_type = get_meta("item_type")
	
	if has_meta("source_peer_id"):
		source_peer_id = int(get_meta("source_peer_id"))
		remove_meta("source_peer_id")
	
	# 设置节点名和 meta
	name = "drop_item_%d" % drop_id
	set_meta("drop_id", drop_id)
	add_to_group("network_drop")
	
	if source_peer_id > 0:
		print("[DropItemOnline] _ready drop_id=%d, type=%s, source_peer=%d, pos=%s" % [drop_id, item_type, source_peer_id, global_position])
	else:
		print("[DropItemOnline] _ready drop_id=%d, type=%s, pos=%s" % [drop_id, item_type, global_position])


## 检查玩家是否可以拾取物品
func _can_player_pickup(player: Node2D) -> bool:
	if not player or not is_instance_valid(player):
		return false
	
	# ===== 原本逻辑（server 权威）：死亡玩家不能拾取（客户端只负责展示） =====
	# 1) 服务器端：使用 _death_drop_processed 作为权威死亡判定（避免 now_hp 同步滞后）。
	if NetworkManager.is_server() and ("peer_id" in player):
		var pid := int(player.peer_id)
		if NetworkPlayerManager and ("_death_drop_processed" in NetworkPlayerManager) and NetworkPlayerManager._death_drop_processed.has(pid):
			return false
	
	# 2) 兜底：now_hp<=0 视为死亡（客户端/服务器通用）
	if "now_hp" in player and player.now_hp <= 0:
		return false
	
	return true


## 查找最近的可以拾取的玩家
func _find_nearest_player() -> Node2D:
	var players = NetworkPlayerManager.players
	if players.is_empty():
		print("[DropItemOnline] 警告: players 字典为空!")
		return null
	
	var nearest: Node2D = null
	var nearest_dist: float = INF
	
	# 调试：打印所有玩家信息（仅服务器，每秒一次）
	if NetworkManager.is_server() and Engine.get_frames_drawn() % 60 == 0:
		print("[DropItemOnline] 服务器 players 字典: %d 个玩家" % players.size())
		for pid in players.keys():
			var p = players[pid]
			if p and is_instance_valid(p):
				var role = p.player_role_id if "player_role_id" in p else "unknown"
				var can_pickup = _can_player_pickup(p)
				print("  - peer_id=%d, role=%s, can_pickup=%s, pos=%s" % [pid, role, can_pickup, p.global_position])
	
	for peer_id in players.keys():
		var player = players[peer_id]
		if not _can_player_pickup(player):
			continue
		
		var dist = global_position.distance_to(player.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = player
	
	return nearest


func _physics_process(delta: float) -> void:
	if is_collected:
		return
	
	if not is_moving:
		return
	
	# 只有服务器执行移动和拾取判断
	if NetworkManager.is_server():
		_server_physics_process(delta)
	else:
		# 客户端：本地预测移动（视觉效果）
		_client_physics_process(delta)


## 服务器：物理处理（移动和拾取判断）
func _server_physics_process(delta: float) -> void:
	# 每帧更新最近的玩家
	var nearest = _find_nearest_player()
	if nearest:
		target_player = nearest
	
	# 检查目标玩家是否有效
	if not target_player or not is_instance_valid(target_player):
		is_moving = false
		return
	
	# 计算到目标的距离
	var distance = global_position.distance_to(target_player.global_position)
	
	# 调试：每秒打印一次
	if Engine.get_frames_drawn() % 60 == 0:
		var role = target_player.player_role_id if "player_role_id" in target_player else "unknown"
		var pid = target_player.peer_id if "peer_id" in target_player else 0
		print("[DropItemOnline] 服务器追踪: drop_id=%d -> peer_id=%d(role=%s), dist=%.1f, pickup_dist=%.1f" % [
			drop_id, pid, role, distance, pickup_distance
		])
	
	# 到达拾取距离 - 只有服务器判断拾取
	if distance <= pickup_distance:
		_server_process_pickup()
		return
	
	# 移动向目标
	var direction = (target_player.global_position - global_position).normalized()
	global_position += direction * speed * delta


## 客户端：物理处理（本地预测移动，仅视觉效果）
func _client_physics_process(delta: float) -> void:
	# 每帧更新最近的玩家
	var nearest = _find_nearest_player()
	if nearest:
		target_player = nearest
	
	# 检查目标玩家是否有效
	if not target_player or not is_instance_valid(target_player):
		return
	
	# 客户端不判断拾取，只做移动预测
	# 拾取由服务器通过 notify_drop_collected 广播
	
	# 移动向目标
	var direction = (target_player.global_position - global_position).normalized()
	global_position += direction * speed * delta


## 服务器：处理拾取
func _server_process_pickup() -> void:
	if is_collected:
		return
	
	is_collected = true
	is_moving = false
	set_physics_process(false)
	
	# 确定拾取者（最近到达的玩家）
	var collector_peer_id = 0
	if target_player and "peer_id" in target_player:
		collector_peer_id = target_player.peer_id
	
	var role = target_player.player_role_id if (target_player and "player_role_id" in target_player) else "unknown"
	print("[DropItemOnline] 服务器拾取 drop_id=%d, collector_peer_id=%d, role=%s, type=%s, target=%s" % [
		drop_id, collector_peer_id, role, item_type, 
		target_player.name if target_player else "null"
	])
	
	# 奖励资源（只有有效的 peer_id 才发送）
	if collector_peer_id > 0:
		print("[DropItemOnline] 调用 award_player_resource: peer_id=%d, type=%s" % [collector_peer_id, item_type])
		NetworkPlayerManager.award_player_resource(collector_peer_id, item_type, 1)
	else:
		print("[DropItemOnline] 警告: 无效的 collector_peer_id=%d (target=%s)" % [
			collector_peer_id, target_player.name if target_player else "null"
		])
	
	# 通知所有端删除物品（包括服务器自己）
	# rpc_drop_collected 会统一处理删除，这里不要调用 queue_free
	NetworkPlayerManager.notify_drop_collected(drop_id)


## 外部调用：开始移动向玩家
func start_moving() -> void:
	if is_collected:
		return
	
	# 不立即开始移动，只显示物品
	# 等待玩家进入 drop_item_area 范围后才开始移动
	show()
	set_collision_layer_value(5, true)
	
	print("[DropItemOnline] start_moving (等待玩家靠近) drop_id=%d, pos=%s" % [drop_id, global_position])


## 外部调用：当特定玩家进入拾取范围时开始移动（由 player_online 的 _on_drop_item_area_area_entered 调用）
func start_moving_for_player(trigger_peer_id: int) -> void:
	if is_collected or is_moving:
		return
	
	# 检查触发的玩家是否可以拾取
	var trigger_player = NetworkPlayerManager.get_player_by_peer_id(trigger_peer_id)
	if not trigger_player:
		print("[DropItemOnline] 找不到触发玩家 peer_id=%d, drop_id=%d" % [trigger_peer_id, drop_id])
		return
	
	# 使用统一的检查方法
	if not _can_player_pickup(trigger_player):
		print("[DropItemOnline] 玩家 %d 不能拾取此物品 drop_id=%d" % [trigger_peer_id, drop_id])
		return
	
	# 触发玩家可以拾取，开始飞向该玩家
	target_player = trigger_player
	is_moving = true
	
	print("[DropItemOnline] start_moving_for_player: drop_id=%d, trigger_peer=%d, target=%s" % [
		drop_id, trigger_peer_id, target_player.name if target_player else "null"
	])
	
	# 通知所有客户端开始移动（用于视觉效果）
	rpc("rpc_start_moving", trigger_peer_id)


## RPC: 通知客户端开始移动
@rpc("authority", "call_remote", "reliable")
func rpc_start_moving(target_peer_id: int) -> void:
	if is_collected:
		return
	
	# 找到目标玩家
	target_player = NetworkPlayerManager.get_player_by_peer_id(target_peer_id)
	is_moving = true
	
	print("[DropItemOnline] 客户端收到移动通知: drop_id=%d, target_peer=%d" % [drop_id, target_peer_id])


## 外部调用：立即删除（由服务器 RPC 触发）
func remove_item() -> void:
	is_collected = true
	is_moving = false
	set_physics_process(false)
	queue_free()


## 延迟初始化（在节点进入场景树后调用）
func _deferred_init() -> void:
	# 读取保存的位置和缩放
	if has_meta("spawn_position"):
		global_position = get_meta("spawn_position")
		remove_meta("spawn_position")
	
	if has_meta("spawn_scale"):
		scale = get_meta("spawn_scale")
		remove_meta("spawn_scale")
	
	# 播放动画
	if has_meta("spawn_ani_name"):
		var ani_name = get_meta("spawn_ani_name")
		var anim_sprite = get_node_or_null("all_animation")
		if anim_sprite:
			anim_sprite.play(ani_name)
		remove_meta("spawn_ani_name")
	
	# 开始移动
	start_moving()


## ==================== 生成器函数 ====================

## 预加载场景（避免 duplicate 问题）
const DROP_ITEM_SCENE = preload("res://scenes/items/drop_items_online.tscn")

## 生成掉落物品实例
## options: {
##   box: Node - 父节点（默认 GameMain.duplicate_node）
##   ani_name: String - 动画名（gold/masterkey）
##   position: Vector2 - 位置（世界坐标）
##   scale: Vector2 - 缩放
##   drop_id: int - 唯一ID
##   source_peer_id: int - 来源玩家ID（0 表示无限制）
## }
func gen_drop_item(options: Dictionary) -> void:
	var parent_node = options.get("box", GameMain.duplicate_node)
	if not parent_node:
		push_error("[DropItemOnline] 无法找到父节点!")
		return
	
	# 使用 instantiate() 创建新实例（而不是 duplicate）
	var new_item = DROP_ITEM_SCENE.instantiate() as DropItemOnline
	if not new_item:
		push_error("[DropItemOnline] 无法实例化掉落物品!")
		return
	
	# 设置 meta（在 _ready 之前）
	if options.has("drop_id"):
		new_item.set_meta("drop_id_override", options.drop_id)
	
	# 物品类型
	var ani_name = options.get("ani_name", "gold")
	new_item.set_meta("item_type", ani_name)
	
	# 来源玩家ID（用于限制来源玩家不能拾取自己掉落的物品）
	if options.has("source_peer_id"):
		new_item.set_meta("source_peer_id", options.source_peer_id)
	
	# 保存位置和缩放到 meta（在 _ready 后应用）
	var spawn_pos = options.get("position", Vector2.ZERO)
	var spawn_scale = options.get("scale", Vector2(4, 4))
	new_item.set_meta("spawn_position", spawn_pos)
	new_item.set_meta("spawn_scale", spawn_scale)
	new_item.set_meta("spawn_ani_name", ani_name)
	
	# 添加到场景
	parent_node.add_child(new_item)
	
	# 立即初始化
	new_item._deferred_init()
