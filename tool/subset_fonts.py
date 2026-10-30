#!/usr/bin/env python3
"""把 MiSans 可变字体裁成「GB2312 + 项目 UI 字符」子集。

Flutter 会把 pubspec 里声明的字体整份打进 APK。MiSansVF.ttf 全量约
20 MB，而 App 默认字体是系统字体，MiSans 只是可选外观；整份打包纯属
浪费。这里保留 GB2312 常用字、拉丁/标点，以及仓库里出现过的字符，
常见论坛内容不会缺字，生僻字回落到系统字体。

用法：
    python3 tool/subset_fonts.py --source /path/to/MiSansVF.ttf

依赖：fonttools（`pip install fonttools`）。
"""

from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUTPUT = os.path.join(ROOT, "assets/fonts/MiSansVF.ttf")


def gb2312_chars() -> set[str]:
    chars: set[str] = set()
    for hi in range(0xB0, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                chars.add(bytes([hi, lo]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return chars


def repository_chars() -> set[str]:
    chars: set[str] = set()
    patterns = [
        os.path.join(ROOT, "lib/**/*.dart"),
        os.path.join(ROOT, "lib/l10n/modules/**/*.arb"),
        os.path.join(ROOT, "README.md"),
    ]
    for pattern in patterns:
        for path in glob.glob(pattern, recursive=True):
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    chars.update(handle.read())
            except (OSError, UnicodeDecodeError):
                continue
    return chars


def build_charset() -> set[str]:
    chars = gb2312_chars() | repository_chars()
    # 常用拉丁、标点、符号与全角字符；论坛正文里经常出现。
    for start, end in (
        (0x20, 0x7E),
        (0xA0, 0xFF),
        (0x2000, 0x206F),
        (0x2190, 0x21FF),
        (0x2460, 0x24FF),
        (0x3000, 0x303F),
        (0xFF00, 0xFFEF),
    ):
        chars.update(chr(code) for code in range(start, end + 1))
    chars.update("“”‘’…—–·•™©®°′″€£¥→←↑↓✓✔✕✖★☆")
    return {char for char in chars if char.isprintable() or char == " "}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="完整的 MiSansVF.ttf")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="输出路径")
    args = parser.parse_args()

    if not os.path.isfile(args.source):
        print(f"源字体不存在: {args.source}", file=sys.stderr)
        return 1

    chars = build_charset()
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", suffix=".txt", delete=False
    ) as handle:
        handle.write("".join(sorted(chars)))
        text_file = handle.name

    try:
        # --layout-features='*' 保留 kerning / locl；variable font 的 fvar
        # 轴默认保留，Flutter 仍能按 FontWeight 命中 wght。
        subprocess.run(
            [
                "pyftsubset",
                args.source,
                f"--text-file={text_file}",
                f"--output-file={args.output}",
                "--layout-features=*",
                "--glyph-names",
                "--symbol-cmap",
                "--legacy-cmap",
                "--notdef-glyph",
                "--notdef-outline",
                "--recommended-glyphs",
                "--name-IDs=*",
                "--name-legacy",
                "--name-languages=*",
            ],
            check=True,
        )
    finally:
        os.unlink(text_file)

    before = os.path.getsize(args.source) / (1024 * 1024)
    after = os.path.getsize(args.output) / (1024 * 1024)
    print(f"字符数: {len(chars)}")
    print(f"MiSansVF: {before:.1f} MB -> {after:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
