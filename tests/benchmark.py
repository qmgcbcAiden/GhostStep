"""离线 Lua CPU 探针；不代表以撒进程 FPS 或实际 Boss 战性能。"""
from pathlib import Path
from statistics import mean
from time import perf_counter
from lupa import lua51
root = Path(__file__).resolve().parents[1]
lua = lua51.LuaRuntime(unpack_returned_tuples=True)
lua.globals().root = str(root)
lua.execute('package.path=root.."/?.lua;"..package.path')
lua.execute((root/'tests/smoke.lua').read_text())
lua.execute('''
local P=require('decision/predictive')
local R=require('config/runtime')
local D=require('config/defaults')
local T=require('sensors/terrain')
Isaac.GetTime=function() return os.clock()*1000 end
function benchmark(n,kind)
    local st=R.create(D.get())
    st.player.moveSpeed=1
    local hz={}
    for i=1,n do
        local a=i*2.39996
        local d=60+(i%40)*5
        local x,y=math.cos(a)*d,math.sin(a)*d
        hz[i]={id='p:'..i,kind=kind or 'projectile',pos=Vector(x,y),vel=Vector(-x/d*4,-y/d*4),radius=4,speed=4}
    end
    local cmd=P.run(st,{config=st.config,terrain=T.create(),getHazards=function() return hz end},0)
    return st.decision.usedBudgetMs,st.decision.metrics.evaluated,st.decision.metrics.checks,
        cmd~=nil,st.decision.reason,st.decision.metrics.hazards
end
''')
for count in (1, 50, 150, 300):
    rows = [lua.globals().benchmark(count) for _ in range(30)]
    times = sorted(row[0] for row in rows)
    print(f'n={count} mean={mean(times):.3f}ms p95={times[28]:.3f}ms max={max(times):.3f}ms '
          f'evaluated={mean(row[1] for row in rows):.1f} checks={mean(row[2] for row in rows):.0f} '
          f'intervened={sum(row[3] for row in rows)}/30 reason={rows[-1][4]} relevant={rows[-1][5]}')

# 接触几何多检查两段顺序移动；在真实墙钟预算下验证其额外 CPU 成本。
for count in (2, 8, 16, 50):
    rows = [lua.globals().benchmark(count, 'enemy') for _ in range(30)]
    times = sorted(row[0] for row in rows)
    print(f'enemy n={count} mean={mean(times):.3f}ms p95={times[28]:.3f}ms max={max(times):.3f}ms '
          f'evaluated={mean(row[1] for row in rows):.1f} intervened={sum(row[3] for row in rows)}/30')

# 主更新 CPU：包含传感器、地形、模型、JSON 编码和内存缓存；无真实磁盘 I/O。
full = lua51.LuaRuntime(unpack_returned_tuples=True)
full.globals().root = str(root)
full.execute('package.path=root.."/?.lua;"..package.path')
full.execute((root/'tests/smoke.lua').read_text())
full.execute((root/'tests/integration.lua').read_text())
full.execute('''
Isaac.GetTime=function() return os.clock()*1000 end
GhostStep3.Config.budgetMs=1.5
function full_benchmark(frame,n)
    local entities={}
    for i=1,n do
        local a=i*2.39996
        local d=40+(i%40)*5
        local x,y=math.cos(a)*d,math.sin(a)*d
        entities[i]={Type=EntityType.ENTITY_PROJECTILE,Index=i+100,InitSeed=i+100,
            Position=Vector(160+x,160+y),Velocity=Vector(-x/d*4,-y/d*4),Size=4,SpawnerType=0,
            IsDead=function() return false end}
    end
    local p=INTEGRATION_STEP(frame,entities)
    return p.totalMs,p.sensorsMs,p.terrainMs,p.decisionMs,p.recordingMs
end
''')
for group, count in enumerate((50, 300)):
    rows = [full.globals().full_benchmark(1000+group*100+i, count) for i in range(30)]
    times = sorted(row[0] for row in rows)
    print(f'full-update n={count} mean={mean(times):.3f}ms p95={times[28]:.3f}ms max={max(times):.3f}ms '
          f'sensors={mean(row[1] for row in rows):.3f}ms terrain={mean(row[2] for row in rows):.3f}ms '
          f'planner={mean(row[3] for row in rows):.3f}ms recording={mean(row[4] for row in rows):.3f}ms')
