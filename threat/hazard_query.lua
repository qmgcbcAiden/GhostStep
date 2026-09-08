-- 与预测控制共用几何，所有候选均使用同一生效窗口。
local Query={}
local Geometry=require("threat/geometry")
local Predict=require("threat/projectile_predict")
function Query.create() return setmetatable({hazards={},frame=0},{__index=Query}) end
function Query.update(self,hazards,frame) self.hazards=hazards; self.frame=frame or 0 end
function Query.near(self,p) return self.hazards end
function Query.firstCollision(self,p,v,r,horizon,terrain)
    local best,hit
    for i=1,#self.hazards do
        local e=self.hazards[i]
        if Geometry.reachable(e,p,r,v:Length(),horizon) then
            local cache={}
            for t=0,math.min(horizon,best or horizon) do
                local t1=math.min(horizon,t+1)
                local a,b=p+v*t,p+v*t1
                if Geometry.clearance(e,a.X,a.Y,b.X,b.Y,r,t,t1,self.frame,cache)<=0 then
                    -- 仅明确不能穿格子的直线弹幕才可用墙截断。敌人/幽灵弹不能复用玩家通行图。
                    local blocked=e.kind=="projectile" and e.blocksOnGrid==true
                        and Predict.pathBlockedByWall(e,t,terrain)
                    if not blocked then best,hit=math.max(t,(Geometry.window(e,self.frame))),e; break end
                end
            end
        end
    end
    return best,hit
end
function Query.isInDanger(self,p,r,terrain)
    local t,e=self:firstCollision(p,Vector(0,0),r,0,terrain)
    return t==0,e
end
return Query
