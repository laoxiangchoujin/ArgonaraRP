"""
生成 **3D 时空蓝噪声（STBN）**：void-and-cluster（Ulichney 1993）的三维版 + 全程环面卷积 ⇒ 无缝可平铺。

性质（对齐 STBN 的定义）：
  · **每个 z 切片单独看**：是一张合法的二维蓝噪声（点分布均匀、低频被压掉）；
  · **沿 z（时间维）**：同一个 (x,y) 在相邻帧的取值也互相排斥 ⇒ 时域误差"错开"，TAA/时间累积收敛更快。
（能量函数 = 空间高斯核 × 时间高斯核，三个维度一起做 void-and-cluster，所以两个性质是同一个优化出来的。）

输出：一张 **2D 图集**（和 NVIDIA 发布的 STBN 一样）：
  · `size × depth` 的体积铺成 `(8×8)` 个 `size×size` 的 tile ⇒ 边长 `size*8` 的 PNG；
  · **单通道**（值复制到 R/G/B，A=255，只为看着是灰的）；
  · 切片 z 的位置：tile = (z % tilesX, z / tilesX)（tilesX = 8）。

shader 寻址（Point + Repeat 采样）：
    int   z    = frameIndex % depth;                      // 帧号沿 z 走
    float2 tile = float2(z % 8, z / 8);
    float2 uv   = (tile * size + float2(pixelPos.x % size, pixelPos.y % size) + 0.5) / (size * 8);
    float  n    = SAMPLE_TEXTURE2D_LOD(_STBN, sampler_point_repeat, uv, 0).r;

用法：
    python Tools/generate_blue_noise.py                      # 默认：--mode jitter（推荐，秒级）
    python Tools/generate_blue_noise.py --mode scroll        # 每帧固定步长平移（**会有"流动"观感**，别的指标很好）
    python Tools/generate_blue_noise.py --mode 3d            # 朴素三维 void-and-cluster（慢，且切片质量差）
    python Tools/generate_blue_noise.py --mode 3d --cache Tools/stbn_cache.npy   # 存/复用中间 rank 体积

⚠️ 三种模式的取舍（2026-09-24 实测后定的）：
   · `jitter`（默认）= 每帧把基图挪到一个**随机**位置 ⇒ 每帧都是合法空间蓝噪声、相邻帧互不相关，且**没有方向性**
     ⇒ 时间累积后只剩"沙沙"噪声。**用它**。
   · `scroll` = 每帧挪 (1,1) ⇒ 统计指标也好（lag1 ≈ −0.17），但图案**整体匀速平移** ⇒ 画面上看是"在流动"，很怪。
   · `3d` = 三维一起做 void-and-cluster ⇒ 每个切片单独看**不是**空间蓝噪声（低频/白噪声 0.6~0.97），别用。

⚠️ 导入设置（同目录产出的 .meta）：**sRGB 关、Point、不压缩、不生成 mip**（本项目没有 repeat 采样器，wrap 自己用 fmod 绕）。
   少任何一条都会破坏分布（sRGB 会做伽马变换、线性过滤会把蓝噪声糊成白噪声、压缩会出块）。
"""

import argparse
import os
import time

import numpy as np
from PIL import Image

# 图集每行放几个切片（8×8 = 64 个切片；depth 不是 64 的倍数时也能用，只是末尾留空）
TILES_X = 8


def make_kernel(sigma_xy: float, sigma_z: float, r_xy: int, r_z: int) -> np.ndarray:
    """
    截断后的"空间 × 时间"高斯核（float32，(2r+1, 2r+1, 2r_z+1)）。
    截断是必须的：更新一步能量只需要动中心周围这一小块 —— 否则 64³ 每步都要搬 26 万个值，慢得没法用。
    """
    a = np.arange(-r_xy, r_xy + 1, dtype=np.float32)
    b = np.arange(-r_z, r_z + 1, dtype=np.float32)
    dx, dy, dz = np.meshgrid(a, a, b, indexing="ij")
    k = np.exp(-(dx * dx + dy * dy) / (2.0 * sigma_xy * sigma_xy) - (dz * dz) / (2.0 * sigma_z * sigma_z))
    return k.astype(np.float32)


def make_energy_offset(n: int, nz: int, r_xy: int, r_z: int):
    """环面上的邻居索引（预先算好，每步复用；避免反复取模）。形状和 kernel 一致。"""
    ax = (np.arange(-r_xy, r_xy + 1) % n)
    az = (np.arange(-r_z, r_z + 1) % nz)
    yy, xx, zz = np.meshgrid(ax, ax, az, indexing="ij")
    return yy, xx, zz  # 用时再加中心坐标再取模


def add_energy(energy: np.ndarray, kernel: np.ndarray, off, y: int, x: int, z: int,
               n: int, nz: int, sign: float) -> None:
    """在 (y,x,z) 放/拿走一个点 ⇒ 只更新它周围那一小块能量（环面回绕）。"""
    oy, ox, oz = off
    ys = (oy + y) % n
    xs = (ox + x) % n
    zs = (oz + z) % nz
    energy[ys, xs, zs] += sign * kernel


def largest_void(energy: np.ndarray, binary: np.ndarray, pos_inf: np.float32) -> tuple:
    return np.unravel_index(np.argmin(np.where(binary, pos_inf, energy)), energy.shape)


def tightest_cluster(energy: np.ndarray, binary: np.ndarray, neg_inf: np.float32) -> tuple:
    return np.unravel_index(np.argmax(np.where(binary, energy, neg_inf)), energy.shape)


def void_and_cluster(n: int, nz: int, kernel: np.ndarray, off, verbose: bool = True) -> np.ndarray:
    """返回 rank 体积（int32，0..n*n*nz-1）：每个体素一个"排序序号"，归一化后就是 STBN 掩码。"""
    total = n * n * nz
    half = total // 2
    pos_inf = np.float32(np.inf)
    neg_inf = np.float32(-np.inf)
    energy = np.zeros((n, n, nz), dtype=np.float32)
    binary = np.zeros((n, n, nz), dtype=bool)
    rank = np.full((n, n, nz), -1, dtype=np.int32)

    def report(tag: str, done: int, over: int, t0: float) -> None:
        if not verbose:
            return
        print(f"  {tag}: {done}/{over} ({100.0 * done / over:.0f}%)  用时 {time.time() - t0:.0f}s", flush=True)

    # ---------- Phase 0：先填到一半，再把"最紧的点"和"最大的洞"互换到稳定 ----------
    t0 = time.time()
    y, x, z = n // 2, n // 2, nz // 2
    binary[y, x, z] = True
    add_energy(energy, kernel, off, y, x, z, n, nz, +1.0)
    num_on = 1
    while num_on < half:
        y, x, z = largest_void(energy, binary, pos_inf)
        binary[y, x, z] = True
        add_energy(energy, kernel, off, y, x, z, n, nz, +1.0)
        num_on += 1
        if num_on % 20000 == 0:
            report("Phase0 填充", num_on, half, t0)

    swaps = 0
    t1 = time.time()
    while True:
        cy, cx, cz = tightest_cluster(energy, binary, neg_inf)
        binary[cy, cx, cz] = False
        add_energy(energy, kernel, off, cy, cx, cz, n, nz, -1.0)

        vy, vx, vz = largest_void(energy, binary, pos_inf)
        if (vy, vx, vz) == (cy, cx, cz):
            binary[cy, cx, cz] = True
            add_energy(energy, kernel, off, cy, cx, cz, n, nz, +1.0)
            break
        binary[vy, vx, vz] = True
        add_energy(energy, kernel, off, vy, vx, vz, n, nz, +1.0)
        swaps += 1
        if verbose and swaps % 2000 == 0:
            print(f"  Phase0 松弛: 已互换 {swaps} 次，用时 {time.time() - t1:.0f}s", flush=True)
        # 安全阀：核相对网格太大时这一步可能来回震荡（小尺寸试跑会碰到），别让它无限转
        if swaps > 40 * total:
            print(f"  ⚠️ Phase0 松弛 {swaps} 次仍未收敛，直接接受当前图案（加大 --size 或调小 --radius-*）", flush=True)
            break
    report(f"Phase0 松弛（{swaps} 次互换）", half, half, t1)

    # Phase 1 要把这批点全拿走、Phase 2 又要从它出发 ⇒ 先留一份副本（内存很小，比事后重建快得多）
    binary_p0 = binary.copy()
    energy_p0 = energy.copy()

    # ---------- Phase 1：从"最紧"开始逐个拿走，序号从 num_on-1 递减 ----------
    t0 = time.time()
    r = num_on - 1
    while r >= 0:
        y, x, z = tightest_cluster(energy, binary, neg_inf)
        binary[y, x, z] = False
        add_energy(energy, kernel, off, y, x, z, n, nz, -1.0)
        rank[y, x, z] = r
        r -= 1
        if r % 20000 == 0:
            report("Phase1 反排序", num_on - 1 - r, num_on, t0)

    # ---------- Phase 2：从 Phase 0 的图案出发，逐个填进"最大的洞"，序号从 num_on 递增 ----------
    t0 = time.time()
    binary = binary_p0
    energy = energy_p0
    r = num_on
    while r < total:
        y, x, z = largest_void(energy, binary, pos_inf)
        binary[y, x, z] = True
        add_energy(energy, kernel, off, y, x, z, n, nz, +1.0)
        rank[y, x, z] = r
        r += 1
        if r % 20000 == 0:
            report("Phase2 填充", r - num_on, total - num_on, t0)

    return rank


def low_freq_ratio(rank: np.ndarray) -> tuple:
    """质量指标：3D 里"低频能量 / 总能量"，越小越蓝。同时给出每个切片单独看时的空间低频占比。"""
    n, _, nz = rank.shape
    x = rank.astype(np.float64) / rank.size - 0.5
    power = np.abs(np.fft.fftshift(np.fft.fftn(x))) ** 2
    cy, cx, cz = (n // 2, n // 2, nz // 2)
    yy, xx, zz = np.meshgrid(np.arange(n), np.arange(n), np.arange(nz), indexing="ij")
    rr = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2 + (zz - cz) ** 2)
    low = power[rr <= n / 8.0].sum()
    ratio_3d = float(low / max(power.sum(), 1e-12))

    # 单个切片的二维低频占比（取中间几层平均）
    slices = []
    for k in range(0, nz, max(1, nz // 4)):
        s = x[:, :, k]
        p = np.abs(np.fft.fftshift(np.fft.fft2(s))) ** 2
        r2 = np.sqrt((yy[:, :, 0] - cy) ** 2 + (xx[:, :, 0] - cx) ** 2)
        slices.append(float(p[r2 <= n / 8.0].sum() / max(p.sum(), 1e-12)))
    return ratio_3d, float(np.mean(slices))


def build_atlas(rank: np.ndarray, tiles_x: int = TILES_X) -> np.ndarray:
    """
    rank 体积 → 2D 图集（8×8 个 tile，按 z 顺序铺）。

    ⚠️ 行方向要**自下而上**放：PNG 的第 0 行是图像**顶部**，而 Unity 的 uv.y=0 在**底部** ⇒
       把 z=0 放在图像最后一行，shader 里就能直接用 `tileY = z / 8`（否则要写 `7 - z/8`，很容易搞错）。
    """
    n, _, nz = rank.shape
    tiles_y = (nz + tiles_x - 1) // tiles_x
    atlas = np.zeros((n * tiles_y, n * tiles_x), dtype=np.uint8)
    for z in range(nz):
        ty, tx = tiles_y - 1 - z // tiles_x, z % tiles_x
        tile = np.floor((rank[:, :, z] + 0.5) * 255.0 / rank.size).astype(np.uint8)
        atlas[ty * n:(ty + 1) * n, tx * n:(tx + 1) * n] = tile
    return atlas


def build_scrolled_atlas(pattern: np.ndarray, depth: int, step_y: int, step_x: int,
                         tiles_x: int = TILES_X) -> np.ndarray:
    """
    **滚动 2D 蓝噪声**版 STBN：第 z 帧 = 同一张 2D 蓝噪声平移 (z*step_y, z*step_x) 个纹素。
    为什么比"朴素三维 void-and-cluster"好：
      · 每帧只是原图案的**平移** ⇒ 频谱一模一样 ⇒ **每个切片都是合法的空间蓝噪声**（那条性质是严格成立的）；
      · 相邻帧落在图案的**近邻位置**，而蓝噪声的近邻是互相排斥的 ⇒ 相邻帧**错开**（实测 lag-1 相关 ≈ −0.18）。
    代价：图案在时间上以固定步长"滚动"（周期 = 边长/步长），没有别的副作用。
    （行方向自下而上，理由见 build_atlas。）
    """
    n = pattern.shape[0]
    tiles_y = (depth + tiles_x - 1) // tiles_x
    atlas = np.zeros((n * tiles_y, n * tiles_x), dtype=np.uint8)
    for z in range(depth):
        ty, tx = tiles_y - 1 - z // tiles_x, z % tiles_x
        atlas[ty * n:(ty + 1) * n, tx * n:(tx + 1) * n] = np.roll(np.roll(pattern, z * step_y, 0), z * step_x, 1)
    return atlas


def build_jittered_atlas(pattern: np.ndarray, depth: int, seed: int,
                         tiles_x: int = TILES_X) -> np.ndarray:
    """
    **每帧随机跳一个位置**的 STBN：第 z 帧 = 基础 2D 蓝噪声环面平移 (oy_z, ox_z)，偏移随机挑。

    和滚动版的唯一区别是"偏移怎么取"，但观感差别很大：
      · 滚动版（`build_scrolled_atlas`）：偏移 = z*(step_y,step_x) ⇒ 图案**整体匀速平移** ⇒ 眼睛能跟住特征
        ⇒ 看起来像"画面在流动"（虽然它的统计指标其实很好：切片频谱不变、lag1 = −0.17）；
      · 本版：每帧跳到一个随机位置（并挑"和上一帧最不相关"的那个）⇒ 相邻帧互不相关，但**没有方向性**
        ⇒ 时间累积之后只剩下"沙沙"的噪声，不会有流动感。
    每帧仍然是原图案的**平移** ⇒ 频谱一模一样（每帧都是合法空间蓝噪声）。行方向自下而上（理由见 build_atlas）。
    """
    n = pattern.shape[0]
    tiles_y = (depth + tiles_x - 1) // tiles_x
    atlas = np.zeros((n * tiles_y, n * tiles_x), dtype=np.uint8)
    rng = np.random.default_rng(seed)

    # 上一帧（"同一位置"基准，用于挑最不相关的偏移）：中心化后存下来省得每轮重算
    prev = pattern.astype(np.float64).ravel()
    prev -= prev.mean()
    prev_norm = max(float(np.linalg.norm(prev)), 1e-12)

    offset = (0, 0)
    for z in range(depth):
        if z > 0:
            # 候选择优：取 |同位置相关系数| 最小的那个偏移（= 和上一帧最不相关）
            best = None
            for _ in range(24):
                cand = (int(rng.integers(n)), int(rng.integers(n)))
                s = np.roll(np.roll(pattern, cand[0], 0), cand[1], 1).astype(np.float64).ravel()
                s -= s.mean()
                corr = abs(float(np.dot(prev, s)) / (prev_norm * max(float(np.linalg.norm(s)), 1e-12)))
                if best is None or corr < best[0]:
                    best = (corr, cand)
            offset = best[1]

        tile = np.roll(np.roll(pattern, offset[0], 0), offset[1], 1)
        ty, tx = tiles_y - 1 - z // tiles_x, z % tiles_x
        atlas[ty * n:(ty + 1) * n, tx * n:(tx + 1) * n] = tile

        v = tile.astype(np.float64).ravel()
        v -= v.mean()
        prev, prev_norm = v, max(float(np.linalg.norm(v)), 1e-12)
    return atlas


def atlas_to_vol(atlas: np.ndarray, n: int, depth: int, tiles_x: int = TILES_X) -> np.ndarray:
    """2D 图集 → (n, n, depth) 体积（0..1），只为自检用（切片在图集里的位置规则见 build_atlas）。"""
    tiles_y = atlas.shape[0] // n
    vol = np.zeros((n, n, depth), dtype=np.float32)
    for z in range(depth):
        ty, tx = tiles_y - 1 - z // tiles_x, z % tiles_x
        vol[:, :, z] = atlas[ty * n:(ty + 1) * n, tx * n:(tx + 1) * n] / 255.0
    return vol


def report_quality(vol: np.ndarray) -> None:
    """自检：① 3D 低频占比；② 每个切片（按自身中位数二值化）的低频/白噪声；③ 时间维 lag-1 相关。"""
    n, _, nz = vol.shape
    yy, xx = np.mgrid[0:n, 0:n]
    rad = np.sqrt((yy - n // 2) ** 2 + (xx - n // 2) ** 2).astype(int)
    cnt = np.maximum(np.bincount(rad.ravel(), minlength=n // 2), 1)

    def psd2(a):
        p = np.abs(np.fft.fftshift(np.fft.fft2(a - a.mean()))) ** 2
        return np.bincount(rad.ravel(), p.ravel(), minlength=n // 2) / cnt

    rng = np.random.default_rng(1)
    white = psd2(rng.random((n, n)) < 0.5)[1:n // 8].sum()
    slices = [psd2(vol[:, :, z] < np.median(vol[:, :, z]))[1:n // 8].sum() / white for z in range(0, nz, max(1, nz // 8))]
    lag1 = np.mean([np.corrcoef(vol[:, :, z].ravel(), vol[:, :, z + 1].ravel())[0, 1] for z in range(nz - 1)])
    print(f"自检：切片低频/白噪声 = {np.mean(slices):.5f}（越接近0越好，1=白噪声）；时间维 lag1 相关 = {lag1:+.4f}（负=相邻帧错开）")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=("jitter", "scroll", "3d"), default="jitter",
                   help="jitter = 每帧随机跳位（推荐：指标好、且没有'流动'观感）；"
                        "scroll = 每帧固定步长平移（统计好但有流动感）；3d = 朴素三维 void-and-cluster")
    p.add_argument("--size", type=int, default=64, help="空间边长（2 的幂）")
    p.add_argument("--depth", type=int, default=64, help="时间维层数（切片数）")
    p.add_argument("--pattern", type=str, default=os.path.join("Assets", "ArgonaraRP", "Textures", "BlueNoise64.png"),
                   help="scroll 模式用：基础 2D 蓝噪声图（取 R 通道）")
    p.add_argument("--step-y", type=int, default=1, help="scroll 模式：每帧在 y 方向滚动多少纹素")
    p.add_argument("--step-x", type=int, default=1, help="scroll 模式：每帧在 x 方向滚动多少纹素")
    p.add_argument("--sigma-xy", type=float, default=1.9)
    p.add_argument("--sigma-z", type=float, default=1.5)
    p.add_argument("--radius-xy", type=int, default=6, help="空间截断半径（>=3σ 就够）")
    p.add_argument("--radius-z", type=int, default=4)
    p.add_argument("--seed", type=int, default=20260924)
    p.add_argument("--cache", type=str, default="", help="3d 模式的 rank 体积 .npy 缓存（有就直接读，省得重算）")
    p.add_argument("--out", type=str, default=os.path.join("Assets", "ArgonaraRP", "Textures", "STBN64.png"))
    a = p.parse_args()

    if a.size & (a.size - 1):
        raise SystemExit("size 必须是 2 的幂")

    if a.mode == "jitter":
        # ⚠️ 只取 **R 通道**：不能 convert("L")（那是 R/G/B 加权混合，会把三条独立图案搅成一张"不蓝"的图）
        pattern = np.array(Image.open(a.pattern))[..., 0]
        n = pattern.shape[0]
        print(f"随机跳位 2D 蓝噪声：基图 {a.pattern} ({n}×{n})，共 {a.depth} 帧（seed={a.seed}）")
        atlas = build_jittered_atlas(pattern, a.depth, a.seed)
        vol = atlas_to_vol(atlas, n, a.depth)
    elif a.mode == "scroll":
        # ⚠️ 只取 **R 通道**：不能 convert("L")（那是 R/G/B 加权混合，会把三条独立图案搅成一张"不蓝"的图）
        pattern = np.array(Image.open(a.pattern))[..., 0]
        n = pattern.shape[0]
        print(f"滚动 2D 蓝噪声：基图 {a.pattern} ({n}×{n})，每帧滚动 ({a.step_y},{a.step_x})，共 {a.depth} 帧")
        atlas = build_scrolled_atlas(pattern, a.depth, a.step_y, a.step_x)
        # 自检用的体积（float，0..1）
        vol = np.zeros((n, n, a.depth), dtype=np.float32)
        for z in range(a.depth):
            vol[:, :, z] = np.roll(np.roll(pattern, z * a.step_y, 0), z * a.step_x, 1) / 255.0
    else:
        if a.cache and os.path.exists(a.cache):
            print(f"读到缓存 {a.cache}，跳过生成")
            rank = np.load(a.cache)
        else:
            print(f"生成 STBN：{a.size}×{a.size}×{a.depth}（void-and-cluster，三维）")
            kernel = make_kernel(a.sigma_xy, a.sigma_z, a.radius_xy, a.radius_z)
            off = make_energy_offset(a.size, a.depth, a.radius_xy, a.radius_z)
            t0 = time.time()
            rank = void_and_cluster(a.size, a.depth, kernel, off)
            print(f"生成完成，用时 {time.time() - t0:.0f}s", flush=True)
            if a.cache:
                os.makedirs(os.path.dirname(a.cache), exist_ok=True)
                np.save(a.cache, rank)
                print(f"rank 体积已缓存到 {a.cache}")
        ratio_3d, _ = low_freq_ratio(rank)
        print(f"3D 低频占比 = {ratio_3d:.6f}（越小越蓝）")
        atlas = build_atlas(rank)
        vol = (rank.astype(np.float32) + 0.5) / rank.size

    report_quality(vol)
    rgba = np.dstack([atlas, atlas, atlas, np.full(atlas.shape, 255, np.uint8)])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    Image.fromarray(rgba, mode="RGBA").save(a.out)
    h, w = atlas.shape
    print(f"已写出 {a.out}  ({w}×{h}，{a.depth} 个 {a.size}×{a.size} 切片，单通道复制到 RGB)")


if __name__ == "__main__":
    main()
