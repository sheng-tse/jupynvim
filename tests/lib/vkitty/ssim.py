"""Structural similarity (Wang et al. 2004) of two images, the score the renderer is held to.

    ssim(a, b, mask=None, channels="luma") -> float    mean of the SSIM map (over the mask)
    ssim_map(a, b, channels="luma") -> float64 array   the map itself

The score is of the luma by default, so two colors of nearly the same luma score the same: a pixel
test that must tell a color from another (a wrong palette token) pairs it with an exact or
per-channel color check. channels="rgb" scores each of the R, G and B channels on its own and takes
the mean of the three maps, which does tell a hue apart from a hue of the same luma.

Conventions, the same as skimage.metrics.structural_similarity(gaussian_weights=True, sigma=1.5,
use_sample_covariance=False, data_range=255): luma 0.299 R + 0.587 G + 0.114 B in float64 (a 2-D
array is taken as luma already); a Gaussian window of sigma 1.5 over 11 taps (radius 5, normalized),
applied separably as a weighted sum of shifted slices; K1 0.01, K2 0.03, L 255; population
variances and covariance; the map is computed on the "valid" region, so the 5 px border of the
images is dropped and the map is (H - 10) x (W - 10). A mask is a boolean array of the map's shape.
"""
import numpy as np

SIGMA = 1.5
RADIUS = 5
K1 = 0.01
K2 = 0.03
DATA_RANGE = 255.0


def _weights():
    x = np.arange(-RADIUS, RADIUS + 1, dtype=np.float64)
    w = np.exp(-(x * x) / (2.0 * SIGMA * SIGMA))
    return w / w.sum()


_W = _weights()


def _luma(img):
    arr = np.asarray(img, dtype=np.float64)
    if arr.ndim == 3:
        if arr.shape[2] < 3:
            raise ValueError("an image needs 3 channels, got %d" % arr.shape[2])
        return 0.299 * arr[..., 0] + 0.587 * arr[..., 1] + 0.114 * arr[..., 2]
    if arr.ndim != 2:
        raise ValueError("an image is 2-D or 3-D, got shape %r" % (arr.shape,))
    return arr


def _blur(arr):
    """The valid Gaussian filter of a 2-D array: a weighted sum of shifted slices, rows then
    columns."""
    k = len(_W)
    rows = sum(_W[i] * arr[:, i:arr.shape[1] - k + 1 + i] for i in range(k))
    return sum(_W[i] * rows[i:rows.shape[0] - k + 1 + i, :] for i in range(k))


def _rgb_planes(img):
    arr = np.asarray(img, dtype=np.float64)
    if arr.ndim != 3 or arr.shape[2] < 3:
        raise ValueError("channels='rgb' needs a (H, W, 3) image, got shape %r" % (arr.shape,))
    return [arr[..., c] for c in range(3)]


def ssim_map(a, b, channels="luma"):
    """The SSIM map of two images of the same shape, on the valid region. channels is "luma" (the
    luma of each image) or "rgb" (the mean of the maps of the three color channels)."""
    if channels == "rgb":
        maps = [_ssim_plane(x, y) for x, y in zip(_rgb_planes(a), _rgb_planes(b))]
        return (maps[0] + maps[1] + maps[2]) / 3.0
    if channels != "luma":
        raise ValueError("channels is 'luma' or 'rgb', not %r" % (channels,))
    return _ssim_plane(_luma(a), _luma(b))


def _ssim_plane(x, y):
    """The SSIM map of two 2-D float planes."""
    if x.shape != y.shape:
        raise ValueError("shapes differ: %r and %r" % (x.shape, y.shape))
    if min(x.shape) <= 2 * RADIUS:
        raise ValueError("the images are too small for the window: %r" % (x.shape,))
    c1 = (K1 * DATA_RANGE) ** 2
    c2 = (K2 * DATA_RANGE) ** 2
    mu_x = _blur(x)
    mu_y = _blur(y)
    var_x = _blur(x * x) - mu_x * mu_x
    var_y = _blur(y * y) - mu_y * mu_y
    cov = _blur(x * y) - mu_x * mu_y
    num = (2.0 * mu_x * mu_y + c1) * (2.0 * cov + c2)
    den = (mu_x * mu_x + mu_y * mu_y + c1) * (var_x + var_y + c2)
    return num / den


def ssim(a, b, mask=None, channels="luma"):
    """The mean SSIM of a and b; with a mask (a boolean array of the map's shape) the mean over the
    positions it selects."""
    m = ssim_map(a, b, channels)
    if mask is not None:
        mask = np.asarray(mask, dtype=bool)
        if mask.shape != m.shape:
            raise ValueError("mask shape %r is not the map's %r" % (mask.shape, m.shape))
        if not mask.any():
            raise ValueError("the mask selects no position")
        m = m[mask]
    return float(m.mean())
