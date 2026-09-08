-- 单一共享控制入口；获选命令已做几何验证，不再叠加方向锁或归一化合成。
local Predictive=require("decision/predictive")
local Pipeline={}
function Pipeline.run(state,deps,frame)
    local command=Predictive.run(state,deps,frame)
    return state.decision.layer,command
end
return Pipeline
