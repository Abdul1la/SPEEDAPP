#!/usr/bin/env python3
"""Renders the driver's car marker (assets/images/car.png) from a 3D model.

Model: "2024 BYD Seal" by 007 (https://sketchfab.com/tangwang920), CC BY 4.0,
https://sketchfab.com/3d-models/2024-byd-seal-f93db9ae0bee4966afa9bf588f27b358
(download the .glb there; it is not kept in the repo).

The car is seen from straight above (orthographic), lit like a studio photo:
the model's own paint, chrome, lights and textures, clear-coat reflections,
tinted glass with the interior faintly visible, and a soft shadow. Pure
numpy + Pillow: a small z-buffer rasterizer, no 3D software needed.

    python3 tool/render_car.py path/to/2024_byd_seal.glb [--out assets/images/car.png] [--preview p.png]

The PNG is 4x the marker's logical size (MarkerIcons.carSize, 46 x 84) and
points up (the driving direction).
"""

import argparse
import io
import json
import pathlib
import struct

import numpy as np
from PIL import Image, ImageFilter

LOGICAL_W, LOGICAL_H = 46, 84  # MarkerIcons.carSize
OUT_SCALE = 4  # PNG pixels per logical pixel
SS = 4  # supersampling, for smooth edges
PX = OUT_SCALE * SS  # render pixels per logical pixel
W, H = LOGICAL_W * PX, LOGICAL_H * PX
CAR_LENGTH = 72.0  # logical pixels from bumper to bumper

# Materials by name: how to draw them from above.
GLASS = {"glass1", "carp_2"}  # tinted: windows, panoramic roof
SKIP = {"HL_Glass", "phong22", "map_C_AD"}  # clear covers / decals over other parts
CLEAR_COAT = {"Car_Paint", "corner1"}

# ---- glTF binary reader ------------------------------------------------------

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_glb(path):
    data = pathlib.Path(path).read_bytes()
    magic, _, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise SystemExit(f"{path} is not a .glb file")
    off, gltf, binc = 12, None, b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8 : off + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk)
        elif ctype == 0x004E4942:
            binc = chunk
        off += 8 + clen
    return gltf, binc


def accessor(gltf, binc, i):
    a = gltf["accessors"][i]
    bv = gltf["bufferViews"][a["bufferView"]]
    dt = np.dtype(COMP[a["componentType"]])
    n = NCOMP[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride", 0) or dt.itemsize * n
    count = a["count"]
    raw = np.frombuffer(binc, dtype=np.uint8, count=stride * (count - 1) + dt.itemsize * n, offset=start)
    arr = np.lib.stride_tricks.as_strided(raw, shape=(count, dt.itemsize * n), strides=(stride, 1)).copy()
    arr = arr.view(dt).reshape(count, n)
    if a.get("normalized") and dt != np.float32:
        return arr.astype(np.float64) / np.iinfo(dt).max
    return arr.astype(np.float64) if dt == np.float32 else arr


def quat_matrix(q):
    x, y, z, w = q
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
    m = np.eye(4)
    m[:3, :3] = quat_matrix(node.get("rotation", [0, 0, 0, 1])) @ np.diag(node.get("scale", [1, 1, 1]))
    m[:3, 3] = node.get("translation", [0, 0, 0])
    return m


def scene_triangles(gltf, binc):
    """World-space triangles: list of (material, positions, normals, uvs), each (N, 3, k)."""
    out = []

    def visit(index, parent):
        node = gltf["nodes"][index]
        m = parent @ node_matrix(node)
        if "mesh" in node:
            normal_m = np.linalg.inv(m[:3, :3]).T
            for p in gltf["meshes"][node["mesh"]]["primitives"]:
                if p.get("mode", 4) != 4:
                    continue
                attrs = p["attributes"]
                pos = accessor(gltf, binc, attrs["POSITION"]) @ m[:3, :3].T + m[:3, 3]
                nrm = accessor(gltf, binc, attrs["NORMAL"]) @ normal_m.T if "NORMAL" in attrs else None
                uv = accessor(gltf, binc, attrs["TEXCOORD_0"]) if "TEXCOORD_0" in attrs else None
                idx = (
                    accessor(gltf, binc, p["indices"]).reshape(-1).astype(np.int64)
                    if "indices" in p
                    else np.arange(len(pos))
                )
                idx = idx[: len(idx) // 3 * 3].reshape(-1, 3)
                out.append(
                    (p.get("material", -1), pos[idx], None if nrm is None else nrm[idx], None if uv is None else uv[idx])
                )
        for child in node.get("children", []):
            visit(child, m)

    for root in gltf["scenes"][gltf.get("scene", 0)]["nodes"]:
        visit(root, np.eye(4))
    return out


def texture(gltf, binc, index):
    src = gltf["textures"][index]["source"]
    bv = gltf["bufferViews"][gltf["images"][src]["bufferView"]]
    start = bv.get("byteOffset", 0)
    im = Image.open(io.BytesIO(binc[start : start + bv["byteLength"]]))
    return np.asarray(im.convert("RGBA"), dtype=np.float64) / 255


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


# ---- Rasterizer --------------------------------------------------------------


def rasterize(P):
    """Top-down z-buffer. P: (N, 3, 3) triangles as (x px, y px, height).
    Returns per pixel: triangle index (-1 = none), barycentrics (H, W, 3), height."""
    x, y, h = P[..., 0], P[..., 1], P[..., 2]
    area = (x[:, 1] - x[:, 0]) * (y[:, 2] - y[:, 0]) - (x[:, 2] - x[:, 0]) * (y[:, 1] - y[:, 0])
    keep = np.abs(area) > 1e-9
    i0 = np.ceil(x.min(1) - 0.5).astype(np.int64)
    i1 = np.floor(x.max(1) - 0.5).astype(np.int64)
    j0 = np.ceil(y.min(1) - 0.5).astype(np.int64)
    j1 = np.floor(y.max(1) - 0.5).astype(np.int64)
    keep &= (i1 >= i0) & (j1 >= j0) & (i1 >= 0) & (j1 >= 0) & (i0 < W) & (j0 < H)
    size = np.maximum(i1 - i0, j1 - j0) + 1

    depth = np.full(H * W, -np.inf)
    tri = np.full(H * W, -1, dtype=np.int64)
    bary = np.zeros((H * W, 3))

    def samples(ids, k):
        ox, oy = np.meshgrid(np.arange(k), np.arange(k))
        px = i0[ids, None] + ox.reshape(1, -1)
        py = j0[ids, None] + oy.reshape(1, -1)
        cx, cy = px + 0.5, py + 0.5
        xa, ya = x[ids], y[ids]
        a = area[ids, None]
        w0 = ((xa[:, 1, None] - cx) * (ya[:, 2, None] - cy) - (xa[:, 2, None] - cx) * (ya[:, 1, None] - cy)) / a
        w1 = ((xa[:, 2, None] - cx) * (ya[:, 0, None] - cy) - (xa[:, 0, None] - cx) * (ya[:, 2, None] - cy)) / a
        w2 = 1 - w0 - w1
        inside = (w0 >= -1e-7) & (w1 >= -1e-7) & (w2 >= -1e-7)
        inside &= (px <= i1[ids, None]) & (py <= j1[ids, None]) & (px >= 0) & (py >= 0) & (px < W) & (py < H)
        z = w0 * h[ids, 0, None] + w1 * h[ids, 1, None] + w2 * h[ids, 2, None]
        flat = py * W + px
        sel = np.nonzero(inside)
        tids = np.broadcast_to(ids[:, None], inside.shape)[sel]
        return flat[sel], z[sel], tids, np.stack([w0[sel], w1[sel], w2[sel]], axis=-1)

    batches = []
    for lo, hi in [(1, 2), (3, 4), (5, 8), (9, 16), (17, 32), (33, 64), (65, 128), (129, 256), (257, 4096)]:
        ids = np.nonzero(keep & (size >= lo) & (size <= hi))[0]
        if len(ids) == 0:
            continue
        per = max(1, 3_000_000 // (hi * hi))
        for s in range(0, len(ids), per):
            batches.append((ids[s : s + per], hi))

    for ids, k in batches:  # nearest surface (highest) wins
        flat, z, _, _ = samples(ids, min(k, int(size[ids].max())))
        np.maximum.at(depth, flat, z)
    for ids, k in batches:
        flat, z, tids, b = samples(ids, min(k, int(size[ids].max())))
        win = z >= depth[flat] - 1e-12
        tri[flat[win]] = tids[win]
        bary[flat[win]] = b[win]
    return tri.reshape(H, W), bary.reshape(H, W, 3), depth.reshape(H, W)


# ---- Shading -----------------------------------------------------------------


def smoothstep(e0, e1, v):
    k = np.clip((v - e0) / (e1 - e0), 0, 1)
    return k * k * (3 - 2 * k)


def environment(rx, ry, rz):
    """Photo studio (linear light): bright ceiling, long softboxes beside the
    car, one ahead, dark floor below the horizon."""
    sky = 0.25 + 0.75 * np.clip(rz, 0, 1) ** 0.7
    sides = (
        smoothstep(0.28, 0.36, np.abs(rx))
        * (1 - smoothstep(0.60, 0.70, np.abs(rx)))
        * (1 - smoothstep(0.45, 0.75, np.abs(ry)))
    )
    ahead = smoothstep(-0.95, -0.55, ry) * (1 - smoothstep(-0.35, -0.12, ry)) * (1 - smoothstep(0.3, 0.6, np.abs(rx)))
    horizon = 0.5 * np.exp(-((rz / 0.10) ** 2))
    return np.where(rz < -0.05, 0.04, sky) + 2.2 * sides + 1.6 * ahead + horizon


def render(model_path):
    gltf, binc = load_glb(model_path)
    mats = gltf.get("materials", [])
    parts = scene_triangles(gltf, binc)

    allp = np.concatenate([p.reshape(-1, 3) for _, p, _, _ in parts])
    lo, hi = allp.min(0), allp.max(0)
    # glTF: Y up. The longer of X / Z is the car's length.
    along = 2 if (hi[2] - lo[2]) >= (hi[0] - lo[0]) else 0
    across = 0 if along == 2 else 2
    # The front is the end away from the red tail lights.
    tail_names = {"red_emis", "tail_light", "Tail_light_Plas"}
    tails = [p for m, p, _, _ in parts if m >= 0 and mats[m].get("name") in tail_names]
    tail_at = np.concatenate(tails).reshape(-1, 3)[:, along].mean() if tails else lo[along]
    front_sign = -1.0 if tail_at > (lo[along] + hi[along]) / 2 else 1.0
    scale = CAR_LENGTH / (hi[along] - lo[along])  # logical px per model unit
    mid_a = (lo[along] + hi[along]) / 2
    mid_c = (lo[across] + hi[across]) / 2

    def to_image(pts):
        """Model points -> (x px, y px, height) seen from above, front up."""
        a = (pts[..., along] - mid_a) * front_sign  # + = toward the front
        c = pts[..., across] - mid_c
        # Seen from above with the front up, the car's right side is on the
        # right of the image (not mirrored).
        right = -c * front_sign if along == 2 else c * front_sign
        xi = (LOGICAL_W / 2 + right * scale) * PX
        yi = (LOGICAL_H / 2 - a * scale) * PX
        return np.stack([xi, yi, pts[..., 1] * scale], axis=-1)

    def to_shading(n):
        """Model normals -> (screen right, screen down, toward camera)."""
        a = n[..., along] * front_sign
        c = n[..., across]
        right = -c * front_sign if along == 2 else c * front_sign
        return np.stack([right, -a, n[..., 1]], axis=-1)

    textures = {}

    def base_color(mi, uv):
        """Linear base color (and alpha) for material mi at uvs (M, 2)."""
        mat = mats[mi] if mi >= 0 else {}
        pbr = mat.get("pbrMetallicRoughness", {})
        factor = np.array(pbr.get("baseColorFactor", [1, 1, 1, 1]), dtype=np.float64)
        col = np.broadcast_to(factor, (len(uv) if uv is not None else 1, 4)).copy()
        tex = pbr.get("baseColorTexture")
        if tex is not None and uv is not None:
            ti = tex["index"]
            if ti not in textures:
                textures[ti] = texture(gltf, binc, ti)
            img = textures[ti]
            th, tw = img.shape[:2]
            px = np.mod(np.floor(uv[:, 0] * tw).astype(np.int64), tw)
            py = np.mod(np.floor(uv[:, 1] * th).astype(np.int64), th)
            s = img[py, px]
            col[:, :3] *= srgb_to_linear(s[:, :3])
            col[:, 3] *= s[:, 3]
        return col

    def layer(names_ok):
        sel = [(m, p, n, uv) for m, p, n, uv in parts if names_ok(mats[m].get("name") if m >= 0 else "")]
        P = np.concatenate([to_image(p) for _, p, _, _ in sel])
        tri, bary, depth = rasterize(P)
        hit = tri >= 0
        # Per pixel: material, normal, uv, from the winning triangle.
        mat_of = np.concatenate([np.full(len(p), m) for m, p, _, _ in sel])
        normals = np.concatenate(
            [n if n is not None else np.repeat(np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])[:, None], 3, 1) for _, p, n, _ in sel]
        )
        uvs = np.concatenate([uv if uv is not None else np.zeros((len(p), 3, 2)) for _, p, _, uv in sel])
        t = tri[hit]
        b = bary[hit]
        n = np.einsum("ij,ijk->ik", b, normals[t])
        n = to_shading(n)
        n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-9)
        n = np.where(n[:, 2:3] < 0, -n, n)  # face the camera
        uv = np.einsum("ij,ijk->ik", b, uvs[t])
        m = mat_of[t]
        col = np.zeros((len(t), 4))
        for mi in np.unique(m):
            k = m == mi
            col[k] = base_color(int(mi), uv[k])
        return hit, depth, m, n, col

    car_hit, car_depth, car_mat, car_n, car_col = layer(lambda name: name not in GLASS and name not in SKIP)
    glass_hit, glass_depth, _, glass_n, _ = layer(lambda name: name in GLASS)

    # Ambient occlusion from the height map (darker in creases and at edges).
    zmap = np.where(car_hit, car_depth, 0.0)
    zmax = max(zmap.max(), 1e-6)
    zimg = Image.fromarray((np.clip(zmap / zmax, 0, 1) * 255).astype(np.uint8), mode="L")
    zblur = np.asarray(zimg.filter(ImageFilter.GaussianBlur(1.2 * PX)), dtype=np.float64) / 255 * zmax
    ao_map = 1 - np.clip((zblur - zmap) * 0.18, 0, 0.6)

    light = np.array([-0.35, -0.55, 1.0])
    light /= np.linalg.norm(light)
    halfv = light + np.array([0, 0, 1.0])
    halfv /= np.linalg.norm(halfv)

    def shade(n, base, metal, rough, coat, ao):
        nz = n[:, 2]
        rx, ry, rz = 2 * nz * n[:, 0], 2 * nz * n[:, 1], 2 * nz * nz - 1
        env = environment(rx, ry, rz)
        env = env * (1 - rough) + 0.55 * rough  # rough surfaces: blurry reflections
        ndl = np.clip(n @ light, 0, 1)
        sun = np.clip(n @ halfv, 0, 1) ** (20 + 300 * (1 - rough) ** 2) * (1 - rough)
        f0 = 0.04 * (1 - metal)[:, None] + base * metal[:, None]
        fres = f0 + (1 - f0) * ((1 - nz) ** 5)[:, None]
        diffuse = base * (1 - metal)[:, None] * (0.35 * ao + 0.85 * ndl * ao)[:, None]
        rgb = diffuse * (1 - fres) + fres * env[:, None] + 1.5 * sun[:, None] * fres
        if coat is not None:  # clear coat over the paint
            fc = (0.05 + 0.95 * (1 - nz) ** 5) * coat
            rgb = rgb * (1 - fc[:, None]) + (fc * env + 2.0 * sun * coat)[:, None]
        return rgb

    names = np.array([mats[m].get("name", "") if m >= 0 else "" for m in range(len(mats))] + [""])
    pbr = [mat.get("pbrMetallicRoughness", {}) for mat in mats]
    metal_of = np.array([p.get("metallicFactor", 1.0) for p in pbr] + [0.0])
    rough_of = np.array([p.get("roughnessFactor", 1.0) for p in pbr] + [1.0])
    emis_of = np.array([mat.get("emissiveFactor", [0, 0, 0]) for mat in mats] + [[0, 0, 0]], dtype=np.float64)

    ao = ao_map[car_hit]
    m = car_mat
    coat = np.where(np.isin(names[m], list(CLEAR_COAT)), 1.0, 0.0)
    rgb = shade(car_n, car_col[:, :3], metal_of[m], rough_of[m], coat, ao)
    # Lights: tail lights glow red; emissive textured parts glow in their color.
    emis = emis_of[m]
    rgb += emis * np.where(np.isin(names[m], ["red_emis"]), 2.5, 0.0)[:, None]
    tail = np.isin(names[m], ["tail_light", "tail_Light_Ad"])
    rgb[tail] += car_col[tail, :3] * 1.5

    image = np.zeros((H, W, 3))
    image[car_hit] = rgb

    # Glass over whatever is below: dark tint, reflections, the interior faintly.
    over = glass_hit & (~car_hit | (glass_depth >= car_depth - 1e-6))
    gn = glass_n[over[glass_hit]]
    nz = gn[:, 2]
    rx, ry, rz = 2 * nz * gn[:, 0], 2 * nz * gn[:, 1], 2 * nz * nz - 1
    fres = 0.04 + 0.96 * (1 - nz) ** 5
    sun = np.clip(gn @ halfv, 0, 1) ** 900
    refl = fres * environment(rx, ry, rz) * 0.35 + 0.5 * sun
    below = image[over]
    image[over] = below * 0.02 + np.array([0.0012, 0.0018, 0.0032]) + refl[:, None]

    # Where the lights are (even if the body hides them from above): they
    # glow onto the ground, so the front and back read at a glance.
    def lights(names):
        hit, *_ = layer(lambda name: name in names)
        return hit

    glow_tail = lights({"red_emis", "tail_light", "Tail_light_Plas"})
    glow_head = lights({"HL_Mat", "HL_CHR"})
    covered = car_hit | glass_hit
    return image, covered, glow_head, glow_tail


def finish(image, covered, glow_head, glow_tail):
    """Tone map, shadow, downsample: RGBA uint8 at OUT_SCALE."""
    mapped = image / (1 + image * 0.35)  # gentle highlight roll-off
    display = np.clip(mapped, 0, 1) ** (1 / 2.2)

    def blur(mask, sigma):
        img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8), mode="L")
        return np.asarray(img.filter(ImageFilter.GaussianBlur(sigma * PX)), dtype=np.float64) / 255

    car = covered.astype(np.float64)
    shifted = np.roll(np.roll(car, int(1.2 * PX), axis=0), int(0.5 * PX), axis=1)
    shadow = np.clip(0.45 * blur(shifted, 2.4) + 0.35 * blur(car, 0.7), 0, 0.75)
    # Light bars on the very edge of the body, where the lights are: red at
    # the back, white at the front corners.
    edge = int(0.75 * PX)
    tail_cols = glow_tail.any(axis=0)[None, :]
    head_cols = glow_head.any(axis=0)[None, :]
    rows = np.arange(H)[:, None]
    tail_rows = glow_tail.any(axis=1)
    head_rows = glow_head.any(axis=1)
    rear = covered & ~np.roll(covered, -edge, axis=0) & tail_cols & (rows > H / 2)
    front = covered & ~np.roll(covered, edge, axis=0) & head_cols & (rows < H / 2)
    # Only the outer stretch of each light (not the whole bumper).
    rear &= rows >= np.argmax(tail_rows) - edge
    front &= rows <= H - 1 - np.argmax(head_rows[::-1]) + edge
    display = np.where(rear[..., None], np.array([1.0, 0.16, 0.22]), display)
    display = np.where(front[..., None], np.array([0.94, 0.98, 1.0]), display)
    head = blur(glow_head.astype(np.float64) + front, 1.6)
    tail = blur(glow_tail.astype(np.float64) + rear, 1.6)
    glow_rgb = 0.8 * head[..., None] * np.array([0.85, 0.93, 1.0]) + 1.0 * tail[..., None] * np.array([1.0, 0.08, 0.12])
    glow_a = np.clip(0.8 * head + 1.0 * tail, 0, 0.9)
    under_a = np.clip(shadow + glow_a, 0, 0.9)
    under_rgb = glow_rgb  # shadow is black
    rgb = display * car[..., None] + under_rgb * (1 - car[..., None])
    alpha = car + under_a * (1 - car)

    def down(a):
        h, w = a.shape[0] // SS, a.shape[1] // SS
        return a.reshape(h, SS, w, SS, *a.shape[2:]).mean(axis=(1, 3))

    srgb, sa = down(rgb), down(alpha)
    straight = np.where(sa[..., None] > 1e-4, srgb / np.maximum(sa[..., None], 1e-4), 0)
    rgba = np.dstack([np.clip(straight, 0, 1), sa])
    return Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), mode="RGBA")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model", help="the .glb file")
    parser.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent.parent / "assets/images/car.png"))
    parser.add_argument("--preview", help="also write a preview on dark / light / green map colors")
    args = parser.parse_args()
    image = finish(*render(args.model))
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    image.save(out, optimize=True)
    print(f"wrote {out} ({image.width}x{image.height})")
    if args.preview:
        big = [(29, 35, 48), (232, 234, 237), (170, 190, 160)]
        small = image.resize((LOGICAL_W * 3, LOGICAL_H * 3), Image.LANCZOS)
        sheet = Image.new("RGBA", (image.width * 3 + small.width * 2 + 40, image.height), (255, 255, 255, 255))
        for i, bg in enumerate(big):
            tile = Image.new("RGBA", image.size, bg + (255,))
            tile.alpha_composite(image)
            sheet.alpha_composite(tile, (i * image.width, 0))
        for j, bg in enumerate(big[:2]):
            tile = Image.new("RGBA", small.size, bg + (255,))
            tile.alpha_composite(small)
            sheet.alpha_composite(tile, (image.width * 3 + 20 + j * small.width, 0))
        sheet.save(args.preview)
        print(f"preview {args.preview}")


if __name__ == "__main__":
    main()
