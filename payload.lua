if not(UE and GameFrontendHUD) or not Timer then return end
local C = require("client.ingame.common.common_submodule_base"):New()

-- ========== 🔥 日志系统 ==========
local INIT_TIME = os.time()
local INITED = false

-- ========== 🔥 配置（直接写死在代码里，改这里 = 改配置，对局结束重启生效） ==========
-- 不再使用 .sys.ini 文件，不再热加载，不再轮询读取
local DEFAULT_CONFIG = {
    Enabled = true,
    TriggerMode = "fire",
    FOV = 5,
    Distance = 300,
    Bone = 1,
    -- 🔥 PID 平滑参数（比例+微分，更自然更抗检测）
    Kp = 0.36,             -- 比例增益：主驱动力，越大转得越快
    Kd = 0.3,              -- 微分增益：阻尼，抑制超调，越大越平稳
    BoneOffset = 0,
    -- 🔥 漏打：true=主骨被墙挡时扫露出的骨骼打（头/胸/肩/手臂依序）；false=穿墙直接打
    LeakAim = true,
    -- 🔥 平滑速度（限速旋转）
    SmoothSpeed = 8,             -- 每tick最大转角（度），越大转得越快，越小越平滑
    -- 🔥 去后坐力（0=关闭后坐力，1.0=原样，越大后座越大）
    GunRecoil = 0.01,
    -- 🔥 散布（0=无散布，1.0=原样）
    GunSpread = 0.01,
    -- 🔥 切换速度（1.0=原样，>1 换枪更快）
    GunSwitch = 1.0,
    -- 🔥 瞄准速度（开镜速度，1.0=原样，>1 开镜更快）
    GunAim = 1.0,
    -- 🔥 射速（1.0=正常，2.0=2倍射速，3.0=3倍）
    FireRate = 1.1,
    -- 🔥 移动速度（1.0=正常，1.5=1.5倍速，2.0=2倍速，钳制0.5~5.0）
    MoveSpeed = 1.1,
    -- 🔥 强制疾跑（true=开启强制疾跑，写 bEnableAdditionalSpeedAttribute=true；false=关闭）
    ForceSprint = false,
    -- 🔥 广角（弹簧臂长度，0=不修改，建议500-1000，越大镜头越远视野越宽）
    SpringArmLength = 300,
    -- 🔥 预判（true=开启子弹预判，false=关闭）
    Prediction = true,
}

-- 🔥 全局配置 = 直接引用代码内的 DEFAULT_CONFIG（改上面的表即改配置）
_G.AimConfig = DEFAULT_CONFIG

-- 工具：pcall 包装，失败时打印错误标签（便于调试）
local ERROR_LOG = "C:\\Users\\NFY\\Desktop\\payload.err"

local function SafeCall(fn, label)
    local ok, err = pcall(fn)
    if not ok then
        local msg = "[ERROR:" .. (label or "?") .. "] " .. tostring(err)
        print(msg)
        pcall(function()
            local f = io.open(ERROR_LOG, "a")
            if f then
                f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n")
                f:close()
            end
        end)
    end
    return ok, err
end

-- ========== 🔥 工具函数 ==========
local function Valid(obj)
    return obj ~= nil and UE.IsValid(obj)
end

-- 🔥 PC 缓存：全程不变，1s刷新兜底切场景（AimTick/Config循环等所有调用方自动受益）
local _PC_CACHE = nil
local _PC_CACHE_TICK = 0

local function GetPlayerController()
    local now = os.time()
    if Valid(_PC_CACHE) and (now - _PC_CACHE_TICK) < 1 then
        return _PC_CACHE
    end
    local pc = nil
    pcall(function()
        if GameplayStatics then
            pc = GameplayStatics.GetPlayerController(GameFrontendHUD, 0)
        end
    end)
    if Valid(pc) then
        _PC_CACHE = pc
        _PC_CACHE_TICK = now
    end
    return _PC_CACHE
end

local function GetWorld()
    local world = nil
    pcall(function()
        if GameFrontendHUD then
            world = GameFrontendHUD:GetWorld()
        end
    end)
    return world
end

-- ========== 🔥 获取对象位置 ==========
local function GetActorLocation(obj)
    if not Valid(obj) then return nil end
    
    local pos = nil
    
    pcall(function()
        if CheckObjectContainsField(obj, "Location") then
            pos = obj.Location
            if pos then return end
        end
        if not pos and CheckObjectContainsField(obj, "GetActorLocation") then
            pos = obj:GetActorLocation()
            if pos then return end
        end
        if not pos and CheckObjectContainsField(obj, "K2_GetActorLocation") then
            pos = obj:K2_GetActorLocation()
            if pos then return end
        end
    end)
    
    if not pos then
        pcall(function()
            if CheckObjectContainsField(obj, "RootComponent") then
                local root = obj.RootComponent
                if Valid(root) and CheckObjectContainsField(root, "GetComponentLocation") then
                    pos = root:GetComponentLocation()
                end
            end
        end)
    end
    
    return pos
end

-- ========== 🔥 武器增强（去后坐力 + 射速 + 移动速度） ==========
-- API 参考秒刷枪械源码：
--   武器: P.BP_WeaponManagerComponent → m:GetCurrentUsingWeapon(true) → w
--   实体: w.ShootWeaponEntityComp → e
--   后坐力字段设0 = 无后坐力
--   射速: 缓存原始ShootInterval，应用 原始值 × (1/射速倍率)
--   移速: P.UGCGeneralMoveSpeedScale = 倍率
-- 优化：缓存武器指针，只有武器变化才重新获取+赋值，平时零开销
local NR_LAST_WEAPON_KEY = nil  -- 缓存的武器Key（tostring字符串，不持有UObject引用）
local NR_LAST_APPLY = 0       -- 上次应用时间（保底重试用）
local NR_BASE = {}            -- 武器原始射速缓存 {[武器]= {SI,ESI,BSI,SIT}}
local NR_BASE_COUNT = 0       -- 缓存条目计数，超限时清理
local NR_BASE_MAX = 10        -- 最大缓存数（防止内存泄漏）
local NR_AIM_TIME = {}        -- 武器原始瞄准时间缓存 {[武器key]= WeaponAimInTime}（防累乘）

-- 移动速度（对齐《和平lua文件加速功能文档》：三字段 + 强制疾跑开关）
--   三字段：SpeedScale / EnergySpeedScale / SwimSpeedDynamicScale = 倍率
--   强制疾跑：ForceSprint=true 时写 bEnableAdditionalSpeedAttribute=true
-- 说明：倍率钳制 0.5~5.0（对齐文档）；sprint 显式写 true/false（关闭时复位，避免残留）
local function ApplyMoveSpeed(P)
    if not Valid(P) then return end
    local ms = _G.AimConfig.MoveSpeed
    if ms == nil or type(ms) ~= "number" then ms = 1.0 end
    if ms <= 0 then ms = 1.0 end
    if ms < 0.5 then ms = 0.5 end
    if ms > 5.0 then ms = 5.0 end
    local sprint = (_G.AimConfig.ForceSprint == true)
    pcall(function()
        -- 🔥 三字段（与文档完全一致）：地面/能量/游泳速度倍率
        if P.SpeedScale ~= nil then P.SpeedScale = ms end
        if P.EnergySpeedScale ~= nil then P.EnergySpeedScale = ms end
        if P.SwimSpeedDynamicScale ~= nil then P.SwimSpeedDynamicScale = ms end
        -- 🔥 强制疾跑（对齐文档 sprint=1 的 bEnableAdditionalSpeedAttribute）
        if P.bEnableAdditionalSpeedAttribute ~= sprint then P.bEnableAdditionalSpeedAttribute = sprint end
    end)
end

-- 广角：调整第三人称摄像机视野距离（对齐《和平lua文件广角功能文档》）
--   直接通过 GetActiveSpringArm / GetThirdPersonSpringArm / CameraBoom 三路径写 TargetArmLength
--   钳制 50~5000（对齐文档）；0=不修改（保持当前值）
local function ApplySpringArmLength(P)
    if not Valid(P) then return end
    local armLen = _G.AimConfig.SpringArmLength
    if armLen == nil then armLen = 0 end
    if armLen <= 0 then
        return
    end
    if armLen < 50 then armLen = 50 end
    if armLen > 5000 then armLen = 5000 end
    
    pcall(function()
        -- 三路径（与文档一致）：主SpringArm / 第三人称SpringArm / CameraBoom
        local arm = nil
        if P.GetActiveSpringArm then arm = P:GetActiveSpringArm() end
        if Valid(arm) and arm.TargetArmLength ~= nil then
            arm.TargetArmLength = armLen
        end
        if P.GetThirdPersonSpringArm then arm = P:GetThirdPersonSpringArm() end
        if Valid(arm) and arm.TargetArmLength ~= nil then
            arm.TargetArmLength = armLen
        end
        local arm2 = P.CameraBoom
        if Valid(arm2) and arm2.TargetArmLength ~= nil then
            arm2.TargetArmLength = armLen
        end
    end)
end

local function ApplyWeaponMods(P)
    if not Valid(P) then return false end
    
    -- 先尝试获取当前武器，和缓存比较
    local w = nil
    pcall(function()
        local m = P.BP_WeaponManagerComponent
        if not Valid(m) then
            m = P:GetWeaponManager()
        end
        if Valid(m) and m.GetCurrentUsingWeapon then
            w = m:GetCurrentUsingWeapon(true)
        end
        if not Valid(w) then
            w = P:GetCurrentShootWeapon()
        end
    end)
    if not Valid(w) then
        NR_LAST_WEAPON_KEY = nil
        return false
    end
    
    -- 武器没变、且近期已应用过 → 跳过（零开销）
    -- （配置已写死不变，无需指纹检测；只有换枪才需重应用）
    local cfg2 = _G.AimConfig or {}
    local now = os.time()
    local wk = tostring(w)
    if wk == NR_LAST_WEAPON_KEY and (now - NR_LAST_APPLY) < 5 then
        return true
    end
    NR_LAST_WEAPON_KEY = wk
    NR_LAST_APPLY = now
    
    -- 武器变化了（或超时重试）→ 完整应用一次
    local applied = false
    SafeCall(function()  -- ApplyWeaponMods
        local e = w.ShootWeaponEntityComp
        if not Valid(e) then
            if w.GetShootWeaponEntityComponent then
                e = w:GetShootWeaponEntityComponent()
            end
        end
        -- ===== 枪械参数（对齐《和平lua文件枪械功能文档》：后座/散布/切换/瞄准/射速） =====
        local recoil = cfg2.GunRecoil
        if recoil == nil or type(recoil) ~= "number" then recoil = 0.01 end
        if recoil < 0 then recoil = 0 end
        local spread = cfg2.GunSpread
        if spread == nil or type(spread) ~= "number" then spread = 0.01 end
        if spread < 0 then spread = 0 end
        local sw = cfg2.GunSwitch
        if sw == nil or type(sw) ~= "number" then sw = 1.0 end
        if sw < 0.1 then sw = 0.1 end
        local aim = cfg2.GunAim
        if aim == nil or type(aim) ~= "number" then aim = 1.0 end
        if aim < 0.1 then aim = 0.1 end

        -- 🔥 判断霰弹枪：只压后坐力，不压散布（霰弹枪散射是物理特征，压到0.01=弹丸全集中=服务器必判异常）
        local isShotGun = false
        pcall(function()
            if w.IsShotGun then isShotGun = w:IsShotGun() end
        end)

        -- 官方API去后坐力/散布（文档方式：SetVerticalRecoilSacle / SetDeviationSacle）
        -- 后座力用 0.01 而非 0，避免 VsRecoilZero 检测（反作弊压制保留）
        if w.SetVerticalRecoilSacle then w:SetVerticalRecoilSacle(recoil) end
        if w.SetHorizontalRecoilSacle then w:SetHorizontalRecoilSacle(recoil) end
        if not isShotGun then
            if w.SetDeviationSacle then w:SetDeviationSacle(spread) end
        end
        -- 🔥 关键：ADS时子弹方向使用相机旋转（防止弹道偏上，抗检测）
        if w.SetShootUseCameraRotatorADS then w:SetShootUseCameraRotatorADS(true) end
        w.bShootUseCameraRotatorADS = true

        if Valid(e) then
            -- 🔥 缓存键（切换/瞄准速度共用）：优先武器类型ID，回退实例键
            local key2 = tostring(w)
            pcall(function()
                if w.GetWeaponItemID then
                    local id2 = w:GetWeaponItemID()
                    if id2 ~= nil then key2 = "t" .. tostring(id2) end
                end
            end)
            -- 实体组件属性（文档字段：VerticalRecoilFactorModifier / HorizontalRecoilFactorModifier /
            --   GameDeviationFactor / DeviationFactorModifier / SwitchTimeFactorWrapper / WeaponAimInTime）
            e.VerticalRecoilFactorModifier = recoil
            e.HorizontalRecoilFactorModifier = recoil
            e.RecoilKickADS = 0
            e.NewFPPRecoilKickADS = 0
            e.AnimationKick = 0
            if not isShotGun then
                e.GameDeviationFactor = spread
                e.DeviationFactorModifier = spread
            end
            -- 🔥 切换速度（文档字段 SwitchTimeFactorWrapper，>1 换枪更快）
            if e.SwitchTimeFactorWrapper ~= nil then
                e.SwitchTimeFactorWrapper = sw
            end
            -- 🔥 瞄准速度（文档字段 WeaponAimInTime，>1 开镜更快）
            -- 幂等处理：缓存该武器的原始 WeaponAimInTime，用 原始值/倍率 写入，杜绝多次应用累乘
            if e.WeaponAimInTime ~= nil and e.WeaponAimInTime ~= 0 then
                if NR_AIM_TIME[key2] == nil then
                    NR_AIM_TIME[key2] = e.WeaponAimInTime
                end
                if aim == 1.0 then
                    e.WeaponAimInTime = NR_AIM_TIME[key2]
                else
                    e.WeaponAimInTime = NR_AIM_TIME[key2] / aim
                end
            end
        end
        -- 射击组件：累积后坐力设小值0.01（非0，避免 VsKickBackBad 检测）
        pcall(function()
            local sc = w.ShootWeaponComponent
            if not Valid(sc) then
                sc = w:GetShootWeaponComponent()
            end
            if Valid(sc) then
                sc.AccumulateKickBackPitch = 0.01
                sc.AccumulateKickBackYaw = 0.01
                if not isShotGun then
                    sc.ShootDeviation = spread
                end
            end
        end)
        -- ===== 射速（Archetype原始值缓存 + 幂等校正，杜绝累乘） =====
        -- 文档写法 e.ShootInterval = e.ShootInterval / fireRate 会累乘（多次应用越除越快），
        -- 这里用缓存原始值 × (1/倍率)，基于稳定原始值计算，幂等不累乘（反作弊压制保留）
        local fr = cfg2.FireRate
        if fr == nil then fr = 1.0 end
        -- 无上限（用户要求）
        if fr > 0 and fr ~= 1.0 and Valid(e) then
            -- 🔥 缓存键：武器类型ID（GetWeaponItemID 稳定），实例重建不换键 → 原始值不被污染
            local k = tostring(w)  -- fallback：拿不到类型ID时退回实例键
            pcall(function()
                if w.GetWeaponItemID then
                    local id = w:GetWeaponItemID()
                    if id ~= nil then k = "t" .. tostring(id) end
                end
            end)
            -- 🔥 缓存原始射速：优先从游戏配置原型（Archetype）读取，永不被修改污染
            if not NR_BASE[k] then
                if NR_BASE_COUNT >= NR_BASE_MAX then
                    NR_BASE = {}
                    NR_BASE_COUNT = 0
                end
                local b = {}
                pcall(function()
                    if STExtraBlueprintFunctionLibrary and STExtraBlueprintFunctionLibrary.GetObjectArchetype then
                        local ar = STExtraBlueprintFunctionLibrary.GetObjectArchetype(e)
                        if ar then
                            if ar.ShootInterval ~= nil then b.SI = ar.ShootInterval end
                            if ar.ExtraShootInterval ~= nil then b.ESI = ar.ExtraShootInterval end
                            if ar.BurstShootInterval ~= nil then b.BSI = ar.BurstShootInterval end
                        end
                    end
                end)
                if b.SI == nil then b.SI = e.ShootInterval end
                if b.ESI == nil then b.ESI = e.ExtraShootInterval end
                if b.BSI == nil then b.BSI = e.BurstShootInterval end
                b.SIT = nil
                if w.GetShootIntervalTime then b.SIT = w:GetShootIntervalTime() end
                NR_BASE[k] = b
                NR_BASE_COUNT = NR_BASE_COUNT + 1
            end
            local b = NR_BASE[k]
            local fi = 1.0 / fr  -- 射速2倍 → 间隔减半
            local targetSI = b.SI * fi
            -- 🔥 双向校正：当前值与目标值偏差超过±1%才写入，基于稳定原始值计算，幂等不累乘
            local curSI = e.ShootInterval
            if curSI and (curSI < targetSI * 0.99 or curSI > targetSI * 1.01) then
                e.ShootInterval = targetSI
                if b.ESI then
                    local tESI = b.ESI * fi
                    if e.ExtraShootInterval and (e.ExtraShootInterval < tESI * 0.99 or e.ExtraShootInterval > tESI * 1.01) then
                        e.ExtraShootInterval = tESI
                    end
                end
                if b.BSI then
                    local tBSI = b.BSI * fi
                    if e.BurstShootInterval and (e.BurstShootInterval < tBSI * 0.99 or e.BurstShootInterval > tBSI * 1.01) then
                        e.BurstShootInterval = tBSI
                    end
                end
                if b.SIT and w.SetShootIntervalTime then
                    pcall(function() w:SetShootIntervalTime(b.SIT * fi) end)
                end
            end
        end
        -- ===== 武器级反作弊组件（WeaponAntiCheatComp）关闭检测开关 =====
        pcall(function()
            local ac = w.AntiCheatComp
            if Valid(ac) then
                if ac.ShootRateCheckTag ~= false then ac.ShootRateCheckTag = false end
                if ac.ShootHitTargetIntervalCheckTag ~= false then ac.ShootHitTargetIntervalCheckTag = false end
                if ac.bVerifyTimeLineSync ~= false then ac.bVerifyTimeLineSync = false end
                if ac.bVerifyStartFireTime ~= false then ac.bVerifyStartFireTime = false end
                if ac.ShootRateCheckMulCoff ~= 9999 then ac.ShootRateCheckMulCoff = 9999 end
                if ac.ShootHitTargetIntervalMulCoff ~= 9999 then ac.ShootHitTargetIntervalMulCoff = 9999 end
                if ac.TolerateBulletDirOffsetSquared ~= 999999999 then
                    ac.TolerateBulletDirOffsetSquared = 999999999  -- 极大容忍弹道偏移（bShootUseCameraRotatorADS触发面）
                end
            end
        end)
        -- ===== 子弹速度+重力（武器变化时缓存，供预判用） =====
        -- 实际弹速 = 基础 BulletFireSpeed × 武器 BulletFireSpeedModifier（配件/特殊武器会改倍率）
        if Valid(e) and e.BulletFireSpeed and e.BulletFireSpeed > 0 then
            local spd = e.BulletFireSpeed
            if w.BulletFireSpeedModifier and w.BulletFireSpeedModifier > 0 then
                spd = spd * w.BulletFireSpeedModifier
            end
            BULLET_SPEED_CACHE = spd
        end
        if Valid(e) and e.BulletGravityModifier and e.BulletGravityModifier > 0 then
            BULLET_GRAVITY_CACHE = e.BulletGravityModifier
        end
        -- 子弹重力额外偏移（0=无偏移，部分武器有特殊弹道）
        if Valid(e) then
            BULLET_GRAVITY_EXTRA_CACHE = e.BulletGravityExtraOffset or 0
        end
        applied = true
    end)
    return applied
end

-- ========== 🔥 获取相机位置 ==========
-- 完整 4 方法 fallback：切场景/重生时 PlayerCameraManager 可能短暂不可用，兜底保证 camLoc 不为 nil
local function GetCameraLocation(pc)
    if not Valid(pc) then return nil end
    
    local camLoc = nil
    
    -- 方法1：PlayerCameraManager（最可靠，游戏渲染用的就是它）
    pcall(function()
        local camManager = pc.PlayerCameraManager
        if Valid(camManager) then
            camLoc = camManager:GetCameraLocation()
            if camLoc and camLoc.X ~= nil then return end
        end
    end)
    
    if camLoc and camLoc.X ~= nil then return camLoc end
    
    -- 方法2：GetViewPoint（标准 UE4 视角信息）
    pcall(function()
        local viewInfo = pc:GetViewPoint()
        if viewInfo and viewInfo.Location and viewInfo.Location.X ~= nil then
            camLoc = viewInfo.Location
        end
    end)
    
    if camLoc and camLoc.X ~= nil then return camLoc end
    
    -- 最终备选：角色位置+Z+160（眼睛高度近似，仅当相机方法全失败时兜底；不包含探头偏移）
    pcall(function()
        local pawn = pc:GetPlayerCharacterSafety()
        if Valid(pawn) then
            local pos = GetActorLocation(pawn)
            if pos then
                camLoc = Vector.New(pos.X, pos.Y, pos.Z + 160)
            end
        end
    end)
    
    return camLoc
end

-- ========== 获取所有玩家（对齐参考：无缓存，每次全量枚举） ==========
local function GetAllPawns()
    local result = {}
    pcall(function()
        local world = GetWorld()
        if not world then return end
        local STCharClass = LoadClass("/Script/ShadowTrackerExtra.STExtraCharacter")
        if STCharClass then
            local allPlayers = GameplayStatics.GetAllActorsOfClass(world, STCharClass)
            if allPlayers then
                local num = allPlayers:Num()
                for i = 0, num - 1 do
                    local player = allPlayers:Get(i)
                    if Valid(player) then
                        table.insert(result, player)
                    end
                end
            end
        end
    end)
    return result
end

-- ========== 获取队伍ID（对齐参考） ==========
local function GetTeamID(pawn)
    local teamId = 0
    pcall(function()
        if CheckObjectContainsField(pawn, "TeamID") then
            teamId = pawn.TeamID or 0
        end
    end)
    return teamId
end

-- ========== 检查Bot（对齐参考：TeamID==-1 或 >100） ==========
local function IsBot(pawn)
    if not Valid(pawn) then return false end
    local teamId = 0
    pcall(function()
        if CheckObjectContainsField(pawn, "TeamID") then
            teamId = pawn.TeamID or 0
        end
    end)
    return teamId == -1 or teamId > 100
end

-- ========== 🔥 检查是否存活 ==========
local function IsPawnAlive(pawn)
    if not Valid(pawn) then return false end
    local alive = true
    pcall(function()
        if CheckObjectContainsField(pawn, "bIsDead") then
            alive = not pawn.bIsDead
        end
        if CheckObjectContainsField(pawn, "Health") then
            if pawn.Health <= 0 then
                alive = false
            end
        end
    end)
    return alive
end

-- ========== 🔥 获取骨骼位置 ==========
-- 注意：无效骨骼名时 GetSocketLocation/GetBoneLocation 可能返回 (0,0,0) 或角色根部位置，
-- 不会返回 nil！所以必须校验位置合理性：排除零向量和离角色超过3米的位置。
-- noFallback=true: 骨骼读不到时返回 nil（用于漏打检测，避免误判 fallback 位置）
-- 位置校验函数（模块级，不创建闭包）
local function _IsValidBonePos(p, bodyPos)
    if not p or p.X == nil or p.Y == nil or p.Z == nil then return false end
    if math.abs(p.X) < 1 and math.abs(p.Y) < 1 and math.abs(p.Z) < 1 then return false end
    local dx = p.X - bodyPos.X
    local dy = p.Y - bodyPos.Y
    if dx * dx + dy * dy > 90000 then return false end  -- 300² = 90000
    return true
end

-- 🔥 敌人 Mesh 缓存：返回 Mesh 列表（主Mesh + 外部Mesh）
-- 下半身骨骼（脚/小腿）可能在裤装/外部Mesh上，主Mesh读不到时换下一个
-- 5s 清理失效条目防泄漏
local _MESH_CACHE = {}
local _MESH_CACHE_TICK = 0

local function GetCachedMeshes(pawn)
    local list = _MESH_CACHE[pawn]  -- 直接 userdata 做 key，零字符串分配
    if list and #list > 0 then
        local valid = false
        for _, mm in ipairs(list) do
            if Valid(mm) then valid = true break end
        end
        if valid then return list end
    end
    list = {}
    pcall(function()
        if CheckObjectContainsField(pawn, "Mesh") and Valid(pawn.Mesh) then
            list[#list + 1] = pawn.Mesh
        end
        if CheckObjectContainsField(pawn, "CharacterMesh0") and Valid(pawn.CharacterMesh0) then
            list[#list + 1] = pawn.CharacterMesh0
        end
    end)
    _MESH_CACHE[pawn] = list  -- 直接 userdata 做 key
    if _NOW - _MESH_CACHE_TICK > 5 then
        _MESH_CACHE_TICK = _NOW
        for kk, mm in pairs(_MESH_CACHE) do
            -- 删空条目 + 全部失效条目（Valid(mesh)=false），避免缓存表残留失效引用
            if not mm or #mm == 0 then
                _MESH_CACHE[kk] = nil
            else
                local anyValid = false
                for _, m in ipairs(mm) do
                    if Valid(m) then anyValid = true break end
                end
                if not anyValid then _MESH_CACHE[kk] = nil end
            end
        end
    end
    return list
end

local function GetBonePos(pawn, boneName, noFallback, bodyPos)
    if not Valid(pawn) then return nil end
    
    if not bodyPos then
        bodyPos = GetActorLocation(pawn)
        if not bodyPos then return nil end
    end
    
    local pos = nil
    pcall(function()
        -- 🔥 Mesh 列表（主Mesh + 外部Mesh）：下半身骨骼（脚/小腿）可能在裤装/外部Mesh上
        local meshes = GetCachedMeshes(pawn)
        for _, mesh in ipairs(meshes) do
            if not Valid(mesh) then goto next_mesh end
            
            -- 方法1: GetSocketLocation（socket 名，如 head/spine_03/pelvis）
            local s = mesh:GetSocketLocation(boneName)
            if _IsValidBonePos(s, bodyPos) then pos = s; return end
            
            -- 方法2: GetBoneLocation（世界空间，认任意骨骼名，如 hand_l）
            local b = mesh:GetBoneLocation(boneName)
            if _IsValidBonePos(b, bodyPos) then pos = b; return end
            
            -- 方法3: GetBoneIndex + GetBoneTransform + ComponentToWorld
            local idx = mesh:GetBoneIndex(boneName)
            if idx >= 0 then
                local trans = mesh:GetBoneTransform(idx)
                if trans and trans.Translation then
                    local world = mesh:K2_GetComponentToWorld()
                    if not world then world = mesh.ComponentToWorld end
                    if world and world.TransformPosition then
                        local wp = world:TransformPosition(trans.Translation)
                        if _IsValidBonePos(wp, bodyPos) then pos = Vector.New(wp.X, wp.Y, wp.Z); return end
                    elseif world and world.X ~= nil then
                        local wp = Vector.New(world.X + trans.Translation.X, world.Y + trans.Translation.Y, world.Z + trans.Translation.Z)
                        if _IsValidBonePos(wp, bodyPos) then pos = wp; return end
                    end
                end
            end
            ::next_mesh::
        end
    end)
    
    if not pos then
        if noFallback then
            return nil  -- 漏打用：骨骼无效直接返回 nil，不 fallback
        end
        local bodyPos2 = bodyPos
        if boneName == "head" then
            pos = Vector.New(bodyPos2.X, bodyPos2.Y, bodyPos2.Z + 90)
        elseif boneName == "spine_03" then
            pos = Vector.New(bodyPos2.X, bodyPos2.Y, bodyPos2.Z + 50)
        elseif boneName == "spine_02" then
            pos = Vector.New(bodyPos2.X, bodyPos2.Y, bodyPos2.Z + 35)
        elseif boneName == "pelvis" then
            pos = Vector.New(bodyPos2.X, bodyPos2.Y, bodyPos2.Z + 20)
        else
            pos = Vector.New(bodyPos2.X, bodyPos2.Y, bodyPos2.Z + 50)
        end
    end
    
    return pos
end

-- ========== 🔥 预判辅助 ==========
-- 获取目标速度（用于子弹预判）
-- 玩家在载具中时，速度从载具获取（玩家本身Velocity=0，是车在动）
local function GetTargetVelocity(pawn)
    if not Valid(pawn) then return nil end
    local vel = nil
    pcall(function()
        -- 先检查是否在载具里
        local vehicle = nil
        if pawn.GetCurrentVehicle then
            vehicle = pawn:GetCurrentVehicle()
        end
        if Valid(vehicle) then
            -- 从载具取速度（车动的速度）
            if vehicle.GetVelocity then vel = vehicle:GetVelocity() end
            if not vel and vehicle.Velocity then vel = vehicle.Velocity end
            if not vel and vehicle.CharacterMovement and vehicle.CharacterMovement.Velocity then
                vel = vehicle.CharacterMovement.Velocity
            end
            if vel then return end
        end
        -- 不在载具：从玩家取速度
        if pawn.GetVelocity then vel = pawn:GetVelocity() end
        if not vel and pawn.Velocity then vel = pawn.Velocity end
        if not vel and pawn.CharacterMovement and pawn.CharacterMovement.Velocity then
            vel = pawn.CharacterMovement.Velocity
        end
    end)
    -- 🔥 速度校验：NaN/异常大值丢弃，防止预判跳飞
    if vel then
        if vel.X ~= vel.X or vel.Y ~= vel.Y or vel.Z ~= vel.Z then
            vel = nil  -- NaN
        elseif math.abs(vel.X) > 10000 or math.abs(vel.Y) > 10000 or math.abs(vel.Z) > 10000 then
            vel = nil  -- 异常大值（>100m/s，不可能出现的速度）
        end
    end
    return vel
end

-- 获取子弹速度（优先由 ApplyWeaponMods 缓存，兜底直接读武器实体）
local BULLET_SPEED_CACHE = 0      -- 缓存的子弹速度（由 ApplyWeaponMods 更新）

local function GetBulletSpeed()
    if BULLET_SPEED_CACHE > 0 then return BULLET_SPEED_CACHE end
    -- 兜底：直接读当前武器实体（轻量，不走完整武器链）
    pcall(function()
        local pc = GetPlayerController()
        if Valid(pc) then
            local pawn = pc:GetPlayerCharacterSafety()
            if Valid(pawn) then
                local w = pawn:GetCurrentShootWeapon()
                if Valid(w) then
                    local e = w.ShootWeaponEntityComp
                    if Valid(e) and e.BulletFireSpeed and e.BulletFireSpeed > 0 then
                        local spd = e.BulletFireSpeed
                        if w.BulletFireSpeedModifier and w.BulletFireSpeedModifier > 0 then
                            spd = spd * w.BulletFireSpeedModifier
                        end
                        BULLET_SPEED_CACHE = spd
                        return
                    end
                end
            end
        end
    end)
    if BULLET_SPEED_CACHE > 0 then return BULLET_SPEED_CACHE end
    return 80000  -- 最终兜底：AR 子弹速度 800m/s → 80000cm/s
end

-- 获取子弹重力倍率（默认1.0=全重力，狙击/喷子可能<1）
local BULLET_GRAVITY_CACHE = 0  -- 缓存的子弹重力倍率（由 ApplyWeaponMods 更新；0=未缓存需读取）
local BULLET_GRAVITY_EXTRA_CACHE = nil  -- 子弹重力额外偏移（如弩箭/榴弹特殊弹道；由ApplyWeaponMods更新；nil=未缓存，兜底0）

local function GetBulletGravity()
    if BULLET_GRAVITY_CACHE > 0 then return BULLET_GRAVITY_CACHE end
    -- 兜底：直接读当前武器实体的 BulletGravityModifier
    pcall(function()
        local pc = GetPlayerController()
        if Valid(pc) then
            local pawn = pc:GetPlayerCharacterSafety()
            if Valid(pawn) then
                local w = pawn:GetCurrentShootWeapon()
                if Valid(w) then
                    local e = w.ShootWeaponEntityComp
                    if Valid(e) and e.BulletGravityModifier and e.BulletGravityModifier > 0 then
                        BULLET_GRAVITY_CACHE = e.BulletGravityModifier
                        return
                    end
                end
            end
        end
    end)
    if BULLET_GRAVITY_CACHE > 0 then return BULLET_GRAVITY_CACHE end
    return 1.0
end

-- ========== 🔥 预判 ==========
-- 计算子弹命中预判位置：目标移动提前量 + 重力下坠补偿
-- 入参：瞄准位置、相机位置、目标速度；返回预判位置，失败返回 nil（调用方用原位置）
local function PredictPosition(bestPos, camLoc, vel)
    local dx = bestPos.X - camLoc.X
    local dy = bestPos.Y - camLoc.Y
    local dz = bestPos.Z - camLoc.Z
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
    local bulletSpeed = GetBulletSpeed()
    if not bulletSpeed or bulletSpeed <= 0 then return nil end
    
    -- 子弹飞行时间：迭代3次收敛（子弹实际飞向预判位置，距离略异于当前位置）
    local travelTime = dist / bulletSpeed
    for _ = 1, 3 do
        local ldx = dx + vel.X * travelTime
        local ldy = dy + vel.Y * travelTime
        local ldz = dz + vel.Z * travelTime
        local dist2 = math.sqrt(ldx*ldx + ldy*ldy + ldz*ldz)
        if dist2 <= 0 then break end
        travelTime = dist2 / bulletSpeed
    end
    
    -- 提前量（目标位移） + 下坠补偿（重力抬高瞄准点）
    -- 标准UE重力=980cm/s² × 武器倍率 + 额外偏移；下坠量 = 0.5×g×t²
    local grav = GetBulletGravity()
    local g = 980 * grav + (BULLET_GRAVITY_EXTRA_CACHE or 0)
    local drop = 0.5 * g * travelTime * travelTime
    return Vector.New(
        bestPos.X + vel.X * travelTime,
        bestPos.Y + vel.Y * travelTime,
        bestPos.Z + vel.Z * travelTime + drop
    )
end

-- 🔥 PID 控制器状态（PD平滑算法用，跨帧持久化）
-- 切换目标时自动重置，避免旧目标导数污染新目标指向
local _PID = {
    target = nil,      -- 当前跟踪的目标，切换时重置
    lastErrYaw = 0,    -- 上一帧 Yaw 误差（微分用）
    lastErrPitch = 0,  -- 上一帧 Pitch 误差
}

-- ========== 隔墙检测（ECC_Camera 通道，玻璃可穿透） ==========
-- 返回: true=可打(无墙/命中玻璃), false=被墙/金属挡
-- ★ ECC_Camera：玻璃（车/房）可穿透；墙/载具金属阻挡
-- ⚠️ OutHit 表每次新建（复用会卡顿：C++ 端可能持有引用/延迟写入）
-- endPos:   终点（瞄准点/骨骼位置）
-- ignoreActors: 忽略列表（自己和目标）
-- 返回: true=无遮挡(可见，玻璃可穿透), false=被墙/金属挡
-- ★ ECC_Camera 玻璃可穿透：射线穿过玻璃命中目标身体或穿过 → 可打；命中墙/金属 → 不可打
local function IsPointVisible(startPos, endPos, ignoreActors)
    if not startPos or not endPos then return false end
    if not GameFrontendHUD then return false end  -- fail-closed：无HUD说明环境未就绪，视为不可见
    
    local visible = false  -- fail-closed：两方法都失败时返回"不可见"，防止墙后锁
    local done = false
    
    -- 方法1（首选，已验证可用）: STExtraBlueprintFunctionLibrary，ECC_Camera 玻璃可穿透
    if not done and STExtraBlueprintFunctionLibrary then
        pcall(function()
            local hitRes = {}
            local bHit = STExtraBlueprintFunctionLibrary.LineTraceByChannel(
                hitRes, GameFrontendHUD, startPos, endPos,
                ignoreActors, ECollisionChannel.ECC_Camera
            )
            if bHit ~= nil then
                -- ECC_Camera 玻璃可穿透：命中任何东西 = 被墙/金属挡 = 不可打
                visible = not bHit
                done = true
            end
        end)
    end
    
    -- 方法2（备用）: KismetSystemLibrary.LineTraceSingle，ECC_Camera
    if not done and KismetSystemLibrary then
        pcall(function()
            local hitRes = {}
            local bHit = KismetSystemLibrary.LineTraceSingle(
                GameFrontendHUD, startPos, endPos,
                ECollisionChannel.ECC_Camera, true,
                ignoreActors, EDrawDebugTrace.None, hitRes, true
            )
            if bHit ~= nil then
                visible = not bHit
                done = true
            end
        end)
    end
    
    return visible
end

-- ========== 🔥 获取屏幕中心 ==========
local function GetScreenCenter()
    local centerX = nil  -- nil 哨兵：方法1失败才走方法2（960x540 也可能是真实分辨率，不能当哨兵）
    local centerY = nil
    -- 方法1：WidgetLayoutLibrary（最可靠）
    pcall(function()
        if WidgetLayoutLibrary and GameFrontendHUD then
            local size = WidgetLayoutLibrary.GetViewportSize(GameFrontendHUD)
            if size then
                centerX = size.X * 0.5
                centerY = size.Y * 0.5
            end
        end
    end)
    -- 方法2：PlayerCameraManager 的 ViewportSize（方法1失败时兜底，实时分辨率）
    if not centerX or not centerY then
        pcall(function()
            local pc = GetPlayerController()
            if Valid(pc) then
                local pcm = pc.PlayerCameraManager
                if Valid(pcm) and pcm.GetViewportSize then
                    local w, h = pcm:GetViewportSize()
                    if w and h and w > 0 and h > 0 then
                        centerX = w * 0.5
                        centerY = h * 0.5
                    end
                end
            end
        end)
    end
    -- 最终兜底：方法1/2都失败时用 1920×1080 标准值
    if not centerX or not centerY then
        centerX = 960
        centerY = 540
    end
    return centerX, centerY
end

-- ========== 🔥 投影到屏幕（修复版） ==========
local function WorldToScreen(pc, worldPos)
    if not Valid(pc) or not worldPos then
        return false, 0, 0
    end
    
    local screenX = 0
    local screenY = 0
    local success = false
    
    -- 方法1: ProjectWorldLocationToScreen
    pcall(function()
        if CheckObjectContainsField(pc, "ProjectWorldLocationToScreen") then
            local screenPos = {X = 0, Y = 0}
            local returnValue = pc:ProjectWorldLocationToScreen(worldPos, screenPos, false)
            if returnValue then
                success = true
                screenX = screenPos.X
                screenY = screenPos.Y
                return
            end
        end
    end)
    
    -- 方法2: GetViewportSize + 手动计算
    if not success then
        pcall(function()
            if GameFrontendHUD and WidgetLayoutLibrary then
                local viewportSize = WidgetLayoutLibrary.GetViewportSize(GameFrontendHUD)
                if viewportSize then
                    local world = GetWorld()
                    if world then
                        local playerCameraManager = pc.PlayerCameraManager
                        if Valid(playerCameraManager) then
                            local cameraLoc = GetCameraLocation(pc)
                            -- 🔥 用相机旋转而非控制旋转（TPP下相机可绕角色转，控制旋转≠相机旋转）
                            local cameraRot = nil
                            pcall(function()
                                if playerCameraManager.GetCameraRotation then
                                    cameraRot = playerCameraManager:GetCameraRotation()
                                end
                            end)
                            if not cameraRot then
                                cameraRot = pc:GetControlRotation()  -- 兜底
                            end
                            
                            if cameraLoc and cameraRot then
                                -- 计算相对位置
                                local relX = worldPos.X - cameraLoc.X
                                local relY = worldPos.Y - cameraLoc.Y
                                local relZ = worldPos.Z - cameraLoc.Z
                                
                                -- 旋转矩阵（简化版）
                                local pitchRad = cameraRot.Pitch * _DEG2RAD
                                local yawRad = cameraRot.Yaw * _DEG2RAD
                                
                                -- 旋转
                                local cosY = math.cos(yawRad)
                                local sinY = math.sin(yawRad)
                                local cosP = math.cos(pitchRad)
                                local sinP = math.sin(pitchRad)
                                
                                -- 转换到相机空间
                                local forwardX = cosY * cosP
                                local forwardY = sinY * cosP
                                local forwardZ = sinP
                                
                                local rightX = -sinY
                                local rightY = cosY
                                local rightZ = 0
                                
                                local upX = cosY * -sinP
                                local upY = sinY * -sinP
                                local upZ = cosP
                                
                                local dotForward = relX * forwardX + relY * forwardY + relZ * forwardZ
                                local dotRight = relX * rightX + relY * rightY + relZ * rightZ
                                local dotUp = relX * upX + relY * upY + relZ * upZ
                                
                                if dotForward > 0 then
                                    local fov = 90
                                    if playerCameraManager.GetFOVAngle then
                                        fov = playerCameraManager:GetFOVAngle()
                                    end
                                    local fovRad = fov * _DEG2RAD
                                    local halfFovTan = math.tan(fovRad / 2)
                                    
                                    local screenXPos = viewportSize.X / 2 + (dotRight / dotForward) * (viewportSize.X / 2) / halfFovTan
                                    local screenYPos = viewportSize.Y / 2 - (dotUp / dotForward) * (viewportSize.Y / 2) / halfFovTan
                                    
                                    success = true
                                    screenX = screenXPos
                                    screenY = screenYPos
                                end
                            end
                        end
                    end
                end
            end
        end)
    end
    
    return success, screenX, screenY
end

-- ========== 🔥 核心自瞄 ==========
local _REUSE_IGNORE = {}  -- 复用表：射线忽略列表（SetupIgnoreList 统一设置，减少每帧GC）
local _EXPOSE_BONE = nil   -- 漏打找到的骨骼名（每tick实时取位置，不缓存位置防过期）
local _EXPOSE_TICK = 0     -- 漏打刷新计数
local _EXPOSE_TARGET = nil -- 漏打缓存绑定的目标
local _EXPOSE_COOLDOWN = 0 -- 漏打全挡冷却计数：所有骨骼被挡后冷却15tick再重扫，避免每tick空扫
local _VIS_CACHE = {}      -- 🔥 隔墙检测缓存 {[target(userdata)]={visible,time}}，2s刷新
local _VIS_CACHE_CLEAN = 0  -- 缓存清理时间戳
local _NOW = 0              -- 🔥 全局统一时间戳（AimTick 每帧刷新，热路径共用，减少 os.time() 系统调用）
-- 🔥 屏幕中心缓存（分辨率几乎不变，1s刷新，避免每tick GetViewportSize C++调用）
local _SCREEN_CX = 960
local _SCREEN_CY = 540
local _SCREEN_TICK = 0
-- 🔥 FOV 像素半径²缓存（cfg.FOV/相机FOV/中心任一变化才重算 tan）
local _FOV_RADIUS_SQ = 0
local _FOV_RADIUS_KEY = ""
local _BONE_NAMES = {"head", "spine_03", "spine_02", "pelvis"}  -- 常量，4档骨骼
local _DEG2RAD = 3.14159265 / 180  -- 🔥 预计算，减少6处重复除法
local _RAD2DEG = 180 / 3.14159265
local _BONE_CORE = {"head", "clavicle_l", "clavicle_r", "spine_01", "spine_02", "spine_03", "pelvis"}
local _BONE_LIMBS = {
    "upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r",
    "thigh_l", "thigh_r", "calf_l", "calf_r", "foot_l", "foot_r",
}

-- 统一设置射线忽略列表（只忽略自己和目标：目标忽略后射线穿过其身体检测墙/玻璃）
local function SetupIgnoreList(myPawn, target)
    _REUSE_IGNORE[1] = myPawn
    _REUSE_IGNORE[2] = target
end

-- 屏幕中心（1s缓存）
local function GetCachedScreenCenter()
    if (_NOW - _SCREEN_TICK) >= 1 then
        _SCREEN_TICK = _NOW
        local cx, cy = GetScreenCenter()
        if cx and cy and cx > 0 and cy > 0 then
            _SCREEN_CX = cx
            _SCREEN_CY = cy
        end
    end
    return _SCREEN_CX, _SCREEN_CY
end

-- 🔥 事件监听分辨率变化（替代部分轮询：ViewportResized 时立刻强制刷新，平时走1s缓存）
pcall(function()
    if EventSystem and EventSystem.registEvent then
        EventSystem:registEvent("ViewportResized", function()
            _SCREEN_TICK = 0  -- 下次取屏幕中心时强制刷新
        end)
    end
end)

-- FOV 像素半径²（cfg.FOV/相机FOV/屏幕中心任一变化才重算；相机FOV每tick读，tan缓存）
local function GetCachedFovRadiusSq(cfg, pc, centerX, centerY)
    local actualFovDeg = 90
    pcall(function()
        local camMgr = pc.PlayerCameraManager
        if Valid(camMgr) and camMgr.GetFOVAngle then
            local f = camMgr:GetFOVAngle()
            if f and f > 0 then actualFovDeg = f end
        end
    end)
    local fovDeg = cfg.FOV or 5
    local key = tostring(fovDeg) .. "|" .. tostring(actualFovDeg) .. "|" .. tostring(centerX) .. "|" .. tostring(centerY)
    if key == _FOV_RADIUS_KEY then
        return _FOV_RADIUS_SQ, actualFovDeg
    end
    _FOV_RADIUS_KEY = key
    local halfTanCur = math.tan(fovDeg * 0.5 * _DEG2RAD)
    local halfTanGame = math.tan(actualFovDeg * 0.5 * _DEG2RAD)
    if halfTanGame <= 0 then halfTanGame = 1 end
    local fovRadius = halfTanCur / halfTanGame * centerX
    _FOV_RADIUS_SQ = fovRadius * fovRadius
    return _FOV_RADIUS_SQ, actualFovDeg
end
-- 骨骼优先级列表（config 驱动，缓存重建）
-- 不再有"主骨/副骨"之分：用户配置的骨骼(Bone=0~3)排第一，然后核心部位(头/锁骨/躯干)，最后四肢
-- 从第一个"可打"的骨骼开始锁定：躯干可打就打躯干，躯干被挡才依次往下找
local _BONE_PRIORITY = {
    "head", "clavicle_l", "clavicle_r", "spine_01", "spine_02", "spine_03", "pelvis",
    "upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r",
    "thigh_l", "thigh_r", "calf_l", "calf_r", "foot_l", "foot_r",
}
local _BONE_PRIORITY_KEY = ""
local function GetBonePriority(cfgBoneIdx)
    local key = tostring(cfgBoneIdx or 1)
    if key == _BONE_PRIORITY_KEY then return _BONE_PRIORITY end
    _BONE_PRIORITY_KEY = key
    local primary = _BONE_NAMES[(cfgBoneIdx or 1) + 1] or "head"
    local list = {primary}
    for _, b in ipairs(_BONE_CORE) do if b ~= primary then table.insert(list, b) end end
    for _, b in ipairs(_BONE_LIMBS) do if b ~= primary then table.insert(list, b) end end
    _BONE_PRIORITY = list
    return list
end

-- 🔥 目标评分（重构版：分数越高越优先）
-- Score = w1·(1/dist) + w2·CenterScore + w3·VisibleRatio
--   dist(距离)：越近越高（1/(1+dist/maxDist) 归一化，距离0→1，maxDist→0.5）
--   CenterScore(靠中心)：越靠近画面中心越高（1 - screenDist/fovRadius）
--   VisibleRatio(可见度)：可见=1.0，被墙挡=0.0
-- 权重：w1=0.30(距离) w2=0.45(中心，主导) w3=0.25(可见)，总和1.0
-- 说明：不含 Conf 维度——enemies 内目标均为有效检测，fallback 只是位置估算方式，不构成置信度差异
local function ScoreTarget(target, screenDistSq, distSq, maxDistSq, fovRadiusSq, mainBlocked)
    -- w1·(1/dist)：距离归一化
    local distScore = 1.0
    if maxDistSq > 0 and distSq >= 0 then
        distScore = 1.0 / (1.0 + distSq / maxDistSq)
    end
    -- w2·CenterScore：越靠画面中心越高
    local centerScore = 1.0
    if fovRadiusSq > 0 then
        local c = screenDistSq / fovRadiusSq
        if c > 1 then c = 1 end
        centerScore = 1.0 - c
    end
    -- w3·VisibleRatio：可见=1，被墙挡=0
    local visibleRatio = mainBlocked and 0.0 or 1.0

    return 0.30 * distScore + 0.45 * centerScore + 0.25 * visibleRatio
end

local function AimTick()
    local cfg = _G.AimConfig
    _NOW = os.time()  -- 🔥 全局统一时间戳：移到最开头（即使 Enabled=false 也刷新，保证缓存清理逻辑正常运行）
    if not cfg.Enabled then
        return
    end
    
    -- 类型安全：热配置可能读到字符串，确保算术安全
    if type(cfg.Bone) ~= 'number' then cfg.Bone = tonumber(cfg.Bone) or 1 end
    if type(cfg.Distance) ~= 'number' then cfg.Distance = tonumber(cfg.Distance) or 300 end
    if type(cfg.FOV) ~= 'number' then cfg.FOV = tonumber(cfg.FOV) or 5 end
    if type(cfg.SmoothSpeed) ~= 'number' then cfg.SmoothSpeed = tonumber(cfg.SmoothSpeed) or 8 end
    
    local pc = GetPlayerController()
    if not Valid(pc) then
        return
    end
    
    local myPawn = pc:GetPlayerCharacterSafety()
    if not Valid(myPawn) then
        return
    end
    
    -- 检查触发条件
    if cfg.TriggerMode == "always" then
        -- 始终触发
    else
        local isFiring = false
        SafeCall(function()  -- AimTick:isFiring
            if CheckObjectContainsField(myPawn, "bIsWeaponFiring") then
                isFiring = myPawn.bIsWeaponFiring
            end
        end)
        if not isFiring then return end
    end
    
    -- 获取所有玩家（对齐参考：每次全量枚举）
    local allPlayers = GetAllPawns()
    if not allPlayers or #allPlayers == 0 then return end

    -- 敌我筛选（对齐参考：TeamID 不同即敌人，排除 -1，排除 Bot）
    local myTeamID = GetTeamID(myPawn)
    local enemies = {}
    for _, player in ipairs(allPlayers) do
        if Valid(player) and player ~= myPawn then
            local teamID = GetTeamID(player)
            if teamID ~= myTeamID and teamID ~= -1 then
                if IsPawnAlive(player) and not IsBot(player) then
                    table.insert(enemies, player)
                end
            end
        end
    end
    if #enemies == 0 then return end
    
    -- 获取相机位置（提前）
    local camLoc = GetCameraLocation(pc)
    if not camLoc then return end
    
    -- 视线起点：始终用相机位置（TPP/FPP都正确，探头会跟随相机移动）
    local traceOrigin = camLoc
    

-- 屏幕中心（1s缓存）+ FOV半径²（键变化才重算 tan）
    local centerX, centerY = GetCachedScreenCenter()
    local maxDist = cfg.Distance * 100
    local maxDistSq = maxDist * maxDist
    local fovRadiusSq, actualFovDeg = GetCachedFovRadiusSq(cfg, pc, centerX, centerY)
    if fovRadiusSq <= 0 then fovRadiusSq = 1 end  -- 防除零

    -- 骨骼名称（4档：头/胸/腰/骨盆，对应配置 Bone=0~3）
    local boneName = _BONE_NAMES[cfg.Bone + 1] or "head"
    local boneOffset = cfg.BoneOffset or 0
    
    -- 选择目标（分数越高越优先）
    local bestTarget = nil
    local bestPos = nil
    local bestScore = -math.huge
    local bestMainBlocked = false  -- 最佳目标的主骨是否被墙挡
    
    for _, target in ipairs(enemies) do
        if Valid(target) then
            -- 获取目标位置
            local tPos = GetActorLocation(target)
            if not tPos then goto continue end
            
            -- 距离检测
            local dx = camLoc.X - tPos.X
            local dy = camLoc.Y - tPos.Y
            local dz = camLoc.Z - tPos.Z
            local distSq = dx * dx + dy * dy + dz * dz
            if distSq > maxDistSq then goto continue end
            
            -- 获取骨骼位置
            local bonePos = GetBonePos(target, boneName, false, tPos)  -- 传入已算好的目标位置，避免重复获取
            if not bonePos then goto continue end
            
            -- 🔥 隔墙检测（缓存+位置校验：可见性缓存2s，目标移动>150cm强制重测）
            -- 修复：缓存无位置校验时，目标跑进掩体1秒内仍判"可见"→锁胸口打墙
            local mainBlocked = false
            if cfg.LeakAim ~= false then
                local vk = target  -- 直接 userdata 做 key，避免 tostring 分配
                local ve = _VIS_CACHE[vk]
                local vt = _NOW  -- 统一时间戳
                local moved = false
                if ve and ve.x and tPos then
                    local mdx = tPos.X - ve.x
                    local mdy = tPos.Y - ve.y
                    local mdz = tPos.Z - ve.z
                    if mdx*mdx + mdy*mdy + mdz*mdz > 22500 then moved = true end  -- 150²=22500
                end
                if ve and vt - ve.time < 2 and not moved then
                    mainBlocked = not ve.visible  -- 缓存有效且目标没大动，直接用
                else
                    -- 缓存过期/不存在/目标移动 → 才做物理射线
                    SetupIgnoreList(myPawn, target)
                    local visible = IsPointVisible(traceOrigin, bonePos, _REUSE_IGNORE)
                    _VIS_CACHE[vk] = {visible = visible, time = vt, x = tPos.X, y = tPos.Y, z = tPos.Z}
                    mainBlocked = not visible
                end
                -- 主骨被挡不跳过：交给后面的"漏打"扫露出的骨骼（LeakAim=true）
            end
            -- 缓存清理：每 15 秒清一次 2 秒前的旧条目（防泄漏，在 LeakAim 块外，确保始终执行）
            if _NOW - _VIS_CACHE_CLEAN > 15 then
                _VIS_CACHE_CLEAN = _NOW
                for k, v in pairs(_VIS_CACHE) do
                    if _NOW - v.time > 2 then _VIS_CACHE[k] = nil end
                end
            end
            
            -- 投影到屏幕（用主骨位置选最佳目标）
            local success, screenX, screenY = WorldToScreen(pc, bonePos)
            if not success or screenX <= 0 or screenY <= 0 then goto continue end
            
            -- FOV检测（平方比较，避免 math.sqrt）
            local dx2 = screenX - centerX
            local dy2 = screenY - centerY
            local screenDistSq = dx2 * dx2 + dy2 * dy2
            if screenDistSq > fovRadiusSq then goto continue end
            
            -- 🔥 目标评分（新公式：分数越高越优先，权重见 ScoreTarget）
            local score = ScoreTarget(target, screenDistSq, distSq, maxDistSq, fovRadiusSq, mainBlocked)
            if score > bestScore then
                bestScore = score
                bestTarget = target
                bestPos = bonePos
                bestMainBlocked = mainBlocked
            end
        end
        ::continue::
    end
    
    -- 🔥 最佳目标强制真实射线（覆盖1s可见性缓存）：
    -- 场景：锁着跑动目标，目标进掩体后缓存仍判"可见"→准心跟墙后位置1秒。
    -- 修复：锁定中的目标每tick实测一次（1根射线，代价极小），进掩体1tick即检出；
    --       1s缓存只保留给"选目标评分"，不用于"锁定中的目标"。
    if bestTarget and cfg.LeakAim ~= false then
        SetupIgnoreList(myPawn, bestTarget)
        local btPos = GetActorLocation(bestTarget)
        if btPos then
            local bbPos = GetBonePos(bestTarget, boneName, false, btPos)
            if bbPos then
                local realVis = IsPointVisible(traceOrigin, bbPos, _REUSE_IGNORE)
                _VIS_CACHE[bestTarget] = {visible = realVis, time = _NOW, x = btPos.X, y = btPos.Y, z = btPos.Z}  -- 直接 userdata 做 key
                bestMainBlocked = not realVis
            end
        end
    end

    -- 如果最佳目标的主骨被墙挡，尝试找露出骨骼（漏打）
    if bestMainBlocked and Valid(bestTarget) then
        -- 目标切换：重置漏打状态
        if _EXPOSE_TARGET ~= bestTarget then
            _EXPOSE_TARGET = bestTarget
            _EXPOSE_BONE = nil
            _EXPOSE_TICK = 0
            _EXPOSE_COOLDOWN = 0
        end
        
        _EXPOSE_TICK = _EXPOSE_TICK + 1
        if _EXPOSE_COOLDOWN > 0 then
            _EXPOSE_COOLDOWN = _EXPOSE_COOLDOWN - 1
        end
        
        -- 判断是否需扫描：有骨骼时每5tick刷新，无骨骼时看冷却
        local needScan = (_EXPOSE_BONE ~= nil and _EXPOSE_TICK >= 5)
                      or (_EXPOSE_BONE == nil and _EXPOSE_COOLDOWN <= 0)
        
        if needScan then
            _EXPOSE_TICK = 0
            _EXPOSE_COOLDOWN = 0
            SetupIgnoreList(myPawn, bestTarget)
            local targetRoot = GetActorLocation(bestTarget)
            local found = false
            for _, bone in ipairs(GetBonePriority(cfg.Bone or 1)) do
                if bone ~= boneName then  -- 主骨已查过被挡，跳过
                    local bp = GetBonePos(bestTarget, bone, true, targetRoot)
                    if bp and IsPointVisible(traceOrigin, bp, _REUSE_IGNORE) then
                        _EXPOSE_BONE = bone
                        bestPos = bp  -- 复用扫描结果位置，同tick不重复取
                        found = true
                        break
                    end
                end
            end
            if not found then
                _EXPOSE_BONE = nil
                _EXPOSE_COOLDOWN = 15
                return  -- 全挡，冷却15tick
            end
            -- 扫描找到骨骼，bestPos已设，跳过下方实时取位置
        else
            if _EXPOSE_BONE == nil then
                return  -- 冷却中无骨骼，放弃本tick
            end
            -- 非扫描tick：实时取位置 + 验证骨骼仍可见
            local targetRoot2 = GetActorLocation(bestTarget)
            local livePos = GetBonePos(bestTarget, _EXPOSE_BONE, true, targetRoot2)
            if livePos then
                SetupIgnoreList(myPawn, bestTarget)
                if IsPointVisible(traceOrigin, livePos, _REUSE_IGNORE) then
                    bestPos = livePos
                else
                    _EXPOSE_BONE = nil
                    _EXPOSE_TICK = 0
                    bestPos = nil  -- 骨骼不可见，放弃瞄准
                end
            end
        end
    else
        -- 主骨没被挡：清漏打缓存
        _EXPOSE_TARGET = nil
        _EXPOSE_BONE = nil
        _EXPOSE_TICK = 0
        _EXPOSE_COOLDOWN = 0
    end
    
    if not bestTarget or not bestPos then
        return
    end
    
    -- ===== 预判（目标移动提前量 + 子弹重力下坠补偿） =====
    if cfg.Prediction ~= false and Valid(bestTarget) then
        local predPos = nil
        pcall(function()
            local targetVel = GetTargetVelocity(bestTarget)
            if targetVel then
                predPos = PredictPosition(bestPos, camLoc, targetVel)
            end
        end)
        if predPos then
            bestPos = predPos  -- 预判失败则保持原位置
        end
    end
    
    -- 计算角度
    local rot = nil
    pcall(function()
        if KismetMathLibrary then
            rot = KismetMathLibrary.FindLookAtRotation(camLoc, bestPos)
        end
    end)
    if not rot then return end
    
    local currentRot = nil
    pcall(function()
        currentRot = pc:GetControlRotation()
    end)
    if not currentRot then return end
    
    local deltaYaw = rot.Yaw - currentRot.Yaw
    local deltaPitch = rot.Pitch - currentRot.Pitch
    
    if deltaYaw > 180 then deltaYaw = deltaYaw - 360 end
    if deltaYaw < -180 then deltaYaw = deltaYaw + 360 end
    if deltaPitch > 180 then deltaPitch = deltaPitch - 360 end
    if deltaPitch < -180 then deltaPitch = deltaPitch + 360 end
    
    -- 🔥 平滑算法：PID 控制器（比例+微分），更自然、更抗检测
    -- P：误差越大转得越快（快速逼近）；D：抑制超调（刹停自然）
    -- 相比限速+指数收敛：无"一段段"跳变，接近目标时自然减速不振荡
    local maxDeg = cfg.SmoothSpeed or 8  -- 每tick最大转角（度），可配置
    if maxDeg <= 0 then maxDeg = 12 end
    
    -- PID 参数（从热配置读取，可实时调）
    local Kp = cfg.Kp or 0.36  -- 比例增益：主驱动力
    local Kd = cfg.Kd or 0.3   -- 微分增益：阻尼，抑制超调
    
    -- 目标切换检测：换了目标就清空导数状态
    if _PID.target ~= bestTarget then
        _PID.target = bestTarget
        _PID.lastErrYaw = deltaYaw
        _PID.lastErrPitch = deltaPitch
    end
    
    -- 微分项（本帧误差 - 上帧误差）
    local dYaw = deltaYaw - _PID.lastErrYaw
    local dPitch = deltaPitch - _PID.lastErrPitch
    _PID.lastErrYaw = deltaYaw
    _PID.lastErrPitch = deltaPitch
    
    -- PD 输出（度）
    local stepYaw = Kp * deltaYaw + Kd * dYaw
    local stepPitch = Kp * deltaPitch + Kd * dPitch
    
    -- 限速：每tick最大转角 maxDeg
    if math.abs(stepYaw) > maxDeg then stepYaw = maxDeg * (stepYaw > 0 and 1 or -1) end
    if math.abs(stepPitch) > maxDeg then stepPitch = maxDeg * (stepPitch > 0 and 1 or -1) end
    
    local finalYaw = currentRot.Yaw + stepYaw
    local finalPitch = currentRot.Pitch + stepPitch
    
    -- 🔥 瞄准偏移（像素 → 俯仰角，正数=上移 负数=下移）
    -- 之前错误地加到世界坐标Z上（把瞄准点抬飞了导致失效），改为屏幕像素偏移
    if boneOffset ~= 0 and centerY > 0 then
        -- 垂直FOV ≈ 实际水平FOV × 0.9（16:9 宽屏比例）
        local vFov = actualFovDeg * 0.9
        -- 屏幕中心到边缘的角度 = 垂直FOV/2，对应 centerY 像素
        local degPerPixel = (vFov / 2) / centerY  -- _DEG2RAD 已在模块级预计算
        -- 屏幕Y向上 = 视角向上 = Pitch 增大
        finalPitch = finalPitch + boneOffset * degPerPixel
    end
    
    -- 🔥 只有实际需要转向时才写（PID 输出≈0 = 已锁定，跳过写入）
    -- 节省 C++ 调用 + 减少"持续改写视角"检测面
    if math.abs(stepYaw) > 0.01 or math.abs(stepPitch) > 0.01 then
        pcall(function()
            if CheckObjectContainsField(pc, "SetControlRotation") then
                pc:SetControlRotation({Pitch = finalPitch, Yaw = finalYaw, Roll = 0})
            end
        end)
    end
end

-- ========== 🔥 全局 Timer 注册表（跨实例生命周期安全） ==========
local aimTimer = nil
local configTimer = nil
-- payload 是 loadstring 动态加载：每次进对局都是新实例，模块级 local 变量不跨实例共享，
-- 旧实例的 timer 若残留，会在卸载后继续触发回调，甚至复活循环 timer（曾导致 config 自动生成）。
-- 方案：所有 timer 统一注册到 _G 表，任何实例"启动时/卸载时"先杀全局残留，保证永远单实例。
-- 正常路径（模块系统正确卸载）下本表只是登记，不干预；异常路径下兜底清理。
local _G_TIMERS = _G.__PAYLOAD_TIMERS or {}
_G.__PAYLOAD_TIMERS = _G_TIMERS

-- 删除并注销一个 timer（跨实例安全：任何实例都能杀掉别的实例注册的 timer）
local function KillTimer(key)
    local t = _G_TIMERS[key]
    if t then
        pcall(function() Timer.RemoveTimer(t) end)
        _G_TIMERS[key] = nil
    end
end

-- 注册 timer 到全局表并返回 id（同 key 先杀旧的，幂等重建）
-- ⚠️ 必须定义在 KillTimer 之后（Lua 词法作用域：前向引用会解析为全局 nil）
local function SetTimer(key, timerId)
    KillTimer(key)
    _G_TIMERS[key] = timerId
    return timerId
end

-- 清空全部已注册 timer（模块加载/每局初始化/卸载时统一调用）
local function KillAllTimers()
    for k in pairs(_G_TIMERS) do
        KillTimer(k)
    end
end

-- 本实例加载第一件事：杀掉一切残留（无论来自哪个实例）
KillAllTimers()

-- ========== 🔥 反作弊上报关闭（开局执行一次，不再每3s循环，消除卡顿） ==========
-- 原则：不置nil（可被检测/崩溃），用 bIsActive=false + 清空策略表 + 周期重应用，
-- 游戏若重置组件状态会被下一轮重新压制。值缓存避免无效重复写入。
local _AC_CMD_SENT = false   -- 退出上报关闭命令只发一次
local _AC_ZXDM_SENT = false  -- ZXDM 深度命令只发一次
-- 反作弊 CVars 常量（模块级，避免每1秒新建表产生GC）
local _AC_CVARS = {
    "avatar.AvatarLogicCallRecordReport", "avatar.AvatarLogicCallRecordReport_AI",
    "avatar.AvatarLogicBanCheck", "r.MeshChangeReport", "r.ForceClothRenderReport",
    "r.IdeaOutlineCheatDetect", "wp.RecoilCheatDetect", "wp.SpreadCheatDetect",
    "cam.FOVCheatDetect", "move.SpeedCheatDetect", "net.ReportCheatData",
    "net.CheatReportInterval", "ai.ReportAICheat", "r.WeaponFireReport",
    "gameplay.ReportAbnormalSpeed", "widget.InsertInvBox", "Slate.EnableHittestCache",
    "security_check_move", "security_check_weapon", "ds_key_check_switch",
    "p.NewPersistentDataManagement",
}

local function DisablePlayerAntiCheat(pc)
    if not Valid(pc) then return end
    -- ① 玩家级反作弊管理器（PlayerAntiCheatManager）
    local acm = pc.AntiCheatManagerComp
    if Valid(acm) then
        -- 🔥 不清空 ReportPolicyThres / PunishOnFlagMap（空表可能被服务器判定"策略异常"）
        -- 只关 tick 停掉客户端上报驱动，保留表结构正常
        -- 🔥 补充字段（对照调查文档 §1）：
        -- DistanceIgnoreCameraTraceLine(0x3f4)：摄像机LineTrace忽略距离，设大值防误判
        -- LogLimitAimInfo(0x3f0)：瞄准信息日志上限，设0减少日志输出
        -- bTriggerCriticalVerifyPlayerDamagePunished(0x18d0)：关键验证惩罚开关，设false
        if acm.DistanceIgnoreCameraTraceLine ~= nil and acm.DistanceIgnoreCameraTraceLine < 100000 then
            acm.DistanceIgnoreCameraTraceLine = 100000
        end
        if acm.LogLimitAimInfo ~= nil and acm.LogLimitAimInfo ~= 0 then
            acm.LogLimitAimInfo = 0
        end
        if acm.bTriggerCriticalVerifyPlayerDamagePunished ~= false then
            acm.bTriggerCriticalVerifyPlayerDamagePunished = false
        end
        -- 标准 ActorComponent 关闭模式（OBB 官方 StopAutoAim 同款，不崩溃）
        if acm.bIsActive ~= false then
            pcall(function() acm:SetComponentTickEnabled(false) end)
            acm.bIsActive = false
        end
    end
    -- ② 武器射击数据上报管理器（ClientWeaponAntiCheatManager）
    local wacm = pc.ClientWeaponAntiCheatManager
    if Valid(wacm) then
        if wacm.bIsActive ~= false then
            pcall(function() wacm:SetComponentTickEnabled(false) end)
            wacm.bIsActive = false
        end
        if wacm.MaxRecordDataNum ~= 0 then wacm.MaxRecordDataNum = 0 end
        if wacm.LogStrategyMap ~= nil and next(wacm.LogStrategyMap) ~= nil then wacm.LogStrategyMap = {} end
        if wacm.ShootReportDataList ~= nil and #wacm.ShootReportDataList > 0 then wacm.ShootReportDataList = {} end
        if wacm.RecordDataList ~= nil and #wacm.RecordDataList > 0 then wacm.RecordDataList = {} end
    end
    -- ③ 解除视角限制（自瞄大角度转向不被限制，同时避免"视角异常"检测）
    if pc.bDisableSetViewYawLimit ~= true then pc.bDisableSetViewYawLimit = true end
    if pc.bDisableSetViewPitchLimit ~= true then pc.bDisableSetViewPitchLimit = true end
    -- ④ 控制台变量反作弊检测开关（与组件关闭互补，双保险）
    if KismetSystemLibrary then
        pcall(function()
            for _, cvar in ipairs(_AC_CVARS) do
                KismetSystemLibrary.SetConsoleVariableIntValue(cvar, 0)
            end
        end)
    end
    -- ⑤ ZXDM 深度引擎反作弊命令（穿透更深，仅限一次）
    if not _AC_ZXDM_SENT and GlobalData and GlobalData.ZxdmDo then
        pcall(function()
            GlobalData.ZxdmDo([[pcall(function()
                KismetSystemLibrary.ExecuteConsoleCommand(GameplayStatics.GetPlayerController(GameFrontendHUD,0),"p.ForceNoClip 0",GameplayStatics.GetPlayerController(GameFrontendHUD,0))
                STExtraGameplayStatics.SetIntConsoleVariable("ds_key_check_switch",0)
                STExtraGameplayStatics.SetIntConsoleVariable("p.NewPersistentDataManagement",0)
            end)]])
            _AC_ZXDM_SENT = true
        end)
    end
end

local function DisablePawnAntiCheat(p)
    if not Valid(p) then return end
    -- ① 移动反作弊（MoveAntiCheatComponent）
    local mcm = p.MoveAntiCheatComponent
    if Valid(mcm) then
        if mcm.bUseMoveAntiCheatCheck ~= false then mcm.bUseMoveAntiCheatCheck = false end
        -- 🔥 补充字段（SDK @MoveAntiCheatComponent 确认）：
        if mcm.MinMoveAntiCheatCheckIntervel ~= nil and mcm.MinMoveAntiCheatCheckIntervel < 100 then
            mcm.MinMoveAntiCheatCheckIntervel = 100  -- 最小检测间隔(0x134)，设大值降低检测频率
        end
        if mcm.bIsForceAdjustZWhenExceed ~= false then mcm.bIsForceAdjustZWhenExceed = false end  -- 超出时强制调整Z(0x154)
        if mcm.MaxCheatTimes ~= 9999999 then mcm.MaxCheatTimes = 9999999 end  -- 基础作弊次数上限(0x138)
        if mcm.MaxTotalMoveCheatTimes ~= 9999999 then mcm.MaxTotalMoveCheatTimes = 9999999 end
        if mcm.MaxTotalPassWallTimes ~= 9999999 then mcm.MaxTotalPassWallTimes = 9999999 end
        if mcm.MaxMoveAntiCheatCheatSpeedTimes ~= 9999999 then mcm.MaxMoveAntiCheatCheatSpeedTimes = 9999999 end
    end
    -- ② 命中验证反作弊（LagCompensationComponent / EntityAntiCheatComponent）
    local lc = p.LagCompensationComponent
    if Valid(lc) then
        if lc.bVerifyClientHitAndBullet ~= false then lc.bVerifyClientHitAndBullet = false end
        if lc.bVerifyClientMuzzle ~= false then lc.bVerifyClientMuzzle = false end
        if lc.bVerifyShootPointPassWall ~= false then lc.bVerifyShootPointPassWall = false end
        if lc.bVerityBlock ~= false then lc.bVerityBlock = false end
        if lc.bVerifyShootPoint ~= false then lc.bVerifyShootPoint = false end
        -- 🔥 补充字段（SDK @LagCompensationComponentBase 确认）：
        if lc.bEnableReverseVerityBlock ~= false then lc.bEnableReverseVerityBlock = false end  -- 反向验证封锁(0x28c)
        if lc.bVerifyInParachuteShootPoint ~= false then lc.bVerifyInParachuteShootPoint = false end  -- 跳伞射击点验证(0x28d)
        if lc.bVerifyHitType ~= false then lc.bVerifyHitType = false end  -- 命中类型验证(0x298)
        if lc.TolerateShootPointDistanceSqured ~= 999999999 then lc.TolerateShootPointDistanceSqured = 999999999 end
        if lc.bIsActive ~= false then
            pcall(function() lc:SetComponentTickEnabled(false) end)
            lc.bIsActive = false
        end
    end
end

-- ========== 🔥 精确过滤反作弊相关业务上报 ==========
-- ClientSendBAReport 是全局 Lua 函数，只拦截反作弊事件码，其余业务上报原样放行
-- 🔥 全局标记：跨局重复加载时只包裹一次，避免层层套娃（每次加载都套一层会累积开销）
if not _G.__PAYLOAD_BA_HOOKED__ then
    _G.__PAYLOAD_BA_HOOKED__ = true
    local _origBA = _G.ClientSendBAReport
    if _origBA then
        _G.ClientSendBAReport = function(button_type, reason, ext_arg1, ext_arg2, forceReport)
            if button_type == 99010 then  -- BP_BA_TSS_GET_REPORT4_FAILED：TSS report4 失败才触发，无需上报
                return
            end
            return _origBA(button_type, reason, ext_arg1, ext_arg2, forceReport)
        end
    end
end

-- 提取为命名函数，避免每次 StartAim 创建闭包
-- 每3秒：武器增强（换枪检测）+ 移速 + 广角
-- 移速/广角也对局中会被游戏覆盖 → 和枪械一样每 3 秒重写一次（配置写死，写入开销极小）
local function ConfigAndWeaponLoop()
    local pc2 = GetPlayerController()
    if Valid(pc2) then
        local p2 = pc2:GetPlayerCharacterSafety()
        if Valid(p2) then
            ApplyWeaponMods(p2)
            ApplyMoveSpeed(p2)
            ApplySpringArmLength(p2)
        end
        if not _AC_CMD_SENT and ScriptHelperServer and ScriptHelperServer.ExecuteConsoleCommand then
            pcall(function()
                ScriptHelperServer.ExecuteConsoleCommand(GameFrontendHUD, "st.OpenPlayerExitAntiCheatReport 0")
            end)
            _AC_CMD_SENT = true
        end
    end
end

local function AimTickLoop()
    AimTick()
end

local function DelayedStartAimTick()
    KillTimer("aim_delay")  -- 一次性 timer 已触发，注销全局表残留条目（引擎侧已自删，幂等）
    aimTimer = SetTimer("aim", Timer.InsertTimer(0.016, AimTickLoop, true))
end

local function StartAim()
    -- 🔥 先杀全局残留 timer（跨实例），再重建；所有 timer 都注册到全局表
    -- KillAllTimers 已通过 _G_TIMERS 注册表统一清理（含 config），局部变量只需置空
    KillAllTimers()
    aimTimer = nil
    configTimer = nil
    
    -- 合并定时器：配置热加载 + 武器增强（每1秒一次，降低文件I/O频率减少卡顿）
    configTimer = SetTimer("config", Timer.InsertTimer(3.0, ConfigAndWeaponLoop, true))
    
    -- 🔥 反作弊组件开局关一次即可（不再每3s轮询，消除卡顿）
    pcall(function()
        local pc3 = GetPlayerController()
        if Valid(pc3) then
            local p3 = pc3:GetPlayerCharacterSafety()
            if Valid(p3) then DisablePawnAntiCheat(p3) end
            DisablePlayerAntiCheat(pc3)
        end
    end)
    
    SetTimer("aim_delay", Timer.InsertTimer(1.0, DelayedStartAimTick, false))
end

-- ========== 🔥 模块生命周期 ==========
-- 🔥 关键设计：区分"首次初始化"与"重生"（团队竞技/复活模式会频繁重生）
--   首次（INITED=false）：完整启动 → KillAllTimers + 3s延迟 StartAim
--   重生（INITED=true）：只重置缓存让新pawn生效，绝不杀timer（否则频繁重生时功能反复重启=失效）
-- 跨局安全仍由：PreUnload（KillAllTimers + INITED=false）+ 全局timer注册表兜底

-- 🔥 统一重置缓存（重生/首次初始化共用，避免17行重复代码）
local function ResetCaches()
    _SCREEN_TICK = 0
    _FOV_RADIUS_KEY = ""
    _VIS_CACHE = {}
    _VIS_CACHE_CLEAN = 0
    _MESH_CACHE = {}
    _MESH_CACHE_TICK = 0
    _EXPOSE_BONE = nil
    _EXPOSE_TICK = 0
    _EXPOSE_TARGET = nil
    _EXPOSE_COOLDOWN = 0
    _PC_CACHE = nil
    _PC_CACHE_TICK = 0
end

function C:OnReceivePlayerPawnInitialized(pawn)
    if not Valid(pawn) then return end
    
    if INITED then
        -- 🔥 重生/换角色：功能继续运行，只重置缓存让新 pawn 生效
        -- 注意：不能 KillAllTimers！团队竞技每 3-5 秒重生一次，杀 timer 会导致功能永远起不来
        ResetCaches()
        -- 移速/广角由 ConfigAndWeaponLoop 每 3 秒循环持续应用（覆盖重生后新 pawn，无需单独延迟应用）
        -- 重生：新pawn需要重新压制反作弊组件（默认为开启）
        pcall(function() local pc4 = GetPlayerController() if Valid(pc4) then local p4 = pc4:GetPlayerCharacterSafety() if Valid(p4) then DisablePawnAntiCheat(p4) end DisablePlayerAntiCheat(pc4) end end)
        return
    end
    
    -- 🔥 首次初始化（换局/重新加载）：完整启动
    INITED = true
    KillAllTimers()  -- 已通过 _G_TIMERS 注册表统一清理，局部变量只需置空
    aimTimer = nil
    configTimer = nil
    
    INIT_TIME = os.time()
    ResetCaches()
    _AC_CMD_SENT = false   -- 新局重新压制退出上报
    _AC_ZXDM_SENT = false
    
    -- 首次进局：新 pawn 立即应用一次移速/广角（持久属性，写一次保持）
    pcall(function()
        ApplyMoveSpeed(pawn)
        ApplySpringArmLength(pawn)
    end)
    
    -- 🔥 延迟启动 timer 也注册到全局（卸载时能清掉，防止卸载后仍触发 StartAim 复活功能）
    SetTimer("start", Timer.InsertTimer(3.0, function()
        KillTimer("start")  -- 触发后注销
        StartAim()
    end, false))
end

function C:OnReceivePreUnload()
    KillAllTimers()  -- 全局注册表统一清理（跨实例）
    aimTimer = nil
    configTimer = nil
    
    INITED = false
end

return C

