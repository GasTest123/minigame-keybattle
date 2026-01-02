extends EnemyBehavior
class_name BossShootingBehavior

## Boss 专属射击技能行为
## 向周围360度发射n颗子弹，技能期间无敌，带攻击动作和特效

## 状态枚举
enum SkillState {
	IDLE,       # 待机状态，正常移动
	PREPARING,  # 技能准备阶段
	EXECUTING,  # 技能执行阶段（发射子弹）
	FINISHING,  # 技能结束阶段（等待动画完成）
	COOLDOWN    # 技能冷却中
}

var state: SkillState = SkillState.IDLE

## ==================== 可配置参数 ====================

## 触发条件
var trigger_range: float = 600.0         # 技能触发半径（玩家在此范围内时可触发技能）

## 冷却与准备
var skill_cooldown: float = 5.0          # 技能冷却时间（秒）
var prepare_time: float = 0.5            # 准备时间（秒），在此期间播放准备动画

## 子弹配置
var bullet_count: int = 8                # 每轮发射子弹数量
var bullet_speed: float = 400.0          # 子弹速度
var bullet_damage: int = 15              # 子弹伤害
var bullet_scene_path: String = ""       # 子弹场景路径（可选，优先使用）

## 多轮发射配置
var bullet_rounds: int = 1               # 发射轮次
var bullet_round_interval: float = 0.5   # 每轮之间的间隔时间（秒）

## 特效配置
var fx_sprite_frames_path: String = ""   # 特效 SpriteFrames 资源路径
var fx_animation_name: String = ""       # 特效动画名
var fx_offset: Vector2 = Vector2.ZERO    # 特效位置偏移
var fx_above_boss: bool = true           # 特效是否在Boss上层显示（false则在下层）
var fx_scale: Vector2 = Vector2(1.0, 1.0) # 特效缩放

## Boss动画配置
var skill_sprite_anim: String = "skill"  # SpriteFrames 技能动画名
var skill_anim_player: String = ""       # AnimationPlayer 技能动画名（可选）

## 射击位置偏移
var shoot_offset: Vector2 = Vector2(0, 0)

## ==================== 内部状态 ====================

var state_timer: float = 0.0
var cooldown_timer: float = 0.0
var bullet_scene: PackedScene = null
var fx_sprite_frames: SpriteFrames = null
var fx_node: AnimatedSprite2D = null

## 技能期间保存的原始值
var original_knockback_resistance: float = 0.0
var original_is_invincible: bool = false

## 多轮发射状态
var current_round: int = 0               # 当前发射轮次
var round_timer: float = 0.0             # 轮次间隔计时器
var has_shot_this_round: bool = false    # 当前轮次是否已发射

## 动画完成标记
var animation_finished: bool = false

func _on_initialize() -> void:
	# 从配置中读取参数
	trigger_range = config.get("trigger_range", 600.0)
	skill_cooldown = config.get("skill_cooldown", 5.0)
	prepare_time = config.get("prepare_time", 0.5)
	
	bullet_count = config.get("bullet_count", 8)
	bullet_speed = config.get("bullet_speed", 400.0)
	bullet_damage = config.get("bullet_damage", 15)
	bullet_scene_path = config.get("bullet_scene_path", "")
	
	# 多轮发射配置
	bullet_rounds = config.get("bullet_rounds", 1)
	bullet_round_interval = config.get("bullet_round_interval", 0.5)
	
	fx_sprite_frames_path = config.get("fx_sprite_frames_path", "")
	fx_animation_name = config.get("fx_animation_name", "")
	fx_offset = config.get("fx_offset", Vector2.ZERO)
	fx_above_boss = config.get("fx_above_boss", true)
	fx_scale = config.get("fx_scale", Vector2(1.0, 1.0))
	
	skill_sprite_anim = config.get("skill_sprite_anim", "skill")
	skill_anim_player = config.get("skill_anim_player", "")
	shoot_offset = config.get("shoot_offset", Vector2(0, 0))
	
	# 加载子弹场景
	if bullet_scene_path != "":
		bullet_scene = load(bullet_scene_path) as PackedScene
	else:
		bullet_scene = load("res://scenes/bullets/enemy_bullet.tscn") as PackedScene
	
	if not bullet_scene:
		push_error("[BossShootingBehavior] 无法加载子弹场景")
	
	# 加载特效 SpriteFrames
	if fx_sprite_frames_path != "":
		fx_sprite_frames = load(fx_sprite_frames_path) as SpriteFrames
		if not fx_sprite_frames:
			push_error("[BossShootingBehavior] 无法加载特效资源: " + fx_sprite_frames_path)
	
	# 刷新创建时默认进入冷却，避免Boss生成后立刻放技能
	state = SkillState.COOLDOWN
	state_timer = 0.0
	cooldown_timer = skill_cooldown

func _on_update(delta: float) -> void:
	if not enemy or enemy.is_dead:
		return
	
	# 更新冷却计时器
	if cooldown_timer > 0:
		cooldown_timer -= delta
	
	# 技能期间始终保持不动
	if state == SkillState.PREPARING or state == SkillState.EXECUTING or state == SkillState.FINISHING:
		enemy.velocity = Vector2.ZERO
		enemy.knockback_velocity = Vector2.ZERO
	
	match state:
		SkillState.IDLE:
			_check_trigger()
		
		SkillState.PREPARING:
			_update_prepare(delta)
		
		SkillState.EXECUTING:
			_update_execute(delta)
		
		SkillState.FINISHING:
			_update_finishing(delta)
		
		SkillState.COOLDOWN:
			if cooldown_timer <= 0:
				state = SkillState.IDLE
				print("[BossShootingBehavior] 冷却结束，可再次使用技能")

## 检查是否触发技能
func _check_trigger() -> void:
	if cooldown_timer > 0:
		return
	
	var distance = get_distance_to_player()
	if distance <= trigger_range:
		_start_prepare()

## 开始准备阶段
func _start_prepare() -> void:
	if not enemy:
		return
	
	state = SkillState.PREPARING
	state_timer = prepare_time
	
	# 进入无敌状态，保存原始值
	original_knockback_resistance = enemy.knockback_resistance
	original_is_invincible = enemy.is_invincible
	
	enemy.knockback_resistance = 1.0  # 完全免疫击退
	enemy.knockback_velocity = Vector2.ZERO  # 清除已有的击退速度
	if enemy.has_method("set_invincible"):
		enemy.set_invincible(true)
	
	# 停止移动
	enemy.velocity = Vector2.ZERO
	
	# 重置多轮发射状态
	current_round = 0
	round_timer = 0.0
	has_shot_this_round = false
	animation_finished = false
	
	# 播放准备/技能动画
	_play_skill_animation()
	
	# 显示特效
	_show_fx_effect()
	
	# 联网模式：广播技能开始给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		NetworkPlayerManager.broadcast_boss_skill_start(
			enemy, 
			skill_sprite_anim, 
			fx_sprite_frames_path, 
			fx_animation_name, 
			fx_offset, 
			fx_scale, 
			fx_above_boss
		)
	
	print("[BossShootingBehavior] 技能准备中 | 准备时间:", prepare_time, "秒")

## 更新准备阶段
func _update_prepare(delta: float) -> void:
	state_timer -= delta
	
	if state_timer <= 0:
		_start_execute()

## 开始执行阶段（发射子弹）
func _start_execute() -> void:
	state = SkillState.EXECUTING
	current_round = 0
	round_timer = 0.0
	has_shot_this_round = false
	
	# 立即发射第一轮
	_shoot_bullets_in_circle()
	current_round = 1
	has_shot_this_round = true
	
	print("[BossShootingBehavior] 开始执行 | 总轮次:", bullet_rounds)

## 更新执行阶段
func _update_execute(delta: float) -> void:
	if not enemy:
		return
	
	# 检查是否已完成所有轮次
	if current_round >= bullet_rounds:
		# 所有轮次完成，进入结束阶段
		_start_finishing()
		return
	
	# 更新轮次间隔计时器
	round_timer += delta
	
	# 检查是否可以发射下一轮
	if round_timer >= bullet_round_interval:
		_shoot_bullets_in_circle()
		current_round += 1
		round_timer = 0.0
		print("[BossShootingBehavior] 发射第", current_round, "/", bullet_rounds, "轮")

## 开始结束阶段（等待动画完成）
func _start_finishing() -> void:
	state = SkillState.FINISHING
	
	# 连接动画完成信号
	var sprite = enemy.get_node_or_null("AnimatedSprite2D")
	if sprite and not sprite.animation_finished.is_connected(_on_skill_animation_finished):
		sprite.animation_finished.connect(_on_skill_animation_finished, CONNECT_ONE_SHOT)
	
	print("[BossShootingBehavior] 等待动画完成...")

## 更新结束阶段
func _update_finishing(_delta: float) -> void:
	# 等待动画完成信号触发 _on_skill_animation_finished
	# 如果动画已经完成（animation_finished 为 true），则结束技能
	if animation_finished:
		_end_skill()

## 技能动画完成回调
func _on_skill_animation_finished() -> void:
	animation_finished = true
	
	# 清理特效
	_cleanup_fx()
	
	# 结束技能
	if state == SkillState.FINISHING:
		_end_skill()

## 发射360度环形子弹
func _shoot_bullets_in_circle() -> void:
	if not enemy:
		return
	
	var shoot_pos = enemy.global_position + shoot_offset
	var angle_step = TAU / bullet_count  # TAU = 2π
	
	# 联网模式：通过 NetworkPlayerManager 广播子弹
	if GameMain.current_mode_id == "online":
		for i in range(bullet_count):
			var angle = i * angle_step
			var direction = Vector2(cos(angle), sin(angle))
			NetworkPlayerManager.broadcast_enemy_bullet(shoot_pos, direction, bullet_speed, bullet_damage, "basic", bullet_scene_path)
		print("[BossShootingBehavior] 广播 ", bullet_count, " 颗子弹 | 位置:", shoot_pos, " 伤害:", bullet_damage)
		return
	
	# 单机模式：直接生成子弹
	if not bullet_scene:
		return
	
	for i in range(bullet_count):
		var angle = i * angle_step
		var direction = Vector2(cos(angle), sin(angle))
		
		# 创建子弹实例
		var bullet = bullet_scene.instantiate()
		if not bullet:
			continue
		
		# 添加到场景树
		get_tree().root.add_child(bullet)
		
		# 初始化子弹
		if bullet.has_method("start"):
			bullet.start(shoot_pos, direction, bullet_speed, bullet_damage)
		else:
			push_error("[BossShootingBehavior] 子弹没有start方法")
			bullet.queue_free()
			continue
	
	print("[BossShootingBehavior] 发射 ", bullet_count, " 颗子弹 | 位置:", shoot_pos, " 伤害:", bullet_damage)

## 播放技能动画
func _play_skill_animation() -> void:
	if not enemy:
		return
	
	# 播放 SpriteFrames 动画
	if skill_sprite_anim != "":
		var sprite = enemy.get_node_or_null("AnimatedSprite2D")
		if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation(skill_sprite_anim):
			sprite.play(skill_sprite_anim)
	
	# 播放 AnimationPlayer 动画
	if skill_anim_player != "":
		enemy.play_skill_animation(skill_anim_player)

## 显示技能特效
func _show_fx_effect() -> void:
	if not enemy or not fx_sprite_frames or fx_animation_name == "":
		return
	
	# 检查是否有这个动画
	if not fx_sprite_frames.has_animation(fx_animation_name):
		push_error("[BossShootingBehavior] 特效资源中没有动画: " + fx_animation_name)
		return
	
	# 创建特效节点
	fx_node = AnimatedSprite2D.new()
	fx_node.sprite_frames = fx_sprite_frames
	fx_node.position = fx_offset
	fx_node.scale = fx_scale
	
	# 设置层级
	if fx_above_boss:
		fx_node.z_index = 10  # 在Boss上层
	else:
		fx_node.z_index = -1  # 在Boss下层
	
	# 添加到Boss节点
	enemy.add_child(fx_node)
	
	# 播放动画（循环播放，直到技能结束时手动清理）
	fx_node.play(fx_animation_name)

## 清理特效节点
func _cleanup_fx() -> void:
	if is_instance_valid(fx_node):
		fx_node.queue_free()
		fx_node = null

## 结束技能
func _end_skill() -> void:
	if not enemy:
		return
	
	# 清理特效（确保清理）
	_cleanup_fx()
	
	# 恢复原始状态
	enemy.knockback_resistance = original_knockback_resistance
	if enemy.has_method("set_invincible"):
		enemy.set_invincible(original_is_invincible)
	
	# 进入冷却状态
	state = SkillState.COOLDOWN
	cooldown_timer = skill_cooldown
	
	# 恢复行走动画
	enemy.play_animation("walk")
	enemy.stop_skill_animation()
	
	# 联网模式：广播技能结束给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		NetworkPlayerManager.broadcast_boss_skill_end(enemy)
	
	print("[BossShootingBehavior] 技能结束，进入冷却 | 冷却时间:", skill_cooldown, "秒")

## 检查是否正在释放技能（供Enemy类查询）
func is_skill_active() -> bool:
	return state == SkillState.PREPARING or state == SkillState.EXECUTING or state == SkillState.FINISHING

## 清理资源
func _exit_tree() -> void:
	_cleanup_fx()
