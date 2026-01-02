extends Area2D

## 敌人子弹脚本
## 只对玩家造成伤害，不伤害敌人

@export var speed := 400.0      # 子弹速度
@export var life_time := 3.0    # 最长存活时间（秒）
@export var damage := 10        # 伤害值
var hurt := 1
var dir: Vector2
var _velocity := Vector2.ZERO

## 子弹数据（可选，如果使用数据库）
var bullet_data: EnemyBulletData = null

## 穿透相关
var pierce_count: int = 0  # 剩余穿透次数
var hit_targets: Array = []  # 已命中的目标（用于穿透）

## 击中特效配置
var hit_fx_sprite_frames: SpriteFrames = null  # 击中特效资源
var hit_fx_animation_name: String = ""         # 击中特效动画名
var hit_fx_scale: Vector2 = Vector2(1.0, 1.0)  # 击中特效缩放

## 联网模式：是否为纯视觉子弹（客户端用，不处理伤害）
var is_visual_only: bool = false

## 联网模式：子弹所有者的 peer_id（用于排除自己，boss 玩家技能使用）
var owner_peer_id: int = 0

func start(pos: Vector2, _dir: Vector2, _speed: float, _hurt: int, _life_time: float = 3.0) -> void:
	global_position = pos
	dir = _dir
	speed = _speed
	hurt = _hurt
	life_time = _life_time
	_velocity = dir * speed
	get_tree().create_timer(life_time).timeout.connect(queue_free)

## 设置击中特效
func set_hit_fx(sprite_frames: SpriteFrames, anim_name: String, fx_scale: Vector2 = Vector2(1.0, 1.0)) -> void:
	hit_fx_sprite_frames = sprite_frames
	hit_fx_animation_name = anim_name
	hit_fx_scale = fx_scale

## 使用子弹数据初始化
func initialize_with_data(pos: Vector2, _dir: Vector2, data: EnemyBulletData) -> void:
	if data == null:
		push_error("[EnemyBullet] 子弹数据为空")
		return
	
	bullet_data = data
	global_position = pos
	dir = _dir
	speed = data.speed
	hurt = data.damage
	life_time = data.life_time
	pierce_count = data.pierce_count
	_velocity = dir * speed
	
	# 应用外观
	if has_node("AnimatedSprite2D"):
		var sprite = $AnimatedSprite2D
		if data.texture_path != "":
			var texture = load(data.texture_path) as Texture2D
			if texture:
				# AnimatedSprite2D 需要 SpriteFrames，创建一个包含单帧的 SpriteFrames
				var sprite_frames = SpriteFrames.new()
				sprite_frames.add_animation("default")
				sprite_frames.add_frame("default", texture)
				sprite_frames.set_animation_loop("default", true)
				sprite.sprite_frames = sprite_frames
				sprite.play("default")
		sprite.scale = data.scale
	
	# 应用碰撞大小
	if has_node("CollisionShape2D"):
		var collision = $CollisionShape2D
		if collision.shape is CircleShape2D:
			collision.shape.radius = data.collision_radius
	
	get_tree().create_timer(life_time).timeout.connect(queue_free)

func _physics_process(delta: float) -> void:
	global_position += _velocity * delta

func _on_body_shape_entered(_body_rid: RID, body: Node2D, _body_shape_index: int, _local_shape_index: int) -> void:
	# 只对玩家造成伤害（不攻击怪物）
	if body.is_in_group("player"):
		# 检查玩家是否已经死亡（不攻击墓碑）
		var target_hp = body.get("now_hp")
		if target_hp != null and target_hp <= 0:
			return  # 跳过已死亡的玩家
		
		# 检查是否是子弹所有者（不攻击自己）
		if owner_peer_id > 0:
			var target_peer_id = body.get("peer_id")
			if target_peer_id == owner_peer_id:
				return  # 跳过所有者，不造成伤害
			
			# Boss 玩家发射的子弹只攻击非 Boss 玩家
			var target_role = body.get("player_role_id")
			if target_role == "boss":
				return  # 跳过其他 Boss 玩家，不造成伤害
		
		# 检查是否已经命中过（穿透逻辑）
		if pierce_count > 0 and body in hit_targets:
			return
		
		# 计算碰撞点位置（子弹和玩家之间的中点）
		var hit_pos = (global_position + body.global_position) / 2.0
		
		# 播放击中特效
		_play_hit_fx(hit_pos)
		
		# 对玩家造成伤害（纯视觉子弹不造成伤害）
		if not is_visual_only and body.has_method("player_hurt"):
			body.player_hurt(hurt)
		
		# 记录命中的目标
		if pierce_count > 0:
			hit_targets.append(body)
			pierce_count -= 1
			# 如果还有穿透次数，不销毁子弹
			if pierce_count > 0:
				return
		
		queue_free()
		return
	
	# 如果碰撞到敌人（怪物），忽略不造成伤害
	if body.is_in_group("enemy"):
		return  # Boss 子弹不攻击怪物
	
	# 如果碰撞到其他物体（如墙壁），也销毁
	# 这里可以根据需要添加更多碰撞检测

## 播放击中特效
## hit_pos: 碰撞点位置
func _play_hit_fx(hit_pos: Vector2) -> void:
	if not hit_fx_sprite_frames or hit_fx_animation_name == "":
		return
	
	# 检查是否有这个动画
	if not hit_fx_sprite_frames.has_animation(hit_fx_animation_name):
		return
	
	# 创建特效节点
	var fx_node = AnimatedSprite2D.new()
	fx_node.sprite_frames = hit_fx_sprite_frames
	fx_node.global_position = hit_pos  # 使用碰撞点位置
	fx_node.scale = hit_fx_scale
	fx_node.z_index = 15
	
	# 添加到场景树
	get_tree().root.add_child(fx_node)
	
	# 播放动画
	fx_node.play(hit_fx_animation_name)
	
	# 动画结束后自动清理
	fx_node.animation_finished.connect(func(): fx_node.queue_free())
