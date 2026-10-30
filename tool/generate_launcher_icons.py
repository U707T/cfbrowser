#!/usr/bin/env python3
"""生成 cfbrowser 的启动器图标（Claude 美学 · Warm Orb）。

设计：
- 经典：暖纸/深墨底 + 陶土色球体 + 墨色/奶油色轨道；
- 现代：同几何，球体换成墨色（浅色底）/奶油色（深色底），轨道改为陶土色。

输出：
- Android 旧版 mipmap PNG（日/夜、两套风格、5 个密度）
- Android 自适应图标：渐变背景、前景（日/夜）、单色
- 设置页预览 PNG（4 张 256px）
- Windows .ico
- tool/launcher_icon/*.svg 设计源文件

依赖：cairosvg、Pillow。用法：python3 tool/generate_launcher_icons.py
"""

from __future__ import annotations

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

SPHERE = "M280 512 a232 232 0 1 0 464 0 a232 232 0 1 0 -464 0 Z"
HIGHLIGHT = "M358 420 a72 42 0 1 0 144 0 a72 42 0 1 0 -144 0 Z"
ORBIT = "M120 512 a392 142 0 1 0 784 0 a392 142 0 1 0 -784 0 Z"
DOT = "M802 340 a26 26 0 1 0 52 0 a26 26 0 1 0 -52 0 Z"
SHADOW = "M292 540 a220 56 0 1 0 440 0 a220 56 0 1 0 -440 0 Z"

ORB_GRADIENTS = {
    "terra": [("0", "#EF9B78"), ("0.55", TERRA), ("1", TERRA_DEEP)],
    "ink": [("0", "#4A423B"), ("0.55", "#2A2521"), ("1", "#171412")],
    "cream": [("0", "#FFFDF8"), ("0.55", "#F1E8D9"), ("1", "#D8CAB6")],
}

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


def svg(light: bool, orb: str, orbit: str) -> str:
    bg_hi, bg_lo = (PAPER_HI, PAPER_LO) if light else (DARK_HI, DARK_LO)
    glow = "0.75" if light else "0.10"
    shadow = "0.16" if light else "0.35"
    return f'''<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{bg_hi}"/><stop offset="1" stop-color="{bg_lo}"/>
    </linearGradient>
    <radialGradient id="glow" cx="32%" cy="20%" r="80%">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="{glow}"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="orb" cx="34%" cy="28%" r="75%">
      {_stops(ORB_GRADIENTS[orb])}
    </radialGradient>
    <filter id="shadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="16" stdDeviation="22" flood-color="#000000" flood-opacity="{shadow}"/>
    </filter>
  </defs>
  <rect width="1024" height="1024" rx="228" fill="url(#bg)"/>
  <rect width="1024" height="1024" rx="228" fill="url(#glow)"/>
  <circle cx="512" cy="512" r="232" fill="url(#orb)" filter="url(#shadow)"/>
  <ellipse cx="512" cy="512" rx="392" ry="142" transform="rotate(-22 512 512)" stroke="{orbit}" stroke-width="14" opacity="0.55"/>
  <circle cx="828" cy="340" r="26" fill="{orbit}"/>
  <ellipse cx="430" cy="420" rx="72" ry="42" fill="#FFFFFF" opacity="0.18" transform="rotate(-30 430 420)"/>
</svg>
'''


def _gradient_attr(stops: list[tuple[str, str]], cx: int, cy: int, radius: int) -> str:
    items = "".join(
        f'          <item android:offset="{offset}" android:color="{color}"/>\n'
        for offset, color in stops
    )
    return f'''      <aapt:attr name="android:fillColor">
        <gradient
            android:type="radial"
            android:centerX="{cx}"
            android:centerY="{cy}"
            android:gradientRadius="{radius}">
{items}        </gradient>
      </aapt:attr>'''


def foreground(orb: str, orbit: str) -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">

    <!-- 自适应安全区：整体缩到 78% -->
    <group
        android:scaleX="0.78"
        android:scaleY="0.78"
        android:pivotX="512"
        android:pivotY="512">

        <!-- 球体下方的柔和阴影 -->
        <path android:pathData="{SHADOW}">
            <aapt:attr name="android:fillColor">
                <gradient
                    android:type="radial"
                    android:centerX="512"
                    android:centerY="540"
                    android:gradientRadius="240">
                    <item android:offset="0" android:color="#33000000"/>
                    <item android:offset="1" android:color="#00000000"/>
                </gradient>
            </aapt:attr>
        </path>

        <!-- 球体 -->
        <path android:pathData="{SPHERE}">
{_gradient_attr(ORB_GRADIENTS[orb], 420, 400, 370)}
        </path>

        <!-- 轨道 -->
        <group
            android:rotation="-22"
            android:pivotX="512"
            android:pivotY="512">
            <path
                android:fillColor="#00000000"
                android:strokeColor="{orbit}"
                android:strokeWidth="14"
                android:strokeAlpha="0.55"
                android:pathData="{ORBIT}" />
        </group>

        <!-- 轨道上的小点 -->
        <path
            android:fillColor="{orbit}"
            android:pathData="{DOT}" />

        <!-- 球体高光 -->
        <group
            android:rotation="-30"
            android:pivotX="430"
            android:pivotY="420">
            <path
                android:fillColor="#FFFFFF"
                android:fillAlpha="0.18"
                android:pathData="{HIGHLIGHT}" />
        </group>
    </group>
</vector>
'''


def monochrome() -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">

    <group
        android:scaleX="0.78"
        android:scaleY="0.78"
        android:pivotX="512"
        android:pivotY="512">
        <path
            android:fillColor="#FFFFFF"
            android:fillAlpha="0.32"
            android:pathData="{SPHERE}" />
        <group
            android:rotation="-22"
            android:pivotX="512"
            android:pivotY="512">
            <path
                android:fillColor="#00000000"
                android:strokeColor="#FFFFFF"
                android:strokeWidth="14"
                android:pathData="{ORBIT}" />
        </group>
        <path
            android:fillColor="#FFFFFF"
            android:pathData="{DOT}" />
        <group
            android:rotation="-30"
            android:pivotX="430"
            android:pivotY="420">
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
        foreground("terra", INK), encoding="utf-8"
    )
    (night / "ic_launcher_foreground.xml").write_text(
        foreground("terra", CREAM), encoding="utf-8"
    )
    (drawable / "ic_launcher_modern_light_foreground.xml").write_text(
        foreground("ink", TERRA), encoding="utf-8"
    )
    (drawable / "ic_launcher_modern_foreground.xml").write_text(
        foreground("cream", TERRA), encoding="utf-8"
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
    svgs = write_assets()
    write_drawables()
    write_pngs(svgs)
    print("launcher icons generated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
