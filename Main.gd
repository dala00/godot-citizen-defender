extends Node2D
## 殺人鬼から市民を守る 2D ゲーム（画像なし・即時描画版）
## プレイヤーは殺人鬼と狙われている市民の間に割り込んで妨害する。
## 妨害し続けると殺人鬼は混乱→大ジャンプして消え、別の場所に着地して新たな標的を狙う。

const SCREEN := Vector2(1024, 640)
const PLAY_MARGIN := 50.0  # 市民が画面外に出たと見なす余白

# --- プレイヤー ---
const PLAYER_SPEED := 270.0
const PLAYER_RADIUS := 16.0

# --- 市民 ---
const TARGET_CITIZENS := 11
const CITIZEN_SPEED := 38.0
const CITIZEN_RADIUS := 11.0
const CITIZEN_HP := 3
const FLEE_SPEED := 180.0

# --- 殺人鬼（基準値。難易度で変化）---
const KILLER_RADIUS := 16.0
const ATTACK_RANGE := 30.0
const BLOCK_RADIUS := 36.0   # この距離内で線分上にいれば妨害成立

var rng := RandomNumberGenerator.new()
var font: Font

var citizens: Array = []
var player := {"pos": SCREEN * 0.5, "face": Vector2.DOWN}
var killer := {}

# 街路グリッド：建物ブロックを道で囲む
const COLS := 4
const ROWS := 3
const ROAD := 80.0           # 道幅（＝歩けるエリア）
var buildings: Array = []    # Rect2（歩行不可の障害物）
var building_colors: Array = []
var v_roads: Array = []      # 縦道の中心x
var h_roads: Array = []      # 横道の中心y

var score := 0
var elapsed := 0.0
var game_over := false

var sfx := {}   # 効果音キャッシュ（起動時にコード合成）
var tex := {}   # キャラのスプライト（Blender 製・未インポート時は丸で代替）
const DEBUG_AUTOPLAY := false   # スクショ撮影用の自動操作（撮影後 false に戻す）


func _ready() -> void:
	rng.randomize()
	font = ThemeDB.fallback_font
	_load_tex()
	_build_sfx()
	_start_bgm()
	_build_city()
	_reset()


func _start_bgm() -> void:
	var path := "res://assets/Urban_Atmosphere.mp3"
	if not ResourceLoader.exists(path):
		return
	var stream = load(path)
	if stream is AudioStreamMP3:
		stream.loop = true   # ループ再生
	var p := AudioStreamPlayer.new()
	p.name = "BGM"
	p.stream = stream
	p.volume_db = -10.0   # SE が聞こえるよう控えめ
	p.bus = "Master"
	add_child(p)
	p.play()


func _load_tex() -> void:
	for k in ["citizen", "killer", "player"]:
		var path := "res://assets/%s.png" % k
		if ResourceLoader.exists(path):
			tex[k] = load(path)


## スプライトを中心 pos に size 四方で描く。テクスチャが無ければ false。
func _spr(key: String, pos: Vector2, size: float, rot := 0.0, mod := Color.WHITE) -> bool:
	var t = tex.get(key)
	if t == null:
		return false
	var s := Vector2(size, size)
	if is_zero_approx(rot):
		draw_texture_rect(t, Rect2(pos - s * 0.5, s), false, mod)
	else:
		# 中心 pos で回転（スプライトは鼻が上＝-Y 向きで作成）
		draw_set_transform(pos, rot, Vector2.ONE)
		draw_texture_rect(t, Rect2(-s * 0.5, s), false, mod)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return true


## 向きベクトルからスプライト回転角（鼻=上=-Y を基準）
func _face_rot(face: Vector2) -> float:
	if face.length_squared() < 0.0001:
		return 0.0
	return face.angle() + PI * 0.5


## 建物グリッドを生成。道(ROAD幅)で全ブロックを囲み、周囲も道にする。
func _build_city() -> void:
	buildings.clear()
	building_colors.clear()
	v_roads.clear()
	h_roads.clear()
	var bw := (SCREEN.x - ROAD * (COLS + 1)) / COLS
	var bh := (SCREEN.y - ROAD * (ROWS + 1)) / ROWS
	var palette := [Color(0.48, 0.52, 0.62), Color(0.60, 0.53, 0.45), Color(0.46, 0.58, 0.60)]
	for cx in COLS:
		for cy in ROWS:
			var x := ROAD + cx * (bw + ROAD)
			var y := ROAD + cy * (bh + ROAD)
			buildings.append(Rect2(x, y, bw, bh))
			building_colors.append(palette[(cx + cy) % palette.size()])
	# 道の中心線（縦 COLS+1 本、横 ROWS+1 本）
	for i in COLS + 1:
		v_roads.append(i * (bw + ROAD) + ROAD * 0.5)
	for j in ROWS + 1:
		h_roads.append(j * (bh + ROAD) + ROAD * 0.5)


func _reset() -> void:
	score = 0
	elapsed = 0.0
	game_over = false
	player.pos = SCREEN * 0.5
	citizens.clear()
	for i in TARGET_CITIZENS:
		_spawn_citizen(true)
	_init_killer()


# ----------------------------------------------------------------------------
# 難易度（経過時間で逓増）
# ----------------------------------------------------------------------------
func _level() -> int:
	return int(elapsed / 6.0)  # 6秒ごとに 1 段階

func _killer_speed() -> float:
	return 72.0 + _level() * 15.0

func _attack_interval() -> float:
	return max(0.35, 0.95 - _level() * 0.07)

func _frustration_max() -> float:
	return min(2.0, 1.2 + _level() * 0.1)  # 妨害してから諦めるまで（短め）

func _air_time() -> float:
	return max(1.1, 3.0 - _level() * 0.22)  # 早く戻ってくる


# ----------------------------------------------------------------------------
# 市民
# ----------------------------------------------------------------------------
func _spawn_citizen(anywhere := false) -> void:
	var c := {
		"hp": CITIZEN_HP,
		"vel": Vector2.ZERO,
		"dir_timer": rng.randf_range(0.6, 2.0),
		"state": "wander",   # wander / flee
		"flash": 0.0,        # ダメージ表示用
		"flee_time": 0.0,
		"face": Vector2.DOWN,
	}
	if anywhere:
		c.pos = _random_road_point()
	else:
		# 画面端の道から入ってくる
		var edge := rng.randi() % 4
		match edge:
			0: c.pos = Vector2(_pick(v_roads), -20)
			1: c.pos = Vector2(_pick(v_roads), SCREEN.y + 20)
			2: c.pos = Vector2(-20, _pick(h_roads))
			3: c.pos = Vector2(SCREEN.x + 20, _pick(h_roads))
	c.vel = _rand_dir() * CITIZEN_SPEED
	citizens.append(c)


func _rand_dir() -> Vector2:
	var a := rng.randf_range(0, TAU)
	return Vector2(cos(a), sin(a))


func _pick(arr: Array):
	return arr[rng.randi() % arr.size()]


## 道の上のランダムな点を返す
func _random_road_point() -> Vector2:
	if rng.randf() < 0.5:
		return Vector2(_pick(v_roads), rng.randf_range(20, SCREEN.y - 20))
	return Vector2(rng.randf_range(20, SCREEN.x - 20), _pick(h_roads))


## 軸ごとに建物（radiusぶん膨らませた矩形）と衝突解決して移動先を返す。
## 壁ずりが効くよう X→Y の順に押し戻す。
func _move_axis(pos: Vector2, delta: Vector2, radius: float) -> Vector2:
	var p := pos
	p.x += delta.x
	for b in buildings:
		var ex: Rect2 = (b as Rect2).grow(radius)
		if ex.has_point(p):
			if delta.x > 0.0:
				p.x = ex.position.x - 0.01
			elif delta.x < 0.0:
				p.x = ex.position.x + ex.size.x + 0.01
	p.y += delta.y
	for b in buildings:
		var ey: Rect2 = (b as Rect2).grow(radius)
		if ey.has_point(p):
			if delta.y > 0.0:
				p.y = ey.position.y - 0.01
			elif delta.y < 0.0:
				p.y = ey.position.y + ey.size.y + 0.01
	return p


## 建物の中に居たら最寄りの縦道へスナップして道の上に出す
func _ensure_walkable(p: Vector2, radius: float) -> Vector2:
	for b in buildings:
		if (b as Rect2).grow(radius).has_point(p):
			var best: float = v_roads[0]
			for vx in v_roads:
				if abs(vx - p.x) < abs(best - p.x):
					best = vx
			p.x = best
			break
	return p


func _update_citizens(dt: float) -> void:
	var to_remove: Array = []
	for c in citizens:
		if c.flash > 0.0:
			c.flash -= dt
		if c.state == "flee":
			# 助かった市民は建物を無視して最寄りの画面端へ一直線に退場
			c.flee_time += dt
			c.pos += c.vel * dt
			c.face = c.vel.normalized()
			if _is_off_screen(c.pos) or c.flee_time > 5.0:
				to_remove.append(c)
			continue
		# うろうろ
		c.dir_timer -= dt
		if c.dir_timer <= 0.0:
			c.dir_timer = rng.randf_range(0.8, 2.4)
			if rng.randf() < 0.25:
				c.vel = Vector2.ZERO  # 立ち止まる
			else:
				c.vel = _rand_dir() * CITIZEN_SPEED
		var want: Vector2 = c.vel * dt
		var np: Vector2 = _move_axis(c.pos, want, CITIZEN_RADIUS)
		# 壁にぶつかって進めなかったら向き直す
		if want.length() > 0.1 and np.distance_to(c.pos) < want.length() * 0.5:
			c.vel = _rand_dir() * CITIZEN_SPEED
			c.dir_timer = rng.randf_range(0.4, 1.0)
		c.pos = np
		if c.vel.length() > 1.0:
			c.face = c.vel.normalized()
		# 画面内へ戻す（端で反射）
		if c.pos.x < 20 or c.pos.x > SCREEN.x - 20:
			c.vel.x = -c.vel.x
			c.pos.x = clamp(c.pos.x, 20, SCREEN.x - 20)
		if c.pos.y < 20 or c.pos.y > SCREEN.y - 20:
			c.vel.y = -c.vel.y
			c.pos.y = clamp(c.pos.y, 20, SCREEN.y - 20)
		# 殺人鬼と重ならないよう押し出す（空中時は除く）
		if killer.state != "air":
			var d: Vector2 = c.pos - killer.pos
			var dl := d.length()
			var min_d := CITIZEN_RADIUS + KILLER_RADIUS
			if dl > 0.01 and dl < min_d:
				var desired: Vector2 = killer.pos + d / dl * min_d
				c.pos = _move_axis(c.pos, desired - c.pos, CITIZEN_RADIUS)

	for c in to_remove:
		if killer.get("target") == c:
			killer.target = null
		citizens.erase(c)

	while citizens.size() < TARGET_CITIZENS:
		_spawn_citizen(false)


func _is_off_screen(p: Vector2) -> bool:
	return p.x < -PLAY_MARGIN or p.x > SCREEN.x + PLAY_MARGIN \
		or p.y < -PLAY_MARGIN or p.y > SCREEN.y + PLAY_MARGIN


# ----------------------------------------------------------------------------
# 殺人鬼
# ----------------------------------------------------------------------------
func _init_killer() -> void:
	killer = {
		"pos": Vector2(SCREEN.x * 0.5, 60),
		"state": "air",          # stalk / air。開幕はジャンプ着地で登場
		"target": null,
		"attack_timer": 0.0,
		"frustration": 0.0,
		"air_timer": 2.0,        # 開幕の猶予
		"land_pos": SCREEN * 0.5,
		"blocked": false,
		"stuck": 0.0,            # 建物で進めない時間
		"face": Vector2.DOWN,
		"air_total": 2.0,        # 今回のジャンプ滞空時間
		"take_pos": Vector2(SCREEN.x * 0.5, 60),  # 離陸地点
	}
	# 着地点はどこかの市民の近くに（道の上へ補正）
	if not citizens.is_empty():
		var c = citizens[rng.randi() % citizens.size()]
		killer.land_pos = _ensure_walkable(c.pos, KILLER_RADIUS)


func _pick_target() -> void:
	var candidates := citizens.filter(func(c): return c.state == "wander")
	if candidates.is_empty():
		killer.target = null
		return
	# 近いほど狙われやすい
	candidates.sort_custom(func(a, b):
		return killer.pos.distance_squared_to(a.pos) < killer.pos.distance_squared_to(b.pos))
	# 近い数体からランダムに
	var n: int = min(3, candidates.size())
	killer.target = candidates[rng.randi() % n]
	killer.attack_timer = _attack_interval()
	killer.frustration = 0.0


func _start_jump(saved: bool, land_override = null) -> void:
	if saved and killer.target != null:
		# 助かった市民は喜んで逃げる
		var t = killer.target
		t.state = "flee"
		var edge := _nearest_edge_dir(t.pos)
		t.vel = edge * FLEE_SPEED
		score += 1
		_play("rescue")
	else:
		_play("jump")
	killer.target = null
	killer.state = "air"
	killer.air_timer = _air_time()
	killer.air_total = killer.air_timer
	killer.take_pos = killer.pos   # 離陸地点
	killer.stuck = 0.0
	var lp: Vector2
	if land_override != null:
		lp = land_override
	elif citizens.is_empty():
		lp = Vector2(rng.randf_range(120, SCREEN.x - 120), rng.randf_range(120, SCREEN.y - 120))
	else:
		var c = citizens[rng.randi() % citizens.size()]
		lp = c.pos + _rand_dir() * rng.randf_range(40, 120)
	lp.x = clamp(lp.x, 60, SCREEN.x - 60)
	lp.y = clamp(lp.y, 60, SCREEN.y - 60)
	killer.land_pos = _ensure_walkable(lp, KILLER_RADIUS)  # 建物の上に降りない


func _nearest_edge_dir(p: Vector2) -> Vector2:
	# 最も近い画面端へ向かう単位ベクトル
	var d_left := p.x
	var d_right := SCREEN.x - p.x
	var d_top := p.y
	var d_bot := SCREEN.y - p.y
	var m: float = min(d_left, d_right, d_top, d_bot)
	if m == d_left: return Vector2.LEFT
	if m == d_right: return Vector2.RIGHT
	if m == d_top: return Vector2.UP
	return Vector2.DOWN


func _player_is_blocking() -> bool:
	if killer.target == null:
		return false
	var m: Vector2 = killer.pos
	var t: Vector2 = killer.target.pos
	var seg := t - m
	var len2 := seg.length_squared()
	if len2 < 1.0:
		return false
	var u: float = clamp((player.pos - m).dot(seg) / len2, 0.0, 1.0)
	var proj := m + seg * u
	return player.pos.distance_to(proj) < BLOCK_RADIUS and u > 0.12 and u < 0.95


func _update_killer(dt: float) -> void:
	match killer.state:
		"air":
			killer.air_timer -= dt
			if killer.air_timer <= 0.0:
				killer.pos = killer.land_pos
				killer.state = "stalk"
				_pick_target()
		"stalk":
			# 標的が無効なら選び直し
			if killer.target == null or not citizens.has(killer.target) \
					or killer.target.state == "flee":
				_pick_target()
				if killer.target == null:
					return
			var target = killer.target
			killer.face = (target.pos - killer.pos).normalized()  # 標的の方を向く
			killer.blocked = _player_is_blocking()
			if killer.blocked:
				# 困って立ち止まる（混乱が溜まる）
				killer.frustration += dt
				if killer.frustration >= _frustration_max():
					_start_jump(true)  # 諦めてジャンプ＝救助成功
			else:
				killer.frustration = max(0.0, killer.frustration - dt * 0.6)
				var to_t: Vector2 = target.pos - killer.pos
				var dist := to_t.length()
				if dist > ATTACK_RANGE:
					var step := to_t.normalized() * _killer_speed() * dt
					var np := _move_axis(killer.pos, step, KILLER_RADIUS)
					var moved := np.distance_to(killer.pos)
					killer.pos = np
					# 建物に阻まれて進めない → 飛び越える（標的の近くへ着地）
					if moved < step.length() * 0.5:
						killer.stuck += dt
						if killer.stuck > 0.8:
							_start_jump(false, target.pos)
					else:
						killer.stuck = 0.0
				else:
					killer.stuck = 0.0
					# 攻撃
					killer.attack_timer -= dt
					if killer.attack_timer <= 0.0:
						killer.attack_timer = _attack_interval()
						target.hp -= 1
						target.flash = 0.25
						_play("attack", rng.randf_range(0.94, 1.08))
						if target.hp <= 0:
							_trigger_game_over()


func _trigger_game_over() -> void:
	if DEBUG_AUTOPLAY:
		return  # スクショ撮影中は死なない
	game_over = true
	_play("gameover")


# ----------------------------------------------------------------------------
# プレイヤー入力
# ----------------------------------------------------------------------------
func _update_player(dt: float) -> void:
	if DEBUG_AUTOPLAY and killer.state == "stalk" and killer.target != null:
		# スクショ用：殺人鬼と標的の間に張り付く
		var mid: Vector2 = (killer.pos + killer.target.pos) * 0.5
		var to_mid: Vector2 = mid - player.pos
		if to_mid.length() > 2.0:
			player.pos = _move_axis(player.pos, to_mid.normalized() * PLAYER_SPEED * dt, PLAYER_RADIUS)
			player.face = to_mid.normalized()
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W): dir.y -= 1
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S): dir.y += 1
	if dir != Vector2.ZERO:
		player.pos = _move_axis(player.pos, dir.normalized() * PLAYER_SPEED * dt, PLAYER_RADIUS)
		player.face = dir.normalized()
	player.pos.x = clamp(player.pos.x, PLAYER_RADIUS, SCREEN.x - PLAYER_RADIUS)
	player.pos.y = clamp(player.pos.y, PLAYER_RADIUS, SCREEN.y - PLAYER_RADIUS)


# ----------------------------------------------------------------------------
# メインループ
# ----------------------------------------------------------------------------
func _process(dt: float) -> void:
	if game_over:
		if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER):
			_reset()
		queue_redraw()
		return
	elapsed += dt
	_update_player(dt)
	_update_citizens(dt)
	_update_killer(dt)
	queue_redraw()


# ----------------------------------------------------------------------------
# 描画
# ----------------------------------------------------------------------------
func _draw() -> void:
	_draw_city()
	# 妨害ライン（殺人鬼→標的）
	if not game_over and killer.state == "stalk" and killer.target != null:
		var col := Color(1, 0.3, 0.2, 0.35)
		if killer.blocked:
			col = Color(0.3, 1, 0.4, 0.7)
		draw_line(killer.pos, killer.target.pos, col, 3.0)

	# 市民
	for c in citizens:
		_draw_citizen(c)

	# 殺人鬼
	_draw_killer()

	# プレイヤー
	_draw_player()

	# UI
	_draw_ui()

	if game_over:
		_draw_gameover()


func _draw_city() -> void:
	# 地面（道のアスファルト）
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0.40, 0.42, 0.45))
	# 道のセンターライン（破線）
	for cx in v_roads:
		draw_dashed_line(Vector2(cx, 0), Vector2(cx, SCREEN.y), Color(0.97, 0.92, 0.55, 0.35), 2.0, 16.0)
	for cy in h_roads:
		draw_dashed_line(Vector2(0, cy), Vector2(SCREEN.x, cy), Color(0.97, 0.92, 0.55, 0.35), 2.0, 16.0)
	# 建物（歩行不可の障害物）。影＋本体＋屋上のふち
	for i in buildings.size():
		var r: Rect2 = buildings[i]
		draw_rect(Rect2(r.position + Vector2(4, 4), r.size), Color(0, 0, 0, 0.35))  # 影
		draw_rect(r, building_colors[i])
		draw_rect(r, Color(0, 0, 0, 0.5), false, 2.0)
		# 屋上にハッチ（歩けない感）
		var inset := r.grow(-8.0)
		if inset.size.x > 0 and inset.size.y > 0:
			draw_rect(inset, Color(1, 1, 1, 0.05))


func _draw_citizen(c: Dictionary) -> void:
	var targeted: bool = killer.target == c and killer.state == "stalk"
	# 状態リング（足元）
	if c.state == "flee":
		draw_circle(c.pos, CITIZEN_RADIUS + 5, Color(0.4, 1.0, 0.5, 0.85), false, 3.0)
	elif targeted:
		draw_circle(c.pos, CITIZEN_RADIUS + 5, Color(1.0, 0.85, 0.2, 0.9), false, 3.0)
	# スプライト（無ければ丸）
	if not _spr("citizen", c.pos, 44.0, _face_rot(c.face)):
		var col := Color(0.75, 0.75, 0.78)
		if c.state == "flee": col = Color(0.4, 0.9, 0.5)
		elif targeted: col = Color(1.0, 0.85, 0.3)
		draw_circle(c.pos, CITIZEN_RADIUS, col)
	# 被弾フラッシュ
	if c.flash > 0.0:
		draw_circle(c.pos, CITIZEN_RADIUS + 2, Color(1, 1, 1, clamp(c.flash * 2.0, 0.0, 0.7)))
	# 狙われている市民の上に HP
	if targeted and c.state == "wander":
		_draw_hp_bar(c.pos + Vector2(-14, -CITIZEN_RADIUS - 14), 28.0, float(c.hp) / CITIZEN_HP)


func _draw_hp_bar(pos: Vector2, w: float, ratio: float) -> void:
	ratio = clamp(ratio, 0.0, 1.0)
	draw_rect(Rect2(pos, Vector2(w, 4)), Color(0, 0, 0, 0.6))
	var col := Color(0.3, 0.9, 0.3) if ratio > 0.5 else Color(0.95, 0.7, 0.2)
	if ratio <= 0.34:
		col = Color(0.95, 0.3, 0.25)
	draw_rect(Rect2(pos, Vector2(w * ratio, 4)), col)


## ジャンプ：離陸地点から上へ飛んで消え、着地地点へ落ちてくる
func _draw_killer_jump() -> void:
	var H := 240.0   # ジャンプの高さ
	var base := 58.0
	var take: Vector2 = killer.take_pos
	var land: Vector2 = killer.land_pos
	var total: float = killer.air_total
	var t: float = clamp(1.0 - killer.air_timer / total, 0.0, 1.0)
	var rot := _face_rot(killer.face)
	# 着地予告リング（早めに出して着地点を知らせる）
	var ring: float = lerp(48.0, KILLER_RADIUS + 6.0, t)
	draw_arc(land, ring, 0, TAU, 40, Color(1, 0.2, 0.2, 0.85), 3.0)
	draw_circle(land, 4, Color(1, 0.2, 0.2, 0.85))
	if t < 0.5:
		# 上昇：離陸地点から上へ、大きくなりながらフェードアウト
		var a: float = t / 0.5
		var hgt: float = (1.0 - pow(1.0 - a, 2.0)) * H
		var scl: float = 1.0 + 0.45 * a
		var al: float = 1.0 - smoothstep(0.6, 1.0, a)
		draw_circle(take, KILLER_RADIUS * (1.0 - 0.7 * a), Color(0, 0, 0, 0.25 * (1.0 - a)))  # 影
		var jp := take + Vector2(0, -hgt)
		if not _spr("killer", jp, base * scl, rot, Color(1, 1, 1, al)):
			draw_circle(jp, KILLER_RADIUS * scl, Color(0.85, 0.12, 0.12, al))
	else:
		# 落下：上空から着地地点へ、小さくなりながらフェードイン
		var b: float = (t - 0.5) / 0.5
		var hgt: float = pow(1.0 - b, 2.0) * H
		var scl: float = 1.0 + 0.45 * (1.0 - b)
		var al: float = smoothstep(0.0, 0.25, b)
		draw_circle(land, KILLER_RADIUS * (0.4 + 0.6 * b), Color(0, 0, 0, 0.25 * b))  # 影
		var jp := land + Vector2(0, -hgt)
		if not _spr("killer", jp, base * scl, rot, Color(1, 1, 1, al)):
			draw_circle(jp, KILLER_RADIUS * scl, Color(0.85, 0.12, 0.12, al))


func _draw_killer() -> void:
	if killer.state == "air":
		_draw_killer_jump()
		return
	# 通常（スプライト or 丸）
	if not _spr("killer", killer.pos, 58.0, _face_rot(killer.face)):
		draw_circle(killer.pos, KILLER_RADIUS, Color(0.85, 0.12, 0.12))
		draw_circle(killer.pos, KILLER_RADIUS, Color(0, 0, 0, 0.5), false, 2.0)
		draw_circle(killer.pos + Vector2(0, -2), 3, Color(1, 1, 1, 0.9))
	# 混乱表示
	if killer.blocked:
		var fr: float = killer.frustration / _frustration_max()
		draw_string(font, killer.pos + Vector2(-8, -KILLER_RADIUS - 8), "!?", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 0.3))
		_draw_hp_bar(killer.pos + Vector2(-16, -KILLER_RADIUS - 6), 32.0, fr)


func _draw_player() -> void:
	var blocking := not game_over and _player_is_blocking()
	# 妨害中はシールド光（足元）
	if blocking:
		draw_circle(player.pos, PLAYER_RADIUS + 7, Color(0.4, 1, 0.5, 0.25))
		draw_arc(player.pos, PLAYER_RADIUS + 7, 0, TAU, 32, Color(0.4, 1, 0.5, 0.95), 3.0)
	# スプライト（無ければ丸）
	if not _spr("player", player.pos, 54.0, _face_rot(player.face)):
		draw_circle(player.pos, PLAYER_RADIUS, Color(0.3, 0.6, 1.0))
		draw_circle(player.pos, PLAYER_RADIUS, Color(1, 1, 1, 0.8), false, 2.0)


func _draw_ui() -> void:
	draw_string(font, Vector2(16, 30), "助けた人数: %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1))
	draw_string(font, Vector2(16, 56), "経過: %ds   難易度 Lv.%d" % [int(elapsed), _level() + 1], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.85, 0.85, 0.9))
	var hint := "矢印/WASDで移動 ・ 殺人鬼(赤)と狙われた市民(黄)の間に入って守れ！"
	draw_string(font, Vector2(16, SCREEN.y - 14), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.8, 0.85))


func _draw_gameover() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.6))
	var c := SCREEN * 0.5
	_draw_center_text("GAME OVER", c + Vector2(0, -40), 48, Color(1, 0.3, 0.3))
	_draw_center_text("助けた人数: %d 人" % score, c + Vector2(0, 10), 28, Color(1, 1, 1))
	_draw_center_text("スペース / Enter でリスタート", c + Vector2(0, 60), 18, Color(0.8, 0.8, 0.8))


func _draw_center_text(text: String, center: Vector2, size: int, col: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, center - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


# ----------------------------------------------------------------------------
# 効果音（PCM をコード合成。アセット0）
# ----------------------------------------------------------------------------
const SR := 22050

func _build_sfx() -> void:
	# 攻撃：低い square の刺すような一発
	sfx["attack"] = _make_sfx([{"freq": 150.0, "freq2": 90.0, "wave": "square", "dur": 0.08, "vol": 0.45, "env": "decay"}])
	# 救助：tri で明るい上昇2音
	sfx["rescue"] = _make_sfx([
		{"freq": 523.0, "wave": "tri", "dur": 0.09, "vol": 0.5, "env": "attackdecay"},
		{"freq": 784.0, "wave": "tri", "dur": 0.13, "vol": 0.5, "env": "attackdecay"},
	])
	# ジャンプ：saw を上昇スイープする whoosh
	sfx["jump"] = _make_sfx([{"freq": 220.0, "freq2": 760.0, "wave": "saw", "dur": 0.18, "vol": 0.35, "env": "decay"}])
	# ゲームオーバー：下降スイープ＋ノイズの爆発
	sfx["gameover"] = _make_sfx([
		{"freq": 420.0, "freq2": 60.0, "wave": "saw", "dur": 0.45, "vol": 0.5, "env": "decay"},
		{"freq": 0.0, "wave": "noise", "dur": 0.3, "vol": 0.4, "env": "decay"},
	])


func _osc(wave: String, phase: float) -> float:
	match wave:
		"square": return 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
		"tri": return 4.0 * abs(fmod(phase, 1.0) - 0.5) - 1.0
		"saw": return 2.0 * fmod(phase, 1.0) - 1.0
		"noise": return rng.randf_range(-1.0, 1.0)
		_: return sin(phase * TAU)


## セグメント列を繋いで AudioStreamWAV(16bit/mono) を合成
func _make_sfx(segments: Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	var phase := 0.0
	for seg in segments:
		var dur: float = seg.get("dur", 0.1)
		var n: int = int(SR * dur)
		var f1: float = seg.get("freq", 440.0)
		var f2: float = seg.get("freq2", f1)
		var wave: String = seg.get("wave", "sine")
		var vol: float = seg.get("vol", 0.6)
		var env: String = seg.get("env", "decay")
		for i in n:
			var t: float = float(i) / float(max(1, n))
			var freq: float = lerp(f1, f2, t)
			phase += freq / SR  # 位相は累積で進めて繋ぎ目ノイズを防ぐ
			var e := 1.0
			match env:
				"decay": e = 1.0 - t
				"attackdecay": e = sin(t * PI)
			var v: float = _osc(wave, phase) * e * vol
			var iv := int(clamp(v, -1.0, 1.0) * 32767.0)
			data.append(iv & 0xff)
			data.append((iv >> 8) & 0xff)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SR
	stream.stereo = false
	stream.data = data
	return stream


## 使い捨て Player で再生し、終わったら自動破棄
func _play(key: String, pitch := 1.0) -> void:
	if not sfx.has(key):
		return
	var p := AudioStreamPlayer.new()
	p.stream = sfx[key]
	p.pitch_scale = pitch
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()
