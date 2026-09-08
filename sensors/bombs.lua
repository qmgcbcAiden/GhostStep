-- 使用实际引信倒计时；未知引信明确标记，不再由 FrameCount 猜固定 150 帧。
local Bombs={}
local function get(e,fn,fallback)
    local ok,v=pcall(fn,e); if ok and v~=nil then return v end; return fallback
end
function Bombs.collect(player,tracker,frame,config)
    if not config.hazardBombs then tracker:clear(); return end
    local ok,entities=pcall(Isaac.FindByType,EntityType.ENTITY_BOMB,-1,-1,false)
    if not ok or not entities then return end
    local entries={}
    for i=1,#entities do
        local e=entities[i]
        if not get(e,function(x) return x:IsDead() end,true) then
            local bomb=get(e,function(x) return x:ToBomb() end,e)
            local countdown=get(bomb,function(x) return x.ExplosionCountdown end,nil)
            if type(countdown)~='number' or countdown<0 then countdown=nil end
            local damage=get(bomb,function(x) return x.ExplosionDamage end,12)
            if damage>0 then
                entries[#entries+1]={index=e.Index,seed=e.InitSeed,kind='bomb',entityType=e.Type,variant=e.Variant,
                    sourceIndex=e.SpawnerEntity and e.SpawnerEntity.Index,ownerType=e.SpawnerType,
                    pos=e.Position,vel=e.Velocity,speed=e.Velocity:Length(),
                    radius=90*get(bomb,function(x) return x.RadiusMultiplier end,1),damage=damage,
                    fuseFrames=countdown,appearFrame=countdown and frame+countdown,
                    endFrame=countdown and frame+countdown+2,
                    timingKnown=countdown~=nil,confidence=countdown and 1 or 0.3}
            end
        end
    end
    tracker:update(entries,frame,'bomb')
end
return Bombs
