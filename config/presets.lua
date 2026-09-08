-- 辅助强度：默认适中。强度调提前量/输入偏好，不增加计算上限或锁定时长。
local Presets={}
Presets.list={
    {name="低",plannerHorizon=12,intentPenalty=5,smoothPenalty=0.25,safetyMargin=1},
    {name="适中",plannerHorizon=18,intentPenalty=3,smoothPenalty=0.2,safetyMargin=1.5},
    {name="高",plannerHorizon=24,intentPenalty=1.5,smoothPenalty=0.15,safetyMargin=2.5},
}
function Presets.apply(config,index)
    local p=Presets.list[index]
    if not p then return nil end
    local old={}
    for k,v in pairs(p) do if k~="name" then old[k]=config[k]; config[k]=v end end
    config.preset=index
    return old
end
function Presets.getName(i) return Presets.list[i] and Presets.list[i].name or "?" end
return Presets
