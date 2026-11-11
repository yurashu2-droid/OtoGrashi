"""ちびキャラの頭部（ニット帽つき）を生成する Blender スクリプト。

使い方:
  blender --background --python build_head.py     # Blender 本体
  python3 build_head.py                            # pip install bpy 済みの環境

出力（このファイルと同じフォルダ）:
  face_<表情>.png / hat_pattern.png / brim.png   テクスチャ
                                          （glb には face_smile を貼る。他の表情は差し替え用）
  chibi_head.glb                          Unlit の glTF
  chibi_head.blend                        Blender ファイル
  preview_*.png                           確認用レンダリング
"""
import base64
import json
import math
import os
import random
import struct

import bpy  # bmesh / mathutils より先に読み込む（pip版bpy対策）
import bmesh
from mathutils import Matrix, Vector
import numpy as np
from PIL import Image, ImageDraw, ImageOps

OUT = os.path.dirname(os.path.abspath(__file__))
random.seed(7)

# ---- 色 -----------------------------------------------------------------
SKIN = "#FFE1D2"
BLUSH = "#FFB3A7"
FRECKLE = "#DDA08C"
LINE = "#3A2A2A"
HAIR = "#8C6844"
HAIR_DARK = "#5A3F2C"
HAT = "#E8604C"
HAT_BAND = "#FFF4E0"
HAT_ACCENT = "#2F3E6E"
BRIM = "#2FA39A"
BRIM_RIB = "#23807A"
POM = "#FFF4E0"
POM_ACCENT = "#F6C453"
BACKGROUND = "#2B2B2E"


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def hex_linear(h):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (*[lin(c) for c in hex_rgb(h)], 1.0)


# ---- テクスチャ ---------------------------------------------------------
def save_aa(img, name, size):
    path = os.path.join(OUT, name)
    img.resize(size, Image.LANCZOS).save(path)
    return path


FACE_HALF = 1.3  # 顔テクスチャが覆う範囲（頭の実寸 ±1.3）
EXPRESSIONS = ("smile", "tongue", "wink", "surprised", "sleepy")
TONGUE = "#E8797A"
MOUTH_IN = "#8A3B3B"


def make_face_texture(expression="smile"):
    """顔。頭を正面から平行投影する。座標は変形後の頭の実寸で、画像の端 = ±FACE_HALF。"""
    s = 2048
    img = Image.new("RGB", (s, s), hex_rgb(SKIN))
    d = ImageDraw.Draw(img)

    k = s / (2 * FACE_HALF)  # 実寸 1 あたりのピクセル

    def px(x, z):
        return (s / 2 + x * k, s / 2 - z * k)

    def blob(x, z, rx, rz, col):
        cx, cy = px(x, z)
        d.ellipse([cx - rx * k, cy - rz * k, cx + rx * k, cy + rz * k], fill=hex_rgb(col))

    def stroke(points, width, col):
        for i in range(len(points) - 1):
            (x0, z0), (x1, z1) = points[i], points[i + 1]
            for t in range(21):
                k = t / 20
                blob(x0 + (x1 - x0) * k, z0 + (z1 - z0) * k, width, width, col)

    def arc(cx, cz, rx, rz, a0, a1, n=16):
        return [(cx + rx * math.cos(math.radians(a)), cz + rz * math.sin(math.radians(a)))
                for a in [a0 + (a1 - a0) * i / n for i in range(n + 1)]]

    eye_x, eye_z, mouth_z = 0.42, -0.2, -0.47
    for side in (-1, 1):
        blob(side * 0.62, -0.43, 0.11, 0.065, BLUSH)
        for fx, fz in ((0.50, -0.34), (0.60, -0.31), (0.70, -0.35), (0.56, -0.40)):
            blob(side * fx, fz, 0.016, 0.016, FRECKLE)

    def eye_happy(side):  # 上向きの弧（にっこり閉じ目）
        stroke(arc(side * eye_x, eye_z, 0.115, 0.085, 20, 160), 0.026, LINE)

    def eye_closed(side):  # 横一文字（目をつむる）
        stroke(arc(side * eye_x, eye_z + 0.04, 0.11, 0.035, 200, 340), 0.026, LINE)

    def eye_open(side, r=0.06):
        blob(side * eye_x, eye_z + 0.01, r * 1.6, r * 2.0, LINE)
        blob(side * eye_x + 0.025, eye_z + 0.05, r * 0.5, r * 0.5, "#FFFFFF")

    if expression == "smile":
        for side in (-1, 1):
            eye_happy(side)
        stroke(arc(0, mouth_z, 0.075, 0.06, 200, 340, 12), 0.022, LINE)
    elif expression == "tongue":
        for side in (-1, 1):
            eye_closed(side)
        blob(0.03, mouth_z - 0.035, 0.11, 0.10, TONGUE)
        stroke(arc(0, mouth_z + 0.03, 0.09, 0.04, 200, 340, 12), 0.022, LINE)
    elif expression == "wink":
        eye_open(-1)
        eye_happy(1)
        blob(0, mouth_z - 0.01, 0.13, 0.10, MOUTH_IN)
        blob(0, mouth_z + 0.035, 0.15, 0.06, SKIN)  # 上を削って D の形に
    elif expression == "surprised":
        for side in (-1, 1):
            eye_open(side, 0.07)
            stroke(arc(side * eye_x, eye_z + 0.2, 0.08, 0.03, 20, 160), 0.018, HAIR)  # 眉
        blob(0, mouth_z - 0.02, 0.07, 0.09, MOUTH_IN)
    elif expression == "sleepy":
        for side in (-1, 1):
            stroke(arc(side * eye_x, eye_z, 0.11, 0.05, 200, 340), 0.026, LINE)
        stroke(arc(0, mouth_z, 0.04, 0.025, 200, 340, 8), 0.018, LINE)
        blob(0.23, mouth_z - 0.02, 0.05, 0.06, "#BFE3F2")  # よだれ
    else:
        raise ValueError(expression)
    return save_aa(img, f"face_{expression}.png", (1024, 1024))


def make_hat_texture():
    """帽子本体。u=周方向、v=高さ（0.5=赤道、1=てっぺん）。"""
    w, h = 2048, 1024
    img = Image.new("RGB", (w, h), hex_rgb(HAT))
    d = ImageDraw.Draw(img)

    def y(v):
        return (1 - v) * h

    d.rectangle([0, y(0.83), w, y(0.69)], fill=hex_rgb(HAT_BAND))
    n = 16
    step = w / n
    for i in range(n):
        x0 = i * step
        # ジグザグ
        d.line([(x0, y(0.73)), (x0 + step / 2, y(0.79)), (x0 + step, y(0.73))],
               fill=hex_rgb(HAT_ACCENT), width=22, joint="curve")
        # ドット
        for cx, v, col, r in ((x0 + step / 2, 0.715, HAT, 13), (x0, 0.805, HAT, 13),
                              (x0 + step / 2, 0.87, HAT_BAND, 17)):
            for dx in (0, w):  # 継ぎ目対策
                d.ellipse([cx + dx - r, y(v) - r, cx + dx + r, y(v) + r], fill=hex_rgb(col))
                d.ellipse([cx - dx - r, y(v) - r, cx - dx + r, y(v) + r], fill=hex_rgb(col))
    return save_aa(img, "hat_pattern.png", (1024, 512))


def make_brim_texture():
    """折り返し。u=周方向にリブの縦線。"""
    w, h = 2048, 256
    img = Image.new("RGB", (w, h), hex_rgb(BRIM))
    d = ImageDraw.Draw(img)
    n = 22
    for i in range(n):
        x = (i + 0.5) * w / n
        d.rectangle([x - 11, 0, x + 11, h], fill=hex_rgb(BRIM_RIB))
    return save_aa(img, "brim.png", (1024, 128))


# ---- マテリアル ---------------------------------------------------------
# 色ソケットを出力へ直結する。glTF エクスポーターはこの形を Unlit
# (KHR_materials_unlit) として書き出す。Emission ノードを挟むと Unlit にならない。
def unlit(name, color=None, image_path=None):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.use_backface_culling = False
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    if image_path:
        src = nt.nodes.new("ShaderNodeTexImage")
        src.image = bpy.data.images.load(image_path)
    else:
        src = nt.nodes.new("ShaderNodeRGB")
        src.outputs[0].default_value = hex_linear(color)
    nt.links.new(src.outputs[0], out.inputs[0])
    return mat


# ---- メッシュ -----------------------------------------------------------
def add_object(name, bm, mats, parent, matrix=None):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    for m in mats:
        mesh.materials.append(m)
    for p in mesh.polygons:
        p.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = parent
    if matrix is not None:
        obj.matrix_local = matrix
    return obj


def sphere_bm(radius=1.0, scale=(1, 1, 1), seg=48, rings=24):
    bm = bmesh.new()
    bm.loops.layers.uv.new("UVMap")  # 先に作らないと calc_uvs が効かない
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=radius, calc_uvs=True)
    bmesh.ops.scale(bm, vec=Vector(scale), verts=bm.verts)
    return bm


def cut(bm, co, no):
    """平面 (co, no) の法線側だけ残す。"""
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, plane_co=Vector(co), plane_no=Vector(no),
                           clear_inner=True)


def torus_bm(major, minor, z_scale, seg=64, ring=20):
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    grid = [[bm.verts.new(((major + minor * math.cos(b)) * math.cos(a),
                           (major + minor * math.cos(b)) * math.sin(a),
                           minor * math.sin(b) * z_scale))
             for b in [2 * math.pi * j / ring for j in range(ring)]]
            for a in [2 * math.pi * i / seg for i in range(seg)]]
    for i in range(seg):
        for j in range(ring):
            f = bm.faces.new([grid[i][j], grid[(i + 1) % seg][j],
                              grid[(i + 1) % seg][(j + 1) % ring], grid[i][(j + 1) % ring]])
            for loop, (du, dv) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
                loop[uv].uv = ((i + du) / seg, (j + dv) / ring)
    return bm


# ---- 頭の形 -------------------------------------------------------------
HEAD_BOTTOM, HEAD_HEIGHT = -1.5, 2.7  # 頭の下端と高さ（実寸）


def load_head_profiles(path, n=241):
    """手描きの輪郭（左＝正面、右＝横顔で左向き）から、高さごとの寸法を読む。
    返り値は h=0(あご)〜1(頭頂) の各段での (横幅の半分, 顔側の端の y, 後頭部側の端の y)。
    y は -Y が顔側。"""
    img = Image.open(path).convert("L")
    w, h = img.size
    ink = np.array(img) < 128
    mid = w // 2 + 60  # 左右の絵の境目

    def solid(part):
        # 外側を塗りつぶし、それ以外（線と内側）を図形とみなす
        outside = Image.fromarray(np.where(part, 0, 255).astype(np.uint8))
        outside = ImageOps.expand(outside, border=2, fill=255)
        ImageDraw.floodfill(outside, (0, 0), 128)
        return (np.array(outside)[2:-2, 2:-2] != 128)

    def rows(mask):
        ys = np.nonzero(mask.any(axis=1))[0]
        top, bottom = ys.min(), ys.max()
        out = []
        for i in range(n):
            y = int(round(bottom - (bottom - top) * i / (n - 1)))
            xs = np.nonzero(mask[y])[0]
            out.append((xs.min(), xs.max()) if len(xs) else (np.nan, np.nan))
        arr = np.array(out, dtype=float)
        for c in range(2):  # 抜けを補間してから軽くならす
            col = arr[:, c]
            ok = ~np.isnan(col)
            col[~ok] = np.interp(np.nonzero(~ok)[0], np.nonzero(ok)[0], col[ok])
            arr[:, c] = np.convolve(np.pad(col, 4, mode="edge"), np.ones(9) / 9, "valid")
        return arr, bottom - top

    front, fh = rows(solid(ink[:, :mid]))
    side, sh = rows(solid(ink[:, mid:]))
    half_w = (front[:, 1] - front[:, 0]) / 2 / fh * HEAD_HEIGHT
    axis = (side[:, 0].min() + side[:, 1].max()) / 2
    y_front = (side[:, 0] - axis) / sh * HEAD_HEIGHT
    y_back = (side[:, 1] - axis) / sh * HEAD_HEIGHT
    return np.stack([half_w, y_front, y_back], axis=1)


PROFILE = load_head_profiles(os.path.join(OUT, "head_outline.png"))


def head_deform(v):
    """単位球の点を、手描き輪郭どおりの頭に移す。
    球の高さ z を輪郭の段 h に、各段の断面は横幅と、横顔の前端〜後端で決まる楕円。"""
    x, y, z = v
    h = min(max((z + 1) / 2, 0.0), 1.0)
    f = h * (len(PROFILE) - 1)
    i = min(int(f), len(PROFILE) - 2)
    half_w, y_front, y_back = PROFILE[i] + (PROFILE[i + 1] - PROFILE[i]) * (f - i)
    c = math.hypot(x, y)
    dx, dy = (x / c, y / c) if c > 1e-6 else (0.0, 0.0)
    yc, half_d = (y_front + y_back) / 2, (y_back - y_front) / 2
    return Vector((half_w * dx, yc + half_d * dy, HEAD_BOTTOM + HEAD_HEIGHT * h))


def sphere_dir(phi, el):
    """方位 phi（0=正面、+で右＝+X）、仰角 el の単位ベクトル。"""
    return Vector((math.sin(phi) * math.cos(el), -math.cos(phi) * math.cos(el), math.sin(el)))


def head_point(phi, el, lift=1.0):
    return head_deform(sphere_dir(phi, el)) * lift


def ribbon_bm(points, widths, flat=0.35, sides=8):
    """点列に沿った平たい帯（断面は楕円）。幅は頭の外向きに対して横方向。"""
    bm = bmesh.new()
    rings = []
    n = len(points)
    for i, p in enumerate(points):
        t = (points[min(i + 1, n - 1)] - points[max(i - 1, 0)]).normalized()
        out = p.normalized()
        b = t.cross(out).normalized()
        nn = b.cross(t).normalized()
        w = widths[i]
        rings.append([bm.verts.new(p + b * math.cos(a) * w + nn * math.sin(a) * w * flat)
                      for a in [2 * math.pi * k / sides for k in range(sides)]])
    for i in range(n - 1):
        for k in range(sides):
            bm.faces.new([rings[i][k], rings[i][(k + 1) % sides],
                          rings[i + 1][(k + 1) % sides], rings[i + 1][k]])
    for ring in (rings[0], rings[-1][::-1]):
        bm.faces.new(ring[::-1])
    return bm


def hair_lock(phi, el0, el1, width, swing=0.0, flick=0.25, curl=0.0, steps=18, lift=1.05):
    """生え際(el0)から el1 まで頭に沿って下り、毛先で外へ跳ねる房。
    swing: 毛先の左右への流れ（ラジアン）、curl: 毛先の巻き（ラジアン）。"""
    pts, ws = [], []
    for i in range(steps + 1):
        t = i / steps
        ph = phi + swing * t ** 1.5 + 0.06 * math.sin(t * 7 + phi * 3)
        el = el0 + (el1 - el0) * t
        p = head_point(ph, el, lift + flick * t ** 2.2)
        pts.append(p)
        # 毛先近くまで幅を保ち、最後に丸く閉じる
        ws.append(width * math.sqrt(max(0.0, 1 - t ** 5)) * (1 + 0.12 * math.sin(t * math.pi))
                  + 0.02)
    if curl:
        end, prev = pts[-1], pts[-2]
        t = (end - prev).normalized()
        side = t.cross(end.normalized()).normalized() * (1 if curl > 0 else -1)
        r = 0.07
        center = end + side * r
        for j in range(1, 13):
            a = abs(curl) * j / 12
            pts.append(center - side * r * math.cos(a) + t * r * math.sin(a)
                       + end.normalized() * 0.01 * j)
            ws.append(0.045)
    return pts, ws


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    face_png = [make_face_texture(e) for e in EXPRESSIONS][0]
    hat_png, brim_png = make_hat_texture(), make_brim_texture()

    m_skin = unlit("Skin", SKIN)
    m_face = unlit("Face", image_path=face_png)
    m_hair = unlit("Hair", HAIR)
    m_hair_dark = unlit("HairDark", HAIR_DARK)
    m_hat = unlit("Hat", image_path=hat_png)
    m_brim = unlit("Brim", image_path=brim_png)
    m_pom = unlit("Pom", POM)
    m_pom2 = unlit("PomAccent", POM_ACCENT)

    root = bpy.data.objects.new("ChibiHead", None)
    bpy.context.collection.objects.link(root)

    # 頭：単位球を head_deform で変形。正面向きの面だけ顔テクスチャ。
    # UV は変形後の実寸を正面から平行投影（FACE_HALF で正規化）。
    bm = sphere_bm(seg=64, rings=32)
    for f in bm.faces:
        f.material_index = 1 if f.calc_center_median().normalized().y < -0.2 else 0
    for v in bm.verts:
        v.co = head_deform(v.co)
    uv = bm.loops.layers.uv.verify()
    for f in bm.faces:
        for loop in f.loops:
            co = loop.vert.co
            loop[uv].uv = (co.x / (2 * FACE_HALF) + 0.5, co.z / (2 * FACE_HALF) + 0.5)
    add_object("Head", bm, [m_skin, m_face], root)

    # 髪のかたまり：頭を少し膨らませた殻から、顔の部分をくり抜く。
    # 切り口は房で隠す。
    bm = sphere_bm(seg=64, rings=32)
    face_cut = [f for f in bm.faces
                if (c := f.calc_center_median().normalized()).z < 0.18
                and (c.y < -0.2 or c.z < -0.55)]
    bmesh.ops.delete(bm, geom=face_cut, context="FACES")
    for v in bm.verts:
        v.co = head_deform(v.co) * 1.04
    add_object("HairMass", bm, [m_hair], root)

    # 房：(方位°, 生え際の仰角°, 毛先の仰角°, 幅, 流れ°, 跳ね, 巻き°)
    locks = [
        # 前髪（短め、左右に流れる）
        (-50, 24, -8, 0.27, -14, 0.10, 0), (-27, 24, -4, 0.26, 8, 0.08, 0),
        (-6, 24, -2, 0.24, -10, 0.06, 0), (16, 24, -6, 0.27, 12, 0.08, 0),
        (38, 24, -3, 0.26, -6, 0.10, 0), (58, 22, -10, 0.27, 14, 0.12, 0),
        # 横髪（外へ跳ねる）
        (-72, 20, -26, 0.30, -12, 0.26, 0), (-94, 18, -30, 0.31, 10, 0.32, 0),
        (-116, 16, -28, 0.30, -8, 0.28, 0), (76, 20, -27, 0.30, 12, 0.27, 0),
        (98, 18, -31, 0.31, -10, 0.33, 0), (120, 16, -27, 0.30, 8, 0.28, 0),
        # 後ろ髪
        (140, 14, -30, 0.32, 10, 0.24, 0), (162, 14, -34, 0.32, -8, 0.20, 0),
        (-176, 14, -33, 0.33, 6, 0.20, 0), (-154, 14, -32, 0.32, 8, 0.22, 0),
        (-136, 14, -30, 0.32, -10, 0.24, 0),
        # はみ出した巻き毛
        (-86, 12, -6, 0.10, -24, 0.40, 320),
        (68, 8, 2, 0.09, 22, 0.38, -280),
    ]
    for i, (ph, e0, e1, w, sw, fl, cu) in enumerate(locks):
        pts, ws = hair_lock(math.radians(ph), math.radians(e0), math.radians(e1), w,
                            math.radians(sw), fl, math.radians(cu))
        add_object(f"HairLock{i}", ribbon_bm(pts, ws), [m_hair], root)
        if cu == 0:  # 濃い色の筋（イラストの描線の代わり）
            pts, ws = hair_lock(math.radians(ph + (5 if i % 2 else -5)), math.radians(e0 - 6),
                                math.radians(e1 + (e0 - e1) * 0.25), w * 0.22,
                                math.radians(sw), fl, lift=1.05 + w * 0.32)
            add_object(f"HairStreak{i}", ribbon_bm(pts, ws, flat=0.5), [m_hair_dark], root)

    # 帽子：後ろに傾けた半球＋折り返し＋ポンポン（つばは顔側で高く、後ろで下がる）
    hat = bpy.data.objects.new("HatRoot", None)
    bpy.context.collection.objects.link(hat)
    hat.parent = root
    hat.matrix_local = (Matrix.Translation((0, 0, 0.12))
                        @ Matrix.Rotation(math.radians(-10), 4, "X"))

    bm = sphere_bm(radius=1.12, scale=(1, 1, 1.3))
    cut(bm, (0, 0, 0.3), (0, 0, 1))
    add_object("HatDome", bm, [m_hat], hat)

    add_object("HatBrim", torus_bm(1.1, 0.15, 2.0), [m_brim], hat,
               Matrix.Translation((0, 0, 0.45)))

    pom = bpy.data.objects.new("PomRoot", None)
    bpy.context.collection.objects.link(pom)
    pom.parent = hat
    pom.matrix_local = Matrix.Translation((0, 0, 1.12 * 1.3 + 0.2))
    add_object("PomCore", sphere_bm(radius=0.3, seg=20, rings=12), [m_pom], pom)
    n = 22
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(1 - z * z)
        a = i * math.pi * (3 - math.sqrt(5))
        p = Vector((r * math.cos(a), r * math.sin(a), z)) * 0.27
        add_object(f"PomBump{i}", sphere_bm(radius=0.15, seg=14, rings=8),
                   [m_pom2 if i % 5 == 2 else m_pom], pom, Matrix.Translation(p))

    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "chibi_head.glb"),
                              export_format="GLB", export_apply=True)
    write_viewer_gltf()
    render_previews()
    bpy.ops.file.pack_all()
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "chibi_head.blend"))


def write_viewer_gltf():
    """glb をバイナリ埋め込みの glTF(JSON) にしてビューア用に書き出す。
    アーティファクトは .glb を配信できないので .json の名前にする。"""
    data = open(os.path.join(OUT, "chibi_head.glb"), "rb").read()
    json_len = struct.unpack("<I", data[12:16])[0]
    gltf = json.loads(data[20:20 + json_len])
    bin_start = 20 + json_len + 8
    gltf["buffers"][0]["uri"] = ("data:application/octet-stream;base64,"
                                 + base64.b64encode(data[bin_start:]).decode())
    os.makedirs(os.path.join(OUT, "viewer"), exist_ok=True)
    with open(os.path.join(OUT, "viewer", "chibi_head.gltf.json"), "w") as f:
        json.dump(gltf, f, separators=(",", ":"))


def render_previews():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24
    scene.cycles.device = "CPU"
    scene.render.resolution_x = scene.render.resolution_y = 800
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = hex_linear(BACKGROUND)
    scene.world = world

    cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
    bpy.context.collection.objects.link(cam)
    cam.data.lens = 85
    scene.camera = cam
    target = Vector((0, 0, 0.45))
    for name, az, el in (("front", 0, 5), ("threequarter", 38, 12), ("side", 90, 5),
                         ("back", 180, 10), ("ref", 40, 12)):
        a, e = math.radians(az), math.radians(el)
        cam.location = target + 9.5 * Vector((math.sin(a) * math.cos(e),
                                              -math.cos(a) * math.cos(e), math.sin(e)))
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(OUT, f"preview_{name}.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    build()
