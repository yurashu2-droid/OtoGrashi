"""ちびキャラの頭部（ニット帽つき）を生成する Blender スクリプト。

使い方:
  blender --background --python build_head.py     # Blender 本体
  python3 build_head.py                            # pip install bpy 済みの環境

出力（このファイルと同じフォルダ）:
  face.png / hat_pattern.png / brim.png   テクスチャ
  chibi_head.glb                          Unlit の glTF
  chibi_head.blend                        Blender ファイル
  preview_*.png                           確認用レンダリング
"""
import math
import os
import random

import bpy  # bmesh / mathutils より先に読み込む（pip版bpy対策）
import bmesh
from mathutils import Matrix, Vector
from PIL import Image, ImageDraw

OUT = os.path.dirname(os.path.abspath(__file__))
random.seed(7)

# ---- 色 -----------------------------------------------------------------
SKIN = "#FFE1D2"
BLUSH = "#FFB3A7"
FRECKLE = "#DDA08C"
LINE = "#3A2A2A"
HAIR = "#6B4A3A"
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


def make_face_texture():
    """顔。頭を正面から投影するので、中心(0,0)=頭の中心、範囲は±1。"""
    s = 2048
    img = Image.new("RGB", (s, s), hex_rgb(SKIN))
    d = ImageDraw.Draw(img)

    def px(x, z):
        return ((x / 2 + 0.5) * s, (0.5 - z / 2) * s)

    def blob(x, z, rx, rz, col):
        cx, cy = px(x, z)
        d.ellipse([cx - rx * s / 2, cy - rz * s / 2, cx + rx * s / 2, cy + rz * s / 2],
                  fill=hex_rgb(col))

    def stroke(points, width, col):
        for i in range(len(points) - 1):
            (x0, z0), (x1, z1) = points[i], points[i + 1]
            for t in range(21):
                k = t / 20
                blob(x0 + (x1 - x0) * k, z0 + (z1 - z0) * k, width, width, col)

    for side in (-1, 1):
        blob(side * 0.50, -0.46, 0.17, 0.10, BLUSH)
        for fx, fz in ((0.40, -0.35), (0.50, -0.31), (0.59, -0.36)):
            blob(side * fx, fz, 0.022, 0.022, FRECKLE)
        # 閉じた目（上向きの弧）
        arc = [(side * 0.36 + 0.115 * math.cos(a), -0.26 + 0.085 * math.sin(a))
               for a in [math.radians(20 + 140 * i / 16) for i in range(17)]]
        stroke(arc, 0.026, LINE)
    # 口（にっこり）
    smile = [(0.075 * math.cos(a), -0.43 + 0.06 * math.sin(a))
             for a in [math.radians(200 + 140 * i / 12) for i in range(13)]]
    stroke(smile, 0.022, LINE)
    return save_aa(img, "face.png", (1024, 1024))


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


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    face_png, hat_png, brim_png = make_face_texture(), make_hat_texture(), make_brim_texture()

    m_skin = unlit("Skin", SKIN)
    m_face = unlit("Face", image_path=face_png)
    m_hair = unlit("Hair", HAIR)
    m_hat = unlit("Hat", image_path=hat_png)
    m_brim = unlit("Brim", image_path=brim_png)
    m_pom = unlit("Pom", POM)
    m_pom2 = unlit("PomAccent", POM_ACCENT)

    root = bpy.data.objects.new("ChibiHead", None)
    bpy.context.collection.objects.link(root)
    root.scale = (1.08, 1.0, 0.96)  # 少し横長のちび頭

    # 頭：正面(-Y)向きの面だけ顔テクスチャ。UV は正面からの平行投影。
    bm = sphere_bm()
    uv = bm.loops.layers.uv.verify()
    for f in bm.faces:
        f.material_index = 1 if f.normal.y < -0.2 else 0
        for loop in f.loops:
            loop[uv].uv = (loop.vert.co.x / 2 + 0.5, loop.vert.co.z / 2 + 0.5)
    add_object("Head", bm, [m_skin, m_face], root)

    # 後ろ髪：頭より一回り大きい殻の後ろ側
    bm = sphere_bm(radius=1.07)
    cut(bm, (0, -0.1, 0), (0, 1, -0.3))
    cut(bm, (0, 0, -0.7), (0, 0, 1))  # あごより上で切りそろえる
    add_object("HairBack", bm, [m_hair], root)

    # 生え際：房のすき間から肌が見えないよう、額の上を覆う
    bm = sphere_bm(radius=1.015)
    cut(bm, (0, 0, 0.3), (0, 0, 1))
    add_object("HairCap", bm, [m_hair], root)

    # 前髪・横髪：つぶした球の房を額に沿って並べる
    for i, deg in enumerate((-78, -58, -38, -17, 4, 24, 44, 63, 80)):
        phi = math.radians(deg)
        elev = math.radians(13 + random.uniform(-3, 3))
        pos = Vector((math.sin(phi) * math.cos(elev), -math.cos(phi) * math.cos(elev),
                      math.sin(elev))) * 0.97
        roll = math.radians(random.uniform(-22, 22) + deg * 0.25)
        length = 0.25 + random.uniform(-0.04, 0.05) + abs(deg) / 300
        mat = (Matrix.Translation(pos) @ Matrix.Rotation(phi, 4, "Z")
               @ Matrix.Rotation(roll, 4, "Y") @ Matrix.Diagonal((0.21, 0.11, length, 1)))
        add_object(f"HairTuft{i}", sphere_bm(seg=20, rings=12), [m_hair], root, mat)

    # 帽子：後ろに傾けた半球＋折り返し＋ポンポン
    hat = bpy.data.objects.new("HatRoot", None)
    bpy.context.collection.objects.link(hat)
    hat.parent = root
    hat.matrix_local = Matrix.Rotation(math.radians(-15), 4, "X")

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
    render_previews()
    bpy.ops.file.pack_all()
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "chibi_head.blend"))


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
                         ("back", 180, 10)):
        a, e = math.radians(az), math.radians(el)
        cam.location = target + 9.5 * Vector((math.sin(a) * math.cos(e),
                                              -math.cos(a) * math.cos(e), math.sin(e)))
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(OUT, f"preview_{name}.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    build()
