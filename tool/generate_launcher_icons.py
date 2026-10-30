#!/usr/bin/env python3
"""生成 cfbrowser 的启动器图标。

设计：浏览器窗口 + 地球（经典）/ 闪电（现代）。
- 经典：纸色底、墨色窗口、琥珀色顶栏；
- 现代：墨色底、纸色窗口、琥珀色闪电。

输出：
- Android 旧版 mipmap PNG（日/夜、两套风格、5 个密度）
- Android 自适应图标 vector drawable（前景 / 夜间前景 / 单色）
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

PAPER = "#F0F0F3"
INK = "#1C1C1E"
AMBER = "#FFB003"

WINDOW_BODY = (
    "M304 224 H720 A96 96 0 0 1 816 320 V704 A96 96 0 0 1 720 800 "
    "H304 A96 96 0 0 1 208 704 V320 A96 96 0 0 1 304 224 Z"
)
TOPBAR = (
    "M304 224 H720 A96 96 0 0 1 816 320 V340 H208 V320 A96 96 0 0 1 304 224 Z"
)
DOTS = [(286, 282, 13, 0.92), (336, 282, 13, 0.58), (386, 282, 13, 0.30)]
GLOBE_CIRCLE = "M367 590 a145 145 0 1 0 290 0 a145 145 0 1 0 -290 0 Z"
GLOBE_ELLIPSE = "M512 445 a62 145 0 1 1 0 290 a62 145 0 1 1 0 -290 Z"
GLOBE_LINE = "M367 590 L657 590"
BOLT = "M566 400 L430 606 L508 606 L474 760 L610 548 L532 548 Z"

MIPMAP_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def svg(bg: str, body: str, globe_fill: str, line: str, symbol: str) -> str:
    dots = "\n  ".join(
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{INK}" opacity="{alpha}"/>'
        for cx, cy, r, alpha in DOTS
    )
    if symbol == "globe":
        foreground = (
            f'<circle cx="512" cy="590" r="145" fill="{globe_fill}"/>\n'
            f'  <ellipse cx="512" cy="590" rx="62" ry="145" fill="none" '
            f'stroke="{line}" stroke-width="20"/>\n'
            f'  <path d="{GLOBE_LINE}" stroke="{line}" stroke-width="20"/>'
        )
    else:
        foreground = f'<path d="{BOLT}" fill="{AMBER}"/>'
    return f'''<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="1024" height="1024" rx="228" fill="{bg}"/>
  <path d="{WINDOW_BODY}" fill="{body}"/>
  <path d="{TOPBAR}" fill="{AMBER}"/>
  {dots}
  {foreground}
</svg>
'''


def dots_xml(color: str = INK) -> str:
    paths = []
    for cx, cy, r, alpha in DOTS:
        paths.append(
            f'    <path\n'
            f'        android:fillColor="{color}"\n'
            f'        android:fillAlpha="{alpha}"\n'
            f'        android:pathData="M{cx - r} {cy} a{r} {r} 0 1 0 {2 * r} 0 '
            f'a{r} {r} 0 1 0 {-2 * r} 0 Z" />'
        )
    return "\n".join(paths)


def vector_foreground(window_fill: str, globe_fill: str, line: str, symbol: str) -> str:
    if symbol == "globe":
        foreground = f'''    <path
        android:fillColor="{globe_fill}"
        android:pathData="{GLOBE_CIRCLE}" />
    <path
        android:fillColor="#00000000"
        android:strokeColor="{line}"
        android:strokeWidth="20"
        android:pathData="{GLOBE_ELLIPSE}" />
    <path
        android:fillColor="#00000000"
        android:strokeColor="{line}"
        android:strokeWidth="20"
        android:pathData="{GLOBE_LINE}" />'''
    else:
        foreground = f'''    <path
        android:fillColor="{AMBER}"
        android:pathData="{BOLT}" />'''
    return f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">

    <!-- 浏览器窗口：内容控制在自适应图标安全区内 -->
    <path
        android:fillColor="{window_fill}"
        android:pathData="{WINDOW_BODY}" />
    <path
        android:fillColor="{AMBER}"
        android:pathData="{TOPBAR}" />

{dots_xml()}

{foreground}
</vector>
'''


def vector_monochrome(symbol: str) -> str:
    if symbol == "globe":
        foreground = f'''    <path
        android:fillColor="#FFFFFF"
        android:fillAlpha="0.12"
        android:strokeColor="#FFFFFF"
        android:strokeWidth="18"
        android:pathData="{GLOBE_CIRCLE}" />
    <path
        android:fillColor="#00000000"
        android:strokeColor="#FFFFFF"
        android:strokeWidth="14"
        android:pathData="{GLOBE_ELLIPSE}" />
    <path
        android:fillColor="#00000000"
        android:strokeColor="#FFFFFF"
        android:strokeWidth="14"
        android:pathData="{GLOBE_LINE}" />'''
    else:
        foreground = f'''    <path
        android:fillColor="#FFFFFF"
        android:pathData="{BOLT}" />'''
    return f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">

    <!-- 单色图标：用透明度分层，由系统取色 -->
    <path
        android:fillColor="#FFFFFF"
        android:fillAlpha="0.28"
        android:strokeColor="#FFFFFF"
        android:strokeWidth="20"
        android:pathData="{WINDOW_BODY}" />
    <path
        android:fillColor="#FFFFFF"
        android:fillAlpha="0.72"
        android:pathData="{TOPBAR}" />

{dots_xml("#FFFFFF")}

{foreground}
</vector>
'''


def render(svg_path: Path, out_path: Path, size: int) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        url=str(svg_path),
        write_to=str(out_path),
        output_width=size,
        output_height=size,
    )


def write_backgrounds() -> None:
    (RES / "values/ic_launcher_background.xml").write_text(
        f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{PAPER}</color>
    <color name="ic_launcher_dark_background">{INK}</color>
    <color name="ic_launcher_modern_background">{INK}</color>
    <color name="ic_launcher_modern_light_background">{PAPER}</color>
</resources>
''',
        encoding="utf-8",
    )
    (RES / "values-night/ic_launcher_background.xml").write_text(
        f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{INK}</color>
</resources>
''',
        encoding="utf-8",
    )


def write_drawables() -> None:
    (RES / "drawable/ic_launcher_foreground.xml").write_text(
        vector_foreground(INK, PAPER, INK, "globe"), encoding="utf-8"
    )
    (RES / "drawable-night/ic_launcher_foreground.xml").write_text(
        vector_foreground(PAPER, INK, PAPER, "globe"), encoding="utf-8"
    )
    (RES / "drawable/ic_launcher_modern_light_foreground.xml").write_text(
        vector_foreground(INK, INK, INK, "bolt"), encoding="utf-8"
    )
    (RES / "drawable/ic_launcher_modern_foreground.xml").write_text(
        vector_foreground(PAPER, PAPER, PAPER, "bolt"), encoding="utf-8"
    )
    (RES / "drawable/ic_launcher_monochrome.xml").write_text(
        vector_monochrome("globe"), encoding="utf-8"
    )
    # 夜间单色与日间一致；保留文件避免旧资源残留。
    (RES / "drawable-night/ic_launcher_monochrome.xml").write_text(
        vector_monochrome("globe"), encoding="utf-8"
    )
    (RES / "drawable/ic_launcher_modern_monochrome.xml").write_text(
        vector_monochrome("bolt"), encoding="utf-8"
    )


def write_svgs() -> dict[str, Path]:
    variants = {
        "classic_light": svg(PAPER, INK, PAPER, INK, "globe"),
        "classic_dark": svg(INK, PAPER, INK, PAPER, "globe"),
        "modern_light": svg(PAPER, INK, INK, INK, "bolt"),
        "modern_dark": svg(INK, PAPER, PAPER, PAPER, "bolt"),
    }
    paths: dict[str, Path] = {}
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    for name, content in variants.items():
        path = SVG_DIR / f"{name}.svg"
        path.write_text(content, encoding="utf-8")
        paths[name] = path
    return paths


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
    render(svgs["modern_light"], ico_source, 256)
    image = Image.open(ico_source).convert("RGBA")
    image.save(
        ROOT / "windows/runner/resources/app_icon.ico",
        format="ICO",
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    ico_source.unlink(missing_ok=True)


def main() -> int:
    svgs = write_svgs()
    write_backgrounds()
    write_drawables()
    write_pngs(svgs)
    print("launcher icons generated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
