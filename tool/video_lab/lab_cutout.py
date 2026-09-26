"""Subject cut-outs for the video lab.

The app will use Apple's Vision foreground-instance masks (people, animals and
objects). For look development on Windows the lab separates the subject by
relative depth (Depth Anything V2 Small, already cached locally): the nearest
coherent layer is kept, with a threshold that grows towards the bottom of the
frame so the ground in front of an animal is not taken for the animal.
Masks are cached next to the clips as mask_s{i}.npy.
"""

import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

MASK_W, MASK_H = 288, 512
MODEL = "depth-anything/Depth-Anything-V2-Small-hf"


def _otsu(values):
    hist = np.bincount(values.ravel(), minlength=256).astype(float)
    w = np.cumsum(hist)
    mu = np.cumsum(hist * np.arange(256))
    var = (mu[-1] * w - mu * w[-1]) ** 2 / (w * (w[-1] - w) + 1e-9)
    return int(np.argmax(var))


def compute_masks(frames):
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    import torch
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation
    proc = AutoImageProcessor.from_pretrained(MODEL)
    model = AutoModelForDepthEstimation.from_pretrained(MODEL).eval()
    rows = (np.arange(MASK_H)[:, None] / MASK_H) ** 2
    masks = []
    with torch.no_grad():
        for frame in frames:
            im = frame.convert("RGB").resize((MASK_W, MASK_H))
            d = model(**proc(images=im, return_tensors="pt")).predicted_depth[0].numpy()
            d = (d - d.min()) / (np.ptp(d) + 1e-6)
            d = np.asarray(Image.fromarray((d * 255).astype(np.uint8)).resize((MASK_W, MASK_H)), np.float32)
            th = _otsu(d.astype(np.uint8))
            masks.append(((d > th + 45 * rows) * 255).astype(np.uint8))
    masks = np.stack(masks)
    # temporal median of three frames steadies flicker at the edges
    smooth = np.median(np.stack([np.roll(masks, 1, 0), masks, np.roll(masks, -1, 0)]), axis=0).astype(np.uint8)
    out = []
    for m in smooth:
        img = Image.fromarray(m).filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5))
        out.append(np.asarray(img.filter(ImageFilter.GaussianBlur(1.5))))
    return np.stack(out)


def attach_masks(sources, src_dir):
    for i, src in enumerate(sources):
        cache = Path(src_dir) / f"mask_s{i}.npy"
        if cache.exists():
            masks = np.load(cache)
        else:
            masks = compute_masks(src.frames)
            np.save(cache, masks)
        src.masks = [Image.fromarray(m) for m in masks]
        src.has_subject = has_subject(masks)


def has_subject(masks):
    """True when the kept layer looks like a figure rather than ground or nothing:
    it covers 5-90% of the frame (close-ups are big) and is not a wide band hugging the bottom."""
    votes = []
    for m in masks[::6]:
        on = m > 96
        cover = on.mean()
        rows = np.where(on.any(axis=1))[0]
        cols = np.where(on.any(axis=0))[0]
        if not len(rows):
            votes.append(False)
            continue
        height = (rows[-1] - rows[0]) / m.shape[0]
        width = (cols[-1] - cols[0]) / m.shape[1]
        ground = rows[-1] > m.shape[0] * 0.95 and width > 0.9 and height < 0.5
        votes.append(0.05 < cover < 0.9 and not ground)
    return float(np.mean(votes)) >= 0.5
