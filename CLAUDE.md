# CLAUDE.md

殺人鬼から市民を守る 2D ゲーム（Godot 4.6 / GL Compatibility）。日本語でやり取りする。

## アーキテクチャ

- **薄い `.tscn` ＋ コード集約**：`Main.tscn` は `Main.gd` を付けた `Node2D` 1個だけ。エンティティ・UI・街は全部コードで生成・描画する。
- **即時描画**：ルート `Main.gd` の `_draw()` で街→市民→殺人鬼→プレイヤー→UI の順に全部描く。`_process` で毎フレーム `queue_redraw()`。
- **エンティティは Dictionary**：`citizens`（dict の配列）、`player`、`killer`（dict）。ノードは作らない。状態は文字列（市民 `wander`/`flee`、殺人鬼 `stalk`/`air`）。
- **物理エンジン不使用**：建物は `Rect2` の配列 `buildings`。衝突は `_move_axis()` の自前スイープAABB（radiusぶん膨らませた矩形に X→Y 順で押し戻し）。`_ensure_walkable()` は点を最寄りの縦道へ逃がす。
- **街**：`_build_city()` が `COLS`×`ROWS` の建物ブロックを道(`ROAD`幅)で囲んで生成。`v_roads`/`h_roads` は道の中心線。建物の上は全員歩行不可。

## ゲームの肝

- 殺人鬼は標的に接近して攻撃（市民HP0でゲームオーバー）。プレイヤーが殺人鬼と標的の**線分の間**(`_player_is_blocking()`)に入ると混乱ゲージ(`frustration`)が溜まり、満タンで諦めてジャンプ＝救助(+1)。
- 殺人鬼は建物で詰まると(`stuck`)大ジャンプで飛び越える。ジャンプ＝`air` 状態、`_draw_killer_jump()` で上昇→消失→着地のアニメ。
- 難易度は経過時間で逓増。**調整は `_level()` と各 `_killer_speed()` / `_attack_interval()` / `_frustration_max()` / `_air_time()`**（ファイル冒頭付近）。基本定数も冒頭（`PLAYER_SPEED`, `BLOCK_RADIUS`, `CITIZEN_HP` 等）。

## アセット

- **スプライト**：`assets/{citizen,killer,player}.png`。Blender で「真上・正射影・透過PNG」をレンダーして作る（[[blender-to-godot-assets]] の手順）。鼻を +Y（上）向きで作り、ゲーム側は `_face_rot()` で進行方向へ回転。差し替えは `_spr()` 経由（未インポート時は丸にフォールバック）。
- **効果音**：アセットなし。`_build_sfx()` が起動時に PCM を合成（`_make_sfx`/`_osc`）。使い捨て Player で `_play()`。
- **BGM**：`assets/Urban_Atmosphere.mp3`（FLASH☆BEAT / DOVA-SYNDROME）。`_start_bgm()` でループ再生。
- `resource/` は `.gdignore` 付き＝Godot 取り込み対象外（README用スクショ等を置く）。

## GDScript の注意（ハマりやすい）

- **Dictionary アクセスは Variant**。`var x := some_dict.foo * 2` は「型推論できない」パーサエラーになる。`var x: Vector2 = ...` のように**明示型を書く**。`clamp`/`lerp`/`max`/`min` などのグローバルも Variant を返すので同様。
- `name`/`modulate` などは `Node`/`CanvasItem` のプロパティ名。ローカル変数・引数に使うと shadow 警告 → 別名にする。

## 開発ループ（godot-mcp）

- 実行：`mcp__godot__run_project`（projectPath はこのフォルダ）。エラーは `mcp__godot__get_debug_output` の output に `Parser Error` 等として出る（errors 配列ではなく output を見る）。変更後は `stop_project`→`run_project`。
- **スクショ**：`_shot.ps1`（gitignore 済み・dev用）を Windows PowerShell で実行。GLウィンドウは PrintWindow が空になるので、**前面化してから CopyFromScreen**で撮る。撮影は `citizen-defender (DEBUG)` ウィンドウ対象。
- **新規 png/mp3 はエディタを前面化すると自動インポート**される（`.import` が生成されるまで実行ゲームの `load()` は失敗）。
- スクショ用にプレイヤー自動操作 `DEBUG_AUTOPLAY`（撮影後は必ず `false` に戻す）。

## Web 書き出し（[[godot-web-export]]）

- **フォントは同梱必須**：`SystemFont` は Web で豆腐になる。`fonts/SawarabiGothic.ttf`（OFL を使用文字＋ASCIIにサブセット化、約87KB）を `_load_font()` で `load()`。**テキストを増やしたら `python tools/subset_font.py` を再実行**（`.gd` を走査して生成）。原本 `fonts/_src/`（1.9MB）は gitignore＆export 除外。
- **BGM 自動再生制限**：`_start_bgm()` は `OS.has_feature("web")` 時は鳴らさず、`_input()` の初回クリック/キーで `play()`（`bgm_started` フラグ）。デスクトップは即再生。
- リソースは `FileAccess` 生読みせず `load()`（フォント・mp3・png すべて）。
- 表示は `canvas_items` ＋ aspect=keep（既定）で解像度非依存。
- 再書き出し：`Godot..._console.exe --headless --path . --export-release "Web" exports/citizen-defender.html`。preset 名は `Web`、`export_presets.cfg` の `exclude_filter` で `fonts/_src/*,resource/*` を除外。`exports/` は成果物 gitignore（`.gdignore` で Godot 取り込みも除外）。

## Git

- リモート `origin`（GitHub, SSH）。`main` で作業。キリのいいところでコミット&プッシュしてよい。
