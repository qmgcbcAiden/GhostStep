"""Run Lua 5.1 and 5.3 syntax, behavioral and callback integration checks."""
import argparse
from pathlib import Path
from lupa import lua51, lua53

ROOT = Path(__file__).resolve().parents[1]

def run(version):
    module = {"5.1": lua51, "5.3": lua53}[version]
    lua = module.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().mod_root = str(ROOT)
    lua.execute('package.path = mod_root .. "/?.lua;" .. package.path')
    compile_lua = lua.eval('function(source, name) local f,err=(loadstring or load)(source,name); assert(f,err) end')
    for path in ROOT.rglob('*.lua'):
        if '.git' not in path.parts and 'references' not in path.parts:
            compile_lua(path.read_text(encoding='utf-8'), str(path.relative_to(ROOT)))
    for name in ('smoke.lua', 'smoke_main.lua', 'shared_control.lua', 'integration.lua'):
        try:
            lua.execute((ROOT/'tests'/name).read_text(encoding='utf-8'))
        except module.LuaError:
            print(f'FAILED: Lua {version}: {name}', flush=True)
            raise
    print(f'Lua {version}: syntax + all behavior/integration checks passed', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--lua', choices=('5.1', '5.3', 'both'), default='both')
    args = parser.parse_args()
    for version in ('5.1', '5.3') if args.lua == 'both' else (args.lua,):
        run(version)
