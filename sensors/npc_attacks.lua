-- sensors/npc_attacks.lua
-- NPC attack pre-fire detection (Phase 3.4 + Tier 1 table-driven refactor)
-- Scans NPCs for known attack animations (from data/npc_animdb.lua),
-- generates threat entries using category profiles (from data/npc_profiles.lua).
--
-- Tier 1 additions:
--   - fuseFrames: windup countdown → feeds into threat_level urgency (reuse bomb fuse mechanism)
--   - appearFrame: when the attack actually hits → future_motion "not yet existing" logic
--   - Table-driven: all NPC type + animation mappings in data/npc_animdb.lua
--
-- Coverage: stomping (Daddy Long Legs), jumping (Mom's Hand, Widow, Leaper),
--   laser windup (Vis, Maw, Bloat, Adversary), ranged (Horf, Gatling Gurdy)

local NpcAttackSensor = {}

local EntityType = EntityType
local Profiles = require("data/npc_profiles")

-- Load animation database (pcall: file missing = no coverage = graceful degradation)
local okAnimDB, animDB = pcall(require, "data/npc_animdb")
if not okAnimDB then animDB = nil end

-- ===== Animation lookup =====

--- Safe lowercase animation name read
local function safeAnimationLower(entity)
    local okSprite, sprite = pcall(function() return entity:GetSprite() end)
    if not okSprite or sprite == nil then return "" end
    local okAnim, anim = pcall(function() return sprite:GetAnimation() end)
    if not okAnim or type(anim) ~= "string" then return "" end
    return string.lower(anim)
end

--- Find attack animation entry from animDB for this entity + current animation
--- Returns {name, totalFrames, windupFrames, category} or nil
local function findAttackEntry(entityType, entityVariant, animLower)
    if not animDB then return nil end
    local key = tostring(entityType) .. ":" .. tostring(entityVariant or 0)
    local entries = animDB[key]
    if not entries then return nil end
    -- Check if current animation matches any attack animation (case-insensitive)
    for i = 1, #entries do
        local e = entries[i]
        if string.lower(e.name) == animLower then
            return e
        end
    end
    return nil
end

--- Animations to exclude (death/appear transitions are not attacks)
local EXCLUDE_TOKENS = { "death", "appear" }
local function isExcludedAnimation(anim)
    for i = 1, #EXCLUDE_TOKENS do
        if string.find(anim, EXCLUDE_TOKENS[i], 1, true) then return true end
    end
    return false
end

--- Get entity-specific jump radius from profile table
local function getJumpRadius(entityType)
    return Profiles.jumpRadiusByType[entityType] or Profiles.defaultJumpRadius
end

--- Get player position (for laser direction calculation)
local function getPlayerPosition()
    local ok, player = pcall(Isaac.GetPlayer, 0)
    if ok and player then return player.Position end
    return nil
end

--- Build tracker entry from attack detection
--- Returns {pos, vel, speed, radius, kind, fuseFrames?, appearFrame?, ...} or nil
local function buildEntry(entity, attackEntry, frame)
    local cat = attackEntry.category
    local profile = Profiles.categories[cat]
    if not profile then return nil end

    local pos = entity.Position
    local kind = profile.kind
    local radius
    local vel = Vector(0, 0)
    local speed = 0

    if cat == "stomping" then
        radius = profile.radius

    elseif cat == "jumping" then
        radius = getJumpRadius(entity.Type)
        if profile.velScale and profile.velScale > 0 then
            vel = entity.Velocity * profile.velScale
            speed = vel:Length()
        end

    elseif cat == "laser" or cat == "ranged" then
        radius = profile.radius
        -- Direction: NPC -> player (laser fires toward player)
        local playerPos = getPlayerPosition()
        if playerPos then
            local delta = playerPos - pos
            if delta:Length() > 1 then
                vel = delta:Normalized() * (profile.pathLength or 480)
            end
        end
    end

    -- Tier 1 fields: fuseFrames and appearFrame
    -- fuseFrames: frames until the attack lands (windupFrames - already played)
    -- appearFrame: absolute frame when the threat becomes real
    -- NOTE: for npc_attack kind, future_motion uses appearFrame to determine existence
    -- NOTE: for laser kind, the entry is immediately active (no fuse delay in collision)
    local entry = {
        pos = pos,
        vel = vel,
        speed = speed,
        radius = radius,
        kind = kind,
    }

    -- Windup countdown (fuse): how many frames until the attack hits
    -- attackEntry.windupFrames = total windup frames for this animation
    -- entity:GetSprite():GetFrame() = current frame within animation (0-indexed)
    local okFrame, animFrame = pcall(function()
        return entity:GetSprite():GetFrame()
    end)
    if okFrame and type(animFrame) == "number" then
        local remaining = attackEntry.windupFrames - animFrame
        if remaining > 0 then
            entry.fuseFrames = remaining
            -- appearFrame for npc_attack kind (future_motion skips before this)
            if kind == "npc_attack" then
                entry.appearFrame = frame + remaining
            end
        end
    end

    return entry
end

-- ===== Public API =====

--- Collect active NPC attack precursors into tracker
function NpcAttackSensor.collect(player, tracker, frame, config)
    if not config.hazardNpcAttacks then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    -- If animDB failed to load, no coverage: clear and return
    if not animDB then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okAll, entities = pcall(Isaac.GetRoomEntities)
    if not okAll or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        local okNpc, isNpc = pcall(function()
            return e:ToNPC() ~= nil and e:IsActiveEnemy() and not e:IsDead()
                and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
        end)
        if okNpc and isNpc then
            local animLower = safeAnimationLower(e)
            if animLower ~= "" and not isExcludedAnimation(animLower) then
                local attackEntry = findAttackEntry(e.Type, e.Variant, animLower)
                if attackEntry then
                    local okBuild, entry = pcall(buildEntry, e, attackEntry, frame)
                    if okBuild and entry then
                        count = count + 1
                        entries[count] = {
                            index = e.Index + 10000, -- offset to avoid collision with entity Index
                            pos = entry.pos,
                            vel = entry.vel,
                            speed = entry.speed,
                            radius = entry.radius,
                            kind = entry.kind,
                            -- Tier 1 fields (transparent passthrough to tracker)
                            fuseFrames = entry.fuseFrames,
                            appearFrame = entry.appearFrame,
                        }
                    end
                end
            end
        end
    end

    tracker:update(entries, frame, "npc_attack")
end

function NpcAttackSensor.resetRoom()
    -- No state to reset (stateless sensor)
end

return NpcAttackSensor
