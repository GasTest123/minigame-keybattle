extends Node

var animation_scene = preload("res://scenes/animations/animations.tscn")
var animation_scene_obj = null
var drop_item_scene = preload("res://scenes/items/drop_items.tscn")
var drop_item_scene_obj = null
var drop_item_scene_online = preload("res://scenes/items/drop_items_online.tscn")
var drop_item_scene_online_obj = null

var duplicate_node = null
var current_session: GameSession = null

func _ready():
	init_duplicate_node()
	animation_scene_obj = animation_scene.instantiate()
	#add_child(animation_scene_obj)
	drop_item_scene_obj = drop_item_scene.instantiate()
	#add_child(drop_item_scene_obj)
	drop_item_scene_online_obj = drop_item_scene_online.instantiate()
	#add_child(drop_item_scene_online_obj)

	# 初始化战斗特效管理器（预加载所有特效）
	CombatEffectManager.initialize()
	
	# 创建会话
	if current_session == null:
		current_session = GameSession.new()
		add_child(current_session)
		current_session.gold_changed.connect(func(amount, change): gold_changed.emit(amount, change))
		current_session.master_key_changed.connect(func(amount, change): master_key_changed.emit(amount, change))
	
	print("[GameMain] 初始化完成")


# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
	#pass

# 初始化拷贝对象容器
func init_duplicate_node():
	if duplicate_node != null:
		duplicate_node.queue_free()
	var node2d = Node2D.new()
	node2d.name = "duplicate_node"
	get_window().add_child.call_deferred(node2d)
	duplicate_node = node2d
	pass

# 信号：当钥匙数量改变时发出
signal gold_changed(new_amount: int, change: int)
# 信号：当主钥数量改变时发出
signal master_key_changed(new_amount: int, change: int)
signal item_collected(item_type: String)

# 向后兼容属性（代理到current_session）
var gold: int:
	get: return current_session.gold if current_session else 0
	set(value): if current_session: current_session.gold = value

var master_key: int:
	get: return current_session.master_key if current_session else 0
	set(value): if current_session: current_session.master_key = value

var score: int:
	get: return current_session.score if current_session else 0
	set(value): if current_session: current_session.score = value

var level: int = 1

var revive_count: int:
	get: return current_session.revive_count if current_session else 0
	set(value): if current_session: current_session.revive_count = value

# 添加钥匙
func add_gold(amount: int) -> void:
	gold += amount
	item_collected.emit("gold")
	print("获得钥匙: +%d (总计: %d)" % [amount, gold])

# 扣除钥匙
func remove_gold(amount: int) -> bool:
	if gold >= amount:
		gold -= amount
		return true
	return false

# 添加主钥
func add_master_key(amount: int) -> void:
	master_key += amount
	item_collected.emit("master_key")
	print("获得主钥: +%d (总计: %d)" % [amount, master_key])

# 扣除主钥
func remove_master_key(amount: int) -> bool:
	if master_key >= amount:
		master_key -= amount
		return true
	return false

# 重置游戏数据
func reset_game() -> void:
	if current_session:
		current_session.reset()
	level = 1
	print("[GameMain] 游戏数据已重置")

# 玩家选择的数据（代理到session）
var selected_class_id: String:
	get: return current_session.selected_class_id if current_session else "balanced"
	set(value): if current_session: current_session.selected_class_id = value

var selected_weapon_ids: Array:
	get: return current_session.selected_weapon_ids if current_session else []
	set(value): if current_session: current_session.selected_weapon_ids = value

var current_mode_id: String:
	get: return current_session.current_mode_id if current_session else "survival"
	set(value): if current_session: current_session.current_mode_id = value

var current_map_id: String:
	get: return current_session.current_map_id if current_session else ""
	set(value): if current_session: current_session.current_map_id = value
