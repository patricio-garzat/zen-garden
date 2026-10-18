#!/usr/bin/env python3
"""Provisional app icon: raked ripples around a stone, lit like the in-game sand.
Usage: python3 tools/make-icon.py  (writes ZenGarden/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png)"""
import numpy as np
from PIL import Image
from pathlib import Path

N = 1024
y, x = np.mgrid[0:N, 0:N].astype(np.float32) / N - 0.5
cx, cy = 0.04, 0.02
rx, ry = 0.17, 0.125
d = np.sqrt(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2)          # 1 at the stone edge
r = (d - 1.0) * 0.15                                               # distance outside, roughly
spacing = 0.045
h = 0.012 * np.cos(2 * np.pi * r / spacing)
h *= np.clip((r + 0.01) / 0.02, 0, 1)
# Straight raked lines far from the stone
far = np.clip((r - 0.22) / 0.05, 0, 1)
lines = 0.012 * np.cos(2 * np.pi * (y + 0.5) / spacing)
h = h * (1 - far) + lines * far
rng = np.random.default_rng(3)
h += rng.normal(0, 0.0006, h.shape)

gy, gx = np.gradient(h, 1.0 / N)
n = np.stack([-gx, -gy, np.ones_like(h)], -1)
n /= np.linalg.norm(n, axis=-1, keepdims=True)
L = np.array([-0.6, -0.55, 0.58]); L /= np.linalg.norm(L)        # image y points down
ndl = np.clip((n @ L + 0.12) / 1.12, 0, 1)
albedo = np.array([0.80, 0.74, 0.63])
sun = np.array([0.80, 0.74, 0.64]); sky = np.array([0.34, 0.36, 0.40])
col = albedo * (sun * ndl[..., None] + sky)

# Stone shadow + stone
sh = np.sqrt(((x - cx - 0.045) / (rx * 1.05)) ** 2 + ((y - cy - 0.04) / (ry * 1.05)) ** 2)
col *= (1 - 0.55 * np.clip(1.15 - sh, 0, 1) ** 0.8)[..., None]
inside = d < 1.0
sz = np.sqrt(np.clip(1 - d ** 2, 0, 1))
sn = np.stack([(x - cx) / rx * 0.8, (y - cy) / ry * 0.8, sz + 0.3], -1)
sn /= np.linalg.norm(sn, axis=-1, keepdims=True)
sl = np.clip(sn @ L, 0, 1)
stone = np.array([0.20, 0.19, 0.18]) * (0.25 + 1.1 * sl[..., None]) + np.array([0.06, 0.06, 0.06]) * sz[..., None]
col = np.where(inside[..., None], stone, col)

srgb = np.where(col <= 0.0031308, col * 12.92, 1.055 * np.power(np.clip(col, 0, None), 1 / 2.4) - 0.055)
img = Image.fromarray((np.clip(srgb, 0, 1) * 255).astype(np.uint8), "RGB")
out = Path(__file__).resolve().parent.parent / "ZenGarden/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
img.save(out)
print(out)
