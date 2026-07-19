import numpy as np
import torch


def _hex_to_rgb(h):
    h = h.lstrip("#")
    if len(h) != 6:
        return (255, 255, 255)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _make_frame(W, H, style, frame_width, bevel, tint_hex):
    """Return an RGB uint8 array (H, W, 3) and an alpha (H, W) for the frame band.
    Alpha is 1 inside the frame band, 0 in the inner image hole."""
    out = np.zeros((H, W, 3), dtype=np.float32)
    alpha = np.zeros((H, W), dtype=np.float32)

    fw = max(0, int(frame_width))
    if fw == 0 or style == "none":
        return out.astype(np.uint8), alpha

    # Distance from nearest edge (0 at edge, grows inward).
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.minimum(np.minimum(xx, yy), np.minimum(W - 1 - xx, H - 1 - yy))
    band = d < fw
    alpha[band] = 1.0

    # t: 0 at outer edge, 1 at inner edge of frame band
    t = np.clip(d / max(fw - 1, 1), 0.0, 1.0)

    # Multi-stop ramp for a realistic molded profile (outer rim → highlight → mid → inner rim).
    # ramp goes 0..1..0 across the band so we get rim shadows at both edges.
    rim = np.minimum(t, 1.0 - t) * 2.0  # 0 at edges, 1 at middle of band
    rim = np.clip(rim, 0.0, 1.0)
    # Profile shading: dark at outer rim, bright lobe near outer 1/3, mid, dark at inner rim.
    profile = (
        0.55 * (1.0 - np.cos(np.pi * t)) * 0.5  # smooth ramp
        + 0.65 * np.exp(-((t - 0.25) ** 2) / 0.015)  # bright outer ridge
        + 0.25 * np.exp(-((t - 0.7) ** 2) / 0.04)   # secondary ridge
    )
    profile = np.clip(profile * rim ** 0.4, 0.0, 1.5)

    if style == "gold":
        dark = np.array([90, 55, 10], dtype=np.float32)
        mid  = np.array([200, 150, 30], dtype=np.float32)
        hi   = np.array([255, 233, 150], dtype=np.float32)
    elif style == "silver":
        dark = np.array([70, 72, 78], dtype=np.float32)
        mid  = np.array([170, 173, 180], dtype=np.float32)
        hi   = np.array([245, 247, 250], dtype=np.float32)
    elif style == "wood":
        dark = np.array([45, 22, 8], dtype=np.float32)
        mid  = np.array([120, 65, 25], dtype=np.float32)
        hi   = np.array([190, 125, 65], dtype=np.float32)
    else:
        dark = np.array([60, 60, 60], dtype=np.float32)
        mid  = np.array([140, 140, 140], dtype=np.float32)
        hi   = np.array([220, 220, 220], dtype=np.float32)

    p = np.clip(profile, 0.0, 1.0)[..., None]
    p2 = np.clip(profile - 1.0, 0.0, 1.0)[..., None]
    base = dark[None, None, :] * (1.0 - p) + mid[None, None, :] * p
    base = base + (hi[None, None, :] - mid[None, None, :]) * p2

    # Wood grain: layered sin + perpendicular streaks per side
    if style == "wood":
        # Determine which side this pixel belongs to (so grain runs along the long axis of each rail)
        top = yy
        left = xx
        bottom = H - 1 - yy
        right = W - 1 - xx
        side = np.argmin(np.stack([top, left, bottom, right], axis=-1), axis=-1)
        # along-axis coord: x for top/bottom, y for left/right
        along = np.where((side == 0) | (side == 2), xx, yy)
        across = d
        grain = (
            0.55
            + 0.22 * np.sin(along * 0.06 + np.sin(across * 0.4) * 1.5)
            + 0.18 * np.sin(along * 0.013 + 1.7)
            + 0.10 * np.sin(along * 0.31 + across * 0.2)
        )
        grain = np.clip(grain, 0.35, 1.15)
        base = base * grain[..., None]

    # Brushed metal micro-noise for silver/gold
    if style in ("silver", "gold"):
        micro = 1.0 + 0.04 * np.sin(yy * 1.7 + xx * 0.13) + 0.03 * np.sin(xx * 2.3)
        base = base * micro[..., None]

    # Directional bevel: light from top-left.
    if bevel > 0:
        top = yy
        left = xx
        bottom = H - 1 - yy
        right = W - 1 - xx
        idx = np.argmin(np.stack([top, left, bottom, right], axis=-1), axis=-1)
        light = np.zeros_like(t)
        light[(idx == 0) | (idx == 1)] = 1.0
        light[(idx == 2) | (idx == 3)] = -1.0
        bevel_strength = (1.0 - t) * float(bevel)
        adj = light * bevel_strength * 55.0
        base = base + adj[..., None]

    # Inner & outer dark rim lines for depth
    rim_dark = np.exp(-(d ** 2) / 2.0) + np.exp(-((fw - 1 - d) ** 2) / 2.0)
    base = base - rim_dark[..., None] * 50.0

    # Tint multiply
    tint = np.array(_hex_to_rgb(tint_hex), dtype=np.float32) / 255.0
    base = base * tint[None, None, :]

    base = np.clip(base, 0, 255)
    out[band] = base[band]
    return out.astype(np.uint8), alpha


def _round_corners(alpha_full, radius):
    if radius <= 0:
        return alpha_full
    H, W = alpha_full.shape
    r = min(radius, min(H, W) // 2)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    # signed distance to rounded rect
    cx = np.clip(xx, r, W - 1 - r)
    cy = np.clip(yy, r, H - 1 - r)
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    mask = (dist <= r).astype(np.float32)
    return alpha_full * mask


class PixaCoolFrames:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image": ("IMAGE",),
                "frame_style": (["none", "wood", "gold", "silver"], {"default": "gold"}),
                "frame_width": ("INT", {"default": 40, "min": 0, "max": 1024, "step": 1}),
                "inner_padding": ("INT", {"default": 0, "min": 0, "max": 512, "step": 1}),
                "corner_radius": ("INT", {"default": 0, "min": 0, "max": 1024, "step": 1}),
                "bevel": ("FLOAT", {"default": 0.5, "min": 0.0, "max": 1.0, "step": 0.05}),
                "tint": ("STRING", {"default": "#ffffff"}),
            },
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "apply"
    CATEGORY = "PixaTools/Image"

    def apply(self, image, frame_style, frame_width, inner_padding, corner_radius, bevel, tint):
        # image: (B, H, W, C) float in [0,1]
        out_batch = []
        for img in image:
            arr = (img.cpu().numpy() * 255.0).clip(0, 255).astype(np.uint8)
            H, W, C = arr.shape
            pad = int(inner_padding)
            fw = int(frame_width)
            total = fw + pad
            new_H = H + 2 * total
            new_W = W + 2 * total

            # Background: matted with inner color (use frame inner color for padding band)
            canvas = np.zeros((new_H, new_W, 3), dtype=np.uint8)

            # Place image in the middle
            canvas[total:total + H, total:total + W] = arr[..., :3]

            # Inner padding band fill (use a neutral matte = darkest of frame)
            if pad > 0:
                matte = (20, 20, 20)
                # top/bottom
                canvas[fw:fw + pad, fw:new_W - fw] = matte
                canvas[new_H - fw - pad:new_H - fw, fw:new_W - fw] = matte
                # left/right
                canvas[fw:new_H - fw, fw:fw + pad] = matte
                canvas[fw:new_H - fw, new_W - fw - pad:new_W - fw] = matte

            frame_rgb, frame_alpha = _make_frame(new_W, new_H, frame_style, fw, bevel, tint)
            a = frame_alpha[..., None]
            canvas = (canvas.astype(np.float32) * (1.0 - a) + frame_rgb.astype(np.float32) * a).astype(np.uint8)

            # Rounded corners (outside becomes black; alpha not in IMAGE type)
            if corner_radius > 0:
                full_alpha = np.ones((new_H, new_W), dtype=np.float32)
                full_alpha = _round_corners(full_alpha, int(corner_radius))
                canvas = (canvas.astype(np.float32) * full_alpha[..., None]).astype(np.uint8)

            t = torch.from_numpy(canvas.astype(np.float32) / 255.0)
            out_batch.append(t)

        # Pad to same size if needed (all same since deterministic)
        result = torch.stack(out_batch, dim=0)
        return (result,)
