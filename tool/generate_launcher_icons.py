#!/usr/bin/env python3
"""生成 cfbrowser 的启动器图标（Claude 美学 · Warm Orb）。

设计：
- 经典：暖纸/深墨底 + 陶土色球体 + 墨色/奶油色轨道；
- 现代：同几何，球体换成墨色（浅色底）/奶油色（深色底），轨道改为陶土色。

几何基准（2026-11-09，按用户给的定稿参照图 1:1 量出来的，1024 视口 = 图标边长）：
- 球 R=223（直径占图标 43.5%），球心居中；
- 轨道中心线 374×136、线宽 16、倾角 -22°，外沿包围盒宽 716.6 = 图标的 70%；
- 轨道点 r=19，圆心落在轨道中心线上（参数角 -18°）；
- 投影是球底下方一颗独立的椭圆柔影（rx 214 / ry 56 / 球心下 268）。
参照图里点的圆心偏在轨道线内侧约 10 单位（看着像浮在环内圈上），这里改成正好压线。

层次：
- 轨道分前后两半：后半圈先画在球体之下（被球体挡住），前半圈补在球体之上。
  整圈压在球上会失去前后关系；后半圈整段藏起来又会让环读成一道斜杠 —— 只有在
  环足够松（外沿 1.71×球半径）时，这种「挡一半」的做法才成立，所以环/球比例不能随便收紧。

输出：
- Android 旧版 mipmap PNG（日/夜、两套风格、5 个密度）
- Android 自适应图标：渐变背景、前景（日/夜）、单色
- 设置页预览 PNG（4 张 256px）
- Windows .ico
- tool/launcher_icon/*.svg 设计源文件

依赖：cairosvg、Pillow。用法：python3 tool/generate_launcher_icons.py
"""

from __future__ import annotations

import math
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
SVG_DIR = ROOT / "tool/launcher_icon"

PAPER_HI = "#FCF8F0"
PAPER_LO = "#E7DED0"
DARK_HI = "#2B2521"
DARK_LO = "#191614"
INK = "#262320"
CREAM = "#F4EFE5"
TERRA = "#D97757"
TERRA_DEEP = "#B8553B"

# ── 几何（1024 视口；自适应层可见区 = 中央 72/108 = 682.7 单位）──────────
SPHERE_R = 223.0
ORBIT_RX = 374.0          # 中心线半长轴
ORBIT_RY = 136.0          # 中心线半短轴
ORBIT_W = 16.0            # 线宽
ORBIT_TILT = 22.0         # 实际旋转 -ORBIT_TILT
RING_ALPHA = 0.80         # 参照图里环压在暖纸底上实测 ≈ (79,76,72)
DOT_R = 20.0
DOT_ANGLE = -18.0         # 轨道参数角（局部系），圆心压在轨道中心线上
DOT_ALPHA = 0.95

# 投影：球底下方一颗独立椭圆柔影（用「圆 + 径向渐变 + 纵向压扁」实现，
# 矢量图没有模糊，直接画椭圆渐变会在上下边缘留硬边）
SHADOW_ALPHA_LIGHT = 0.14
SHADOW_ALPHA_DARK = 0.22
SHADOW_RX = 248.0
SHADOW_RY = 76.0
SHADOW_CY = 815.0

# 球体径向渐变与高光：全部按球半径取比例，换半径时两者不会脱节
ORB_GRAD_CX = 512 - 0.40 * SPHERE_R
ORB_GRAD_CY = 512 - 0.48 * SPHERE_R
ORB_GRAD_R = 1.60 * SPHERE_R
HL_CX = 512 - 0.353 * SPHERE_R
HL_CY = 512 - 0.397 * SPHERE_R
HL_RX = 0.310 * SPHERE_R
HL_RY = 0.181 * SPHERE_R
HL_TILT = 30.0


def _circle(cx: float, cy: float, r: float) -> str:
    return f"M{cx - r:g} {cy:g} a{r:g} {r:g} 0 1 0 {2 * r:g} 0 a{r:g} {r:g} 0 1 0 {-2 * r:g} 0 Z"


def _ellipse(cx: float, cy: float, rx: float, ry: float) -> str:
    return f"M{cx - rx:g} {cy:g} a{rx:g} {ry:g} 0 1 0 {2 * rx:g} 0 a{rx:g} {ry:g} 0 1 0 {-2 * rx:g} 0 Z"


SPHERE = _circle(512, 512, SPHERE_R)
RING = _ellipse(512, 512, ORBIT_RX, ORBIT_RY)
SHADOW = _circle(512, SHADOW_CY, SHADOW_RX)
HIGHLIGHT = _ellipse(HL_CX, HL_CY, HL_RX, HL_RY)
# 轨道点的局部坐标：椭圆参数角，圆心正好落在轨道中心线上
DOT_CX = 512 + ORBIT_RX * math.cos(math.radians(DOT_ANGLE))
DOT_CY = 512 + ORBIT_RY * math.sin(math.radians(DOT_ANGLE))
DOT = _circle(DOT_CX, DOT_CY, DOT_R)

# 轨道前后半圈：局部坐标系里以长轴（y = 512）对半分
HALF_BACK = "M0 0 H1024 V512 H0 Z"
HALF_FRONT = "M0 512 H1024 V1024 H0 Z"
SHADOW_SQUASH = SHADOW_RY / SHADOW_RX

ORB_GRADIENTS = {
    "terra": [("0", "#EF9B78"), ("0.55", TERRA), ("1", TERRA_DEEP)],
    "ink": [("0", "#4A423B"), ("0.55", "#2A2521"), ("1", "#171412")],
    "cream": [("0", "#FFFDF8"), ("0.55", "#F1E8D9"), ("1", "#D8CAB6")],
}


# ── 标记占比 ────────────────────────────────────────────────────────────
# 标记 = 球 + 轨道（含线宽）+ 轨道点，不含底板、不含投影。
# 口径：标记 bbox 宽度 ÷ 可见区宽度。
#   传统图标：整张 1024 就是可见区；
#   自适应图标：可见区是中央 72/108，即 1024 × 72/108 = 682.7 单位。
# 0.70 是定稿参照图实测值（轨道外沿 716.6 / 1024），到这个数 LEGACY_SCALE 正好 = 1.0。
MARK_RATIO = 0.70


def _mark_bbox_w() -> float:
    """旋转后轨道外沿（含线宽）的包围盒宽度。"""
    t = math.radians(ORBIT_TILT)
    hw = math.hypot(
        (ORBIT_RX + ORBIT_W / 2) * math.cos(t),
        (ORBIT_RY + ORBIT_W / 2) * math.sin(t),
    )
    return 2 * hw


MARK_BBOX_W = _mark_bbox_w()
LEGACY_SCALE = round(MARK_RATIO * 1024 / MARK_BBOX_W, 4)
FG_SCALE = round(MARK_RATIO * (1024 * 72 / 108) / MARK_BBOX_W, 4)

MIPMAP_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def _stops(stops: list[tuple[str, str]]) -> str:
    return "".join(
        f'<stop offset="{offset}" stop-color="{color}"/>' for offset, color in stops
    )


def _halves_clip_svg(prefix: str) -> str:
    return (
        f'    <clipPath id="{prefix}back"><path d="{HALF_BACK}"/></clipPath>\n'
        f'    <clipPath id="{prefix}front"><path d="{HALF_FRONT}"/></clipPath>\n'
    )


def _orbit_svg(orbit: str) -> str:
    half = (
        f'<ellipse cx="512" cy="512" rx="{ORBIT_RX:g}" ry="{ORBIT_RY:g}" fill="none" '
        f'stroke="{orbit}" stroke-width="{ORBIT_W:g}" opacity="{RING_ALPHA}"/>'
    )
    return (
        f'    <g transform="rotate(-{ORBIT_TILT:g} 512 512)">'
        f'<g clip-path="url(#lc-back)">{half}</g></g>\n'
        f'    <circle cx="512" cy="512" r="{SPHERE_R:g}" fill="url(#orb)"/>\n'
        f'    <g transform="rotate(-{ORBIT_TILT:g} 512 512)">'
        f'<g clip-path="url(#lc-front)">{half}</g></g>\n'
        f'    <g transform="rotate(-{ORBIT_TILT:g} 512 512)">'
        f'<circle cx="{DOT_CX:g}" cy="{DOT_CY:g}" r="{DOT_R:g}" fill="{orbit}" '
        f'opacity="{DOT_ALPHA}"/></g>\n'
    )


def svg(light: bool, orb: str, orbit: str, mark_scale: float = LEGACY_SCALE) -> str:
    """旧版/桌面用整张图标（含底板）。"""
    bg_hi, bg_lo = (PAPER_HI, PAPER_LO) if light else (DARK_HI, DARK_LO)
    glow = "0.75" if light else "0.10"
    shadow = SHADOW_ALPHA_LIGHT if light else SHADOW_ALPHA_DARK
    return f'''<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{bg_hi}"/><stop offset="1" stop-color="{bg_lo}"/>
    </linearGradient>
    <radialGradient id="glow" cx="32%" cy="20%" r="80%">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="{glow}"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="orb" gradientUnits="userSpaceOnUse"
        cx="{ORB_GRAD_CX:g}" cy="{ORB_GRAD_CY:g}" r="{ORB_GRAD_R:g}">
      {_stops(ORB_GRADIENTS[orb])}
    </radialGradient>
    <radialGradient id="contact" gradientUnits="userSpaceOnUse"
        cx="512" cy="{SHADOW_CY:g}" r="{SHADOW_RX:g}">
      <stop offset="0" stop-color="#000000" stop-opacity="{shadow}"/>
      <stop offset="0.55" stop-color="#000000" stop-opacity="{shadow * 0.8:.3f}"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0"/>
    </radialGradient>
{_halves_clip_svg("lc-")}  </defs>
  <rect width="1024" height="1024" rx="228" fill="url(#bg)"/>
  <rect width="1024" height="1024" rx="228" fill="url(#glow)"/>
  <g transform="translate(512 512) scale({mark_scale}) translate(-512 -512)">
    <g transform="translate(512 {SHADOW_CY:g}) scale(1 {SHADOW_SQUASH:g}) translate(-512 -{SHADOW_CY:g})">
      <circle cx="512" cy="{SHADOW_CY:g}" r="{SHADOW_RX:g}" fill="url(#contact)"/>
    </g>
{_orbit_svg(orbit)}    <ellipse cx="{HL_CX:g}" cy="{HL_CY:g}" rx="{HL_RX:g}" ry="{HL_RY:g}" fill="#FFFFFF" opacity="0.18" transform="rotate(-{HL_TILT:g} {HL_CX:g} {HL_CY:g})"/>
  </g>
</svg>
'''


def _gradient_attr(stops: list[tuple[str, str]]) -> str:
    items = "".join(
        f'                    <item android:offset="{offset}" android:color="{color}"/>\n'
        for offset, color in stops
    )
    return f'''            <aapt:attr name="android:fillColor">
                <gradient
                    android:type="radial"
                    android:centerX="{ORB_GRAD_CX:g}"
                    android:centerY="{ORB_GRAD_CY:g}"
                    android:gradientRadius="{ORB_GRAD_R:g}">
{items}                </gradient>
            </aapt:attr>'''


def _ring_path(orbit: str, alpha: float) -> str:
    return f'''            <path
                android:fillColor="#00000000"
                android:strokeColor="{orbit}"
                android:strokeWidth="{ORBIT_W:g}"
                android:strokeAlpha="{alpha:g}"
                android:pathData="{RING}" />'''


def _shadow_xml(shadow_alpha: float, indent: str = "        ") -> str:
    return f'''{indent}<!-- 球体下方的独立柔影：圆 + 径向渐变 + 纵向压扁，避免椭圆渐变的硬边 -->
{indent}<group
{indent}    android:pivotX="512"
{indent}    android:pivotY="{SHADOW_CY:g}"
{indent}    android:scaleY="{SHADOW_SQUASH:g}">
{indent}    <path android:pathData="{SHADOW}">
{indent}        <aapt:attr name="android:fillColor">
{indent}            <gradient
{indent}                android:type="radial"
{indent}                android:centerX="512"
{indent}                android:centerY="{SHADOW_CY:g}"
{indent}                android:gradientRadius="{SHADOW_RX:g}">
{indent}                <item android:offset="0" android:color="#{int(shadow_alpha * 255):02X}000000"/>
{indent}                <item android:offset="0.55" android:color="#{int(shadow_alpha * 0.8 * 255):02X}000000"/>
{indent}                <item android:offset="1" android:color="#00000000"/>
{indent}            </gradient>
{indent}        </aapt:attr>
{indent}    </path>
{indent}</group>'''


def _orbit_xml(orbit: str, orb: str, indent: str = "        ") -> str:
    return f'''{indent}<!-- 轨道后半圈：先画，被球体挡住 -->
{indent}<group
{indent}    android:rotation="-{ORBIT_TILT:g}"
{indent}    android:pivotX="512"
{indent}    android:pivotY="512">
{indent}    <clip-path android:pathData="{HALF_BACK}" />
{_ring_path(orbit, RING_ALPHA)}
{indent}</group>

{indent}<!-- 球体 -->
{indent}<path android:pathData="{SPHERE}">
{_gradient_attr(ORB_GRADIENTS[orb])}
{indent}</path>

{indent}<!-- 轨道前半圈：补回球体之上 -->
{indent}<group
{indent}    android:rotation="-{ORBIT_TILT:g}"
{indent}    android:pivotX="512"
{indent}    android:pivotY="512">
{indent}    <clip-path android:pathData="{HALF_FRONT}" />
{_ring_path(orbit, RING_ALPHA)}
{indent}</group>

{indent}<!-- 轨道点：圆心压在轨道中心线上 -->
{indent}<group
{indent}    android:rotation="-{ORBIT_TILT:g}"
{indent}    android:pivotX="512"
{indent}    android:pivotY="512">
{indent}    <path
{indent}        android:fillColor="{orbit}"
{indent}        android:fillAlpha="{DOT_ALPHA}"
{indent}        android:pathData="{DOT}" />
{indent}</group>'''


def foreground(orb: str, orbit: str, shadow_alpha: float) -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">

    <!-- 自适应前景：标记占可见区 {round(MARK_RATIO * 100)}%（1024 视口 → 108dp 画布，可见区 = 中央 72dp） -->
    <group
        android:scaleX="{FG_SCALE}"
        android:scaleY="{FG_SCALE}"
        android:pivotX="512"
        android:pivotY="512">

{_shadow_xml(shadow_alpha)}

{_orbit_xml(orbit, orb)}

        <!-- 球体高光 -->
        <group
            android:rotation="-{HL_TILT:g}"
            android:pivotX="{HL_CX:g}"
            android:pivotY="{HL_CY:g}">
            <path
                android:fillColor="#FFFFFF"
                android:fillAlpha="0.18"
                android:pathData="{HIGHLIGHT}" />
        </group>
    </group>
</vector>
'''


def monochrome() -> str:
    # 单色不表达前后关系，轨道整圈压在最上层
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">

    <group
        android:scaleX="{FG_SCALE}"
        android:scaleY="{FG_SCALE}"
        android:pivotX="512"
        android:pivotY="512">
        <path
            android:fillColor="#FFFFFF"
            android:fillAlpha="0.32"
            android:pathData="{SPHERE}" />
        <group
            android:rotation="-{ORBIT_TILT:g}"
            android:pivotX="512"
            android:pivotY="512">
{_ring_path("#FFFFFF", 1.0)}
            <path
                android:fillColor="#FFFFFF"
                android:fillAlpha="{DOT_ALPHA}"
                android:pathData="{DOT}" />
        </group>
        <group
            android:rotation="-{HL_TILT:g}"
            android:pivotX="{HL_CX:g}"
            android:pivotY="{HL_CY:g}">
            <path
                android:fillColor="#FFFFFF"
                android:fillAlpha="0.15"
                android:pathData="{HIGHLIGHT}" />
        </group>
    </group>
</vector>
'''


def background(light: bool) -> str:
    hi, lo = (PAPER_HI, PAPER_LO) if light else (DARK_HI, DARK_LO)
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">
    <path android:pathData="M0 0 H1024 V1024 H0 Z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="1024"
                android:endY="1024">
                <item android:offset="0" android:color="{hi}"/>
                <item android:offset="1" android:color="{lo}"/>
            </gradient>
        </aapt:attr>
    </path>
</vector>
'''


def adaptive(foreground_name: str) -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/{foreground_name}" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
'''


def render(svg_path: Path, out_path: Path, size: int) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        url=str(svg_path),
        write_to=str(out_path),
        output_width=size,
        output_height=size,
    )


def write_assets() -> dict[str, Path]:
    variants = {
        "classic_light": svg(True, "terra", INK),
        "classic_dark": svg(False, "terra", CREAM),
        "modern_light": svg(True, "ink", TERRA),
        "modern_dark": svg(False, "cream", TERRA),
    }
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    paths: dict[str, Path] = {}
    for name, content in variants.items():
        path = SVG_DIR / f"{name}.svg"
        path.write_text(content, encoding="utf-8")
        paths[name] = path
    return paths


def write_drawables() -> None:
    drawable = RES / "drawable"
    night = RES / "drawable-night"
    drawable.mkdir(parents=True, exist_ok=True)
    night.mkdir(parents=True, exist_ok=True)

    (drawable / "ic_launcher_background.xml").write_text(
        background(True), encoding="utf-8"
    )
    (night / "ic_launcher_background.xml").write_text(
        background(False), encoding="utf-8"
    )
    (drawable / "ic_launcher_foreground.xml").write_text(
        foreground("terra", INK, SHADOW_ALPHA_LIGHT), encoding="utf-8"
    )
    (night / "ic_launcher_foreground.xml").write_text(
        foreground("terra", CREAM, SHADOW_ALPHA_DARK), encoding="utf-8"
    )
    (drawable / "ic_launcher_modern_light_foreground.xml").write_text(
        foreground("ink", TERRA, SHADOW_ALPHA_LIGHT), encoding="utf-8"
    )
    (drawable / "ic_launcher_modern_foreground.xml").write_text(
        foreground("cream", TERRA, SHADOW_ALPHA_DARK), encoding="utf-8"
    )
    mono = monochrome()
    (drawable / "ic_launcher_monochrome.xml").write_text(mono, encoding="utf-8")
    (night / "ic_launcher_monochrome.xml").write_text(mono, encoding="utf-8")
    (drawable / "ic_launcher_modern_monochrome.xml").write_text(
        mono, encoding="utf-8"
    )

    for path, fg in {
        RES / "mipmap-anydpi-v26/ic_launcher.xml": "ic_launcher_foreground",
        RES / "mipmap-night-anydpi-v26/ic_launcher.xml": "ic_launcher_foreground",
        RES / "mipmap-anydpi-v26/ic_launcher_modern.xml":
            "ic_launcher_modern_light_foreground",
        RES / "mipmap-night-anydpi-v26/ic_launcher_modern.xml":
            "ic_launcher_modern_foreground",
    }.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(adaptive(fg), encoding="utf-8")

    # 保留颜色资源，供旧系统/外部引用回退。
    (RES / "values/ic_launcher_background.xml").write_text(
        f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{PAPER_LO}</color>
    <color name="ic_launcher_dark_background">{DARK_LO}</color>
    <color name="ic_launcher_modern_background">{DARK_LO}</color>
    <color name="ic_launcher_modern_light_background">{PAPER_LO}</color>
</resources>
''',
        encoding="utf-8",
    )
    (RES / "values-night/ic_launcher_background.xml").write_text(
        f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{DARK_LO}</color>
</resources>
''',
        encoding="utf-8",
    )


def write_pngs(svgs: dict[str, Path]) -> None:
    styles = {
        "ic_launcher": ("classic_light", "classic_dark"),
        "ic_launcher_modern": ("modern_light", "modern_dark"),
    }
    for drawable_name, (day, night) in styles.items():
        for density, size in MIPMAP_SIZES.items():
            render(svgs[day], RES / f"mipmap-{density}/{drawable_name}.png", size)
            render(
                svgs[night],
                RES / f"mipmap-night-{density}/{drawable_name}.png",
                size,
            )

    previews = {
        "icon_default_preview.png": "classic_light",
        "icon_default_dark_preview.png": "classic_dark",
        "icon_modern_light_preview.png": "modern_light",
        "icon_modern_preview.png": "modern_dark",
    }
    for name, variant in previews.items():
        render(svgs[variant], ROOT / "assets/images" / name, 256)

    ico_source = ROOT / "build" / "launcher_icon_256.png"
    render(svgs["classic_light"], ico_source, 256)
    image = Image.open(ico_source).convert("RGBA")
    image.save(
        ROOT / "windows/runner/resources/app_icon.ico",
        format="ICO",
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    ico_source.unlink(missing_ok=True)


def main() -> int:
    print(
        f"mark bbox = {MARK_BBOX_W:.1f} units, "
        f"legacy scale = {LEGACY_SCALE}, fg scale = {FG_SCALE}"
    )
    svgs = write_assets()
    write_drawables()
    write_pngs(svgs)
    print("launcher icons generated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
