-- 沙箱/离线测试的 JSON 编码兜底。正常游戏优先使用内置 json.encode。
local escapes={['"']='\\"',['\\']='\\\\',['\b']='\\b',['\f']='\\f',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
local function quote(s)
    return '"'..s:gsub('[%z\1-\31\\"]',function(c) return escapes[c] or string.format('\\u%04x',string.byte(c)) end)..'"'
end
local function encode(value,seen)
    local t=type(value)
    if t=='nil' then return 'null' end
    if t=='boolean' then return value and 'true' or 'false' end
    if t=='number' then
        if value~=value or value==math.huge or value==-math.huge then return 'null' end
        return string.format('%.17g',value)
    end
    if t=='string' then return quote(value) end
    assert(t=='table','JSON unsupported type: '..t)
    seen=seen or {}; assert(not seen[value],'JSON cycle'); seen[value]=true
    local array,n=true,0
    for k in pairs(value) do
        n=n+1
        if type(k)~='number' or k<1 or k%1~=0 then array=false end
    end
    array=array and n>0 and n==#value
    local out={}
    if array then
        for i=1,n do out[i]=encode(value[i],seen) end
    else
        local keys={}; for k in pairs(value) do keys[#keys+1]=k end
        table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
        for _,k in ipairs(keys) do out[#out+1]=quote(tostring(k))..':'..encode(value[k],seen) end
    end
    seen[value]=nil
    return (array and '[' or '{')..table.concat(out,',')..(array and ']' or '}')
end
return encode
