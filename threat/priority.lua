-- 有界最大堆：遍历所有对象，保留最可能接近玩家的 K 个，避免按实体顺序截断。
local Priority = {}
function Priority.offer(heap, value, key, limit)
    if limit <= 0 then return end
    local n=#heap
    if n>=limit and key>=heap[1].key then return end
    local node={value=value,key=key}
    if n<limit then
        n=n+1; heap[n]=node
        while n>1 do
            local p=math.floor(n/2)
            if heap[p].key>=node.key then break end
            heap[n]=heap[p]; n=p; heap[n]=node
        end
    else
        heap[1]=node
        local i=1
        while i*2<=n do
            local j=i*2
            if j<n and heap[j+1].key>heap[j].key then j=j+1 end
            if heap[j].key<=node.key then break end
            heap[i]=heap[j]; i=j; heap[i]=node
        end
    end
end
function Priority.projectileKey(e,p,horizon)
    if not p then return e.pos:Length() end
    local dx,dy=e.pos.X-p.position.X,e.pos.Y-p.position.Y
    local vx,vy=e.vel.X-p.velocity.X,e.vel.Y-p.velocity.Y
    local vv=vx*vx+vy*vy
    local t=vv>0.001 and math.max(0,math.min(horizon,-(dx*vx+dy*vy)/vv)) or 0
    local closest=math.sqrt((dx+vx*t)^2+(dy+vy*t)^2)-(e.radius or 0)-(p.radius or 10)
    return closest+0.15*t
end
return Priority
