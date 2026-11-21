#!/usr/bin/env python3
"""オトグラシの「3つの音」の小物を sprite stacking で作る試作ビルド。

4面図(TOP/SIDE/FRONT/BACK)をピクセルアートとしてコードで描き、
danielwh2/sprite-stacking のスライサー(views_to_slices.py)で輪切りストリップに彫る。

  python3 build.py --slicer /path/to/sprite-stacking/skills/sprite-stacking/scripts/views_to_slices.py

出力: out/<name>/{views,slices,check}.png, out/turntable.gif, demo.html
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import io
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
UPSCALE = 8  # スキルの推奨: ネイティブ解像度で描いて 8x NEAREST
GAP = 6  # ビュー間の余白 (ネイティブpx)


def rgb(h: str) -> tuple[int, int, int, int]:
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)


class View:
    """左下原点 (x 右向き, z 上向き) で描けるRGBAキャンバス。"""

    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.a = np.zeros((h, w, 4), dtype=np.uint8)

    def px(self, x: int, z: int, col: str) -> None:
        if 0 <= x < self.w and 0 <= z < self.h:
            self.a[self.h - 1 - z, x] = rgb(col)

    def rect(self, x0: int, z0: int, x1: int, z1: int, col: str) -> None:
        """両端含む。"""
        for z in range(z0, z1 + 1):
            for x in range(x0, x1 + 1):
                self.px(x, z, col)

    def clear(self, x: int, z: int) -> None:
        if 0 <= x < self.w and 0 <= z < self.h:
            self.a[self.h - 1 - z, x] = (0, 0, 0, 0)

    def filled(self, x: int, z: int) -> bool:
        return 0 <= x < self.w and 0 <= z < self.h and self.a[self.h - 1 - z, x, 3] > 0

    def glyph(self, x0: int, z_top: int, rows: list[str], col: str) -> None:
        for dy, row in enumerate(rows):
            for dx, ch in enumerate(row):
                if ch == "#":
                    self.px(x0 + dx, z_top - dy, col)

    def mirrored(self) -> "View":
        v = View(self.w, self.h)
        v.a = self.a[:, ::-1].copy()
        return v


NOTE = [
    "..##.",
    "..###",
    "..#.#",
    "..#..",
    "###..",
    "###..",
]

LAVENDER, LAVENDER_HI, LAVENDER_SH, LAVENDER_DEEP = "#b39df2", "#cdbffa", "#8e79d1", "#7b63d6"


# --------------------------------------------------------------------------- コップ
def cup():
    W = L = 30
    H = 58
    C = 15  # 中心 (x0 = C - hw, x1 = C + hw - 1)

    def hw(z: int) -> int:
        if z <= 35:
            return 10 + round(4 * z / 35)
        if z <= 38:
            return 15
        dome = [14, 14, 13, 12, 10, 7]
        return dome[z - 39] if z <= 44 else 0

    def band(z: int, t: float) -> str:
        """高さ z、左右位置 t(0..1) の表面色。"""
        if z <= 1:  # 底
            return "#8fa3ae" if t < 0.75 else "#74889a"
        if z <= 30:  # コーヒー
            if 0.16 <= t < 0.26:
                return "#a9764a"  # プラカップの映り込み
            ice = z >= 21 and ((int(t * 7) + z // 3) % 2 == 0)
            if ice:
                return "#d9b98c" if t < 0.6 else "#b98a5a"
            if t < 0.08 or t >= 0.74:
                return "#3b2016"
            return "#6b3d24" if z >= 21 else "#5a3320"
        if z <= 35:  # 空の透明部分
            if 0.16 <= t < 0.26:
                return "#f5fafb"
            return "#a9bcc6" if t >= 0.74 else "#d5e3e8"
        if z <= 38:  # フタの縁
            if z == 38 and t < 0.7:
                return "#ffffff"
            return "#b4c3cc" if t >= 0.74 else "#f2f6f7"
        if 0.16 <= t < 0.3:  # ドーム
            return "#f7fbfc"
        return "#a9bcc6" if t >= 0.74 else "#dbe7eb"

    def body(v: View) -> None:
        for z in range(45):
            h = hw(z)
            x0, x1 = C - h, C + h - 1
            for x in range(x0, x1 + 1):
                v.px(x, z, band(z, (x - x0) / (x1 - x0)))

    def straw(v: View, lean: int) -> tuple[int, int]:
        x0 = 14
        for z in range(45, H):  # ドームの上から。ドーム内の行に描くとフタの表面に色が写る
            x0 = 14 + (z - 45) * lean // 12
            v.px(x0, z, LAVENDER_HI)
            v.px(x0 + 1, z, LAVENDER)
            v.px(x0 + 2, z, LAVENDER_SH)
        return x0, x0 + 2

    side, front, back = View(L, H), View(W, H), View(W, H)
    for v in (side, front, back):
        body(v)
    sx0, sx1 = straw(side, 5)  # 後ろ(右)へ傾く
    fx0, fx1 = straw(front, 2)
    straw(back, -2)
    # 正面のステッカー
    front.rect(10, 8, 19, 19, "#f4ecdb")
    front.rect(10, 8, 19, 8, "#dccfb6")
    front.glyph(12, 17, NOTE, LAVENDER_DEEP)
    front.glyph(13, 17, [r[:1].replace("#", ".") + r[1:] for r in NOTE], LAVENDER_DEEP)

    top = View(W, L)  # ここだけ z を「上が奥(back)」の行として使う
    for y in range(L):
        for x in range(W):
            d = ((x - 14.5) ** 2 + (y - 14.5) ** 2) ** 0.5
            if d >= 15.1:
                continue
            if d > 13:
                col = "#f2f6f7"
            elif d > 12:
                col = "#b4c3cc"
            elif 7 <= d < 10 and x < 14 and y < 16:
                col = "#f7fbfc"
            elif d < 2.3:
                col = "#6c7c88"
            else:
                col = "#dbe7eb"
            top.a[y, x] = rgb(col)
    # 上から見たストロー: TOPの色は「上に何もない面」に塗られるので、先端だけ描く
    # (穴から先端までの筋を描くと、ドームの上面に紫の斑点として転写される)
    ty0, ty1 = L - 1 - sx1, L - 1 - sx0
    for y in range(ty0, ty1 + 1):
        for x in range(fx0, fx1 + 1):
            top.a[y, x] = rgb(LAVENDER_HI)
    top.a[ty0 + 1, fx0 + 1] = rgb(LAVENDER_DEEP)

    return dict(name="cup", label="コップ", views=[top, side, front, back], slices=H, round_=True)


# --------------------------------------------------------------------------- 蛇口
CHROME_HI, CHROME, CHROME_SH, CHROME_DK = "#e6edf3", "#aab6c4", "#7d8a9c", "#647084"
WATER, WATER_HI, WATER_SH = "#8fd3f0", "#d4f1fb", "#5fb4dc"


def faucet():
    W, L, H = 17, 26, 34

    # SIDE (正面が左)
    side = View(L, H)
    side.rect(14, 0, 25, 2, CHROME)
    side.rect(14, 0, 25, 0, CHROME_SH)
    side.rect(22, 0, 25, 2, CHROME_SH)
    side.rect(16, 3, 23, 5, CHROME)
    side.rect(16, 5, 21, 5, CHROME_HI)
    side.rect(22, 3, 23, 5, CHROME_SH)
    for z in range(6, 34):  # 支柱
        side.px(18, z, CHROME_HI)
        side.px(19, z, CHROME)
        side.px(20, z, CHROME)
        side.px(21, z, CHROME_SH)
    for x in range(0, 22):  # 横に渡る首
        side.px(x, 33, CHROME_HI)
        side.px(x, 32, CHROME)
        side.px(x, 31, CHROME)
        side.px(x, 30, CHROME_SH)
    for z in range(22, 34):  # 吐水口へ降りる部分
        side.px(0, z, CHROME_HI)
        side.px(1, z, CHROME)
        side.px(2, z, CHROME)
        side.px(3, z, CHROME_SH)
    side.rect(0, 22, 3, 23, CHROME_DK)  # ノズル
    side.px(4, 29, CHROME_SH)
    side.px(17, 29, CHROME_SH)
    for x, z in ((0, 33), (1, 33), (0, 32), (21, 33), (20, 33), (21, 32)):
        side.clear(x, z)
    for z in range(2, 22):  # 水
        side.px(1, z, WATER_HI if z % 5 < 2 else WATER)
        side.px(2, z, WATER)
    side.rect(0, 0, 3, 1, WATER)

    # FRONT (水は彫ったあとに手で直すので、ここでは支柱だけ描く)
    front = View(W, H)
    front.rect(0, 0, 11, 2, CHROME)
    front.rect(0, 0, 11, 0, CHROME_SH)
    front.rect(9, 0, 11, 2, CHROME_SH)
    front.rect(2, 3, 9, 5, CHROME)
    front.rect(2, 5, 7, 5, CHROME_HI)
    front.rect(8, 3, 9, 5, CHROME_SH)
    for z in range(6, 34):
        front.px(4, z, CHROME_HI)
        front.px(5, z, CHROME)
        front.px(6, z, CHROME)
        front.px(7, z, CHROME_SH)
    front.rect(4, 22, 7, 23, CHROME_DK)
    front.clear(4, 33)
    front.clear(7, 33)
    # レバー
    front.rect(8, 9, 14, 12, "#4a4f5e")
    front.rect(8, 12, 14, 12, "#6a7082")
    front.rect(8, 9, 14, 9, "#3d414e")
    front.rect(13, 8, 16, 13, LAVENDER)
    front.rect(13, 13, 15, 13, LAVENDER_HI)
    front.rect(13, 8, 16, 8, LAVENDER_SH)
    front.rect(16, 8, 16, 13, LAVENDER_SH)
    for x, z in ((16, 13), (16, 8)):
        front.clear(x, z)
    back = front.mirrored()

    top = View(W, L)
    for y in range(12):
        for x in range(12):
            d = ((x - 5.5) ** 2 + (y - 5.5) ** 2) ** 0.5
            if d < 6.1:
                top.a[y, x] = rgb(CHROME_SH if d > 4.6 else CHROME)
    for y in range(4, 26):  # 首
        top.a[y, 4] = rgb(CHROME_HI)
        top.a[y, 5] = rgb(CHROME_HI)
        top.a[y, 6] = rgb(CHROME)
        top.a[y, 7] = rgb(CHROME_SH)
    for y in range(4, 8):  # レバー
        for x in range(8, 17):
            top.a[y, x] = rgb(LAVENDER if x >= 13 else "#6a7082")
    top.a[4, 13:16] = rgb(LAVENDER_HI)
    top.a[4, 16] = (0, 0, 0, 0)
    top.a[7, 16] = (0, 0, 0, 0)

    def fix(vol: np.ndarray) -> None:
        """visual hull では水が支柱と同じ幅(4px)に彫られるので、手で 2px の水流に削る。"""
        for z in range(0, 22):
            vol[z, 22:26, 4:8] = 0
            if z < 2:  # 水はね
                vol[z, 22:26, 4:8] = rgb(WATER)
                vol[z, 22, 4] = vol[z, 22, 7] = vol[z, 25, 4] = vol[z, 25, 7] = 0
                if z == 1:
                    vol[z, 23:25, 5:7] = rgb(WATER_HI)
                continue
            lit = (z % 5) < 2
            vol[z, 23, 5] = rgb(WATER_HI if lit else WATER)
            vol[z, 23, 6] = rgb(WATER)
            vol[z, 24, 5] = rgb(WATER)
            vol[z, 24, 6] = rgb(WATER_SH if not lit else WATER)

    return dict(name="faucet", label="水", views=[top, side, front, back], slices=H, round_=False, fix=fix)


# --------------------------------------------------------------------------- ノートPC
def laptop():
    W, L, H = 40, 30, 26
    SIL_HI, SIL, SIL_SH, SIL_DK = "#e4e7ec", "#c8ccd4", "#9aa0ad", "#7b8290"
    BEZEL, SCREEN = "#23232b", "#2b2545"

    def screen_x0(z: int) -> int:
        return 22 + round((z - 2) * 4 / 23)

    side = View(L, H)
    side.rect(0, 0, 23, 0, SIL_SH)
    side.rect(0, 1, 23, 1, SIL)
    side.rect(0, 2, 23, 2, SIL_HI)
    for z in range(2, H):
        x0 = screen_x0(z)
        # 画面は4px厚: 手前2pxが画面色、奥2pxが天板色になる。3pxだと中央の行が
        # 天板色になり、回したときに画面へ銀色の横縞が出る
        side.px(x0, z, BEZEL)
        side.px(x0 + 1, z, BEZEL)
        side.px(x0 + 2, z, SIL)
        side.px(x0 + 3, z, SIL_SH)

    def base_rows(v: View) -> None:
        v.rect(0, 0, W - 1, 0, SIL_SH)
        v.rect(0, 1, W - 1, 1, SIL)
        v.rect(0, 2, W - 1, 2, SIL_HI)

    front = View(W, H)
    base_rows(front)
    front.rect(16, 2, 23, 2, SIL_DK)  # 開くときに指をかける切り欠き
    front.rect(0, 3, W - 1, H - 1, BEZEL)
    front.rect(2, 6, W - 3, H - 3, SCREEN)
    bars = [2, 3, 5, 8, 6, 9, 7, 4, 6, 8, 5, 3, 2]  # 波形 (片側の高さ)
    mid = 14
    for i, b in enumerate(bars):
        x = 7 + i * 2
        half = b // 2
        front.rect(x, mid - half, x, mid + half, LAVENDER if i % 3 else LAVENDER_HI)
    front.rect(4, 19, 5, 20, "#ff6b6b")  # 録音ランプ
    front.clear(0, H - 1)
    front.clear(W - 1, H - 1)

    back = View(W, H)
    base_rows(back)
    back.rect(0, 3, W - 1, H - 1, SIL)
    back.rect(0, H - 3, W - 1, H - 1, SIL_HI)
    back.rect(0, 3, W - 1, 4, SIL_SH)
    back.rect(6, 2, W - 7, 3, SIL_DK)  # ヒンジ
    back.glyph(17, 17, NOTE, LAVENDER_DEEP)
    back.glyph(18, 17, [r[:1].replace("#", ".") + r[1:] for r in NOTE], LAVENDER_DEEP)
    back.clear(0, H - 1)
    back.clear(W - 1, H - 1)

    top = View(W, L)
    for y in range(L):
        for x in range(W):
            top.a[y, x] = rgb(SIL_HI if y < 3 else SIL)
    for y in range(9, 20):  # キーボードの凹み
        for x in range(3, 37):
            top.a[y, x] = rgb("#23252c")
    for ky in range(10, 19, 3):
        for kx in range(4, 36, 3):
            top.a[ky : ky + 2, kx : kx + 2] = rgb("#565b6b")
    top.a[16:18, 13:26] = rgb("#565b6b")  # スペースキー
    top.a[10:12, 34:36] = rgb(LAVENDER)  # 1つだけ光るキー
    for y in range(22, 28):  # トラックパッド
        for x in range(14, 26):
            top.a[y, x] = rgb(SIL_SH if y == 27 or x == 25 else "#d7dbe2")

    return dict(name="laptop", label="キーボード", views=[top, side, front, back], slices=H, round_=False)


# --------------------------------------------------------------------------- ビルド
def sheet_of(views: list[View]) -> Image.Image:
    h = max(v.h for v in views) + GAP * 2
    w = sum(v.w for v in views) + GAP * (len(views) + 1)
    sheet = np.zeros((h, w, 4), dtype=np.uint8)
    x = GAP
    for v in views:
        y = (h - v.h) // 2  # 上下中央: スライサーの読み順判定はビューの縦中心で行を分ける
        sheet[y : y + v.h, x : x + v.w] = v.a
        x += v.w + GAP
    im = Image.fromarray(sheet)
    return im.resize((w * UPSCALE, h * UPSCALE), Image.NEAREST)


def data_uri(arr: np.ndarray) -> str:
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def load_slicer(path: Path):
    spec = importlib.util.spec_from_file_location("views_to_slices", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slicer", type=Path, required=True, help="sprite-stacking の views_to_slices.py")
    ap.add_argument("--viewer", action="store_true", help="上流の viewer.html も out/ に書き出す (git管理外)")
    a = ap.parse_args()
    sp = load_slicer(a.slicer)

    out = HERE / "out"
    stacks, vols = [], []
    for prop in (cup(), faucet(), laptop()):
        d = out / prop["name"]
        d.mkdir(parents=True, exist_ok=True)
        sheet = sheet_of(prop["views"])
        sheet.save(d / "views.png")
        vol, views = sp.views_to_slices(
            np.array(sheet),
            slices=prop["slices"],
            top_nose="down",
            order="reading",
            colours=0,  # パレットは自分で管理しているので減色しない
            shade=0.12,
            dark_thresh=0,  # 輪郭線なしで描いたので剥がさない
            round_=prop["round_"],
        )
        if "fix" in prop:
            prop["fix"](vol)
        n, h, w = vol.shape[:3]
        expect = (prop["slices"], prop["views"][0].h, prop["views"][0].w)
        assert (n, h, w) == expect, f"{prop['name']}: carved {(n, h, w)}, drew {expect}"
        strip = np.concatenate(list(vol), axis=1)
        Image.fromarray(strip).save(d / "slices.png")
        sp.build_preview(vol, views, d / "check.png")
        if a.viewer:
            sp.build_html_viewer(vol, views, d / "viewer.html", title=prop["name"])
        for z0, z1 in sp.thin_runs(vol):
            print(f"warning[{prop['name']}]: slices {z0}-{z1} に1px幅のパーツ (回すと点滅する)")
        print(f"{prop['name']}: {n} slices of {w} x {h}px")
        vols.append(vol)
        stacks.append(
            dict(
                name=prop["name"],
                label=prop["label"],
                count=n,
                w=w,
                h=h,
                strip=data_uri(strip),
                views=data_uri(np.array(sheet_of(prop["views"]).resize(
                    (sheet.width // UPSCALE, sheet.height // UPSCALE), Image.NEAREST))),
            )
        )

    # ターンテーブルGIF (スライサー付属の参照レンダラで描く)
    scale, frames_n = 4, 36
    frames = []
    for i in range(frames_n):
        ims = [sp.render_stack_image(v, i * 360 / frames_n) for v in vols]
        W = sum(im.width for im in ims) + 8 * (len(ims) + 1)
        Hh = max(im.height for im in ims) + 12
        fr = Image.new("RGBA", (W, Hh), rgb("#f6f1e7"))
        x = 8
        for im in ims:
            fr.alpha_composite(im, (x, Hh - 6 - im.height))
            x += im.width + 8
        frames.append(fr.resize((W * scale, Hh * scale), Image.NEAREST).convert("RGB"))
    frames[0].save(out / "turntable.gif", save_all=True, append_images=frames[1:], duration=90, loop=0)
    frames[5].save(out / "turntable.png")

    tpl = HERE / "demo.template.html"
    if tpl.exists():
        html = tpl.read_text(encoding="utf-8")
        marker = "/*__STACKS__*/null"
        assert marker in html, "demo.template.html にマーカーがない"
        (HERE / "demo.html").write_text(html.replace(marker, json.dumps(stacks, ensure_ascii=False), 1), encoding="utf-8")
        print("demo.html を更新")


if __name__ == "__main__":
    sys.exit(main())
