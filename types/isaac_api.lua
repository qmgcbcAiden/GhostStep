-- types/isaac_api.lua
-- Isaac Repentance+ API 类型声明（仅供 sumneko.lua LSP 使用，不参与运行时）
-- 覆盖本项目实际用到的 API，无需完整游戏 API 声明

---@meta

--================================================================
-- Vector
--================================================================

---@class Vector
---@field X number
---@field Y number
local Vector = {}

---@param x number
---@param y number
---@return Vector
function Vector.new(x, y) end

---@return number
function Vector:Length() end

---@return Vector
function Vector:Normalized() end

---@param other Vector
---@return number
function Vector:Distance(other) end

---@param other Vector
---@return number
function Vector:DistanceSquared(other) end

---@param other Vector
---@return number
function Vector:DistanceTo(other) end

---@param angle number
---@return Vector
function Vector:Rotated(angle) end

---@return number
function Vector:GetAngleDegrees() end

---@param a Vector|number
---@param b Vector|number
---@return Vector
function Vector.__add(a, b) end

---@param a Vector
---@param b Vector|number
---@return Vector
function Vector.__sub(a, b) end

---@param a Vector|number
---@param b Vector|number
---@return Vector
function Vector.__mul(a, b) end

---@param a Vector
---@param n number
---@return Vector
function Vector.__div(a, n) end

---@param a Vector
---@param b Vector
---@return boolean
function Vector.__eq(a, b) end

---@param a Vector
---@return string
function Vector.__tostring(a) end

-- 全局构造函数 Vector(x, y)
---@type fun(x: number, y: number): Vector
_G.Vector = nil

--================================================================
-- Isaac 全局命名空间
--================================================================

---@class IsaacNamespace
local Isaac = {}

---@return number
function Isaac.GetFrameCount() end

---@return number
function Isaac.GetTime() end

---@param msg string
function Isaac.DebugString(msg) end

---@return number
function Isaac.GetScreenWidth() end

---@return number
function Isaac.GetScreenHeight() end

---@param worldPos Vector
---@return Vector
function Isaac.WorldToScreen(worldPos) end

---@param str string
---@param x number
---@param y number
---@param r number
---@param g number
---@param b number
---@param a number
function Isaac.RenderText(str, x, y, r, g, b, a) end

---@return Entity[]
function Isaac.GetRoomEntities() end

---@param entityType integer
---@param variant? integer
---@param subtype? integer
---@param cache? boolean
---@return Entity[]
function Isaac.FindByType(entityType, variant, subtype, cache) end

---@param playerIndex? integer
---@return EntityPlayer
function Isaac.GetPlayer(playerIndex) end

---@type IsaacNamespace
_G.Isaac = nil

--================================================================
-- Game / Room / Level
--================================================================

---@class Game
local Game = {}

---@return Room
function Game:GetRoom() end

---@return Level
function Game:GetLevel() end

---@return number
function Game:GetNumPlayers() end

---@return Seeds
function Game:GetSeeds() end

---@return fun(): Game
_G.Game = nil

---@class Room
local Room = {}

---@return boolean
function Room:IsClear() end

---@return number
function Room:GetGridSize() end

---@return number
function Room:GetGridWidth() end

---@param index integer
---@return GridEntity|nil
function Room:GetGridEntity(index) end

---@param index integer
---@return Vector
function Room:GetGridPosition(index) end

---@class Level
local Level = {}

---@return integer
function Level:GetCurrentRoomIndex() end

---@return integer
function Level:GetStage() end

---@class Seeds
local Seeds = {}

---@return integer
function Seeds:GetStartSeed() end

--================================================================
-- Entity / EntityPlayer
--================================================================

---@class Entity
---@field Type integer
---@field Variant integer
---@field SubType integer
---@field Position Vector
---@field Velocity Vector
---@field HitPoints number
---@field MaxHitPoints number
---@field EntityFlag integer
---@field Sprite SpriteEntity
local Entity = {}

---@return boolean
function Entity:IsDead() end

---@return Vector
function Entity:GetMovementVector() end

---@param flag integer
---@return boolean
function Entity:HasEntityFlags(flag) end

---@class EntityPlayer : Entity
local EntityPlayer = {}

---@return integer
function EntityPlayer:GetPlayerType() end

---@return integer
function EntityPlayer:GetControllerIndex() end

---@return number
function EntityPlayer:GetHearts() end

---@return number
function EntityPlayer:GetMaxHearts() end

---@return EntityPlayer
_G.GetPlayer = nil -- not used directly but for completeness

--================================================================
-- Sprite (minimal)
--================================================================

---@class SpriteEntity
local SpriteEntity = {}

---@return number, number, number, number
function SpriteEntity:GetFrame() end

--================================================================
-- GridEntity
--================================================================

---@class GridEntity
---@field Desc GridEntityDesc
local GridEntity = {}

---@return integer
function GridEntity:GetType() end

---@return integer
function GridEntity:GetVariant() end

---@return Vector
function GridEntity:GetPosition() end

---@class GridEntityDesc
---@field Type integer
---@field Variant integer

--================================================================
-- 全局枚举
--================================================================

---@class EntityTypeTable
---@field ENTITY_PLAYER integer
---@field ENTITY_TEAR integer
---@field ENTITY_FAMILIAR integer
---@field ENTITY_BOMB integer
---@field ENTITY_LASER integer
---@field ENTITY_KNIFE integer
---@field ENTITY_PROJECTILE integer
---@field ENTITY_EFFECT integer
---@field ENTITY_NPC integer
---@type EntityTypeTable
_G.EntityType = nil

---@class GridEntityTypeTable
---@field GRID_SPIKES integer
---@field GRID_SPIKES_ONOFF integer
---@field GRID_ROCK_SPIKED integer
---@field GRID_TNT integer
---@field GRID_SPIDERWEB integer
---@type GridEntityTypeTable
_G.GridEntityType = nil

---@class GridCollisionClassTable
---@field COLLISION_NONE integer
---@field COLLISION_SOLID integer
---@field COLLISION_WALL integer
---@field COLLISION_PIT integer
---@field COLLISION_OBJECT integer
---@type GridCollisionClassTable
_G.GridCollisionClass = nil

---@class ButtonActionTable
---@field ACTION_LEFT integer
---@field ACTION_RIGHT integer
---@field ACTION_UP integer
---@field ACTION_DOWN integer
---@field ACTION_SHOOTLEFT integer
---@field ACTION_SHOOTRIGHT integer
---@field ACTION_SHOOTUP integer
---@field ACTION_SHOOTDOWN integer
---@type ButtonActionTable
_G.ButtonAction = nil

---@class InputHookTable
---@field GET_ACTION_VALUE integer
---@field IS_ACTION_PRESSED integer
---@field IS_ACTION_TRIGGERED integer
---@type InputHookTable
_G.InputHook = nil

---@class EntityFlagTable
---@field FLAG_FRIENDLY integer
---@type EntityFlagTable
_G.EntityFlag = nil

---@class EffectVariantTable
---@field CREEP_RED integer
---@field CREEP_GREEN integer
---@field CREEP_YELLOW integer
---@field CREEP_WHITE integer
---@field CREEP_BLACK integer
---@field CREEP_BROWN integer
---@field HOT_BOMB_FIRE integer
---@field RED_CANDLE_FLAME integer
---@field SHOCKWAVE integer
---@field SHOCKWAVE_DIRECTIONAL integer
---@field CRACKWAVE integer
---@field MOM_FOOT_STOMP integer
---@field TARGET integer
---@field ROCKET integer
---@field MOMS_HAND integer
---@field BULLET_POOF integer
---@field TEAR_POOF_A integer
---@field BOMB_CRATER integer
---@field DUST_CLOUD integer
---@type EffectVariantTable
_G.EffectVariant = nil

---@class ModCallbacksTable
---@field MC_POST_PLAYER_UPDATE integer
---@field MC_INPUT_ACTION integer
---@field MC_POST_NEW_ROOM integer
---@field MC_POST_RENDER integer
---@field MC_POST_PLAYER_DEATH integer
---@field MC_ENTITY_TAKE_DMG integer
---@field MC_PRE_GAME_EXIT integer
---@type ModCallbacksTable
_G.ModCallbacks = nil

--================================================================
-- Input 全局
--================================================================

---@class InputNamespace
local Input = {}

---@param button integer
---@param controllerIndex? integer
---@return boolean
function Input.IsButtonTriggered(button, controllerIndex) end

---@param action integer
---@param controllerIndex? integer
---@return boolean
function Input.IsActionPressed(action, controllerIndex) end

---@param action integer
---@param controllerIndex? integer
---@return number
function Input.GetActionValue(action, controllerIndex) end

---@type InputNamespace
_G.Input = nil

--================================================================
-- ModConfigMenu（外部 MCM mod 注入的全局）
--================================================================

---@class ModConfigMenu
local ModConfigMenu = {}

---@class ModConfigMenuOptionType
---@field BOOLEAN integer
---@field NUMBER integer
---@field KEYBIND_KEYBOARD integer
---@field SCROLL integer

---@type ModConfigMenuOptionType
ModConfigMenu.OptionType = nil

---@param mod string
---@param subcategory string
---@param settings table
function ModConfigMenu.AddSetting(mod, subcategory, settings) end

---@param mod string
---@param subcategory? string
---@param info table
function ModConfigMenu.UpdateCategory(mod, subcategory, info) end

---@param mod string
---@param subcategory string
---@param title string
function ModConfigMenu.AddTitle(mod, subcategory, title) end

---@param mod string
---@param subcategory string
---@param text string|fun(): string
function ModConfigMenu.AddText(mod, subcategory, text) end

---@param mod string
---@param subcategory string
---@param count? integer
function ModConfigMenu.AddSpace(mod, subcategory, count) end

---@type ModConfigMenu
_G.ModConfigMenu = nil
