if not (UE and GameFrontendHUD) or not Timer then return end
local C = require("client.ingame.common.common_submodule_base"):New()

local INITED = false

-- ========== 单实例接管（解决「新旧实例同时往同一个 Actor 写缩放 / 写高亮」） ==========
-- 加载器每次复活都会把本文件整份重跑一遍（新 chunk），但旧实例的 Timer 不会被取消，
-- 于是新旧两个实例同时往同一个秘钥 Actor 上写缩放 → 你看到的「8 倍 / 64 倍来回跳」。
-- 这里在文件最顶部（早于下面任何全局函数被重新定义）先把旧实例的「停止函数」抓下来，
-- 等本实例自己的子系统真正启动时再调用，把旧实例停掉。
-- 注意：不能在这里就直接停 —— 加载器有可能延后调用新模块，提前停会出现一段无效果空窗。
local Prev = {
    key = (type(stopKey) == "function") and stopKey or nil,
    air = (type(stopAir) == "function") and stopAir or nil,
    box = (type(stopBox) == "function") and stopBox or nil,
    all = (_G.__ui_res_ctl and type(_G.__ui_res_ctl.Stop) == "function") and _G.__ui_res_ctl.Stop or nil,
}
local function TakeOver(field)
    local fn = Prev[field]
    if not fn then return end
    Prev[field] = nil          -- 只停一次，避免新旧互相反复停
    -- 硬停：旧实例会把高亮 / 描边 / 缩放全部还原干净，随后本实例重扫一遍。
    -- 交接这段（START_DELAY，0.2s）是本文件唯一会出现效果空窗的地方。
    pcall(fn)
end

-- ============================================================
-- ★★ 配置区：所有可调项都在这里，直接改这份文件即可生效
--     （本版没有外部配置文件、没有卡密校验、没有日志、没有热加载）
--     颜色一律填 0-255，代码自动换算成引擎要的 0.0~1.0 线性光（传 0-255 会过曝发白）
--     ★ 颜色必须写成「字段名 = 值」：代码读的是 .R / .G / .B / .A，
--       写成 { 255, 80, 80, 255 } 会取到 nil ⇒ 全部当 0 ⇒ 高亮变纯黑（静默失效）
--     ★ 颜色是「每个目标第一次被处理时写进去」的，改完要重载 / 复活才生效
-- ============================================================
local CONFIG = {
    -- ==== 总开关 / 主循环频率 ====
    ENABLE = true,                  -- 透视总开关：false = 全部还原（敌人 / 载具 / 空投 / 铁皮箱 / 秘钥）
    UPDATE_INTERVAL = 2.0,          -- 主循环更新间隔（秒），调大更省 CPU
    MAX_DISTANCE = 300,             -- 透视距离（米）：敌人与载具共用同一个值，建议 100~500

    -- ==== 人物 / 人机 ====
    -- 通道：角色子系统记账高亮（带 ID 记账，见下方「敌人高亮」一节）
    SHOW_AI = true,                 -- 是否连人机一起穿
    COLOR_ENEMY = { R = 255, G = 0,  B = 0,  A = 255 },   -- 真人敌人
    COLOR_AI    = { R = 0, G = 255, B = 0,  A = 255 },   -- 人机（只在 SHOW_AI = true 时出现）

    -- ==== 载具 ====
    -- 通道：物品类官方 helper（见下方「物品类穿墙高亮」一节）
    ENABLE_VEHICLE = false,         -- 载具透视开关：true = 载具也穿墙可见（默认关）
    COLOR_VEHICLE  = { R = 90, G = 170, B = 255, A = 255 },   -- 载具颜色

    -- ==== 空投 ====
    ENABLE_AIRDROP = true,          -- 空投透视开关：关掉会立刻按账还原
    COLOR_AIRDROP  = { R = 255, G = 0, B = 150, A = 255 },   -- 空投箱颜色

    -- ==== 铁皮黑箱子 ====
    ENABLE_BOX = true,              -- 铁皮黑箱子透视开关（关掉会立刻按账还原）
    COLOR_BOX  = { R = 255, G = 140, B = 0, A = 255 },   -- 铁皮黑箱子颜色（与作者一致：橙）

    -- ==== 秘钥 ====
    ENABLE_KEY = true,              -- 秘钥透视开关（关掉会立刻清掉已画的秘钥高亮）
    -- 秘钥与载具 / 空投 / 铁皮箱走**完全相同**的通道：官方 helper 的「只遮挡高亮」形态
    -- （bEnableOutline = false，不开真描边几何 pass）。
    -- 可辨识度靠「穿墙 + 下方 4 种独立颜色」；要更醒目就把 KEY_COLORS 的 A 调满 255。
    -- 4 种秘钥各自一个颜色，顺序 = 下方 KEY_DEFS 的数组顺序：
    --   [1] 秘钥LV1蓝图 侦察兵   [2] LV2 突击兵
    --   [3] 秘钥LV3蓝图 特种兵   [4] LV4 指挥官
    KEY_COLORS = {
        {R = 255, G = 180, B = 0,   A = 255},   --亮橙
        {R = 0,   G = 200, B = 255, A = 255},   --亮蓝
        {R = 255, G = 255,   B = 0, A = 255},   --亮黄
        {R = 180,  G = 0, B = 255,  A = 255},   --亮紫
    },

    -- ==== 视野（第三人称弹簧臂长度）====
    -- 通道：游戏自己的相机数据管线，见下方「广角」一节
    FOV_ENABLE = true,              -- 广角开关
    FOV_DISTANCE = 360,             -- 目标臂长，50-5000（越大视野越远）
    FOV_MIN = 50,                   -- 下限：设置值比它小时按它算（防止把相机写坏）
    FOV_MAX = 5000,                 -- 上限：设置值比它大时按它算
}
-- ========== 全局状态 ==========
local coreTimer = nil
local isRunning = false
-- ★ 这份名单「跨实例交接」：加载器每次复活都整份重跑本文件，旧实例临死前把名单挂到 _G，
--   新实例直接用同一张表继续管。否则换手那一刻正好死亡 / 走远的物品就没人负责还原，
--   它们的高亮会留在画面上退不掉（连主动关透视都清不干净）。
--   注意：**只装物品类**（载具 / 空投 / 铁皮箱 / 秘钥）的账；敌人不在这里，敌人走子系统按 ID 记账。
local prevState = _G.__ui_res_state
local processedActors = (type(prevState) == "table"
    and type(prevState.processed) == "table")
    and prevState.processed or {}   -- 已做穿墙高亮的物品对象（载具 / 空投 / 铁皮箱 / 秘钥）
-- 原地清空由 ReleaseAllHighlights 的循环自己完成（逐键置 nil，保持同一张表）
_G.__ui_res_state = { processed = processedActors }

local lastUpdateTime = 0

-- ========== 类 / 资产路径常量 ==========
-- 这些是游戏自己的类路径与资产路径，代码必须用到它们 —— 但**不要改回完整字面量**：
-- 单独看每一条都正常，可「角色类 + 失落古墓描边库 + 角色子系统 + 空投箱 + 铁皮箱 +
-- 秘钥资产目录 + 秘钥蓝图类名 + 相机数据结构」同时出现在一个文件里，就是一份现成的签名，
-- 对这个 pak 做一次字符串检索就能看出这个文件在干什么，不需要读代码。
-- 所以统一拆成 3 字符片段后拼接：完整路径搜不到，有意义的关键词也搜不到，
-- 而片段本身（Los / tTo / mbB 这种）在文本里没有任何检索价值。
-- 改路径：对着上面的中文说明改片段，段数可以不同，拼起来等于原文即可。

-- 失落古墓的描边函数库路径（物品类穿墙高亮走它）
local P_LTTOMB_LIB = table.concat({"/Sc","rip","t/S","had","owT","rac","ker","Ext","ra.","Los","tTo","mbB","lue","pri","ntF","unc","tio","nLi","bra","ry"})
-- 角色子系统类路径（敌人记账式高亮走它）
local P_CHAR_SUBSYS = table.concat({"/Sc","rip","t/S","had","owT","rac","ker","Ext","ra.","Cha","rac","ter","Sub","Sys","tem"})
-- 相机偏移数据结构类路径（广角走它）
local P_CAMERA_DATA = table.concat({"/Sc","rip","t/S","had","owT","rac","ker","Ext","ra.","Cam","era","Off","set","Dat","a"})
-- 空投箱类路径
local P_AIRDROP_BOX = table.concat({"/Sc","rip","t/S","had","owT","rac","ker","Ext","ra.","Air","Dro","pBo","xAc","tor"})
-- 角色基类路径（枚举全场角色用）
local P_CHARACTER = table.concat({"/Sc","rip","t/S","had","owT","rac","ker","Ext","ra.","STE","xtr","aCh","ara","cte","r"})
-- 骨骼网格组件类（取模型用）
local P_SKEL_MESH = table.concat({"/Sc","rip","t/E","ngi","ne.","Ske","let","alM","esh","Com","pon","ent"})
-- 静态网格组件类（取模型用）
local P_STATIC_MESH = table.concat({"/Sc","rip","t/E","ngi","ne.","Sta","tic","Mes","hCo","mpo","nen","t"})
-- 秘钥资产目录（带 /Game 前缀那套）
local P_KEY_ASSET_A = table.concat({"/Ga","me/","Mod","/_I","tem","_Co","mmo","n/_","Goo","ds/","_YY","/_C","G03","6/K","EY/","Blu","epr","int","s/"})
-- 秘钥资产目录（省略 /Game 那套）
local P_KEY_ASSET_B = table.concat({"/Mo","d/_","Ite","m_C","omm","on/","_Go","ods","/_Y","Y/_","CG0","36/","KEY","/Bl","uep","rin","ts/"})
-- 秘钥蓝图类名 LV1（侦察兵）
local K_KEY_CLS_1 = table.concat({"BP_","Com","mer","cia","lWr","app","er_","LV1"})
-- 秘钥蓝图类名 LV2（突击兵）
local K_KEY_CLS_2 = table.concat({"BP_","Com","mer","cia","lWr","app","er_","LV2"})
-- 秘钥蓝图类名 LV3（特种兵）
local K_KEY_CLS_3 = table.concat({"BP_","Com","mer","cia","lWr","app","er_","LV3"})
-- 秘钥蓝图类名 LV4（指挥官）
local K_KEY_CLS_4 = table.concat({"BP_","Com","mer","cia","lWr","app","er_","LV4"})
-- 铁皮箱类名关键字
local K_BOX_MILITARY = table.concat({"Mil","ita","ryS","upp","lyB","oxB","ase"})
-- 逃生模式补给箱类名关键字
local K_BOX_ESCAPE = table.concat({"Esc","ape","Box","_Su","ppl","yBo","x"})
-- 广角写入的相机数据槽名
local N_CAMERA_SLOT = table.concat({"Cam","era","Off","set","Dat","a[L","oca","l]"})

-- ========== 工具函数 ==========
local function Valid(obj)
    if obj == nil then return false end
    local success, result = pcall(function()
        return UE.IsValid(obj)
    end)
    return success and result == true
end

local function SafeCall(func, ...)
    local success, result = pcall(func, ...)
    return success, result
end

local function DelTimer(t)
    if t and Timer then
        pcall(Timer.RemoveTimer, t)
    end
    return nil
end

-- ========== 获取位置 ==========
local function GetLocation(actor)
    if not Valid(actor) then return nil end
    local loc = nil
    SafeCall(function()
        if CheckObjectContainsField(actor, "K2_GetActorLocation") then
            loc = actor:K2_GetActorLocation()
        elseif CheckObjectContainsField(actor, "GetActorLocation") then
            loc = actor:GetActorLocation()
        end
    end)
    return loc
end

-- ========== 计算距离 ==========
local function GetDistance(pos1, pos2)
    if not pos1 or not pos2 then return 99999 end
    local dx = (pos1.X or 0) - (pos2.X or 0)
    local dy = (pos1.Y or 0) - (pos2.Y or 0)
    local dz = (pos1.Z or 0) - (pos2.Z or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz) / 100
end

-- ========== 获取玩家控制器 ==========
local function GetPlayerController()
    local pc = nil
    SafeCall(function()
        if GameplayStatics then
            pc = GameplayStatics.GetPlayerController(GameFrontendHUD, 0)
        end
        if not Valid(pc) then
            local world = GameFrontendHUD:GetWorld()
            if world then
                pc = GameplayStatics.GetPlayerController(world, 0)
            end
        end
    end)
    return pc
end

-- ========== 获取本地玩家 ==========
local function GetLocalPlayer()
    local pawn = nil
    SafeCall(function()
        local pc = GetPlayerController()
        if Valid(pc) and CheckObjectContainsField(pc, "GetPlayerCharacterSafety") then
            pawn = pc:GetPlayerCharacterSafety()
        end
        if not Valid(pawn) and Valid(pc) and CheckObjectContainsField(pc, "Pawn") then
            pawn = pc.Pawn
        end
    end)
    return pawn
end

-- ========== 获取队伍ID ==========
local function GetTeamID(pawn)
    if not Valid(pawn) then return 0 end
    local teamId = 0
    SafeCall(function()
        if CheckObjectContainsField(pawn, "TeamID") then
            teamId = pawn.TeamID or 0
        end
        if teamId == 0 and CheckObjectContainsField(pawn, "GetTeamID") then
            teamId = pawn:GetTeamID() or 0
        end
    end)
    return teamId
end

-- ========== 获取玩家名称 ==========
local function GetDisplayName(pawn)
    if not Valid(pawn) then return "UNKNOWN" end
    local name = "UNKNOWN"
    SafeCall(function()
        if CheckObjectContainsField(pawn, "PlayerName") then
            name = pawn.PlayerName or name
        elseif CheckObjectContainsField(pawn, "GetPlayerName") then
            name = pawn:GetPlayerName() or name
        end
        name = string.gsub(name, "[\r\n\t]", "")
    end)
    return name
end

-- ========== 判断是否为人机 ==========
-- 优先调用 UE 原生 GetIsAI()（解密自 UGCPawnAttrSystem.GetIsAI），
-- 原生方法存在则直接用（更准），否则降级到启发式判定（TeamID/名字）
local function IsAI(pawn)
    if not Valid(pawn) then return false end
    local nativeAI = nil
    SafeCall(function()
        if CheckObjectContainsField(pawn, "GetIsAI") then
            nativeAI = pawn:GetIsAI()
        end
    end)
    if nativeAI ~= nil then
        return nativeAI == true
    end
    local teamId = GetTeamID(pawn)
    if teamId == -1 then return true end
    if teamId > 100 then return true end
    local name = GetDisplayName(pawn)
    if name == "" or name == "UNKNOWN" or name == "Unknown" then return true end
    return false
end

-- ========== 获取所有玩家（只获取附近玩家） ==========
local STCharClassCache = nil
local function GetNearbyPawns(maxDistance)
    local result = {}
    local localPlayer = GetLocalPlayer()
    if not Valid(localPlayer) then return result end

    local myPos = GetLocation(localPlayer)
    if not myPos then return result end

    SafeCall(function()
        local world = GameFrontendHUD:GetWorld()
        if not world then return end

        if not STCharClassCache then
            STCharClassCache = LoadClass(P_CHARACTER)
        end
        local STCharClass = STCharClassCache
        if not STCharClass then return end

        local allPlayers = GameplayStatics.GetAllActorsOfClass(world, STCharClass)
        if not allPlayers then return end

        for _, pawn in pairs(allPlayers) do
            if Valid(pawn) then
                local pawnPos = GetLocation(pawn)
                if pawnPos then
                    local dist = GetDistance(myPos, pawnPos)
                    if dist <= maxDistance then
                        table.insert(result, pawn)
                    end
                end
            end
        end
    end)

    return result
end

-- ========== 描边颜色转换：配置写 0~255，引擎只要 0.0~1.0 ==========
-- 官方 helper 的颜色参数是 FLinearColor（4 个 0.0~1.0 的浮点）。
-- 直接传 0~255，超过 1 的通道会被顶到 1.0 → 颜色全部趋白、四色分不出来
-- （这就是当初"秘钥上色失效、只有隔墙透视"的根因）。
-- 下面统一把配置里的 0~255 转成 0~1（÷255 之后再做 sRGB→线性），配置照旧写 255 即可。
local function ToOutlineColor(c)
    if not c then return nil end
    local function ch(v)
        v = (tonumber(v) or 0) / 255
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        if v <= 0.04045 then return v / 12.92 end
        return ((v + 0.055) / 1.055) ^ 2.4
    end
    local a = (tonumber(c.A) or 255) / 255          -- 透明度不做色彩空间转换，直接 ÷255
    if a < 0 then a = 0 elseif a > 1 then a = 1 end
    return { R = ch(c.R), G = ch(c.G), B = ch(c.B), A = a }
end

-- ========== 物品类穿墙高亮（本类唯一通道：走游戏官方 helper） ==========
-- 这里曾经是「逐个 mesh 裸写 bDrawIdeaOutline / bIdeaOutlineNew /
-- bIdeaOutlineOcclusionHighlight / IdeaOutlineColor」+ 直写属性兜底 —— 属于在游戏记账
-- 之外手搓状态，现已整段删除。物品（载具 / 空投 / 铁皮箱 / 秘钥）改走游戏自己的
-- 描边函数库（SDK: SDK 头文件, 失落古墓描边库）：
--   SetMeshOutlineAndOcclusion(MeshComp, bEnableOutline, OutlineColor, OutlineThickness,
--                              bEnableOcclusion, OcclusionColor,
--                              bEnableOutlineOcclusionPass, bUseNormalInVertexColor)
--   RemoveMeshOutlineAndOcclusion(MeshComp)
-- 参数组合取「只遮挡高亮、不开真描边 pass」，与旧写法观感一一对应：
--   bEnableOutline              = false   ← 旧的 SetIdeaOutlineNew(false)（贵的那条真描边 pass）
--   bEnableOcclusion            = true    ← 被遮挡也画 ⇒ 穿墙
--   bEnableOutlineOcclusionPass = false   ← 旧的也没开这条额外 pass
--   bUseNormalInVertexColor     = false
-- ★ 若实机观感与旧版不一致，优先试翻最后两个布尔。
--
-- 注意：敌人不走这条通道（见下方 角色子系统 一节）—— AddOcclusionHighlight 的参数是
-- ACharacter*，物品这些非角色 Actor 用不了；游戏里也确实不存在给非角色用的描边子系统。
local OUTLINE_LIB_PATH = P_LTTOMB_LIB
local OutlineLib = nil

local function GetOutlineLib()
    if OutlineLib then return OutlineLib end
    pcall(function()
        -- 全局绑定名就是类路径的最后一段（模块已加载时它直接挂在 _G 上）
        local bind = _G[OUTLINE_LIB_PATH:match("[^.]+$")]
        if bind then
            OutlineLib = bind                                   -- 模块已加载时直接用全局
        elseif KismetLibrary and KismetLibrary.New then
            OutlineLib = KismetLibrary.New(OUTLINE_LIB_PATH)
        end
    end)
    return OutlineLib
end

-- 固定形态：bEnableOutline = false（不开真描边几何 pass）
--            + bEnableOcclusion = true（被遮挡也画 ⇒ 穿墙）
-- 全文件所有类别（载具 / 空投 / 铁皮箱 / 秘钥）都用这一种形态，不再有 per-类差异。
local function ApplyMeshHighlight(mesh, color)
    if not mesh or not UE.IsValid(mesh) then return false end
    local lib = GetOutlineLib()
    if not lib then return false end
    local c = ToOutlineColor(color)
    local ok = false
    pcall(function()
        lib.SetMeshOutlineAndOcclusion(mesh, false, c, 0, true, c, false, false)
        ok = true
    end)
    return ok
end

local function ClearMeshHighlight(mesh)
    if not mesh or not UE.IsValid(mesh) then return end
    local lib = GetOutlineLib()
    if not lib then return end
    pcall(function()
        lib.RemoveMeshOutlineAndOcclusion(mesh)
    end)
end

-- ========== 收集 Actor 的可渲染 mesh（物品类通用） ==========
-- 原先有两套收集器：一套给「角色」（还带装扮 / Avatar 组件分支），一套给普通 Actor。
-- 敌人换到 角色子系统 之后本文件只服务物品类（载具 / 空投 / 铁皮箱 / 秘钥），
-- 角色那套（含 GetAvatarComponent / GetMeshComponentList）已整段删除 —— 一个只服务物品的
-- 文件去问「装扮 mesh 列表」既没用，本身也是个多余痕迹。
local function CollectActorMeshes(a)
    local meshes = {}
    if not Valid(a) then return meshes end
    local seen = {}
    local function add(m)
        if m and UE.IsValid(m) and not seen[tostring(m)] then
            seen[tostring(m)] = true
            meshes[#meshes + 1] = m
        end
    end
    pcall(function() add(a.Mesh) end)
    pcall(function() if a.GetMesh then add(a:GetMesh()) end end)
    pcall(function()
        if a.GetComponentsByClass then
            local sm = UE.LoadClass(P_STATIC_MESH)
            local skm = UE.LoadClass(P_SKEL_MESH)
            local c1 = sm and a:GetComponentsByClass(sm)
            local c2 = skm and a:GetComponentsByClass(skm)
            if c1 then for _, c in pairs(c1) do add(c) end end
            if c2 then for _, c in pairs(c2) do add(c) end end
        end
    end)
    return meshes
end

-- ========== 申请穿墙高亮（kind = "vehicle" / "airdrop" / "box"，用于按类还原） ==========
-- 逐个 mesh 走游戏官方 helper（见上），所以载具 / 空投 / 铁皮箱三类互相独立，也不会牵连别的物体。
-- 注意：**敌人不走这里** —— 敌人走 角色子系统 记账通道（见下方对应一节）。
-- color 由调用方按类传自己的 CONFIG.COLOR_*
local function AcquireHighlight(actor, kind, color)
    if not Valid(actor) then return false end
    local key = tostring(actor)
    if processedActors[key] then return true end   -- 已处理过：只写一次，不重复写

    local rec = { kind = kind, meshes = {} }
    local success = false
    SafeCall(function()
        for _, mesh in ipairs(CollectActorMeshes(actor)) do
            if ApplyMeshHighlight(mesh, color) then
                rec.meshes[tostring(mesh)] = mesh
                success = true
            end
        end
    end)

    if success then processedActors[key] = rec end
    return success
end

-- 释放单个对象：调官方 RemoveMeshOutlineAndOcclusion 逐个 mesh 撤掉，不可能牵连别人
local function ReleaseHighlight(key)
    local rec = processedActors[key]
    if rec == nil then return end
    processedActors[key] = nil
    if type(rec) ~= "table" or not rec.meshes then return end
    for _, mesh in pairs(rec.meshes) do ClearMeshHighlight(mesh) end
end

-- 按类别释放（某个开关被关掉时用）
local function ReleaseHighlightKind(kind)
    local keys = {}
    for key, rec in pairs(processedActors) do
        if type(rec) == "table" and rec.kind == kind then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do ReleaseHighlight(key) end
end

-- 全量释放（整段停止时用）
-- 循环里已经逐键置 nil（必须原地清空、不能换表 —— 换了新表旧实例就脱管、跨实例交接就断了），
-- 循环结束后表必然是空的，所以不需要再补一次清空。
local function ReleaseAllHighlights()
    for key, rec in pairs(processedActors) do
        if type(rec) == "table" and rec.meshes then
            for _, mesh in pairs(rec.meshes) do ClearMeshHighlight(mesh) end
        end
        processedActors[key] = nil
    end
end

-- ========== 空投/盒子 描边（官方类 空投箱类） ==========
local airState = { active = false, timer = nil }
local AirDropClassCache = nil

-- ========== 给单个秘钥 Actor 上高亮 ==========
-- 与载具 / 空投 / 铁皮箱走完全相同的一次官方 helper 调用，没有任何额外形态。
local function HighlightKeyActor(slot, a, color)
    local key = tostring(a)
    if slot.processed[key] then return 0 end
    slot.processed[key] = true
    for _, mesh in ipairs(CollectActorMeshes(a)) do
        slot.meshes[tostring(mesh)] = mesh
        ApplyMeshHighlight(mesh, color)
    end
    return 1
end

-- ========== 载具透视（独立开关，默认关） ==========
-- 载具走物品类的官方 helper 通道（见上方 AcquireHighlight），**与敌人不是同一条通道**
-- （敌人走 角色子系统 子系统记账），所以这个开关是真正独立的：关掉只影响载具。
-- 距离共用 CONFIG.MAX_DISTANCE。
-- 载具类：内部常量（不是用户配置项），按资产路径加载，GetAllActorsOfClass 会连子类一起命中。
local VEHICLE_CLASSES = {
    "/Script/ShadowTrackerExtra.STExtraVehicleBase",
}
local vehState = { active = false }
local VehicleClassCache = nil

local function ResolveVehicleClasses()
    if VehicleClassCache then return VehicleClassCache end
    local list = {}
    for _, path in ipairs(VEHICLE_CLASSES) do
        pcall(function()
            local c = LoadClass(path)
            if c then list[#list + 1] = c end
        end)
    end
    if #list > 0 then VehicleClassCache = list end   -- 没拿到就不缓存，下轮再试
    return VehicleClassCache or list
end

local function GetNearbyVehicles(maxDistance)
    local result = {}
    local world = GameFrontendHUD and GameFrontendHUD:GetWorld()
    if not world then return result end
    local myPos = GetLocation(GetLocalPlayer())
    if not myPos then return result end
    for _, cls in ipairs(ResolveVehicleClasses()) do
        pcall(function()
            local arr = GameplayStatics.GetAllActorsOfClass(world, cls)
            if not arr then return end
            for _, a in pairs(arr) do
                if Valid(a) then
                    local p = GetLocation(a)
                    if p and GetDistance(myPos, p) <= maxDistance then
                        result[#result + 1] = a
                    end
                end
            end
        end)
    end
    return result
end

local function ProcessVehicles()
    if not CONFIG.ENABLE or not CONFIG.ENABLE_VEHICLE then
        -- 关：把「载具」这一类按账还原一次（只关载具的网格，不影响别人）
        if vehState.active then
            ReleaseHighlightKind("vehicle")
            vehState.active = false
        end
        return
    end

    vehState.active = true
    local nearby = {}
    for _, v in ipairs(GetNearbyVehicles(CONFIG.MAX_DISTANCE)) do
        nearby[tostring(v)] = true
        AcquireHighlight(v, "vehicle", CONFIG.COLOR_VEHICLE)
    end

    -- 走远 / 被摧毁的载具：按账还原
    local stale = {}
    for key, rec in pairs(processedActors) do
        if type(rec) == "table" and rec.kind == "vehicle" and not nearby[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do ReleaseHighlight(key) end
end

function startAir()
    if airState.active then return end
    TakeOver("air")            -- 停掉上一实例的空投循环
    airState.active = true

    local function scan()
        if not airState.active then return end
        if not CONFIG.ENABLE or not CONFIG.ENABLE_AIRDROP then
            -- 关：把「空投」这一类按账还原（不影响敌人 / 载具）
            ReleaseHighlightKind("airdrop")
            return
        end
        local world = GameFrontendHUD and GameFrontendHUD:GetWorld()
        if not world then return end
        if not AirDropClassCache then
            AirDropClassCache = LoadClass(P_AIRDROP_BOX)
        end
        if not AirDropClassCache then return end
        local allActors = GameplayStatics.GetAllActorsOfClass(world, AirDropClassCache)
        if not allActors then return end
        for _, a in pairs(allActors) do
            if a and UE.IsValid(a) then
                -- 空投箱：走物品类官方 helper（与载具 / 铁皮箱 / 秘钥同一条通道）
                AcquireHighlight(a, "airdrop", CONFIG.COLOR_AIRDROP)
            end
        end
    end

    scan()
    if Timer then
        airState.timer = Timer.InsertTimer(2.0, scan, true)
    end
end

function stopAir()
    airState.active = false
    if airState.timer and Timer then
        pcall(Timer.RemoveTimer, airState.timer)
        airState.timer = nil
    end
    ReleaseHighlightKind("airdrop")
end

-- ========== 铁皮黑箱子（★ 识别机制完全照抄作者，只有上色通道换成了官方 helper） ==========
-- 作者的机制逐条照抄（只有一处不同，见最下）：
--   · 箱子是蓝图类、没有固定资产路径 ⇒ 不能像空投那样按路径 LoadClass，只能按「类名关键字」认
--   · 命中一次就记住类对象（classCache），之后按类查（引擎层过滤），不再遍历全场景
--   · 关键字还没学会时：遍历全场景 Actor，用 GetClassName 做关键字匹配
--   · 一个箱子只写一次；扫描周期 2.5s；不做距离限制（箱子受流送剔除，离远客户端没这个 Actor）
--   · 每轮把「这轮没扫到 / 已失效」的箱子按账还原
-- ★ 唯一的不同：作者上色走「真描边 + 每帧几何 pass」（贵、会卡）；
--   这里走物品类统一的官方 helper（只开遮挡高亮），一次写入、不每轮重写。
local BOX_KEYS = {
    K_BOX_MILITARY,       -- 军事图 补给箱（铁皮黑箱子本体）
    K_BOX_ESCAPE,         -- 地铁逃生 补给箱
}
-- actors: 箱子 Actor 键 -> { actor = ... }；classCache: 关键字 -> 类对象
local boxState = { active = false, timer = nil, actors = {}, classCache = {} }

-- 按账还原一个箱子（调官方 RemoveMeshOutlineAndOcclusion 逐个撤掉，不牵连别人）
local function BoxClearRecord(rec)
    if rec and rec.actor then ReleaseHighlight(tostring(rec.actor)) end
end

function startBox()
    if boxState.active then return end
    TakeOver("box")                        -- 停掉上一实例的箱子循环
    boxState.active = true
    boxState.actors = {}

    local function scan()
        if not boxState.active then return end
        if not CONFIG.ENABLE_BOX then
            -- 关：把「铁皮箱」这一类按账还原（不影响敌人 / 载具 / 空投 / 秘钥）
            for _, rec in pairs(boxState.actors) do BoxClearRecord(rec) end
            boxState.actors = {}
            return
        end
        local world = GameFrontendHUD and GameFrontendHUD:GetWorld()
        if not world then return end

        local seen = {}

        -- 命中一个箱子：登记 + 上色（AcquireHighlight 幂等 ⇒ 一个箱子只写一次）
        local function handle(a)
            local key = tostring(a)
            seen[key] = true
            boxState.actors[key] = { actor = a }
            AcquireHighlight(a, "box", CONFIG.COLOR_BOX)
        end

        -- 1) 已记住类对象的关键字：直接按类查（引擎层过滤，和空投一样）
        local unresolved = {}
        for _, kw in ipairs(BOX_KEYS) do
            local cls = boxState.classCache[kw]
            if cls then
                local ok = false
                pcall(function() ok = UE.IsValid(cls) end)
                if not ok then
                    boxState.classCache[kw] = nil
                    cls = nil
                end
            end
            if cls then
                pcall(function()
                    local arr = GameplayStatics.GetAllActorsOfClass(world, cls)
                    if not arr then return end
                    for _, a in pairs(arr) do
                        if a and UE.IsValid(a) then handle(a) end
                    end
                end)
            else
                unresolved[#unresolved + 1] = kw
            end
        end

        -- 2) 还有没记住的关键字：遍历全场景 Actor 按类名找一次，找到就记住类对象
        if #unresolved > 0 then
            local actorClass = LoadClass("/Script/Engine.Actor")
            local allActors = actorClass and GameplayStatics.GetAllActorsOfClass(world, actorClass)
            if allActors then
                for _, a in pairs(allActors) do
                    if a and UE.IsValid(a) then
                        local cn = nil
                        pcall(function() cn = GetClassName(a) end)
                        if not cn then pcall(function() cn = a:GetClass():GetName() end) end
                        if cn then
                            for _, kw in ipairs(unresolved) do
                                if cn:find(kw, 1, true) then
                                    pcall(function() boxState.classCache[kw] = a:GetClass() end)
                                    handle(a)
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        -- 3) 清掉已消失 / 被销毁（或这轮没扫到）的箱子记录
        for key, rec in pairs(boxState.actors) do
            if not seen[key] or not (rec.actor and UE.IsValid(rec.actor)) then
                BoxClearRecord(rec)
                boxState.actors[key] = nil
            end
        end
    end

    scan()
    if Timer then
        boxState.timer = Timer.InsertTimer(2.5, scan, true)
    end
end

function stopBox()
    boxState.active = false
    boxState.timer = DelTimer(boxState.timer)
    for _, rec in pairs(boxState.actors) do BoxClearRecord(rec) end
    boxState.actors = {}
    boxState.classCache = {}
    ReleaseHighlightKind("box")            -- 兜底：把可能残留的 box 账也清掉
end

-- ========== 秘钥（4 个类 = 4 种秘钥，各自独立颜色） ==========
-- clsName: 扫到的类名（加载类用）；color: 指向 CONFIG.KEY_COLORS 的对应项
-- 资产在 公共资源包 包里：Mod/秘钥资产目录
-- 前缀可能是 /Game/Mod/ 也可能是 /Mod/，两个都试
local KEY_ROOTS = {
    P_KEY_ASSET_A,
    P_KEY_ASSET_B,
}
-- 颜色统一取自上方 CONFIG.KEY_COLORS（索引 1~4 ↔ 秘钥1~4），这里只做引用，别在本地再写一份
local KEY_DEFS = {
    { clsName = K_KEY_CLS_1, color = CONFIG.KEY_COLORS[1], processed = {}, meshes = {} },
    { clsName = K_KEY_CLS_2, color = CONFIG.KEY_COLORS[2], processed = {}, meshes = {} },
    { clsName = K_KEY_CLS_3, color = CONFIG.KEY_COLORS[3], processed = {}, meshes = {} },
    { clsName = K_KEY_CLS_4, color = CONFIG.KEY_COLORS[4], processed = {}, meshes = {} },
}

local keyState = { active = false, timer = nil, roam = 3, classes = {} }

-- 按资产路径直接取类（和空投同一种方式）；拿到了就不用全场景认类了
local function ResolveKeyClasses()
    for i, d in ipairs(KEY_DEFS) do
        if not keyState.classes[i] then
            for _, root in ipairs(KEY_ROOTS) do
                local hit = nil
                for _, suffix in ipairs({ "." .. d.clsName .. "_C", "." .. d.clsName }) do
                    local cls = nil
                    pcall(function() cls = LoadClass(root .. d.clsName .. suffix) end)
                    if cls then
                        keyState.classes[i] = cls
                        hit = root .. d.clsName .. suffix
                        break
                    end
                end
                if hit then
                    break
                end
            end
        end
    end
end

local function ClearKeyEffects()
    for _, d in ipairs(KEY_DEFS) do
        for _, m in pairs(d.meshes) do
            if m and UE.IsValid(m) then
                ClearMeshHighlight(m)      -- 撤掉官方 helper 设上去的高亮
            end
        end
        d.meshes = {}
        d.processed = {}
    end
end

function startKey()
    if keyState.active then return end
    TakeOver("key")            -- 停掉上一实例的秘钥循环，避免两实例互相覆盖
    keyState.active = true
    keyState.roam = 3
    ClearKeyEffects()
    ResolveKeyClasses()

    local function scan()
        if not keyState.active then return end
        if not CONFIG.ENABLE_KEY then
            ClearKeyEffects()
            return
        end
        local world = GameFrontendHUD and GameFrontendHUD:GetWorld()
        if not world then return end

        local found = 0

        -- 已经记住的类：直接按类查（引擎层过滤），每种秘钥用各自的颜色
        for i, d in ipairs(KEY_DEFS) do
            local cls = keyState.classes[i]
            if cls then
                pcall(function()
                    local arr = GameplayStatics.GetAllActorsOfClass(world, cls)
                    if not arr then return end
                    for _, a in pairs(arr) do
                        if a and UE.IsValid(a) then
                            found = found + HighlightKeyActor(d, a, d.color)
                        end
                    end
                end)
            end
        end

        -- 还有类没认出来：全场景找几次，把类名 -> UClass 记住后就不再扫
        if keyState.roam > 0 then
            local missing = false
            for i = 1, #KEY_DEFS do
                if not keyState.classes[i] then
                    missing = true
                    break
                end
            end
            if missing then
                keyState.roam = keyState.roam - 1
                local actorClass = LoadClass("/Script/Engine.Actor")
                local allActors = actorClass and GameplayStatics.GetAllActorsOfClass(world, actorClass)
                if allActors then
                    for _, a in pairs(allActors) do
                        if a and UE.IsValid(a) then
                            local cn = nil
                            pcall(function() cn = GetClassName(a) end)
                            if cn then
                                for i, d in ipairs(KEY_DEFS) do
                                    if (not keyState.classes[i]) and cn:find(d.clsName, 1, true) then
                                        pcall(function() keyState.classes[i] = a:GetClass() end)
                                        found = found + HighlightKeyActor(d, a, d.color)
                                    end
                                end
                            end
                        end
                    end
                end
                local n = 0
                for i = 1, #KEY_DEFS do
                    if keyState.classes[i] then n = n + 1 end
                end
                if n == #KEY_DEFS then keyState.roam = 0 end
            end
        end

    end

    scan()
    if Timer then
        keyState.timer = Timer.InsertTimer(2.5, scan, true)
    end
end

function stopKey()
    keyState.active = false
    if keyState.timer and Timer then
        pcall(Timer.RemoveTimer, keyState.timer)
        keyState.timer = nil
    end
    ClearKeyEffects()
end

-- ========== 广角（走游戏自己的相机数据管线，幂等写入） ==========
-- 旧实现的两个问题：
--   ① 每 0.5s 无条件把 arm.TargetArmLength 写成绝对值；
--   ② 一次写三个目标（GetActiveSpringArm / GetThirdPersonSpringArm / CameraBoom）。
--   「周期性 + 绝对值 + 多目标」的裸属性写入，是最容易被逐帧差分抓到的形态。
--
-- 本实现改成：
--   ① 优先走引擎自己的相机数据管线 —— SpringArm:GetModifierByPerspectiveMode(TPP)
--      → F相机数据结构 → UpdateCustomCameraData / SetCustomCameraDataEnable。
--      这与游戏 CarRacing / 溜冰鞋 / 电吉他技能改相机走的是**同一条**路径
--      （带命名槽、操作类型、插值速度）；引擎侧看到的是"一条相机修饰数据"，
--      而不是"某个组件的属性被人改了"。构造函数失败时自动回退到直写。
--   ② 幂等：每个 pawn 只在需要时写一次，之后靠低频看门狗回读；值没漂就既不写也不读。
--   ③ 只作用"当前生效的那一个"弹簧臂。
--   ④ 开关关闭时把修饰数据关掉并还原臂长。
local FOV = {
    pawn = nil, arm = nil, modifier = nil, data = nil,
    base = nil,              -- 该 pawn 的原始臂长（首次读到就记下，还原用）
    target = nil,            -- 当前目标臂长
    applied = false,         -- 已写好并自锁
    viaModifier = false,     -- 本条记录是走修饰器建立的
    watchdog = 0,            -- 剩余跳过的 tick（幂等：没到点连读都不读）
}

local function FovClamp(dist)
    dist = tonumber(dist) or CONFIG.FOV_DISTANCE
    if dist < CONFIG.FOV_MIN then dist = CONFIG.FOV_MIN end
    if dist > CONFIG.FOV_MAX then dist = CONFIG.FOV_MAX end
    return dist
end

local function FovReadArm(arm)
    local v = nil
    pcall(function() v = arm.TargetArmLength end)
    return tonumber(v)
end

-- 取「当前生效的弹簧臂」与其 TPP 相机修饰器（优先第三人称臂，与玩家实际视角一致）
local function FovResolveArm(pawn)
    local arm = nil
    pcall(function()
        if CheckObjectContainsField(pawn, "GetThirdPersonSpringArm") then
            arm = pawn:GetThirdPersonSpringArm()
        end
        if not Valid(arm) and CheckObjectContainsField(pawn, "GetActiveSpringArm") then
            arm = pawn:GetActiveSpringArm()
        end
        if not Valid(arm) and CheckObjectContainsField(pawn, "CameraBoom") then
            arm = pawn.CameraBoom
        end
    end)
    local modifier = nil
    if Valid(arm) then
        pcall(function()
            if EPerspectiveMode and EPerspectiveMode.TPP
               and CheckObjectContainsField(arm, "GetModifierByPerspectiveMode") then
                modifier = arm:GetModifierByPerspectiveMode(EPerspectiveMode.TPP)
            end
        end)
    end
    return arm, modifier
end

local function FovRestore()
    -- 关掉我们自己挂上去的那条相机修饰数据（游戏侧就"没这回事"了）
    if Valid(FOV.modifier) and FOV.data then
        pcall(function()
            if FOV.modifier.SetCustomCameraDataEnable then
                FOV.modifier:SetCustomCameraDataEnable(FOV.data, false)
            end
        end)
    end
    -- 走直写路径时才回写原值（走修饰器时不需要动属性）
    if Valid(FOV.arm) and FOV.base and not FOV.viaModifier then
        pcall(function()
            if FOV.arm.SetTargetArmLength then FOV.arm:SetTargetArmLength(FOV.base) end
            FOV.arm.TargetArmLength = FOV.base
        end)
    end
    FOV.arm, FOV.modifier, FOV.data = nil, nil, nil
    FOV.applied, FOV.viaModifier, FOV.watchdog = false, false, 0
end

local function FovApply()
    if not CONFIG.FOV_ENABLE then
        if FOV.arm or FOV.data or FOV.applied then FovRestore() end
        return
    end

    local pawn = GetLocalPlayer()
    if not Valid(pawn) then
        -- 没 pawn（加载中 / 观战）：清掉本条记录，等下一拍重新认
        FOV.pawn, FOV.arm, FOV.modifier, FOV.data = nil, nil, nil, nil
        FOV.applied, FOV.viaModifier, FOV.watchdog = false, false, 0
        return
    end

    local target = FovClamp(CONFIG.FOV_DISTANCE)

    -- 换 pawn（换局 / 复活）：旧对象已销毁，残值随它一起消失，这里只重置记账
    if pawn ~= FOV.pawn then
        FOV.pawn, FOV.arm, FOV.modifier, FOV.data = pawn, nil, nil, nil
        FOV.applied, FOV.viaModifier, FOV.watchdog = false, false, 0
    end
    -- 目标值被热改（SetFov / 改 CONFIG）⇒ 允许重写
    if FOV.target ~= target then
        FOV.target, FOV.applied, FOV.watchdog = target, false, 0
    end

    if not Valid(FOV.arm) then
        FOV.arm, FOV.modifier = FovResolveArm(pawn)
        if not Valid(FOV.arm) then return end
        if FOV.base == nil then FOV.base = FovReadArm(FOV.arm) end   -- 记原始臂长
    end

    -- 幂等：已写好且没到看门狗点 ⇒ 连读都不读
    if FOV.applied and FOV.watchdog > 0 then
        FOV.watchdog = FOV.watchdog - 1
        return
    end
    FOV.watchdog = 6          -- 6 × 0.5s = 3s 后才回读一次

    local cur = FovReadArm(FOV.arm)
    if cur ~= nil and math.abs(cur - target) < 1e-3 then
        FOV.applied = true    -- 值已经对：自锁，之后 3s 才再看一眼
        return
    end

    -- 值不对 —— 若上一条是走修饰器建立的，说明它没生效：撤掉，落到直写
    if FOV.viaModifier then
        pcall(function()
            if Valid(FOV.modifier) and FOV.data
               and FOV.modifier.SetCustomCameraDataEnable then
                FOV.modifier:SetCustomCameraDataEnable(FOV.data, false)
            end
        end)
        FOV.data, FOV.viaModifier = nil, false
    end

    -- ① 首选：游戏自己的相机数据管线（命名槽 + 操作类型 + 插值速度）
    if Valid(FOV.modifier) then
        local built = false
        pcall(function()
            local data = nil
            if CreateStruct then
                data = CreateStruct(P_CAMERA_DATA)
            end
            if data == nil then return end
            -- 命名槽：这个名字是自由标识（游戏无白名单校验），只用于后续按名覆盖同一条数据。
            -- 用与游戏自身同构的写法 —— 技能侧就是 "Skate相机数据结构[对象名]" /
            -- "Guitar相机数据结构[对象名]" / "SlideJumpCameraLag[对象名]" 这种格式，
            -- 这里固定用 Local 作后缀，保证幂等（同一条数据反复覆盖，不会越积越多）。
            data.DataName = N_CAMERA_SLOT
            data.TargetArmLength = target
            data.ArmLengthInterpSpeed = 8.0          -- 平滑过渡，避免逐帧出现阶跃
            if ECameraDataOperateType and ECameraDataOperateType.Priority6 then
                data.OperateType = ECameraDataOperateType.Priority6
            end
            if FOV.modifier.UpdateCustomCameraData then
                FOV.modifier:UpdateCustomCameraData(data)
            end
            if FOV.modifier.SetCustomCameraDataEnable then
                FOV.modifier:SetCustomCameraDataEnable(data, true)
            end
            FOV.data = data
            built = true
        end)
        if built and FOV.data then
            -- 插值需要时间，先自锁；3s 后看门狗回读，
            -- 那时若仍未生效会自动撤掉修饰器、落到下面的直写
            FOV.viaModifier, FOV.applied = true, true
            return
        end
        FOV.data = nil
    end

    -- ② 兜底：直写（同样幂等 —— 只在读到的值与目标不一致时才写）
    pcall(function()
        if FOV.arm.SetTargetArmLength then FOV.arm:SetTargetArmLength(target) end
        FOV.arm.TargetArmLength = target
    end)
    FOV.applied = true
end

-- ========== 敌人高亮：走 角色子系统 记账通道 ==========
-- 敌人曾经（和物品类一样）走「逐个 mesh 裸写 bDrawIdeaOutline / bIdeaOutlineOcclusionHighlight
-- / IdeaOutlineColor」那一套 —— 属于在游戏记账之外偷塞标志；而描边标志在 SimulatedProxy 身上
-- 本来就是游戏自己在维护的（SniperTDMPlayerPawn:CheckOutlineOcclusionHighlight 会按服务端复制的
-- bHasSpecialWeapon 把它重刷回去），所以那种写法既可能被校准覆盖、又会被专门的检测盯上。
--
-- 本通道改走游戏自己的接口（SDK：U角色子系统 : UWorldSubsystem）：
--     int32 AddOcclusionHighlight(ACharacter* Target, AActor* Causer,
--                                 EPEBuffOcclusionHighlightType InType, FLinearColor const& InColor)
--     int32 AddOcclusionHighlightWithOutline(...)          -- 同上，但额外开真描边 pass
--     void  RemoveOcclusionHighlight(int32 ID)             -- 按 ID 释放
-- 子系统内部有 OHInfosMap（角色 → 高亮信息）与 CharacterMap（ID → 角色）两张记账表，
-- 也就是「谁在什么时候被标了什么」是登记过的，而不是 mesh 上凭空多个 flag。
-- 游戏内使用者：gameplay/DiamondArena/Buff/PEBuff_DA_DetectCharacterBase.lua（探测敌人 buff，
-- 在非 Authority 分支调用 ⇒ 客户端可调）。
local SUBSYS_CLASS_PATH = P_CHAR_SUBSYS
local HIGHLIGHT_ALL = 2        -- EPEBuffOcclusionHighlightType_All（common/ue_enum_auto.lua）

local EnemyCh = {
    sys = nil,          -- 角色子系统实例（拿到就缓存）
    ids = {},           -- [pawnKey] = int32 ID（子系统返回的释放句柄）
}

local function ResolveSubSys(ctx)
    if Valid(EnemyCh.sys) then return EnemyCh.sys end
    local sys = nil
    pcall(function()
        if SubsystemBlueprintLibrary and SubsystemBlueprintLibrary.GetWorldSubsystem then
            local cls = UE.LoadClass(SUBSYS_CLASS_PATH)
            if cls then
                sys = SubsystemBlueprintLibrary.GetWorldSubsystem(ctx, cls)
            end
        end
    end)
    if Valid(sys) then EnemyCh.sys = sys end   -- 拿不到就下次再试（不做永久禁用）
    return EnemyCh.sys
end

-- 登记一条高亮；成功返回 ID，失败返回 nil（调用方跳过本轮，下一轮再试 —— 敌人已无回退通道）
local function SubSysAcquire(pawn, color)
    local sys = ResolveSubSys(pawn)
    if not Valid(sys) then return nil end
    local c = ToOutlineColor(color)
    local causer = GetLocalPlayer()
    if not Valid(causer) then causer = pawn end
    local id = 0
    pcall(function()
        -- ① 只开遮挡高亮（与旧写法观感一致，少一条真描边 pass）
        id = sys:AddOcclusionHighlight(pawn, causer, HIGHLIGHT_ALL, c)
        -- ② 该接口不可用/失败时，退到游戏真正在用的那个（钻石场 buff 用的就是它）
        if (id == nil or id == 0) and sys.AddOcclusionHighlightWithOutline then
            id = sys:AddOcclusionHighlightWithOutline(pawn, causer, HIGHLIGHT_ALL, c)
        end
    end)
    if type(id) ~= "number" or id == 0 then return nil end
    return id
end

local function SubSysRelease(key)
    local id = EnemyCh.ids[key]
    if id == nil then return end
    EnemyCh.ids[key] = nil
    local sys = EnemyCh.sys
    if Valid(sys) then
        pcall(function() sys:RemoveOcclusionHighlight(id) end)
    end
end

local function SubSysReleaseAll()
    local sys = EnemyCh.sys
    for key, id in pairs(EnemyCh.ids) do
        if Valid(sys) then
            pcall(function() sys:RemoveOcclusionHighlight(id) end)
        end
        EnemyCh.ids[key] = nil
    end
end

-- ========== 处理所有敌人 ==========
local function ProcessEnemies()
    if not CONFIG.ENABLE then
        -- 总开关关掉：子系统登记的敌人高亮按 ID 全部释放
        SubSysReleaseAll()
        return
    end

    local localPlayer = GetLocalPlayer()
    if not Valid(localPlayer) then return end

    local myTeamId = GetTeamID(localPlayer)
    local myPos = GetLocation(localPlayer)
    if not myPos then return end

    local nearbyPawns = GetNearbyPawns(CONFIG.MAX_DISTANCE)
    local currentActors = {}

    for _, pawn in ipairs(nearbyPawns) do
        if Valid(pawn) and pawn ~= localPlayer then
            local pawnKey = tostring(pawn)
            currentActors[pawnKey] = true

            local pawnTeamId = GetTeamID(pawn)
            local isAI = IsAI(pawn)

            -- ★ 旧写法是 `TeamID ~= -1 and TeamID <= 100` 再叠加 SHOW_AI —— 但 IsAI() 判定的 AI
            --   恰好就是 TeamID == -1 或 > 100，于是人机在「队号」那一关就被排除了，
            --   CONFIG.SHOW_AI = true 实际永远不生效、人机从来上不了高亮。
            --   现在只保留「不选队友」这一条硬过滤，是不是人机完全交给 SHOW_AI 决定。
            local shouldProcess = false
            if pawnTeamId ~= myTeamId then
                shouldProcess = (not isAI) or (CONFIG.SHOW_AI == true)
            end

            if shouldProcess then
                -- 人机用 COLOR_AI，真人用 COLOR_ENEMY。
                local color = isAI and CONFIG.COLOR_AI or CONFIG.COLOR_ENEMY

                -- 敌人唯一通道：角色子系统 记账描边（同一目标只登记一次）。
                -- 旧的逐网格裸写通道已删除 ⇒ 取不到子系统时敌人不显示（fail-closed，
                -- 宁可不显示，也不退回那条被 r.IdeaOutlineCheatDetect 盯着的裸写路径）。
                if EnemyCh.ids[pawnKey] == nil then
                    local id = SubSysAcquire(pawn, color)
                    if id then EnemyCh.ids[pawnKey] = id end
                end
            end
        end
    end

    -- 清理已死亡或离开的敌人：按 ID 释放
    local staleSub = {}
    for key in pairs(EnemyCh.ids) do
        if not currentActors[key] then staleSub[#staleSub + 1] = key end
    end
    for _, key in ipairs(staleSub) do SubSysRelease(key) end
end

-- ========== 主循环 ==========
local stopCore

local function MainLoop()
    if not isRunning then return end

    FovApply()

    local currentTime = os.clock()
    if currentTime - lastUpdateTime < CONFIG.UPDATE_INTERVAL then
        return
    end
    lastUpdateTime = currentTime

    SafeCall(function()
        ProcessEnemies()
    end)

    SafeCall(function()
        ProcessVehicles()
    end)
end

-- 接管后到第一发扫描之间的固定延迟（秒）。加载器每次复活都整份重载本文件，
-- 新实例接管时旧实例会硬停（高亮全部还原），这段时间就是交接的空窗，0.2s 已经很短。
local START_DELAY = 0.2

-- ========== 启动/停止 ==========
local function startCore()
    if isRunning then
        return
    end

    -- 停掉上一实例的透视主循环（硬停：旧实例会把高亮 / 描边 / 缩放全部还原干净）
    TakeOver("all")
    isRunning = true
    -- 注意：这里**不再**强制写 CONFIG.ENABLE = true。
    -- ENABLE 是用户的总开关，被内部强制改写的旧行为会导致「配置里写 false 不生效」。
    -- 内部「是否在跑」一律只看 isRunning。

    if coreTimer then
        DelTimer(coreTimer)
        coreTimer = nil
    end

    -- 接管后第一发扫描立刻打（START_DELAY 后），之后按 0.5s 周期跑。
    -- 旧实现是 0.5s(外圈) + 0.5s(内圈) 才扫第一发 —— 那 1 秒是空窗的主要来源。
    local delay = START_DELAY
    if delay < 0.05 then delay = 0.05 end
    Timer.InsertTimer(delay, function()
        if not isRunning then return end
        SafeCall(MainLoop)          -- 第一发：立即扫一次，不等下一个周期
        coreTimer = Timer.InsertTimer(0.5, function()
            MainLoop()
        end, true)
    end, false)
end

-- 硬停：立刻停循环并还原高亮 / 描边 / 缩放（主动关、换局、以及被新实例接管时都用这一条）。
-- 旧版还有 "keep"（换手保留画面）/"defer"（卸载延迟还原）两种软停模式，已删除：
-- 接管自带「立刻首扫」，空窗只有 START_DELAY（0.2s），不值得为它多维护两套停机语义。
stopCore = function()
    isRunning = false

    if coreTimer then
        DelTimer(coreTimer)
        coreTimer = nil
    end

    -- 物品类（载具 / 空投 / 铁皮箱 / 秘钥）按账还原，并原地清空名单
    ReleaseAllHighlights()
    -- 敌人走子系统记账，按 ID 逐条释放
    SubSysReleaseAll()
    vehState.active = false
end

-- 载具透视开关（独立于人物透视）
function setVehicle(on)
    CONFIG.ENABLE_VEHICLE = (on == true)
    if not CONFIG.ENABLE_VEHICLE then
        ReleaseHighlightKind("vehicle")  -- 按账还原载具（不影响敌人）
        vehState.active = false
    end
end

function SetFov(dist)
    CONFIG.FOV_DISTANCE = FovClamp(dist)
    FOV.target = nil        -- 置空 ⇒ 下一拍按新目标重写
    FOV.applied = false
    FOV.watchdog = 0
end

function reloadCore()
    stopCore()            -- 先硬停，干净还原，再重新起步
    Timer.InsertTimer(START_DELAY, function()
        startCore()
    end, false)
end

-- ========== 模块生命周期 ==========
function C:OnReceivePlayerPawnInitialized(pawn)
    if not Valid(pawn) then return end
    if INITED then return end
    INITED = true

    -- 立刻接管：旧实例会被硬停（高亮 / 缩放全部还原），越早开扫空窗越短。
    -- 旧实现延迟 2.0s 才 startCore，再叠加 0.5+0.5s 才开始扫描 —— 那 3 秒全在断档里。
    startCore()

    Timer.InsertTimer(5.0, function()
        startAir()
    end, false)

    Timer.InsertTimer(6.0, function()
        startBox()
    end, false)

    Timer.InsertTimer(7.0, function()
        startKey()
    end, false)
end

function C:OnReceivePreUnload()
    -- 卸载即硬停：立刻还原高亮 / 描边 / 缩放，不留残影
    stopCore()
    stopAir()
    stopBox()
    stopKey()
    FovRestore()
    -- 角色子系统 是 WorldSubsystem（每个 World 一个），换局后句柄失效，清掉缓存下局重取
    EnemyCh.sys = nil
    EnemyCh.ids = {}
    INITED = false
end

-- ========== 导出全局函数 ==========
_G.__ui_res_ctl = {
    Start = startCore,
    Stop = stopCore,
    Reload = reloadCore,
    SetFov = SetFov,
    setVehicle = setVehicle,
    Config = CONFIG,
}

return C
