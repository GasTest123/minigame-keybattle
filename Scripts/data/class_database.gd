extends Node
class_name ClassDatabase

## 职业数据库（重构版）
## 预定义多个职业及其属性和技能
## 
## 使用新的CombatStats系统管理职业属性

static var classes: Dictionary = {}

## 初始化所有职业
static func initialize_classes() -> void:
	if not classes.is_empty():
		return
	
		# 小美 - 实习生
	var betty = ClassData.new(
		"小美 Betty",
		50,  # max_hp
		400.0,  # speed
		1.10,  # attack_multiplier（所有武器伤害+15%）
		2,  # defense
		0.1,  # crit_chance
		2.5,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	betty.description = "朝气蓬勃的来到公司上班第一天，\n 就遇到了外星人入侵"
	# 平衡者已经通过 attack_multiplier 设置了所有武器伤害+15%
	# speed 保持 400.0（移动速度0%）
	# 加载技能数据（新系统）
	betty.skill_data = load("res://resources/skills/betty_skill.tres") as SkillData
	# 设置皮肤 (需要先在编辑器创建 SpriteFrames 资源)
	betty.skin_frames = load("res://resources/class_skin/betty01.tres")
	betty.scale = Vector2(0.7, 0.7)
	# UI 资源配置
	betty.portrait = load("res://assets/UI/class_poster/portrait-betty-01.png")
	betty.poster = load("res://assets/UI/class_poster/pose-betty-01.png")
	betty.dead_poster = load("res://assets/UI/class_poster/dead-betty-01.png")
	betty.name_image = load("res://assets/UI/class_choose/name-betty-01.png")
	# 同步到新系统
	betty.sync_to_base_stats()
	# 自动生成特性描述
	betty.generate_traits_description()
	classes["betty"] = betty
	
	
	# 战士 - 高血量、近战加成
	var warrior = ClassData.new(
		"雅加婆婆 Baba Yaga",
		60,  # max_hp
		380.0,  # speed (稍慢)
		1.0,  # attack_multiplier
		4,  # defense
		0.1,  # crit_chance
		2.0,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	warrior.description = "别拿保洁不当扫地僧，\n 一直坚信自己能拯救世界，可是从来没人信"
	# 设置近战加成
	warrior.melee_damage_multiplier = 1.3  # 近战武器伤害+30%
	warrior.melee_knockback_multiplier = 1.2  # 近战击退+20%
	# 加载技能数据（新系统）
	warrior.skill_data = load("res://resources/skills/babayaga_skill.tres") as SkillData
	warrior.skin_frames = load("res://resources/class_skin/babayaga01.tres")
	warrior.scale = Vector2(0.7, 0.7)
	# UI 资源配置
	warrior.portrait = load("res://assets/UI/class_poster/portrait-babayaga-01.png")
	warrior.poster = load("res://assets/UI/class_poster/pose-babayaga-01.png")
	warrior.dead_poster = load("res://assets/UI/class_poster/dead-babayaga-01.png")
	warrior.name_image = load("res://assets/UI/class_choose/name-babayaga-01.png")
	# 同步到新系统
	warrior.sync_to_base_stats()
	# 自动生成特性描述
	warrior.generate_traits_description()
	classes["warrior"] = warrior
	
	# 射手 - 高攻击速度、远程加成
	var ranger = ClassData.new(
		"威儿先生 Mr.Will",
		40,  # max_hp
		420.0,  # speed (较快)
		1.0,  # attack_multiplier
		2,  # defense
		0.1,  # crit_chance (高暴击)
		2.0,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	ranger.description = "公司的保安，\n 保得一方平安是他的使命,世界和平是他的心愿"
	# 设置远程加成
	ranger.ranged_damage_multiplier = 1.2  # 远程武器伤害+25%
	#ranger.attack_speed_multiplier = 1.2  # 攻击速度+20%
	# 加载技能数据（新系统）
	ranger.skill_data = load("res://resources/skills/mrwill_skill.tres") as SkillData
	ranger.skin_frames = load("res://resources/class_skin/mrwill01.tres")
	ranger.scale = Vector2(0.7, 0.7)
	# UI 资源配置
	ranger.portrait = load("res://assets/UI/class_poster/portrait-mrwill-01.png")
	ranger.poster = load("res://assets/UI/class_poster/pose-mrwill-01.png")
	ranger.dead_poster = load("res://assets/UI/class_poster/dead-mrwill-01.png")
	ranger.name_image = load("res://assets/UI/class_choose/name-mrwill-01.png")
	# 同步到新系统
	ranger.sync_to_base_stats()
	# 自动生成特性描述
	ranger.generate_traits_description()
	classes["ranger"] = ranger
	
	# 法师 - 低血量、魔法加成、范围伤害
	var mage = ClassData.new(
		"大壮 Armstrong",
		40,  # max_hp (低血量)
		420.0,  # speed
		1.0,  # attack_multiplier (基础攻击稍低)
		2,  # defense
		0.1,  # crit_chance
		2.0,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	mage.description = "上班上的生无可恋，\n 虽然天赋很强，但是只想躺平"
	# 设置魔法加成
	mage.magic_damage_multiplier = 1.2  # 魔法武器伤害+40%
	mage.magic_explosion_radius_multiplier = 1.2  # 爆炸范围+30%
	#mage.magic_speed_multiplier = 0.8  # 魔法冷却-20%（速度降低=冷却减少）
	# 加载技能数据（新系统）
	mage.skill_data = load("res://resources/skills/as_skill.tres") as SkillData
	mage.skin_frames = load("res://resources/class_skin/armstrong01.tres")
	mage.scale = Vector2(0.7, 0.7)
	# UI 资源配置
	mage.portrait = load("res://assets/UI/class_poster/portrait-arm-01.png")
	mage.poster = load("res://assets/UI/class_poster/pose-arm-01.png")
	mage.dead_poster = load("res://assets/UI/class_poster/dead-as-01.png")
	mage.name_image = load("res://assets/UI/class_choose/name-as-01.png")
	# 同步到新系统
	mage.sync_to_base_stats()
	# 自动生成特性描述
	mage.generate_traits_description()
	classes["mage"] = mage
	
	# 平衡者 - 均衡属性
	var balanced = ClassData.new(
		"窦老板 Mr.dot",
		50,  # max_hp
		440.0,  # speed
		0.9,  # attack_multiplier（所有武器伤害+15%）
		3,  # defense
		0.1,  # crit_chance
		2.0,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	balanced.description = "外包公司的老板，来要尾款，被困在了大楼里，\n 脸皮很厚，背后小手段很多"
	# 设置异常加成
	balanced.status_chance_multiplier = 1.5  # 异常触发概率+50%
	balanced.status_effect_multiplier = 1.5  # 异常伤害+50%
	# 加载技能数据（新系统）
	balanced.skill_data = load("res://resources/skills/mrdot_skill.tres") as SkillData
	balanced.skin_frames = load("res://resources/class_skin/mrdot01.tres")
	balanced.scale = Vector2(0.7, 0.7)
	# UI 资源配置
	balanced.portrait = load("res://assets/UI/class_poster/portrait-mrdot-01.png")
	balanced.poster = load("res://assets/UI/class_poster/pose-mrdot-01.png")
	balanced.dead_poster = load("res://assets/UI/class_poster/dead-mrdot-01.png")
	balanced.name_image = load("res://assets/UI/class_choose/name-mrdot-01.png")
	# 同步到新系统
	balanced.sync_to_base_stats()
	# 自动生成特性描述
	balanced.generate_traits_description()
	classes["balanced"] = balanced
	
	# 坦克 - 超高血量、防御
	var tank = ClassData.new(
		"关键先生 KeyPerson",
		80,  # max_hp (超高)
		350.0,  # speed (慢)
		0.8,  # attack_multiplier (低攻击)
		5,  # defense (高防御)
		0.1,  # crit_chance
		2.0,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	tank.description = "啊？这是谁啊？"
	# 设置坦克加成
	tank.damage_reduction_multiplier = 0.8  # 受到伤害-20%（减伤系数0.8）
	tank.luck = 50.0  # 幸运值+50
	# 加载技能数据（新系统）
	tank.skill_data = load("res://resources/skills/kp_skill.tres") as SkillData
	tank.skin_frames = load("res://resources/class_skin/ky01.tres")
	tank.scale = Vector2(0.7, 0.7)
	# UI 资源配置
	tank.portrait = load("res://assets/UI/class_poster/portrait-ky-01.png")
	tank.poster = load("res://assets/UI/class_poster/pose-ky-01.png")
	tank.dead_poster = load("res://assets/UI/class_poster/dead-kp-01.png")
	tank.name_image = load("res://assets/UI/class_choose/name-kp-01.png")
	# 同步到新系统
	tank.sync_to_base_stats()
	# 自动生成特性描述
	tank.generate_traits_description()
	classes["tank"] = tank

	# Boss
	register_boss_class()

	# Player 1-4
	for i in range(4):
		register_player_class(i + 1)

static func register_boss_class() -> void:
	var boss = ClassData.new(
		"怪怪 Monitor",
		100,  # max_hp
		500.0,  # speed
		1.5,  # attack_multiplier（所有武器伤害+50%）
		5,  # defense
		0.1,  # crit_chance
		1.8,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	boss.description = "神秘的显示器怪物，拥有强大的力量"
	# 加载技能数据（新系统）- 使用 monitor 闪电风暴技能
	boss.skill_data = load("res://resources/skills/boss_monitor_skill.tres") as SkillData
	# 使用 monitor 的动画资源
	boss.skin_frames = load("res://resources/enemies/animations/stage1/monitor_sprites.tres") as SpriteFrames
	boss.scale = Vector2(0.8, 0.8)  # monitor 原始尺寸较大(530x600)，调整为合适大小
	# UI 资源配置（使用 monitor 的头像）
	boss.portrait = load("res://assets/UI/BOSSHP_ui/parrit-monitor.png")
	# 同步到新系统
	boss.sync_to_base_stats()
	# 自动生成特性描述
	boss.generate_traits_description()
	classes["boss"] = boss

static func register_player_class(n: int) -> void:
	var player = ClassData.new(
		"KeyPerson-Player%d" % n,
		50,  # max_hp
		400.0,  # speed
		1.15,  # attack_multiplier（所有武器伤害+15%）
		2,  # defense
		0.1,  # crit_chance
		1.8,  # crit_damage
		"",  # skill_name (已废弃，使用 skill_data)
		{}  # skill_params (已废弃，使用 skill_data)
	)
	player.description = "均衡发展的职业，适合所有武器类型"
	# 平衡者已经通过 attack_multiplier 设置了所有武器伤害+15%
	# speed 保持 400.0（移动速度0%）
	# 加载技能数据（新系统）
	player.skill_data = load("res://resources/skills/all_stats.tres") as SkillData
	player.skin_frames = player_sprite_frames("player%d" % n)
	# 同步到新系统
	player.sync_to_base_stats()
	# 自动生成特性描述
	player.generate_traits_description()
	classes["player%d" % n] = player

static func player_sprite_frames(skin: String) -> SpriteFrames:
	var player_path = "res://assets/player/"

	var sprite_frame_custom = SpriteFrames.new()
	var texture_size = Vector2(520, 240)
	var sprite_size = Vector2(130, 240)
	var full_texture: Texture = load(player_path + skin + "-sheet.png")

	var num_columns = int(texture_size.x / sprite_size.x)
	var num_row = int(texture_size.y / sprite_size.y)

	for x in range(num_columns):
		for y in range(num_row):
			var frame = AtlasTexture.new()
			frame.atlas = full_texture
			frame.region = Rect2(Vector2(x, y) * sprite_size, sprite_size)
			sprite_frame_custom.add_frame("default", frame)

	return sprite_frame_custom

## 获取职业（重命名以避免与Node.get_class()冲突）
static func get_class_data(class_id: String) -> ClassData:
	if classes.is_empty():
		initialize_classes()
	return classes.get(class_id, classes["balanced"])

## 获取所有职业ID
static func get_all_class_ids() -> Array:
	if classes.is_empty():
		initialize_classes()
	return classes.keys()
