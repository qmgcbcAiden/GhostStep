#!/usr/bin/env python3
"""
GhostStep3 工具箱 — 项目工具统一 CLI 入口

用法:
    python tools/gs.py              # 交互菜单（数字键选择）
    python tools/gs.py 1            # 直接: 录制回放分析器（列出会话）
    python tools/gs.py 1 --latest   # 直接: 录制回放分析器（分析最新会话）
    python tools/gs.py 2            # 直接: 生成动画数据库
    python tools/gs.py 3            # 直接: 运行冒烟测试
    python tools/gs.py 4            # 直接: 部署到游戏目录
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path

# 项目根目录（tools/ 的上级）
PROJECT_ROOT = Path(__file__).resolve().parent.parent

# 游戏录制目录（Steam 默认安装路径）
GAME_RECORDINGS = Path(r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3\recordings")


def force_utf8():
    """强制 UTF-8 输出（Windows 控制台默认 GBK 会乱码）"""
    try:
        if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
            sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def read_choice(prompt="请选择> "):
    """读取用户输入，EOF 时返回 None（管道/非交互模式）"""
    try:
        return input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        return None


def clear_screen():
    os.system("cls" if os.name == "nt" else "clear")


def pause(msg="按回车继续..."):
    try:
        input(f"\n{msg}")
    except (EOFError, KeyboardInterrupt):
        pass


def terminal_width():
    try:
        return shutil.get_terminal_size().columns
    except Exception:
        return 80


def recordings_dir():
    """返回可用的录制目录（优先游戏内目录，回退仓库目录）"""
    if GAME_RECORDINGS.is_dir():
        return GAME_RECORDINGS
    return PROJECT_ROOT / "recordings"


# =====================================================================
# 工具 1: 录制回放分析器
# =====================================================================

def tool_replay(args=None):
    script = PROJECT_ROOT / "tools" / "replay_viewer.py"
    if not script.exists():
        print(f"  ✗ 找不到 {script}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(script)] + args).returncode

    while True:
        print("\n--- 录制回放分析器 ---")
        print("  1) 列出所有录制会话")
        print("  2) 分析最新会话")
        print("  3) 分析指定文件")
        print("  4) 跨会话受击归因汇总（调参仪表盘）")
        print("  5) 渲染弹幕场快照图（--frame N）")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            return subprocess.run([sys.executable, str(script), "--dir", str(recordings_dir())]).returncode
        elif choice == "2":
            return subprocess.run([sys.executable, str(script), "--dir", str(recordings_dir()), "--latest"]).returncode
        elif choice == "3":
            path = read_choice("  文件路径 (.jsonl)> ")
            if path:
                return subprocess.run([sys.executable, str(script), path.strip('"')]).returncode
        elif choice == "4":
            return subprocess.run([sys.executable, str(script), "--dir", str(recordings_dir()), "--summary"]).returncode
        elif choice == "5":
            path = read_choice("  文件路径 (.jsonl)> ")
            frame = read_choice("  帧号> ")
            if path and frame:
                return subprocess.run([sys.executable, str(script), path.strip('"'), "--frame", frame]).returncode
        else:
            print("  无效选项")


# =====================================================================
# 工具 2: 动画数据库生成器
# =====================================================================

def tool_animdb(args=None):
    script = PROJECT_ROOT / "tools" / "parse_animations.py"
    if not script.exists():
        print(f"  ✗ 找不到 {script}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(script)] + args).returncode

    while True:
        print("\n--- 动画数据库生成器 ---")
        print("  1) 生成（仅高价值分类，自动检测 Steam 路径）")
        print("  2) 生成（全部分类，调试用）")
        print("  3) 指定资源目录生成")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            out = str(PROJECT_ROOT / "data" / "npc_animdb.lua")
            return subprocess.run([sys.executable, str(script), "--output", out]).returncode
        elif choice == "2":
            out = str(PROJECT_ROOT / "data" / "npc_animdb.lua")
            return subprocess.run([sys.executable, str(script), "--output", out, "--all-categories"]).returncode
        elif choice == "3":
            res = read_choice("  资源目录路径> ")
            out = str(PROJECT_ROOT / "data" / "npc_animdb.lua")
            if res:
                return subprocess.run([sys.executable, str(script), "--resource-dir", res.strip('"'), "--output", out]).returncode
        else:
            print("  无效选项")


# =====================================================================
# 工具 3: 冒烟测试
# =====================================================================

def tool_test(args=None):
    runner = PROJECT_ROOT / "tests" / "run_smoke.py"
    if not runner.exists():
        print(f"  ✗ 找不到 {runner}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(runner)] + args, cwd=str(PROJECT_ROOT)).returncode

    while True:
        print("\n--- 冒烟测试 ---")
        print("  1) 运行全部测试")
        print("  2) 详细输出模式")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            return subprocess.run([sys.executable, str(runner)], cwd=str(PROJECT_ROOT)).returncode
        elif choice == "2":
            return subprocess.run([sys.executable, str(runner), "-v"], cwd=str(PROJECT_ROOT)).returncode
        else:
            print("  无效选项")


# =====================================================================
# 工具 4: 部署
# =====================================================================

def tool_deploy(args=None):
    src = PROJECT_ROOT
    dst = Path(r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3")

    if not (src / "main.lua").exists():
        print(f"  ✗ 源目录不存在: {src}")
        return 1

    ROBOCOPY_BASE = [
        "robocopy", str(src), str(dst), "/MIR",
        "/XD", "tests", "recordings", ".git", ".claude", "references", "tools",
        "/XF", "deploy.bat", ".gitignore", "ANALYSIS.md",
    ]
    ROBOCOPY_QUIET = ["/NFL", "/NDL", "/NJH", "/NJS", "/NP"]

    if args is not None and "--dry-run" not in args:
        return subprocess.run(ROBOCOPY_BASE + ROBOCOPY_QUIET + args).returncode

    while True:
        print(f"\n--- 部署 ---")
        print(f"  源: {src}")
        print(f"  目标: {dst}")
        print()
        print("  1) 部署（镜像同步）")
        print("  2) 预览（只显示会改变的文件）")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            result = subprocess.run(ROBOCOPY_BASE + ROBOCOPY_QUIET)
            if result.returncode < 8:
                print("\n  ✓ 部署完成。游戏内按 Ctrl+R 重载 Lua。")
            else:
                print(f"\n  ✗ robocopy 失败，错误码 {result.returncode}")
            return result.returncode
        elif choice == "2":
            return subprocess.run(ROBOCOPY_BASE + ["/L"]).returncode
        else:
            print("  无效选项")


# =====================================================================
# 主菜单
# =====================================================================

TOOLS = [
    ("1", "录制回放分析器", "会话分析 / 归因汇总 / 弹幕场快照", tool_replay),
    ("2", "动画数据库生成器", "解析 anm2 → npc_animdb.lua", tool_animdb),
    ("3", "冒烟测试", "运行全部单元/集成测试", tool_test),
    ("4", "部署", "镜像同步到 Isaac mods 目录", tool_deploy),
]


def print_banner():
    w = terminal_width()
    print("=" * min(w, 60))
    print("  GhostStep3 工具箱")
    print("=" * min(w, 60))


def print_menu():
    print()
    for num, name, desc, _ in TOOLS:
        print(f"  {num}) {name:<16s} {desc}")
    print(f"  0) 退出")
    print()


def main():
    force_utf8()

    # 直接调用: python tools/gs.py <工具编号> [参数...]
    if len(sys.argv) >= 2 and sys.argv[1].isdigit():
        tool_num = sys.argv[1]
        rest = sys.argv[2:]
        for num, _, _, fn in TOOLS:
            if num == tool_num:
                return fn(rest if rest else None)
        print(f"未知工具: {tool_num}")
        return 1

    # 交互模式
    while True:
        clear_screen()
        print_banner()
        print_menu()

        choice = read_choice()
        if choice is None or choice == "0":
            print("再见。")
            return 0

        matched = False
        for num, name, _, fn in TOOLS:
            if choice == num:
                matched = True
                result = fn()
                if result is not None:
                    pause()
                break

        if not matched:
            print("  无效选项")
            pause()


if __name__ == "__main__":
    sys.exit(main() or 0)
