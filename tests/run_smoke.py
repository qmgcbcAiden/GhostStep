# tests/run_smoke.py
# 用 lupa Lua 5.1（与 Isaac 引擎一致）运行 GhostStep3 离线冒烟测试
import os
import sys

from lupa import lua51

lua = lua51.LuaRuntime(unpack_returned_tuples=True)

base = os.path.dirname(os.path.abspath(__file__))
mod_root = os.path.dirname(base)


def run():
    root = mod_root.replace(os.sep, "/")
    lua.execute(f'package.path = "{root}/?.lua;{root}/?/init.lua;" .. package.path')

    for name in ("tests/smoke.lua", "tests/smoke_main.lua"):
        path = os.path.join(mod_root, name)
        src = open(path, encoding="utf-8").read()
        try:
            lua.execute(src)
        except lua51.LuaError as e:
            print(f"--- {name} FAILED ---")
            print(e)
            sys.exit(1)

    # smoke_main.lua 的结果通过 print 输出；失败会 raise error
    print("\n(runner: smoke completed)")


if __name__ == "__main__":
    run()
