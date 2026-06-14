#!/usr/bin/env python3
"""プロジェクト内の .gd で使う文字だけに日本語フォントをサブセット化する。

Web 書き出しでは OS フォントが無いため SystemFont は豆腐(□)になる。
OFL フォント(Sawarabi Gothic)を「実際に使う文字 + ASCII」に絞って同梱する。
テキストを増やしたら再実行すれば良い。

ソースフォント(約1.9MB)が無ければ取得方法:
  Invoke-WebRequest https://github.com/google/fonts/raw/main/ofl/sawarabigothic/SawarabiGothic-Regular.ttf \
    -OutFile fonts/_src/SawarabiGothic-Regular.ttf
"""
import glob
import os
import sys

from fontTools.subset import Subsetter, Options
from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "fonts", "_src", "SawarabiGothic-Regular.ttf")
OUT = os.path.join(ROOT, "fonts", "SawarabiGothic.ttf")


def collect_chars() -> set[str]:
    chars: set[str] = set(chr(c) for c in range(0x20, 0x7F))  # ASCII 印字可能
    for path in glob.glob(os.path.join(ROOT, "*.gd")):
        with open(path, encoding="utf-8") as f:
            chars.update(f.read())
    # 制御文字を除く
    return {c for c in chars if ord(c) >= 0x20}


def main() -> int:
    if not os.path.exists(SRC):
        print(f"source font not found: {SRC}", file=sys.stderr)
        return 1
    chars = collect_chars()
    codepoints = sorted(ord(c) for c in chars)
    font = TTFont(SRC)
    opt = Options()
    opt.glyph_names = False
    opt.name_IDs = ["*"]      # ライセンス等の name レコードを保持
    opt.name_legacy = True
    opt.notdef_outline = True
    opt.recalc_bounds = True
    ss = Subsetter(options=opt)
    ss.populate(unicodes=codepoints)
    ss.subset(font)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    font.save(OUT)
    print(f"{len(codepoints)} glyphs -> {OUT} ({os.path.getsize(OUT)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
