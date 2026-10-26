--[[
    GoldTargetTracker（金币攒钱计划）v2.2.0-rc10
    魔兽世界正式服（至暗之夜 12.x，国服）金币目标追踪插件
    功能：
      1. 可视化面板：当前金币 / 战团银行金币 / 总金币 / 进度条 / 各角色金币列表
      2. 目标值可设定：总目标默认 500 万金（EditBox 回车保存）
      3. 金币数据检测（核心）：
         - 当前角色金币：GetMoney() 铜币转金（含背包+身上）
         - 战团银行金币：pcall 安全调用 C_Bank.FetchDepositedMoney(Enum.BankType.Account)
           ，取铜币转金；API 不可用时显示 0 并标注不支持
         - 总金币（全账号口径）= 当前角色实时金币 + 其他角色最近登录快照金币 + 战团银行金币
         - 多角色统计：DB.roles[realm][角色] 保存每个角色最近登录时的金币快照与日期
      4. 收益统计以首次金币快照 DB.firstTotal 为基准（无初始金额概念）
         - 全账号口径：切换角色时总资产保持稳定，今日收益/今日时均/预计完成/最近 7 天不跳变
         - 一次性迁移 DB.accountBase：重算首次基准并校准昨日记录，之后收益统计从全账号新基准重新累计
      5. 每小时收益统计与预计完成反推：
         - DB.hourly[日期+小时] = 总金币，跨小时记录一次（保留最近 24 条）
         - 每小时收益 = 当前小时总金币 - 上一有记录小时总金币
         - 时均收益 = 最近 24 小时内相邻快照差值的平均
         - 预计完成：还需赚 = 目标 - 总金币；预计小时数 = 还需赚 / 时均收益
           （时均 > 0 时），换算为 X 个月 Y 天 Z 小时 + 预计完成日期（30 天/月、24 小时/天）
         - 界面已移除「累计收益 / 时均收益 / 还需赚」三个统计显示，仅保留今日收益、今日时均、预计还需、预计完成
      6. /gtt 或 /goldtracker 开关面板，面板可拖动、可关闭、记忆位置
      7. 每日自动记账（DB.records[日期] = 该日最后观测到的总金币，随采集持续更新）
      8. 角色资产列表隐藏 0 金角色；设置页展示连续 7 天双线趋势图（总金币/每日收益）
      9. 设置页四分类、战斗中隐藏、金币目标达成提示与自动使用待处理队列
    纯 Lua 实现 UI，不依赖 XML。
--]]

local addonName, addon = ...
local Income = addon.Income

-- TOC 已声明 ## SavedVariables: GoldTargetTrackerData, GoldTargetTrackerBackup
-- GoldTargetTrackerData 为主存档（新文件名，规避旧变量文件加载异常）
-- 两个变量保存在同一插件存档文件；Backup 是独立表快照，不是独立磁盘备份。
-- 注意：存档全局变量在插件文件执行完毕后才注入，这里的 DB 只是执行期快照（通常为 nil），
-- InitDB 必须以当时的主存档全局为准重新绑定。
local DB = GoldTargetTrackerData
local dataReady = false
local playerLoggedIn = false -- 存档已加载不代表玩家余额已就绪；后台采集须等待 PLAYER_LOGIN。

-- ============ 常量与初始化 ============
local DEFAULT_TARGET  = 5000000    -- 默认总目标（金）
local SECONDS_PER_HOUR = 3600      -- 一小时的秒数
local SECONDS_PER_DAY = 86400      -- 一天的秒数
local DAYS_PER_MONTH  = 30         -- 按 30 天/月估算
local HOURS_PER_DAY   = 24         -- 24 小时/天
local MAX_HOURLY      = 24         -- 小时记录保留条数
local MAX_ROLE_ROWS   = 5          -- 旧主面板占位列表保留 5 行

-- 统计已记录的角色快照数量
local function CountRoles(roles)
    local n = 0
    if type(roles) == "table" then
        for _, tbl in pairs(roles) do
            for _ in pairs(tbl) do n = n + 1 end
        end
    end
    return n
end

-- 完整复制数据，避免主表原地修改同时改动备份。
local function CopyData(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do copy[CopyData(k, seen)] = CopyData(v, seen) end
    return copy
end

local function ValidData(data)
    if type(data) ~= "table" then return false end
    local function number(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end
    local function position(value)
        return value == nil or (type(value) == "table"
            and (value.point == nil or type(value.point) == "string")
            and (value.x == nil or number(value.x)) and (value.y == nil or number(value.y)))
    end
    for _, key in ipairs({"records", "hourly", "roles", "pos", "autoUseItems", "todayBase"}) do
        if data[key] ~= nil and type(data[key]) ~= "table" then return false end
    end
    for _, key in ipairs({"records", "hourly"}) do
        for k, v in pairs(data[key] or {}) do
            if type(k) ~= "string" or not number(v) then return false end
        end
    end
    for realm, roles in pairs(data.roles or {}) do
        if type(realm) ~= "string" or type(roles) ~= "table" then return false end
        for name, info in pairs(roles) do
            if type(name) ~= "string" or type(info) ~= "table" then return false end
            for _, key in ipairs({"gold", "bank", "total"}) do
                if info[key] ~= nil and not number(info[key]) then return false end
            end
            if not position(info.pos) or (info.date ~= nil and type(info.date) ~= "string") then return false end
        end
    end
    if not position(data.pos) then return false end
    for _, value in pairs(data.autoUseItems or {}) do
        if type(value) ~= "string" then return false end
    end
    for _, key in ipairs({"firstTotal", "target", "minimapAngle"}) do
        if data[key] ~= nil and not number(data[key]) then return false end
    end
    if data.autoUseEnabled ~= nil and type(data.autoUseEnabled) ~= "boolean" then return false end
    if data.hidePanelInCombat ~= nil and type(data.hidePanelInCombat) ~= "boolean" then return false end
    if data.lockPanel ~= nil and type(data.lockPanel) ~= "boolean" then return false end
    if data.showMinimapIcon ~= nil and type(data.showMinimapIcon) ~= "boolean" then return false end
    if data.autoUseQueuePendingReload ~= nil and type(data.autoUseQueuePendingReload) ~= "boolean" then return false end
    if data.autoUseQueue ~= nil then
        if type(data.autoUseQueue) ~= "table" then return false end
        for _, task in ipairs(data.autoUseQueue) do
            if type(task) ~= "table" or not number(task.itemID) or task.itemID < 1
                or not number(task.count) or task.count < 0
                or (task.name ~= nil and type(task.name) ~= "string")
                or (task.attempts ~= nil and (not number(task.attempts) or task.attempts < 0))
                or (task.inFlight ~= nil and type(task.inFlight) ~= "boolean")
                or (task.beforeCount ~= nil and (not number(task.beforeCount) or task.beforeCount < 0)) then
                return false
            end
        end
    end
    if data.accountBase ~= nil and type(data.accountBase) ~= "boolean" then return false end
    if data.todayBase and (type(data.todayBase.day) ~= "string" or not number(data.todayBase.gold)) then return false end
    return Income.Valid(data.incomeSources)
end

-- 是否存在实质资产/历史数据：角色快照、每日记录、小时记录任一非空，或已写入首次基准。
-- 仅含设置/默认字段（target/name/pos/autoUseItems 等）的表不算实质数据。
local function HasSubstanceData(data)
    if type(data) ~= "table" then return false end
    if data.incomeSources and Income.Valid(data.incomeSources) and Income.Total(data.incomeSources) > 0 then return true end
    if CountRoles(data.roles) > 0 then return true end
    if type(data.records) == "table" and next(data.records) ~= nil then return true end
    if type(data.hourly) == "table" and next(data.hourly) ~= nil then return true end
    return type(data.firstTotal) == "number"
end

local function SyncBackup()
    if not ValidData(DB) then error("GoldTargetTracker: invalid data; backup preserved") end
    -- A complete independent table snapshot; still serialized in the same addon file.
    GoldTargetTrackerBackup = CopyData(DB)
end

-- 初始化保存变量结构（兼容首次加载 / 变量损坏）
local function InitDB()
    -- 存档全局变量在本文件执行完毕后才注入：文件顶层捕获的 DB 可能仍是 nil 或旧表。
    -- 进入初始化时必须重新绑定当前全局主存档，否则会把已加载的主存档误判为缺失，
    -- 转而恢复旧备份或初始化为空数据。
    DB = GoldTargetTrackerData
    local mainValid = ValidData(DB)
    -- 歧义冲突：主存档结构合法但没有任何资产/历史数据（空表或仅设置字段），而恢复快照结构合法
    -- 且仍有历史数据。此时继续初始化会用空主表覆盖更完整的快照（SyncBackup），属于静默丢数据。
    -- 两侧都可能承载用户真实数据，插件不自动选择赢家：保持两个全局原样（含嵌套内容）并暂停。
    if mainValid and not HasSubstanceData(DB)
        and ValidData(GoldTargetTrackerBackup) and HasSubstanceData(GoldTargetTrackerBackup) then
        print("|cffff4040[GoldTargetTracker]|r 存档冲突：主存档无任何历史数据（无角色快照、每日记录、小时记录与首次基准），"
            .. "恢复快照中仍有历史数据。为避免自动覆盖，两套数据均已原样保留、插件已暂停；请手动确认使用哪一份后再恢复。")
        return false
    end
    -- 结构损坏的主存档 + 空备份 {} 不构成有效恢复：继续恢复会用 {} 覆盖主存档，同样属于静默丢数据。
    if DB ~= nil and not mainValid and ValidData(GoldTargetTrackerBackup) and next(GoldTargetTrackerBackup) == nil then
        print("|cffff4040[GoldTargetTracker]|r 存档异常：主存档结构损坏，而恢复快照为空，无法用于恢复。"
            .. "为避免用空数据覆盖，两套数据均已原样保留、插件已暂停；请手动从独立备份恢复。")
        return false
    end
    if not mainValid then
        if (DB ~= nil or GoldTargetTrackerBackup ~= nil) and not ValidData(GoldTargetTrackerBackup) then
            print("|cffff4040[GoldTargetTracker]|r 存档结构异常且无有效恢复快照，插件已暂停；未覆盖原数据。请使用独立备份恢复。")
            return false
        end
        DB = type(GoldTargetTrackerBackup) == "table" and CopyData(GoldTargetTrackerBackup) or {}
        GoldTargetTrackerData = DB
        -- 主存档加载失败时，从备份变量完整恢复历史数据（角色快照/首次基准/每日记录/小时记录/迁移标记）
        -- 注意：必须连同 firstTotal/records/hourly/accountBase 一起恢复，只恢复 roles 会导致
        -- 重复迁移把统计基准写坏，切换角色后今日收益/累计收益/时均等字段归零
        if type(GoldTargetTrackerBackup) == "table" then
            local restored = {}
            if type(GoldTargetTrackerBackup.roles) == "table" then
                DB.roles = CopyData(GoldTargetTrackerBackup.roles)
                restored[#restored + 1] = CountRoles(DB.roles) .. " 个角色快照"
            end
            if type(GoldTargetTrackerBackup.firstTotal) == "number" then
                DB.firstTotal = GoldTargetTrackerBackup.firstTotal
                restored[#restored + 1] = "首次基准"
            end
            if type(GoldTargetTrackerBackup.records) == "table" then
                DB.records = CopyData(GoldTargetTrackerBackup.records)
                restored[#restored + 1] = "每日记录"
            end
            if type(GoldTargetTrackerBackup.hourly) == "table" then
                DB.hourly = CopyData(GoldTargetTrackerBackup.hourly)
                restored[#restored + 1] = "小时记录"
            end
            if GoldTargetTrackerBackup.accountBase ~= nil then
                DB.accountBase = GoldTargetTrackerBackup.accountBase
            end
            if type(GoldTargetTrackerBackup.pos) == "table" then
                DB.pos = CopyData(GoldTargetTrackerBackup.pos)
            end
            if type(GoldTargetTrackerBackup.target) == "number" and GoldTargetTrackerBackup.target > 0 then
                DB.target = GoldTargetTrackerBackup.target
            end
            if type(GoldTargetTrackerBackup.autoUseItems) == "table" then
                DB.autoUseItems = CopyData(GoldTargetTrackerBackup.autoUseItems)
            end
            if #restored > 0 then
                print("|cff4da6ff[GoldTargetTracker]|r 主存档未加载，已从备份恢复：" .. table.concat(restored, "、"))
            else
                print("|cff4da6ff[GoldTargetTracker]|r 未读取到历史存档（首次使用或存档加载异常），将从本次登录开始记录")
            end
        else
            print("|cff4da6ff[GoldTargetTracker]|r 未读取到历史存档（首次使用或存档加载异常），将从本次登录开始记录")
        end
    end
    -- 兼容旧存档/损坏数据：类型不合法时重建字段
    DB.target  = (type(DB.target) == "number" and DB.target > 0) and DB.target or DEFAULT_TARGET
    DB.name    = (type(DB.name) == "string" and DB.name ~= "") and DB.name or "金币攒钱计划"
    DB.records = (type(DB.records) == "table") and DB.records or {}
    DB.hourly  = (type(DB.hourly) == "table") and DB.hourly or {}
    DB.roles   = (type(DB.roles) == "table") and DB.roles or {}
    DB.pos     = (type(DB.pos) == "table") and DB.pos or {}
    DB.autoUseItems = (type(DB.autoUseItems) == "table") and DB.autoUseItems or {}
    DB.autoUseQueue = (type(DB.autoUseQueue) == "table") and DB.autoUseQueue or {}
    -- 战斗隐藏默认开启；旧存档缺字段时补默认值，不覆盖玩家已有选择。
    if DB.hidePanelInCombat == nil then DB.hidePanelInCombat = true end
    if DB.lockPanel == nil then DB.lockPanel = false end
    if DB.showMinimapIcon == nil then DB.showMinimapIcon = true end
    DB.incomeSources = DB.incomeSources or Income.NewData()
    -- 加载诊断：聊天框输出当前读取到的历史角色快照数量
    print("|cff4da6ff[GoldTargetTracker]|r 存档加载完成，当前历史角色快照 " .. CountRoles(DB.roles) .. " 个")
    SyncBackup()
    dataReady = true
    return true
end

-- ============ 数据计算 ============
-- 铜币 -> 金币（向下取整）
local function CopperToGold(copper)
    return math.floor(copper / 10000)
end

-- 当前角色金币（金，GetMoney 已含背包+身上金币）
local function GetGold()
    return CopperToGold(GetMoney())
end

-- 战团银行历史兜底值：实时 API 返回 0 / 不可用时，从角色快照中选择最近一次可信银行值。
-- 可用历史值 = 正数快照，或 bankOk=true 的已确认零。旧存档里没有就绪证据的零（bank=0 且 bankOk≠true）
-- 不能证明"已经清零"，因此不得用它抹掉已知正数兜底。
-- 按时间取新，同一分钟并列时保守选择可信零。未知读数写快照时必须继承这里选出的
-- 全账号最新历史值，不能仅沿用当前角色的旧值再盖上新时间。
local function GetSharedBankFallback()
    local bestBank, bestDate, bestIsZero = nil, nil, false
    if type(DB.roles) == "table" then
        for _, roles in pairs(DB.roles) do
            if type(roles) == "table" then
                for _, info in pairs(roles) do
                    if type(info) == "table" and type(info.bank) == "number" and info.bank >= 0 then
                        local isZero = (info.bankOk == true and info.bank == 0)
                        if isZero or info.bank > 0 then
                            local d = type(info.date) == "string" and info.date or ""
                            local take = (bestBank == nil)
                                or (d > bestDate)
                                or (d == bestDate and isZero and not bestIsZero)
                            if take then
                                bestBank, bestDate, bestIsZero = info.bank, d, isZero
                            end
                        end
                    end
                end
            end
        end
    end
    return bestBank
end

-- 战团银行就绪判断：仅当 C_Bank.CanViewBank(Account) 安全返回 true 才算可查看；
-- API 缺失、抛错或返回非 true 均视为未知。pcall 成功本身不能证明已就绪。
local function IsBankViewReady()
    if not (C_Bank and type(C_Bank.CanViewBank) == "function" and Enum and Enum.BankType) then
        return false
    end
    local ok, canView = pcall(C_Bank.CanViewBank, Enum.BankType.Account)
    return ok and canView == true
end

-- 战团银行金币（铜币 -> 金）；返回 bankGold, bankOk, fromFallback
-- bankOk=true 表示得到可信实时值（正数，或银行界面可查看时确认的 0）；
-- fromFallback=true 表示返回的是历史快照兜底值（用于面板标注）
-- 12.x 官方 API：C_Bank.FetchDepositedMoney(Enum.BankType.Account) 返回战团银行铜币
local function GetWarbandBankGold(useFallback)
    -- 兜底出口：API 不可用或实时值不明确时，若 useFallback 且历史有可信值则使用
    local function tryFallback()
        if useFallback then
            local fb = GetSharedBankFallback()
            if fb then return fb, false, true end
        end
        return 0, false, false
    end
    -- 首选：官方战团银行 API（12.x 有效，返回铜币）
    if C_Bank and type(C_Bank.FetchDepositedMoney) == "function" and Enum and Enum.BankType then
        local ok, copper = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
        if ok and type(copper) == "number" then
            if copper > 0 and copper < math.huge then
                return CopperToGold(copper), true, false
            end
            -- 实时返回 0：只有银行界面可查看时才视为"已确认清零"；
            -- 未就绪的 0 仍是未知状态，保留历史兜底，不能当成可信零。
            if copper == 0 and IsBankViewReady() then
                return 0, true, false
            end
            return tryFallback()
        end
    end
    -- 兜底：旧 C_CurrencyInfo API（部分版本可用；此处没有就绪契约，0 仍按未知处理）
    if C_CurrencyInfo and type(C_CurrencyInfo.GetWarbandBankCurrencyInfo) == "function" then
        local ok, info = pcall(C_CurrencyInfo.GetWarbandBankCurrencyInfo, 0)
        if ok and type(info) == "table" and type(info.quantity) == "number" then
            if info.quantity > 0 and info.quantity < math.huge then
                return CopperToGold(info.quantity), true, false
            end
            return tryFallback()
        end
    end
    return tryFallback()
end

-- 全账号总金币 = 当前角色实时金币 + 战团银行 + 其他角色最近登录快照金币（身上部分）
-- 战团银行共享，只计一次；切换角色时"当前角色实时 ↔ 其他角色快照"互换，总值保持稳定，
-- 因此今日收益/时均/累计/还需赚/预计完成/最近 7 天等统计不随角色切换跳变
local function GetAccountTotalGold()
    local myRealm = GetRealmName()
    local myName = UnitName("player")
    -- 玩家单位未就绪（ADDON_LOADED 早期）时退化为旧口径：仅当前角色 + 银行
    if not myName or myName == "" then
        local bank, _ = GetWarbandBankGold(true)
        return GetGold() + bank
    end
    local total = GetGold()
    if type(DB.roles) == "table" then
        for realm, roles in pairs(DB.roles) do
            if type(roles) == "table" then
                for name, info in pairs(roles) do
                    -- 当前角色用实时值，其余角色取最近登录快照；跳过 0 金币与无效快照
                    if type(info) == "table" and not (name == myName and realm == myRealm) then
                        local g = info.gold
                        if type(g) == "number" and g > 0 then
                            total = total + g
                        end
                    end
                end
            end
        end
    end
    local bank, _ = GetWarbandBankGold(true)
    return total + bank
end

-- 总金币（全账号口径）= 当前角色实时金币 + 战团银行 + 其他角色最近登录快照金币
-- 读取实时值；实时返回 0 / API 不可用且历史有共享非 0 值时使用兜底，避免落库 0 值
local function GetTotalGold()
    return GetAccountTotalGold()
end

-- ============ 收益基准与每日记账（无初始金额概念） ============
-- 一次性迁移：统计口径从旧版「当前角色 + 战团银行」升级为「全账号（所有角色快照 + 战团银行）」
-- 效果：切换角色时总资产保持稳定，今日收益/今日时均/累计收益/时均收益/还需赚/预计还需/预计完成/最近 7 天不再跳变或互相覆盖
-- 迁移动作：① 重算首次基准（累计收益从全账号新基准重新累计）；② 校准历史最后一条每日记录为近似昨日全账号值，避免今日收益虚高
local function MigrateAccountBase()
    if DB.accountBase then return end
    local accTotal = GetAccountTotalGold()
    -- 旧口径（迁移前）总资产：当前角色 + 战团银行；迁移增量 = 原未计入的其他角色快照金币之和
    local oldTotal = GetGold() + select(1, GetWarbandBankGold(true))
    local delta = accTotal - oldTotal
    -- 重算首次基准
    DB.firstTotal = accTotal
    -- 校准历史最后一条每日记录（昨天），近似"昨天全账号值"
    local keys = {}
    for day in pairs(DB.records) do table.insert(keys, day) end
    table.sort(keys)
    if #keys > 0 then
        local lastDay = keys[#keys]
        DB.records[lastDay] = (DB.records[lastDay] or 0) + delta
        -- 同日保留的小时观测也加同一增量：DailyRecord 会用该日最后一条小时观测校正日记录，
        -- 若小时仍是旧口径，刚校准的日记录会被改回旧值，凭空产生今日收益。
        -- 仅调整这一已校准日期，不改更早日期、不加新字段，迁移仍然是一次性近似值。
        if delta ~= 0 and type(DB.hourly) == "table" then
            for key, value in pairs(DB.hourly) do
                if type(key) == "string" and key:sub(1, 10) == lastDay and type(value) == "number" then
                    DB.hourly[key] = value + delta
                end
            end
        end
    end
    DB.accountBase = true
    SyncBackup()
end

-- 首次金币快照：首次登录/记录时保存总金币，作为累计收益与无上一记录时的对比基准
local function EnsureFirstTotal()
    if not DB.firstTotal then
        DB.firstTotal = GetTotalGold()
    end
end

-- 获取某日期之前最近的已记账日期及其金币（用于计算今日收益的基准）
local function GetPrevRecord(beforeDay)
    local prevDay, prevGold = nil, nil
    for day, gold in pairs(DB.records) do
        if day < beforeDay and (prevDay == nil or day > prevDay) then
            prevDay, prevGold = day, gold
        end
    end
    return prevDay, prevGold
end

-- 每日记账：records[day] = 该日最后一次观测到的全账号总金币（持续更新，不是登录时的首帧快照）。
-- 之前只在当天首次写入，记录会冻结在开盘值；现改为每次采集都覆盖为最新值，重复调用只重写同一快照，不做累加。
-- 覆盖今日之前，先校正"上一实际记录日"（取已记录的最新日期，不限于日历昨天）：
-- 若该日存在同一天的小时观测，则以当天最后一条小时记录为准，收益与消费两个方向都校正，
-- 隔日未上线时也能把上一段收益留在它自己的日期里；没有同日观测的历史记录保持原值，
-- 不臆测、不改写更早的日期。
local function DailyRecord()
    local today = date("%Y-%m-%d")
    local prevDay = GetPrevRecord(today)
    if prevDay and type(DB.records[prevDay]) == "number" then
        local lastHourKey, lastGold = nil, nil
        for k, v in pairs(DB.hourly) do
            if k:sub(1, 10) == prevDay and type(v) == "number" then
                if lastHourKey == nil or k > lastHourKey then
                    lastHourKey, lastGold = k, v
                end
            end
        end
        -- 校正后与观测一致，后续轮询自然空操作（幂等）
        if lastGold and lastGold ~= DB.records[prevDay] then
            DB.records[prevDay] = lastGold
            SyncBackup()
        end
    end
    DB.records[today] = GetTotalGold()
end

-- 今日收益 = 当前实时总金币 - 上一记录日总金币（无上一记录则对比首次金币快照）
-- 注意：必须用实时总金币计算；DB.records[today] 只是当天最后一次观测的日结快照，
-- 若用它会导致赚钱后“今日收益/今日时均”不刷新
local function GetTodayGain()
    local today = date("%Y-%m-%d")
    local todayGold = GetTotalGold()
    -- 重置统计/重置所有会设置"今日收益基准"（重置时刻总金币）：
    -- 重置当天今日收益从重置点重新累计为 0，跨天/换日自动失效回到原口径
    if type(DB.todayBase) == "table" and DB.todayBase.day == today and type(DB.todayBase.gold) == "number" then
        return todayGold - DB.todayBase.gold
    end
    local _, prevGold = GetPrevRecord(today)
    return todayGold - (prevGold or DB.firstTotal or todayGold)
end

-- 今日时均 = 今日收益 / 今日在线小时数
-- 已过小时数优先按“今日第一条小时记录时刻 → 当前小时”跨度计算，更贴近实际游玩时长；
-- 无小时记录时退回 0 点起算
local function GetTodayHourlyAvg()
    local gain = GetTodayGain()
    if not gain or gain <= 0 then return nil end
    local todayPrefix = date("%Y-%m-%d")
    local firstHour = nil
    for k in pairs(DB.hourly) do
        if k:sub(1, 10) == todayPrefix then
            local h = tonumber(k:sub(12, 13))
            if h and (firstHour == nil or h < firstHour) then
                firstHour = h
            end
        end
    end
    local hourOfDay = tonumber(date("%H")) or 0
    local hours = firstHour and (hourOfDay - firstHour + 1) or (hourOfDay + 1)
    if hours > 0 then
        return gain / hours
    end
    return nil
end

-- 今日在线秒数：从今日第一条小时记录所在小时起点 → 当前时刻的秒数；
-- 无小时记录时退回今日 0 点起算。用于预计完成随现实时间递增的实时秒级时均
local function GetTodayOnlineSeconds()
    local now = time()
    local todayPrefix = date("%Y-%m-%d")
    local firstHour = nil
    for k in pairs(DB.hourly) do
        if k:sub(1, 10) == todayPrefix then
            local h = tonumber(k:sub(12, 13))
            if h and (firstHour == nil or h < firstHour) then
                firstHour = h
            end
        end
    end
    local y = tonumber(todayPrefix:sub(1, 4))
    local mo = tonumber(todayPrefix:sub(6, 7))
    local d = tonumber(todayPrefix:sub(9, 10))
    local start = time({ year = y, month = mo, day = d, hour = firstHour or 0, min = 0, sec = 0 })
    return math.max(0, now - start)
end

-- 已记账天数（记录条数）
local function GetRecordedDays()
    local n = 0
    for _ in pairs(DB.records) do n = n + 1 end
    return n
end

-- ============ 小时记账（核心新功能） ============
-- 每小时金币快照：DB.hourly[日期+小时] = 总金币
-- 每次刷新覆盖写当前小时键为实时值（赚钱后立即反映），跨小时自然新增下一小时键
local function HourlyRecord()
    local hourKey = date("%Y-%m-%d %H")
    DB.hourly[hourKey] = GetTotalGold()
    -- 仅保留最近 MAX_HOURLY 条
    local keys = {}
    for k in pairs(DB.hourly) do table.insert(keys, k) end
    table.sort(keys)
    while #keys > MAX_HOURLY do
        DB.hourly[keys[1]] = nil
        table.remove(keys, 1)
    end
end

-- 小时记录 key 列表（升序）
local function GetHourlyKeys()
    local keys = {}
    for k in pairs(DB.hourly) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

-- ============ 多角色统计（核心新功能） ============
-- 保存当前角色最近一次登录的金币快照：DB.roles[realm][character]
local function UpdateRoleSnapshot()
    local name = UnitName("player")
    local realm = GetRealmName()
    if not name or not realm or name == "" then return end
    DB.roles = DB.roles or {}
    DB.roles[realm] = DB.roles[realm] or {}
    local bankGold, bankOk = GetWarbandBankGold()
    -- 角色 date 始终是本次快照时间：它表示该角色资产快照/最近更新时间，不是银行观测时间，
    -- 因此银行读数未知时也不能冻结，否则角色列表排序与"最近更新"会停在旧时间。
    local snapDate = date("%Y-%m-%d %H:%M")
    local prev = DB.roles[realm][name]
    -- 银行未知时继承全账号最新可用历史值，避免当前角色的旧正数或旧零借新时间覆盖更新记录。
    -- 历史正数不宣称实时就绪；历史零仅在已有确认依据时保留标记，防止被当作未知零丢弃。
    -- 已确认的正数/零（bankOk=true）照常覆盖旧快照，包括用可信零覆盖旧的正数。
    if not bankOk then
        local historical = GetSharedBankFallback()
        if historical ~= nil then
            bankGold = historical
            bankOk = (historical == 0)
        end
    end
    local gold = GetGold()
    DB.roles[realm][name] = {
        gold   = gold,                  -- 当前角色金币
        bank   = bankGold,              -- 战团银行金币
        bankOk = bankOk,                -- 战团银行读数是否可信（含确认零）
        total  = gold + bankGold,       -- 总金币
        date   = snapDate,
        pos    = prev and prev.pos,     -- 保留该角色手动拖动的个人位置
    }
    SyncBackup()
end

-- 各角色金币列表：跨服合并所有已记录角色 + 战团银行
-- 角色名在显示时若与当前服务器不同则追加服务器名后缀
local function GetRoleRows()
    local rows = {}
    local myRealm = GetRealmName()
    local myName = UnitName("player")
    local list = {}
    -- 遍历所有服务器分组，避免跨服角色被遗漏
    if type(DB.roles) == "table" then
        for realm, roles in pairs(DB.roles) do
            if type(roles) == "table" then
                for name, info in pairs(roles) do
                    list[#list + 1] = { name = name, realm = realm, info = info, isMe = (name == myName and realm == myRealm) }
                end
            end
        end
    end
    -- 本角色置顶，其余按最近记录时间倒序（日期越新越靠前）
    table.sort(list, function(a, b)
        if a.isMe ~= b.isMe then return a.isMe end
        local da, db_ = a.info.date or "", b.info.date or ""
        if da ~= db_ then return da > db_ end
        return (a.realm or "") < (b.realm or "")
    end)
    local myGold = GetGold()
    local myTotal = GetTotalGold()
    local bankGold, bankOk, bankFallback = GetWarbandBankGold(true)
    local shown = 0
    for _, item in ipairs(list) do
        if shown >= MAX_ROLE_ROWS then break end
        -- 过滤：非当前角色且金币为 0（或缺失）的角色行不显示；当前角色无论多少始终显示
        if not item.isMe and (item.info.gold or 0) <= 0 then
            -- 跳过，不占显示行数，也不计入上限
        else
            local displayName = item.name
            if item.realm and item.realm ~= myRealm then
                displayName = item.name .. "（" .. item.realm .. "）"
            end
            if item.isMe then
                rows[#rows + 1] = { name = displayName, gold = myGold, total = myTotal, date = "现在" }
            else
                rows[#rows + 1] = { name = displayName, gold = item.info.gold or 0, total = item.info.total or 0, date = item.info.date or "未记录" }
            end
            shown = shown + 1
        end
    end
    rows[#rows + 1] = { name = "战团银行", gold = bankGold, total = bankGold, date = bankOk and "" or (bankFallback and "历史快照" or "API不支持") }
    return rows
end

-- 设置页角色资产列表：当前角色优先，其余角色按金币降序；隐藏所有 0 金角色。
-- 只返回角色资产，不把共享战团银行混入角色列表（银行已在账号总金币中只计一次）。
local function GetAllRoleRows()
    local rows = {}
    local myRealm, myName = GetRealmName(), UnitName("player")
    local myGold = GetGold()
    if myName and myName ~= "" and myRealm and myGold > 0 then
        rows[#rows + 1] = { name = myName, gold = myGold, isMe = true, realm = myRealm }
    end
    if type(DB.roles) == "table" then
        for realm, roles in pairs(DB.roles) do
            if type(roles) == "table" then
                for name, info in pairs(roles) do
                    local isMe = name == myName and realm == myRealm
                    local gold = type(info) == "table" and tonumber(info.gold) or 0
                    if not isMe and gold and gold > 0 then
                        local displayName = name
                        if realm ~= myRealm then displayName = name .. "（" .. realm .. "）" end
                        rows[#rows + 1] = { name = displayName, gold = gold, isMe = false, realm = realm }
                    end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.isMe ~= b.isMe then return a.isMe end
        if a.gold ~= b.gold then return a.gold > b.gold end
        if a.realm ~= b.realm then return (a.realm or "") < (b.realm or "") end
        return a.name < b.name
    end)
    return rows
end

-- ============ 格式化 ============
-- 天数 -> 「X 个月 Y 天」（30 天/月，预计还需按天显示）
local function FormatMonthsDays(days)
    if days == nil then return "暂无数据" end
    local m = math.floor(days / DAYS_PER_MONTH)
    local d = days % DAYS_PER_MONTH
    return m .. " 个月 " .. d .. " 天"
end

-- 预计完成倒计时：按剩余秒数格式化为 X 个月 X 天 X 小时 X 分（分钟粒度，随现实时间递增）
-- 月/天/小时为 0 时对应单位隐藏，月与天都为 0 时只显示"X 小时 X 分"
local function FormatCountdown(seconds)
    if seconds == nil or seconds < 0 then return "暂无数据" end
    local totalMinutes = math.max(0, math.floor(seconds / 60))
    local m = math.floor(totalMinutes / (DAYS_PER_MONTH * HOURS_PER_DAY * 60))
    local rem = totalMinutes % (DAYS_PER_MONTH * HOURS_PER_DAY * 60)
    local d = math.floor(rem / (HOURS_PER_DAY * 60))
    local h = math.floor((rem % (HOURS_PER_DAY * 60)) / 60)
    local min = rem % 60
    local parts = {}
    if m > 0 then table.insert(parts, m .. " 个月") end
    if d > 0 then table.insert(parts, d .. " 天") end
    if h > 0 then table.insert(parts, h .. " 小时") end
    table.insert(parts, min .. " 分")
    return table.concat(parts, " ")
end

-- 千分位格式化（1,234,567；负数符号保留在最前）
local function FormatNumber(v)
    local sign = ""
    if v < 0 then
        sign = "-"
        v = -v
    end
    local s = tostring(v)
    local result = ""
    while true do
        local head, tail = s:match("^(.-)(%d%d%d)$")
        if not tail or head == "" then
            result = s .. result
            break
        end
        result = "," .. tail .. result
        s = head
    end
    return sign .. result
end

-- 带正负号的金币文本（用于收益）
local function FormatProgress(total, target)
    if target <= 0 then return "0.00%" end
    local hundredths = math.floor(math.max(0, total) * 10000 / target)
    -- 未达标时不能因浮点精度或显示取整而提前显示 100%。
    if total < target then hundredths = math.min(hundredths, 9999) end
    return string.format("%.2f%%", hundredths / 100)
end

local function FormatGain(v)
    if v >= 0 then
        return "|cff00ff00+" .. FormatNumber(v) .. "|r"
    else
        return "|cffff4040" .. FormatNumber(v) .. "|r"
    end
end

-- 万单位格式化：>=1万 显示 X万 / X.X万，小于1万显示原整数（用于主界面简洁显示）
local function FormatWan(v)
    v = v or 0
    if v >= 10000 then
        local wan = v / 10000
        if math.floor(wan) == wan then
            return string.format("%d万", wan)
        end
        return string.format("%.1f万", wan)
    end
    return tostring(math.floor(v))
end

-- 万单位格式化（保留2位小数）：>=1万 显示 X.XX万，小于1万显示原整数（用于当前金币数值）
local function FormatWan2(v)
    v = v or 0
    if v >= 10000 then
        return string.format("%.2f万", v / 10000)
    end
    return tostring(math.floor(v))
end

-- ============ 面板控件（纯 Lua 创建） ============
local panel            -- 主面板（外层 frame：拖动/记忆位置/背景/关闭按钮）
local contentInstances = {}  -- 主面板内容实例；设置页使用独立的刷新入口
local elapsed = 0      -- 定时刷新累计计时（秒），供小时跨点检测
local RefreshPanel     -- 前向声明：刷新入口
local settingsPanel    -- 设置面板（Esc→选项→插件）
local settingsCategory -- 新版设置分类引用，用于同步插件名称
local SelectSettingsPage
local combatCheckbox
local minimapButton
local RefreshGoldTargetDashboard -- 设置页金币目标数据刷新
local CheckAchievementCrossing -- 账号总金币跨线检测
local ResetAchievementBaseline -- 修改目标时重置跨线基准
local CreateAchievementToast -- 成就式金币达标提示
local StartAchievement
local ProcessAutoUseQueue
local ScheduleAutoUseQueue
local reloadHookInstalled = false
local panelWasVisibleBeforeCombat = false
local panelHiddenByCombat = false
local pendingAchievement
local achievementToast
local achievementInProgress = false
local queuedAchievement
local lastObservedTotal, lastObservedTarget
local isReloading = false


-- 设置页使用四分类；主面板继续使用以下 V2 Mini 内容。
-- 创建主界面内容（V2 XP 条版，仅供主面板 /gtt 使用）
-- 扁平化 XP 条样式：透明背景（无面板底色/无渐变/无高光/无辉光）、纯色扁平进度条为主体、
-- 亮黄色百分比、当前金币/目标金币数值、时均收益一行；
-- 其余区块以隐藏占位控件补齐（字段名与完整版一致），RefreshPanel 兼容无需大改
local function CreatePanelContentV2Mini(containerFrame)
    -- 隐藏占位 FontString 工厂（兼容 RefreshPanel 字段访问）
    local function MakeHiddenText(parent)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        fs:SetFont("Fonts\\ARIALN.TTF", 12)
        fs:SetText("")
        fs:Hide()
        return fs
    end

    -- 扁平化 XP 条：无背景纹理、无渐变、无高光、无辉光（背景透明由外层面板保证）
    -- 纯色扁平进度条（WHITE8x8 纯色填充，无渐变光影）
    local progress = CreateFrame("StatusBar", nil, containerFrame, "BackdropTemplate")
    progress:EnableMouse(false)
    progress:SetSize(450, 10)
    progress:SetPoint("TOP", containerFrame, "TOP", 0, -10)
    progress:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    progress:SetStatusBarColor(0.42, 0.32, 0.9, 1)
    progress:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
        insets = { left = 2, right = 2, top = 0, bottom = 0 },
    })
    progress:SetBackdropColor(0, 0, 0, 0.45)
    progress:SetBackdropBorderColor(0, 0, 0, 0)

    -- 条内右侧：亮黄色百分比（扁平实色 + 细描边，无辉光层）
    local progressText = progress:CreateFontString(nil, "OVERLAY")
    progressText:SetFont("Fonts\\ARIALN.TTF", 15, "OUTLINE")
    progressText:SetTextColor(1, 0.88, 0.2)
    progressText:SetPoint("RIGHT", progress, "BOTTOMRIGHT", -5, -20)
    progressText:SetText("0.00%")

    -- 条内居中：当前金币 / 目标金币数值（万单位，扁平实色）
    local txtGoldMini = progress:CreateFontString(nil, "OVERLAY")
    txtGoldMini:SetFont("Fonts\\ARIALN.TTF", 15, "OUTLINE")
    txtGoldMini:SetPoint("CENTER", progress, "CENTER", 0, 6)
    txtGoldMini:SetJustifyH("CENTER")
    txtGoldMini:SetTextColor(1, 1, 1)

    -- 辅助行：预计还需（根据今日实时在线秒数推算，位于进度条左下方，离进度条20像素）
    local labAvgHour = containerFrame:CreateFontString(nil, "OVERLAY")
    labAvgHour:SetFont("Fonts\\ARIALN.TTF", 15)
    labAvgHour:SetTextColor(1, 1, 1)
    labAvgHour:SetPoint("LEFT", progress, "BOTTOMLEFT", 5, -20)
    labAvgHour:SetText("预计还需：")
    local txtAvgHour = containerFrame:CreateFontString(nil, "OVERLAY")
    txtAvgHour:SetFont("Fonts\\ARIALN.TTF", 15, "OUTLINE")
    txtAvgHour:SetPoint("LEFT", labAvgHour, "RIGHT", 4, 0)
    txtAvgHour:SetJustifyH("LEFT")
    -- 辅助行右侧：今日时均收益数值（隐藏标签文字，数值紧跟预计还需之后，与预计还需数值同一行对齐）
    local labAvgMini = containerFrame:CreateFontString(nil, "OVERLAY")
    labAvgMini:SetFont("Fonts\\ARIALN.TTF", 15)
    labAvgMini:SetTextColor(0.7, 0.72, 0.9)
    labAvgMini:SetPoint("LEFT", txtAvgHour, "RIGHT", 4, 0)
    labAvgMini:SetText("")
    local txtAvgMini = containerFrame:CreateFontString(nil, "OVERLAY")
    txtAvgMini:SetFont("Fonts\\ARIALN.TTF", 15, "OUTLINE")
    txtAvgMini:SetTextColor(0.3, 1.0, 0.6)
    txtAvgMini:SetPoint("LEFT", labAvgMini, "RIGHT", 0, 0)
    txtAvgMini:SetJustifyH("LEFT")

    -- ==== 以下仅为兼容 RefreshPanel 字段，全部隐藏 ====
    local txtGold     = MakeHiddenText(containerFrame)
    local txtBank     = MakeHiddenText(containerFrame)
    local txtTotal    = MakeHiddenText(containerFrame)
    local txtGainToday = MakeHiddenText(containerFrame)
    local txtAvgToday = MakeHiddenText(containerFrame)
    local txtNeedTime = MakeHiddenText(containerFrame)
    local txtEta      = MakeHiddenText(containerFrame)

    local editTarget = CreateFrame("EditBox", nil, containerFrame, "InputBoxTemplate")
    editTarget:SetSize(150, 20)
    editTarget:SetAutoFocus(false)
    editTarget:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    editTarget:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        if v and v > 0 then
            DB.target = math.floor(v)
            self:SetText(tostring(DB.target))
            RefreshPanel()
        else
            self:SetText(tostring(DB.target))
        end
        self:ClearFocus()
    end)
    editTarget:SetText(tostring(DB.target))
    editTarget:Hide()

    local roleLines = {}
    for i = 1, MAX_ROLE_ROWS + 1 do
        roleLines[i] = {
            role  = MakeHiddenText(containerFrame),
            gold  = MakeHiddenText(containerFrame),
            total = MakeHiddenText(containerFrame),
            time  = MakeHiddenText(containerFrame),
        }
    end

    local recentLines = {}
    for i = 1, 7 do
        recentLines[i] = {
            date = MakeHiddenText(containerFrame),
            gold = MakeHiddenText(containerFrame),
            gain = MakeHiddenText(containerFrame),
        }
    end

    local content = {
        title = nil,
        txtGold = txtGold, txtBank = txtBank, txtTotal = txtTotal,
        txtGainToday = txtGainToday, txtAvgToday = txtAvgToday,
        txtAvgHour = txtAvgHour, txtAvgMini = txtAvgMini, txtNeedTime = txtNeedTime, txtEta = txtEta,
        progress = progress, progressText = progressText,
        miniGoldText = txtGoldMini, isMini = true,
        editTarget = editTarget,
        roleLines = roleLines, recentLines = recentLines,
        tip = nil,
    }
    contentInstances[#contentInstances + 1] = content
    return content
end

-- 面板位置：当前角色个人拖动位置优先，否则用全局默认位置（DB.pos），再无则返回 nil（调用方居中）
local function GetPanelDefaultPos()
    local realm = GetRealmName()
    local name = UnitName("player")
    local roles = DB.roles and DB.roles[realm]
    local info = roles and roles[name]
    if info and info.pos and info.pos.point then
        return info.pos
    end
    if DB.pos and DB.pos.point then
        return DB.pos
    end
    return nil
end

local function SetCombatHidden(enabled)
    DB.hidePanelInCombat = enabled
    if enabled then
        if InCombatLockdown and InCombatLockdown() and panel and panel:IsShown() then
            panelWasVisibleBeforeCombat = true
            panelHiddenByCombat = true
            panel:Hide()
        end
    else
        if panelHiddenByCombat and panel then panel:Show() end
        panelHiddenByCombat = false
    end
    if combatCheckbox then combatCheckbox:SetChecked(enabled) end
    SyncBackup()
end

local function OpenPluginSettings()
    if InCombatLockdown and InCombatLockdown() then
        print("|cffffcc66[GoldTargetTracker]|r 请脱离战斗后打开设置。")
        return
    end
    if Settings and Settings.OpenToCategory and settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
        if SelectSettingsPage then SelectSettingsPage() end
    else
        print("|cffff4040[GoldTargetTracker]|r 设置界面尚未就绪。")
    end
end

local function OpenPanelMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        print("|cffff4040[GoldTargetTracker]|r 当前客户端的右键菜单 API 不可用。")
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, menu)
        menu:CreateCheckbox("战斗中隐藏", function() return DB.hidePanelInCombat end, function()
            SetCombatHidden(not DB.hidePanelInCombat)
        end)
        menu:CreateCheckbox("锁定窗口", function() return DB.lockPanel end, function()
            DB.lockPanel = not DB.lockPanel
            panel:StopMovingOrSizing()
            panel:SetMovable(not DB.lockPanel)
            SyncBackup()
        end)
        menu:CreateCheckbox("小地图图标", function() return DB.showMinimapIcon end, function()
            DB.showMinimapIcon = not DB.showMinimapIcon
            if minimapButton then
                if DB.showMinimapIcon then minimapButton:Show() else minimapButton:Hide() end
            end
            SyncBackup()
        end)
        menu:CreateDivider()
        menu:CreateButton("设置", OpenPluginSettings)
    end)
end

-- 创建主面板：外层 frame（可拖动/记忆位置/背景/关闭按钮）+ 第一份内容
local function CreatePanel()
    if panel then return end  -- 幂等：防止重复创建同名 Frame
    panel = CreateFrame("Frame", "GoldTargetTrackerFrame", UIParent, "BackdropTemplate")
    panel:SetSize(500, 64)
    -- 默认初始位置：当前角色个人拖动位置优先，否则全局默认位置，再否则居中
    local startPos = GetPanelDefaultPos()
    if startPos then
        panel:SetPoint(startPos.point, UIParent, startPos.point, startPos.x, startPos.y)
    else
        panel:SetPoint("CENTER")
    end
    panel:SetClampedToScreen(true)
    -- 扁平化：面板背景完全透明（无底色、无边框、无光影），仅保留可拖动区域
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0, 0, 0, 0)
    panel:SetBackdropBorderColor(0, 0, 0, 0)
    -- 拖动 + 记忆位置：手动拖动只记录当前角色的个人位置，不改变全局默认位置
    panel:EnableMouse(true)
    panel:SetMovable(not DB.lockPanel)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then OpenPanelMenu(self) end
    end)
    panel:SetScript("OnDragStart", function(self)
        if not DB.lockPanel then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", function(self)
        if DB.lockPanel then return end
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        if point then
            local realm = GetRealmName()
            local name = UnitName("player")
            if realm and name and name ~= "" then
                DB.roles = DB.roles or {}
                DB.roles[realm] = DB.roles[realm] or {}
                DB.roles[realm][name] = DB.roles[realm][name] or {}
                DB.roles[realm][name].pos = { point = point, x = x, y = y }
                SyncBackup()
            end
        end
    end)

    -- 第一份内容：V2 Mini 精简面板（仅进度条 + 时均收益）
    CreatePanelContentV2Mini(panel)
end

-- 所有每日记录按日期升序排序，返回 { {day=..., gold=...}, ... }
local function GetSortedRecords()
    local list = {}
    for day, gold in pairs(DB.records) do
        table.insert(list, { day = day, gold = gold })
    end
    table.sort(list, function(a, b) return a.day < b.day end)
    return list
end

-- 公历日期转整数序号，避免夏令时导致两个本地日期相差 23/25 小时而算错天数。
local function DayOrdinal(dayKey)
    local y, m, d = tostring(dayKey):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or not m or not d then return nil end
    local a = math.floor((14 - m) / 12)
    y = y + 4800 - a
    m = m + 12 * a - 3
    return d + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4)
        - math.floor(y / 100) + math.floor(y / 400) - 32045
end

local function ShiftDayKey(dayKey, offset)
    local y, m, d = tostring(dayKey):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y then return dayKey end
    local stamp = time({ year = y, month = m, day = d + offset, hour = 12, min = 0, sec = 0 })
    return date("%Y-%m-%d", stamp)
end

-- 自然日平均收益：最早一条有效记录至最新一条记录，首尾日期均计入分母。
-- 缺失自然日不伪造收益，按 0 贡献收益但仍计入天数；日记录差额仍按已记录快照计算。
local function GetNaturalDailyAvg()
    local records = GetSortedRecords()
    if #records == 0 then return nil, 0 end
    local firstDay, lastDay = records[1].day, records[#records].day
    local firstOrd, lastOrd = DayOrdinal(firstDay), DayOrdinal(lastDay)
    if not firstOrd or not lastOrd or lastOrd < firstOrd then return nil, 0 end
    local spanDays = lastOrd - firstOrd + 1
    local sum = 0
    local today = date("%Y-%m-%d")
    for _, rec in ipairs(records) do
        local gain
        if rec.day == today then
            gain = GetTodayGain()
        else
            local _, prevGold = GetPrevRecord(rec.day)
            gain = rec.gold - (prevGold or DB.firstTotal or rec.gold)
        end
        sum = sum + (gain or 0)
    end
    return sum / spanDays, spanDays
end

-- 构造连续 7 个自然日：缺失日期收益为 0，总金币沿用上一次已知余额。
local function GetRecent7DayData()
    local result = {}
    local today = date("%Y-%m-%d")
    local firstDay = ShiftDayKey(today, -6)
    local lastKnownDay, lastKnownGold = nil, nil
    for day, gold in pairs(DB.records or {}) do
        if day < firstDay and (lastKnownDay == nil or day > lastKnownDay) then
            lastKnownDay, lastKnownGold = day, gold
        end
    end
    if lastKnownGold == nil and type(DB.firstTotal) == "number" then
        lastKnownGold = DB.firstTotal
    end
    for offset = 6, 0, -1 do
        local day = ShiftDayKey(today, -offset)
        local recordGold = DB.records[day]
        local beforeGold = lastKnownGold
        local gold
        if day == today then
            gold = GetTotalGold()
        elseif type(recordGold) == "number" then
            gold = recordGold
        else
            gold = lastKnownGold or 0
        end
        local gain = 0
        if day == today then
            gain = GetTodayGain() or 0
        elseif type(recordGold) == "number" then
            gain = recordGold - (beforeGold or DB.firstTotal or recordGold)
        end
        result[#result + 1] = { day = day, gold = gold or 0, gain = gain or 0 }
        lastKnownGold = gold or lastKnownGold
    end
    return result
end

-- ============ 刷新显示 ============
-- 公共数据只计算一次，随后遍历所有内容实例（主界面 + 设置界面）同步写入，保证两份显示实时一致
RefreshPanel = function()
    if #contentInstances == 0 then return end
    -- 首个实例控件未创建完成时安全返回（正常不会发生，防御 nil 崩溃）
    local c0 = contentInstances[1]
    if not c0.txtGold or not c0.txtBank or not c0.txtTotal or not c0.txtGainToday or not c0.txtAvgToday
        or not c0.txtNeedTime or not c0.txtEta or not c0.progress or not c0.progressText then
        return
    end

    local gold = GetGold()
    local bankGold, bankOk, bankFallback = GetWarbandBankGold(true)
    -- 全账号总金币（当前角色实时 + 其他角色快照 + 战团银行），切换角色数值稳定
    local total = GetTotalGold()
    local todayGain = GetTodayGain()
    local todayAvg = GetTodayHourlyAvg()
    local need = DB.target - total
    -- 预计还需自然日 = 还差的金币 ÷ 首尾记录日期的自然日平均收益（首尾日期均计入）。
    local needDays = nil
    local recentDailyAvg, avgSpanDays = GetNaturalDailyAvg()
    if recentDailyAvg and recentDailyAvg > 0 and need > 0 then
        needDays = math.ceil(need / recentDailyAvg)
    end

    -- 预计完成：基于今日实时秒级时均动态推算（今日收益/今日在线秒数）。
    -- 一旦停止赚钱，在线秒数持续增长 → 时均下降 → 剩余时间随现实时间递增（每秒可见变化）
    local etaText = todayGain and todayGain > 0 and "正在采集时长" or "今日暂无正收益"
    if need <= 0 then
        etaText = "已达标"
    else
        local onlineSec = GetTodayOnlineSeconds()
        if todayGain and todayGain > 0 and onlineSec > 0 then
            -- 剩余现实秒数 = 差距 / (今日收益/今日在线秒数) = 差距 * 在线秒数 / 今日收益
            local remainSec = (need / todayGain) * onlineSec
            etaText = "剩余 " .. FormatCountdown(remainSec)
        end
    end

    -- 进度条百分比：总金币 / 总目标
    local pct = DB.target > 0 and (total / DB.target) or 0
    pct = math.min(1, math.max(0, pct))

    -- 各角色金币列表行（两份内容共用同一份数据）
    local rows = GetRoleRows()
    -- 统计已记录的非当前角色数量（用于空位引导提示）
    local otherCount = 0
    for _, r in ipairs(rows) do
        if r.name ~= "战团银行" and r.date ~= "现在" then
            otherCount = otherCount + 1
        end
    end
    -- 最近 7 天列表（取记录最后 7 条，按日期升序）
    local records = GetSortedRecords()
    local startIdx = math.max(1, #records - 6)

    for _, content in ipairs(contentInstances) do
        -- 目标编辑框：非编辑状态下同步目标值（两处 EditBox 共享 DB.target，避免一方修改后另一方显示过期）
        if not content.editTarget:HasFocus() then
            content.editTarget:SetText(tostring(DB.target))
        end

        -- 目标下拉菜单：同步当前目标（仅设置界面有该字段）
        if content.targetDD then
            if DB.target == 5000000 then
                UIDropDownMenu_SetSelectedID(content.targetDD, 1)
                UIDropDownMenu_SetText(content.targetDD, "坐骑本体（500万）")
            elseif DB.target == 7000000 then
                UIDropDownMenu_SetSelectedID(content.targetDD, 2)
                UIDropDownMenu_SetText(content.targetDD, "坐骑 + 全部额外NPC（700万）")
            else
                UIDropDownMenu_SetSelectedID(content.targetDD, 3)
                UIDropDownMenu_SetText(content.targetDD, "自定义金额")
            end
        end

        -- 插件名称下拉菜单：同步当前名称（仅设置界面有该字段）
        if content.nameDD then
            if DB.name == "金币攒钱计划" then
                UIDropDownMenu_SetSelectedID(content.nameDD, 1)
                UIDropDownMenu_SetText(content.nameDD, "金币攒钱计划")
            elseif DB.name == "金币目标追踪" then
                UIDropDownMenu_SetSelectedID(content.nameDD, 2)
                UIDropDownMenu_SetText(content.nameDD, "金币目标追踪")
            else
                UIDropDownMenu_SetSelectedID(content.nameDD, 3)
                UIDropDownMenu_SetText(content.nameDD, "自定义")
            end
        end

        -- XP 条内数值：当前金币 / 目标金币（万单位；仅主界面条有该字段，设置界面实例无则自动跳过）
        if content.miniGoldText then
            local miniText = "|cffffffff" .. FormatWan2(total) .. "|r  |cff9a9ab8/ |r|cffffffff" .. FormatWan(DB.target) .. "|r"
            content.miniGoldText:SetText(miniText)
        end

        content.txtGold:SetText("|cff4dff6d" .. FormatNumber(gold) .. "|r 金")
        if bankOk then
            content.txtBank:SetText("|cff85d9ff" .. FormatNumber(bankGold) .. "|r 金")
        elseif bankFallback then
            content.txtBank:SetText("|cff85d9ff" .. FormatNumber(bankGold) .. "|r 金（历史快照）")
        else
            content.txtBank:SetText("0 金（当前版本不支持战团银行）")
        end
        content.txtTotal:SetText("|cffffd24d" .. FormatNumber(total) .. "|r 金")
        -- 差额（设置界面上方）：目标 - 总金币，达标后显示已达成
        if content.txtDiff then
            if need > 0 then
                content.txtDiff:SetText("|cffff6b6b" .. FormatNumber(need) .. "|r 金")
            else
                content.txtDiff:SetText("|cff4dff6d已达成|r")
            end
        end
        content.txtGainToday:SetText(FormatGain(todayGain) .. " 金")
        content.txtAvgToday:SetText(todayAvg and FormatGain(math.floor(todayAvg)) .. " 金/小时" or "暂无数据")
        -- 预计完成（主界面辅助行；设置界面已移除时均收益/还需赚等字段）
        if content.txtAvgHour then
            content.txtAvgHour:SetText(etaText)
        end
        -- 主界面辅助行右侧：今日时均收益（万单位缩写，X.XX万金/小时）
        if content.txtAvgMini then
            if todayAvg then
                local av = math.floor(todayAvg)
                if av >= 10000 then
                    content.txtAvgMini:SetText(string.format("+%.2f万金/小时", av / 10000))
                else
                    content.txtAvgMini:SetText("+" .. av .. " 金/小时")
                end
            else
                content.txtAvgMini:SetText("暂无数据")
            end
        end
        content.txtNeedTime:SetText(needDays and FormatMonthsDays(needDays) or "暂无数据")
        content.txtEta:SetText(etaText)

        -- 进度条（仅主界面实例有，设置界面已无进度条自动跳过）
        if content.progress and content.progressText then
            content.progress:SetMinMaxValues(0, 1)
            content.progress:SetValue(pct)
            -- 百分比字号随进度 0→100% 线性放大：15 → 30（pct 为 0~1）
            content.progressText:SetFont("Fonts\\ARIALN.TTF", 15 + 15 * pct, "OUTLINE")
            content.progressText:SetText(FormatProgress(math.min(total, DB.target), DB.target))
        end
        -- 百分比辉光同步（仅主界面条有该字段，设置界面实例无则自动跳过）
        if content.progressGlow then
            content.progressGlow:SetText(content.progressText:GetText())
        end

        -- 各角色金币列表（设置界面每行不显示总计，仅末尾总计行）
        for i = 1, #content.roleLines do
            local line = content.roleLines[i]
            local row = rows[i]
            if row then
                line.role:SetText(row.name)
                if row.name == "战团银行" then
                    line.role:SetTextColor(0.5, 0.85, 1.0)
                elseif row.date == "现在" then
                    line.role:SetTextColor(0.3, 1.0, 0.6)
                else
                    line.role:SetTextColor(0.9, 0.9, 0.9)
                end
                line.gold:SetText(FormatNumber(row.gold))
                if line.total then
                    line.total:SetText(FormatNumber(row.total))
                end
                line.time:SetText(row.date)
            elseif otherCount == 0 and i == #rows + 1 and i <= MAX_ROLE_ROWS then
                -- 无其它角色记录时，第二个空位显示登录引导
                line.role:SetTextColor(0.55, 0.55, 0.55)
                line.role:SetText("登录其它角色后自动记录")
                line.gold:SetText("")
                if line.total then
                    line.total:SetText("")
                end
                line.time:SetText("")
            else
                line.role:SetText("")
                line.gold:SetText("")
                if line.total then
                    line.total:SetText("")
                end
                line.time:SetText("")
            end
        end

        -- 各角色金币总计行（仅设置界面有该字段）
        if content.totalRow then
            local sum = 0
            for _, r in ipairs(rows) do
                sum = sum + (r.gold or 0)
            end
            content.totalRow:SetText("总计：" .. FormatNumber(sum))
        end

        -- 最近 7 天列表（当天行跟随实时总金币与今日收益，其余行用定格快照）
        local today = date("%Y-%m-%d")
        local lineIdx = 1
        for idx = startIdx, #records do
            local rec = records[idx]
            if lineIdx <= 7 then
                local line = content.recentLines[lineIdx]
                if rec.day == today then
                    line.date:SetText(rec.day)
                    line.gold:SetText(FormatNumber(total))
                    line.gain:SetText(FormatGain(todayGain))
                else
                    local _, prevGold = GetPrevRecord(rec.day)
                    local gain = rec.gold - (prevGold or DB.firstTotal or rec.gold)
                    line.date:SetText(rec.day)
                    line.gold:SetText(FormatNumber(rec.gold))
                    line.gain:SetText(FormatGain(gain))
                end
                lineIdx = lineIdx + 1
            end
        end
        for i = lineIdx, 7 do
            content.recentLines[i].date:SetText("")
            content.recentLines[i].gold:SetText("")
            content.recentLines[i].gain:SetText("")
        end
    end
    if RefreshGoldTargetDashboard then RefreshGoldTargetDashboard() end
    if CheckAchievementCrossing then CheckAchievementCrossing(total) end
end

-- ============ 设置界面重置统计 / 重置所有 ============
-- 重置今日统计；保留历史首次基准、其他日期记录、角色资产及位置。
local function ResetStatData()
    local total = GetTotalGold()
    local todayPrefix = date("%Y-%m-%d")
    -- 设置"今日收益基准"：重置当天今日收益从重置时刻总金币重新累计（跨天自动失效）
    DB.todayBase = { day = todayPrefix, gold = total }
    -- 清除今日小时打点（今日时均/在线秒数/预计还需的时均来源）
    for k in pairs(DB.hourly) do
        if k:sub(1, 10) == todayPrefix then
            DB.hourly[k] = nil
        end
    end
    -- 清除今日每日记录，避免旧快照成为后续收益基准
    -- （下一轮询由 ticker 自愈补写 records[today]=当前总金币，保证最近 7 天今天行恢复显示）
    DB.records[todayPrefix] = nil
    -- 保留角色资产快照及位置，仅刷新当前角色
    UpdateRoleSnapshot()
    SyncBackup()
    RefreshPanel()
    print("|cff4da6ff[GoldTargetTracker]|r 已重置统计：今日收益已从当前余额重新累计；角色资产及历史记录已保留")
end

-- 重置所有：包含重置统计全部内容，并额外清除最近 7 天（全部每日记录/全部小时打点/首次基准）
local function ResetAllData()
    local total = GetTotalGold()
    DB.firstTotal = total
    -- 设置"今日收益基准"：重置当天今日收益从重置时刻总金币重新累计（跨天自动失效）
    DB.todayBase = { day = date("%Y-%m-%d"), gold = total }
    DB.hourly = {}
    DB.records = {}
    DB.incomeSources = Income.NewData()
    if playerLoggedIn then Income:Start(DB.incomeSources, Income.changed) end
    UpdateRoleSnapshot()
    SyncBackup()
    RefreshPanel()
    print("|cff4da6ff[GoldTargetTracker]|r 已重置所有：全部统计已清空（含最近 7 天与全部历史记录），统计从当前总金币重新开始")
end

-- 确认弹窗（原生暴雪确认框）：点击重置按钮后弹出，用户确认后执行，取消不生效
if not StaticPopupDialogs["GOLDTT_RESET_STAT"] then
    StaticPopupDialogs["GOLDTT_RESET_STAT"] = {
        text = "确定要重置今日统计吗？\n\n今日收益将从当前余额重新累计，并清除今日小时记录。\n保留各角色资产、位置和其他日期的历史记录。\n\n此操作不可撤销。",
        button1 = "重置统计",
        button2 = "取消",
        OnAccept = function()
            ResetStatData()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end
if not StaticPopupDialogs["GOLDTT_RESET_ALL"] then
    StaticPopupDialogs["GOLDTT_RESET_ALL"] = {
        text = "确定要重置所有吗？\n\n将清空全部历史统计及累计金币来源收入，并更新来源统计开始时间；保留各角色资产和位置，\n并删除最近 7 天及全部历史每日记录、全部小时打点，统计基准改为当前总金币。\n\n此操作不可撤销！",
        button1 = "重置所有",
        button2 = "取消",
        OnAccept = function()
            ResetAllData()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- ============ 金币目标达成提示与战斗中面板行为 ============
CreateAchievementToast = function()
    if achievementToast then return achievementToast end
    local toast = CreateFrame("Frame", "GoldTargetTrackerAchievementToast", UIParent, "BackdropTemplate")
    achievementToast = toast
    toast:SetSize(360, 100)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -145)
    toast:SetFrameStrata("DIALOG")
    toast:SetFrameLevel(100)
    toast:SetClampedToScreen(true)
    toast:EnableMouse(true)
    toast:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 18,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    toast:SetBackdropColor(0.035, 0.028, 0.018, 0.96)
    toast:SetBackdropBorderColor(0.92, 0.70, 0.26, 1)
    local icon = toast:CreateTexture(nil, "ARTWORK")
    icon:SetSize(54, 54)
    icon:SetPoint("LEFT", toast, "LEFT", 14, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    toast.icon = icon
    local title = toast:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    title:SetTextColor(1.0, 0.85, 0.35)
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -3)
    title:SetText("金币目标达成！")
    toast.title = title
    local target = toast:CreateFontString(nil, "OVERLAY")
    target:SetFont("Fonts\\ARIALN.TTF", 12, "OUTLINE")
    target:SetTextColor(0.96, 0.91, 0.76)
    target:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    toast.target = target
    local total = toast:CreateFontString(nil, "OVERLAY")
    total:SetFont("Fonts\\ARIALN.TTF", 12, "OUTLINE")
    total:SetTextColor(1.0, 0.83, 0.38)
    total:SetPoint("TOPLEFT", target, "BOTTOMLEFT", 0, -4)
    toast.total = total
    local closeButton = CreateFrame("Button", nil, toast, "UIPanelCloseButton")
    closeButton:SetSize(24, 24)
    closeButton:SetPoint("TOPRIGHT", toast, "TOPRIGHT", -2, -2)
    closeButton:SetScript("OnClick", function()
        if toast.entryAnimation then toast.entryAnimation:Stop() end
        toast:Hide()
        achievementInProgress = false
        local nextAchievement = queuedAchievement
        queuedAchievement = nil
        if nextAchievement then StartAchievement(nextAchievement.total, nextAchievement.target) end
    end)
    toast.closeButton = closeButton
    if toast.CreateAnimationGroup then
        local anim = toast:CreateAnimationGroup()
        local alpha = anim:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0)
        alpha:SetToAlpha(1)
        alpha:SetDuration(0.45)
        if alpha.SetSmoothing then alpha:SetSmoothing("OUT") end
        local move = anim:CreateAnimation("Translation")
        move:SetOffset(0, -10)
        move:SetDuration(0.45)
        if move.SetSmoothing then move:SetSmoothing("OUT") end
        toast.entryAnimation = anim
    end
    toast:Hide()
    return toast
end

StartAchievement = function(total, targetOverride)
    if panel then panel:Hide() end
    panelHiddenByCombat = false
    panelWasVisibleBeforeCombat = false
    if achievementInProgress then
        queuedAchievement = { total = total or GetTotalGold(), target = targetOverride or DB.target or DEFAULT_TARGET }
        return
    end
    local toast = CreateAchievementToast()
    achievementInProgress = true
    local achievementTarget = targetOverride or DB.target or DEFAULT_TARGET
    toast.target:SetText("目标金额：" .. FormatNumber(achievementTarget) .. " 金")
    toast.total:SetText("当前账号总金币：" .. FormatNumber(total or GetTotalGold()) .. " 金")
    toast:SetAlpha(1)
    toast:Show()
    if toast.entryAnimation then toast.entryAnimation:Stop(); toast.entryAnimation:Play() end
    if PlaySound and SOUNDKIT then
        local soundID = SOUNDKIT.UI_ACHIEVEMENT_EARNED or SOUNDKIT.ACHIEVEMENT_EARNED
        if soundID then pcall(PlaySound, soundID, "Master") end
    end
end

ResetAchievementBaseline = function()
    lastObservedTotal = GetTotalGold()
    lastObservedTarget = DB.target
    pendingAchievement = nil
    queuedAchievement = nil
end

CheckAchievementCrossing = function(total)
    total = tonumber(total) or GetTotalGold()
    local target = tonumber(DB.target) or DEFAULT_TARGET
    if lastObservedTotal == nil or lastObservedTarget == nil then
        lastObservedTotal, lastObservedTarget = total, target
        return
    end
    if lastObservedTarget ~= target then
        lastObservedTotal, lastObservedTarget = total, target
        pendingAchievement = nil
        return
    end
    if lastObservedTotal < target and total >= target then
        local combat = InCombatLockdown and InCombatLockdown()
        if combat then
            if panelHiddenByCombat or (panel and panel:IsShown()) then
                pendingAchievement = pendingAchievement or { total = total, target = target }
            end
        elseif panel and panel:IsShown() then
            StartAchievement(total)
        end
    end
    lastObservedTotal, lastObservedTarget = total, target
end

-- 面板开关
local function TogglePanel()
    if not panel then return end
    if DB.hidePanelInCombat ~= false and InCombatLockdown and InCombatLockdown() then
        if panel:IsShown() then panel:Hide() end
        return
    end
    if panel:IsShown() then
        panel:Hide()
    else
        RefreshPanel()
        panel:Show()
    end
end

-- ============ 小地图快捷按钮 ============
local MINIMAP_ICON = "Interface\\Icons\\INV_Misc_Coin_01" -- 金币图标
local MINIMAP_RADIUS = 82    -- 小地图中心到按钮中心的距离

-- 根据角度把小地图按钮放在环形轨道上
local function UpdateMinimapButtonPosition(btn)
    local angle = btn.angle or 0
    local x = math.cos(angle) * MINIMAP_RADIUS
    local y = math.sin(angle) * MINIMAP_RADIUS
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- 从鼠标当前位置计算相对小地图中心的角度
local function GetMinimapAngleFromCursor()
    local cx, cy = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    local x, y = px / scale - cx, py / scale - cy
    return math.atan2(y, x)
end

-- 创建小地图旁快捷按钮（左键开关面板，按住可拖动）
local function CreateMinimapButton()
    if minimapButton then return end
    local btn = CreateFrame("Button", "GoldTargetTrackerMinimapButton", Minimap)
    minimapButton = btn
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:SetClampedToScreen(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton", "RightButton")

    -- 图标纹理；纹理无效时回退为文字 "$"
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MINIMAP_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetAllPoints(btn)
    btn.icon = icon
    if not icon:GetTexture() then
        btn:SetNormalFontObject(GameFontNormal)
        btn:SetText("$")
    end
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    -- 初始角度：记忆的角度或默认 -0.7（右上角附近）
    btn.angle = DB.minimapAngle or -0.7
    UpdateMinimapButtonPosition(btn)
    if DB.showMinimapIcon == false then btn:Hide() end

    -- 左键点击开关面板
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            TogglePanel()
        end
    end)

    -- 拖动：按住时跟随鼠标，松开时记录角度
    btn:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function(s)
            s.angle = GetMinimapAngleFromCursor()
            UpdateMinimapButtonPosition(s)
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self.dragging = nil
        self:SetScript("OnUpdate", nil)
        self.angle = GetMinimapAngleFromCursor()
        DB.minimapAngle = self.angle
        UpdateMinimapButtonPosition(self)
    end)

    -- 鼠标提示
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff4da6ff金币攒钱计划|r")
        GameTooltip:AddLine("左键打开/关闭面板")
        GameTooltip:AddLine("拖动可移动按钮")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- ============ 自动使用（物品进背包自动使用，新增功能） ============
-- 自动使用通过队列串行处理，BAG_UPDATE_DELAYED 只负责检测背包差异。
-- 暂时受阻时保留队列并在可重试事件/计时器到期后重新检查。
local bagSnapshot, bagTotals
local hasEnteredWorld = false

-- 只观察完整的背包状态，不执行物品操作。
local function ReadBags()
    if not C_Container or not C_Container.GetContainerNumSlots
        or not C_Container.GetContainerItemInfo then return nil end
    local slots, totals = {}, {}
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local count = C_Container.GetContainerNumSlots(bag)
        if not count then return nil end
        slots[bag] = {}
        for slot = 1, count do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                slots[bag][slot] = {
                    itemID = info.itemID, count = info.stackCount or 1,
                    locked = info.isLocked, name = info.itemName,
                }
                totals[info.itemID] = (totals[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    return slots, totals
end

local function SnapshotBags()
    bagSnapshot, bagTotals = ReadBags()
end

local function IsAutoUseItem(name)
    if type(name) ~= "string" or type(DB.autoUseItems) ~= "table" then return false end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    for _, itemName in ipairs(DB.autoUseItems) do
        if itemName == name then return true end
    end
    return false
end

local function AutoUseBlocked()
    if InCombatLockdown and InCombatLockdown() then return true, "combat" end
    if SpellIsTargeting and SpellIsTargeting() then return true, "targeting" end
    if CursorHasItem and CursorHasItem() then return true, "cursor" end
    for _, frame in ipairs({ MerchantFrame or false, MailFrame or false, TradeFrame or false,
        BankFrame or false, AuctionHouseFrame or false, ItemSocketingFrame or false,
        ScrappingMachineFrame or false }) do
        if frame and frame.IsShown and frame:IsShown() then return true, "interaction" end
    end
    return false
end

local autoUseScheduled = false
local autoUseInFlight = false

local function QueueAutoUseItem(itemID, name, count)
    if not itemID or not count or count <= 0 then return end
    DB.autoUseQueue = type(DB.autoUseQueue) == "table" and DB.autoUseQueue or {}
    for _, task in ipairs(DB.autoUseQueue) do
        if task.itemID == itemID then
            task.count = (task.count or 0) + count
            -- 确认窗口内再次获得同 ID 物品时，同步校准比较基准，避免新增数量掩盖已消耗数量。
            if task.inFlight and task.beforeCount then task.beforeCount = task.beforeCount + count end
            if type(name) == "string" and name ~= "" then task.name = name end
            SyncBackup()
            return
        end
    end
    DB.autoUseQueue[#DB.autoUseQueue + 1] = { itemID = itemID, name = name, count = count, attempts = 0 }
    SyncBackup()
end

ScheduleAutoUseQueue = function(delay)
    if autoUseScheduled or not (C_Timer and C_Timer.After) then return end
    if type(DB.autoUseQueue) ~= "table" or #DB.autoUseQueue == 0 then return end
    autoUseScheduled = true
    C_Timer.After(delay or 0.1, function()
        autoUseScheduled = false
        if ProcessAutoUseQueue then ProcessAutoUseQueue() end
    end)
end

local function ItemCoolingDown(bag, slot)
    if not (C_Container and C_Container.GetContainerItemCooldown) then return false end
    local ok, start, duration, enabled = pcall(C_Container.GetContainerItemCooldown, bag, slot)
    if not ok or type(start) ~= "number" or type(duration) ~= "number" then return false end
    if enabled == false or enabled == 0 or duration <= 0 then return false end
    return start + duration > (GetTime and GetTime() or 0)
end

ProcessAutoUseQueue = function()
    if autoUseInFlight or type(DB.autoUseQueue) ~= "table" or #DB.autoUseQueue == 0 then return end
    if DB.autoUseEnabled == false or type(DB.autoUseItems) ~= "table" or #DB.autoUseItems == 0 then
        DB.autoUseQueue = {}
        SyncBackup()
        return
    end
    local blocked, reason = AutoUseBlocked()
    if blocked then
        -- 战斗中等待 PLAYER_REGEN_ENABLED；其他临时交互阻塞每 2 秒检查一次。
        if reason ~= "combat" then ScheduleAutoUseQueue(2) end
        return
    end
    local current, totals = ReadBags()
    if not current then ScheduleAutoUseQueue(2); return end
    bagSnapshot, bagTotals = current, totals

    local task = DB.autoUseQueue[1]
    if not task then return end
    local totalCount = totals[task.itemID] or 0
    if task.inFlight then
        -- ReloadUI 可能打断使用后的确认计时器：用重载后的背包总数判断该单位是否已经消耗。
        if type(task.beforeCount) == "number" and totalCount < task.beforeCount then
            task.count = math.max(0, (task.count or 1) - (task.beforeCount - totalCount))
            task.attempts = 0
        end
        task.inFlight = nil
        task.beforeCount = nil
        SyncBackup()
        if (task.count or 0) <= 0 then
            table.remove(DB.autoUseQueue, 1)
            SyncBackup()
            ScheduleAutoUseQueue(0.1)
            return
        end
    end
    if totalCount <= 0 or task.count <= 0 then
        table.remove(DB.autoUseQueue, 1)
        SyncBackup()
        ScheduleAutoUseQueue(0.1)
        return
    end
    if task.count > totalCount then task.count = totalCount end
    if (task.attempts or 0) >= 3 then return end

    local chosenBag, chosenSlot, chosenInfo, resolvedName
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = current[bag] and current[bag][slot]
            if info and info.itemID == task.itemID then
                if not resolvedName or resolvedName == "" then resolvedName = info.name end
                if not info.locked and not chosenBag then
                    chosenBag, chosenSlot, chosenInfo = bag, slot, info
                end
            end
        end
    end
    if (not resolvedName or resolvedName == "") and C_Item and C_Item.GetItemInfo then
        resolvedName = C_Item.GetItemInfo(task.itemID)
    end
    if (not resolvedName or resolvedName == "") and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, task.itemID)
        ScheduleAutoUseQueue(2)
        return
    end
    if resolvedName and resolvedName ~= "" then task.name = resolvedName end
    if resolvedName and not IsAutoUseItem(resolvedName) then
        -- 名称已确认但不在当前名单内：删除候选任务，不对非名单物品进行操作。
        table.remove(DB.autoUseQueue, 1)
        SyncBackup()
        ScheduleAutoUseQueue(0.1)
        return
    end
    if not chosenBag then
        -- 物品仍存在但被锁定或暂不可操作，保留队列稍后再试。
        ScheduleAutoUseQueue(2)
        return
    end
    if ItemCoolingDown(chosenBag, chosenSlot) then
        ScheduleAutoUseQueue(2)
        return
    end
    if not resolvedName or resolvedName == "" then
        ScheduleAutoUseQueue(2)
        return
    end
    -- 使用前再次核对槽位，防止上一次背包操作后槽位发生变化。
    local live = C_Container.GetContainerItemInfo(chosenBag, chosenSlot)
    if not live or live.itemID ~= task.itemID or live.isLocked
        or live.stackCount ~= chosenInfo.count or live.stackCount <= 0 then
        ScheduleAutoUseQueue(2)
        return
    end
    local use = C_Container.UseContainerItem
    if type(use) ~= "function" then
        ScheduleAutoUseQueue(2)
        return
    end

    local beforeCount = totalCount
    task.inFlight = true
    task.beforeCount = beforeCount
    SyncBackup()
    local ok, useError = pcall(use, chosenBag, chosenSlot)
    if not ok then
        task.inFlight = nil
        task.beforeCount = nil
        task.attempts = (task.attempts or 0) + 1
        if task.attempts >= 3 then
            print("|cffffcc66[GoldTargetTracker]|r 已尝试使用但调用受阻，任务已保留：" .. tostring(useError))
        end
        SyncBackup()
        ScheduleAutoUseQueue(2)
        return
    end
    autoUseInFlight = true
    C_Timer.After(0.45, function()
        autoUseInFlight = false
        if DB.autoUseQueue[1] ~= task then return end
        local latest, latestTotals = ReadBags()
        if not latest then ScheduleAutoUseQueue(2); return end
        bagSnapshot, bagTotals = latest, latestTotals
        local afterCount = latestTotals[task.itemID] or 0
        beforeCount = task.beforeCount or beforeCount
        task.inFlight = nil
        task.beforeCount = nil
        if afterCount < beforeCount then
            task.count = math.max(0, (task.count or 1) - (beforeCount - afterCount))
            task.attempts = 0
            print("|cff4da6ff[GoldTargetTracker]|r 已尝试使用：" .. tostring(task.name or task.itemID))
        else
            local stillCooling = false
            -- 槽位可能在调用后移动；必须按当前背包重新定位同一 itemID 后判断冷却。
            for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
                for slot = 1, C_Container.GetContainerNumSlots(bag) do
                    local info = latest[bag] and latest[bag][slot]
                    if info and info.itemID == task.itemID and ItemCoolingDown(bag, slot) then
                        stillCooling = true
                        break
                    end
                end
                if stillCooling then break end
            end
            task.attempts = (task.attempts or 0) + 1
            if stillCooling or task.attempts < 3 then
                if stillCooling then task.attempts = 0 end
                -- 冷却/短暂限制时保留该单位；两秒后重新读取背包与使用状态。
                SyncBackup()
                ScheduleAutoUseQueue(2)
                return
            end
            -- shortcut: 无消耗证据时保留任务并等待交互/战斗状态变化，有可靠物品结果 API 后替换。
            print("|cffffcc66[GoldTargetTracker]|r 已尝试使用但未确认消耗，任务已保留，等待条件变化：" .. tostring(task.name or task.itemID))
            SyncBackup()
            return
        end
        if (task.count or 0) <= 0 then table.remove(DB.autoUseQueue, 1) end
        SyncBackup()
        ScheduleAutoUseQueue(0.1)
    end)
end

-- 稳定事件后比较完整背包：只有总数量增加且该物品没有移动/减少证据时才入队。
-- 原有堆叠同槽位增加可入队；移动、整理、拆分/合并堆叠均视为来源不确定并跳过。
local function TryAutoUseItems()
    local current, totals = ReadBags()
    if not current then
        bagSnapshot, bagTotals = nil, nil
        return
    end
    local previous, previousTotals = bagSnapshot, bagTotals
    bagSnapshot, bagTotals = current, totals
    if not previous or DB.autoUseEnabled == false
        or type(DB.autoUseItems) ~= "table" or #DB.autoUseItems == 0 then return end

    local moved = {}
    for bag, slots in pairs(previous) do
        for slot, old in pairs(slots) do
            local now = current[bag] and current[bag][slot]
            -- 同槽位堆叠增加不算移动；槽位消失、换物品或数量减少视为移动/拆堆/合堆证据。
            if not now or now.itemID ~= old.itemID or now.count < old.count then
                moved[old.itemID] = true
            end
        end
    end

    for itemID, total in pairs(totals) do
        local oldTotal = previousTotals and previousTotals[itemID] or 0
        local delta = total - oldTotal
        if delta > 0 and not moved[itemID] then
            local name
            for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
                for slot = 1, C_Container.GetContainerNumSlots(bag) do
                    local info = current[bag] and current[bag][slot]
                    if info and info.itemID == itemID and info.name and info.name ~= "" then
                        name = info.name
                        break
                    end
                end
                if name then break end
            end
            if not name and C_Item and C_Item.GetItemInfo then name = C_Item.GetItemInfo(itemID) end
            -- 已知名称且不在名单中则跳过；名称延迟时暂存候选，等物品信息加载后再决定。
            if not name or name == "" or IsAutoUseItem(name) then
                QueueAutoUseItem(itemID, name, delta)
            end
        end
    end
    if #DB.autoUseQueue > 0 then ScheduleAutoUseQueue(0.1) end
end

local function ResumeAutoUseQueue()
    for _, task in ipairs(DB.autoUseQueue or {}) do task.attempts = 0 end
    SyncBackup()
    ScheduleAutoUseQueue(0.1)
end

-- ============ 定时刷新与事件 ============
local function OnEvent(self, event, ...)
    if event ~= "ADDON_LOADED" and not dataReady then return end
    if event ~= "ADDON_LOADED" then Income:OnEvent(event, ...) end
    if event == "ADDON_LOADED" then
        local addon = ...
        if addon == addonName then
            if not InitDB() then self:UnregisterAllEvents(); return end
            if not reloadHookInstalled and hooksecurefunc and type(ReloadUI) == "function" then
                local okHook = pcall(hooksecurefunc, "ReloadUI", function() isReloading = true end)
                reloadHookInstalled = okHook and true or false
            end
            local ok1, err1 = pcall(CreatePanel)
            if not ok1 then
                print("|cffff4040GoldTargetTracker 创建面板错误: |r" .. tostring(err1))
            end
            local ok2, err2 = pcall(CreateMinimapButton)
            if not ok2 then
                print("|cffff4040GoldTargetTracker 创建小地图按钮错误: |r" .. tostring(err2))
            end
            -- 设置面板（Esc→选项→插件）：依赖 DB 已初始化，必须在 InitDB 之后创建。
            -- 若放文件顶层（加载期）执行，界面创建访问 DB 会因 DB 为 nil 崩溃
            local ok3, settingsPanelRet = pcall(CreateSettingsPanel)
            if not ok3 then
                print("|cffff4040GoldTargetTracker 创建设置面板错误: |r" .. tostring(settingsPanelRet))
            else
                settingsPanel = settingsPanelRet
                if Settings and Settings.RegisterCanvasLayoutCategory then
                    local category = Settings.RegisterCanvasLayoutCategory(settingsPanel, settingsPanel.name)
                    settingsCategory = category
                    Settings.RegisterAddOnCategory(category)
                else
                    InterfaceOptions_AddCategory(settingsPanel)
                end
            end
            -- 恢复面板位置：当前角色个人拖动位置优先，否则全局默认位置
            if panel then
                local startPos = GetPanelDefaultPos()
                if startPos then
                    panel:ClearAllPoints()
                    panel:SetPoint(startPos.point, UIParent, startPos.point, startPos.x, startPos.y)
                end
            end
            -- 首次加载且尚无默认位置时，将当前面板位置固化为全局默认位置（仅此一次；手动拖动不会改写默认）
            if panel and not (DB.pos and DB.pos.point) then
                local point, _, _, x, y = panel:GetPoint(1)
                if point then
                    DB.pos = { point = point, x = x, y = y }
                end
            end
            -- 注意：ADDON_LOADED 阶段玩家金币/角色数据尚未完全就绪，
            -- 不得在此写入 firstTotal/每日记录/小时记录/角色快照（避免落库 0 值），
            -- 全部快照写入推迟到 PLAYER_LOGIN / PLAYER_ENTERING_WORLD
            RefreshPanel()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        playerLoggedIn = true
        Income:Start(DB.incomeSources, function()
            SyncBackup()
            if Income.Refresh then Income.Refresh() end
        end)
        if DB.autoUseQueuePendingReload == true then
            DB.autoUseQueuePendingReload = nil
        else
            DB.autoUseQueue = {}
        end
        -- 登录后再记一次（确保金币已就绪）
        -- 一次性迁移：旧版「当前角色+战团银行」口径 → 全账号口径（须在首次基准/每日记账前执行）
        MigrateAccountBase()
        EnsureFirstTotal()
        DailyRecord()
        HourlyRecord()
        UpdateRoleSnapshot()
        -- 快照当前背包：已有物品只记录不处理，后续 BAG_UPDATE_DELAYED 仅对"新进背包"的物品触发自动使用
        SnapshotBags()
        ResetAchievementBaseline()
        SyncBackup()
        RefreshPanel()
        if #DB.autoUseQueue > 0 and C_Timer and C_Timer.After then
            C_Timer.After(2, function() if ProcessAutoUseQueue then ProcessAutoUseQueue() end end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 进入世界：背包数据已就绪，重建基准快照（覆盖登录早期信息未完全就绪的快照），
        -- 此后 BAG_UPDATE_DELAYED 才真正触发自动使用，只处理"新进背包"的物品
        hasEnteredWorld = true
        SnapshotBags()
        if #DB.autoUseQueue > 0 and C_Timer and C_Timer.After then
            C_Timer.After(2, function() if ProcessAutoUseQueue then ProcessAutoUseQueue() end end)
        end
        -- 进入世界/切换地图：战团银行 API 可能尚未就绪（实时返回 0），
        -- 延迟 4 秒待 API 就绪后再更新角色快照，避免落库 bank=0 / total=0
        C_Timer.After(4, function()
            if not playerLoggedIn then return end
            UpdateRoleSnapshot()
            RefreshPanel()
        end)
        -- 立即刷新一次面板（展示当前角色数据，快照稍后延迟落库）
        RefreshPanel()
    elseif event == "PLAYER_LOGOUT" then
        Income:Stop()
        playerLoggedIn = false
        if isReloading then
            DB.autoUseQueuePendingReload = true
        else
            DB.autoUseQueue = {}
            DB.autoUseQueuePendingReload = nil
        end
        -- 退出阶段钱包 API 可能已归零；保留最近余额事件/后台采集的快照，不再取数覆盖。
        SyncBackup()
    elseif event == "PLAYER_MONEY" or event == "ACCOUNT_MONEY" then
        if not playerLoggedIn then return end
        -- 角色金币 / 战团银行金币变动：先采集最新日/小时/角色快照（快照式写入，重复事件不累加），
        -- 再刷新界面；界面隐藏不影响记账，只是不绘制
        DailyRecord()
        HourlyRecord()
        UpdateRoleSnapshot()
        RefreshPanel()
    elseif event == "PLAYER_REGEN_DISABLED" then
        panelWasVisibleBeforeCombat = panel and panel:IsShown() or false
        panelHiddenByCombat = false
        if DB.hidePanelInCombat ~= false and panelWasVisibleBeforeCombat and panel then
            panelHiddenByCombat = true
            panel:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        local wasVisibleBeforeCombat = panelWasVisibleBeforeCombat
        local shouldRestore = panelHiddenByCombat and DB.hidePanelInCombat ~= false and wasVisibleBeforeCombat
        local hadPendingAchievement = pendingAchievement
        pendingAchievement = nil
        if shouldRestore and panel then panel:Show() end
        panelHiddenByCombat = false
        if panel and panel:IsShown() then
            RefreshPanel()
            if hadPendingAchievement and panel:IsShown() and not achievementInProgress then
                StartAchievement(hadPendingAchievement.total, hadPendingAchievement.target)
            end
        end
        panelWasVisibleBeforeCombat = false
        ResumeAutoUseQueue()
    elseif event == "MERCHANT_CLOSED" or event == "MAIL_CLOSED" or event == "TRADE_CLOSED"
        or event == "BANKFRAME_CLOSED" or event == "AUCTION_HOUSE_CLOSED"
        or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        ResumeAutoUseQueue()
    elseif event == "BAG_UPDATE_DELAYED" then
        if not hasEnteredWorld then
            SnapshotBags()
        else
            TryAutoUseItems()
            if #DB.autoUseQueue > 0 and ScheduleAutoUseQueue then ScheduleAutoUseQueue(0.1) end
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_MONEY")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("ACCOUNT_MONEY")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
for _, optionalEvent in ipairs({ "MERCHANT_CLOSED", "MAIL_CLOSED", "TRADE_CLOSED", "BANKFRAME_CLOSED", "AUCTION_HOUSE_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
    pcall(eventFrame.RegisterEvent, eventFrame, optionalEvent)
end
eventFrame:SetScript("OnEvent", OnEvent)
for _, event in ipairs(Income.events) do eventFrame:RegisterEvent(event) end

-- ============ 诊断：/gtt debug ============
-- 一键把存档关键字段与实时计算值列到聊天框，方便排查"数字不对"类反馈；
-- 输出分块：基础状态 / 实时统计 / 每日记录 / 小时打点 / 角色快照 / 存档元信息
local function DebugDump()
    local today = date("%Y-%m-%d")
    local total = GetTotalGold()
    local todayGain = GetTodayGain()
    local todayAvg = GetTodayHourlyAvg()
    local recentAvg, avgSpanDays = GetNaturalDailyAvg()
    local onlineSec = GetTodayOnlineSeconds()

    print("|cff4da6ff[GoldTargetTracker]|r ===== 存档诊断 " .. today .. " =====")

    -- 基础状态
    local myRealm = GetRealmName()
    local myName = UnitName("player")
    print("当前角色：|cffffffff" .. (myName or "?") .. "|r（" .. (myRealm or "?") .. "）")
    print("计划名称：|cffffffff" .. tostring(DB.name) .. "|r    目标：|cffffd24d" .. FormatNumber(DB.target) .. "|r 金")

    -- 实时统计（全账号口径）
    print("-- 实时统计（全账号口径）--")
    print("当前总金币：|cffffd24d" .. FormatNumber(total) .. "|r 金")
    if todayGain then
        print("今日收益：|cff4dff6d" .. FormatNumber(todayGain) .. "|r 金")
    else
        print("今日收益：暂无数据")
    end
    if todayAvg then
        print("今日时均：|cff4dff6d" .. FormatNumber(math.floor(todayAvg)) .. "|r 金/小时")
    else
        print("今日时均：暂无数据")
    end
    if recentAvg then
        print("首尾日期自然日平均：|cff4dff6d" .. FormatNumber(math.floor(recentAvg)) .. "|r 金/天（统计跨度 " .. tostring(avgSpanDays or 0) .. " 天，含首尾）")
    else
        print("最近7天日均：暂无数据")
    end
    print("今日在线秒数：|cffffffff" .. FormatNumber(onlineSec) .. "|r 秒")

    -- 每日记录
    local records = GetSortedRecords()
    print("-- 每日记录（共 " .. #records .. " 条）--")
    if #records == 0 then
        print("  （无记录）")
    else
        for _, r in ipairs(records) do
            print("  " .. r.day .. " = " .. FormatNumber(r.gold) .. " 金")
        end
    end

    -- 小时打点（最近 10 条）
    local hours = {}
    for k, v in pairs(DB.hourly) do
        table.insert(hours, { k = k, v = v })
    end
    table.sort(hours, function(a, b) return a.k < b.k end)
    print("-- 小时打点（共 " .. #hours .. " 条，显示最近 10 条）--")
    local hStart = math.max(1, #hours - 9)
    for i = hStart, #hours do
        print("  " .. hours[i].k .. " = " .. FormatNumber(hours[i].v) .. " 金")
    end

    -- 角色快照
    local realmCount = 0
    for _ in pairs(DB.roles) do realmCount = realmCount + 1 end
    print("-- 角色快照（服务器 " .. realmCount .. " 个）--")
    local charCount = 0
    for realm, chars in pairs(DB.roles) do
        for name, info in pairs(chars) do
            charCount = charCount + 1
            if charCount <= 40 then
                local dt = type(info.date) == "string" and info.date or "?"
                print("  " .. realm .. " - " .. name .. " = " .. FormatNumber(info.total or 0) .. " 金（" .. dt .. "）")
            end
        end
    end
    if charCount == 0 then
        print("  （无角色快照）")
    elseif charCount > 40 then
        print("  ... 另有 " .. (charCount - 40) .. " 个角色未列出")
    end

    -- 存档元信息
    print("-- 存档元信息 --")
    print("首次基准 firstTotal：|cffffffff" .. FormatNumber(DB.firstTotal or 0) .. "|r 金")
    print("全账号口径标记 accountBase：|cffffffff" .. tostring(DB.accountBase) .. "|r")
    if type(DB.todayBase) == "table" then
        print("今日收益基准 todayBase：|cffffffff" .. FormatNumber(DB.todayBase.gold) .. "|r 金（" .. tostring(DB.todayBase.day) .. "）")
    else
        print("今日收益基准 todayBase：无（正常）")
    end
    -- 自动使用名单
    print("战斗隐藏 hidePanelInCombat：" .. tostring(DB.hidePanelInCombat))
    print("锁定窗口 lockPanel：" .. tostring(DB.lockPanel))
    print("小地图图标 showMinimapIcon：" .. tostring(DB.showMinimapIcon))
    print("自动使用待处理任务：" .. tostring(type(DB.autoUseQueue) == "table" and #DB.autoUseQueue or 0))
    print("-- 自动使用名单（最多 20 项）--")
    local items = (type(DB.autoUseItems) == "table") and DB.autoUseItems or {}
    if #items == 0 then
        print("  （空）")
    else
        for i, name in ipairs(items) do
            print("  " .. i .. ". " .. name)
        end
    end
    print("|cff4da6ff[GoldTargetTracker]|r ===== 诊断结束 =====")
end

-- ============ 命令：/gtt 与 /goldtracker ============
SLASH_GOLDTARGETTRACKER1 = "/gtt"
SLASH_GOLDTARGETTRACKER2 = "/goldtracker"
SlashCmdList["GOLDTARGETTRACKER"] = function(msg)
    msg = msg or ""
    if strtrim(msg) ~= "" then
        local arg = strlower(strtrim(msg))
        if arg == "debug" or arg == "d" or arg == "诊断" then
            DebugDump()
            return
        end
        print("|cff4da6ff[GoldTargetTracker]|r 未知命令：/gtt " .. arg .. "（支持 /gtt debug 诊断）")
        return
    end
    TogglePanel()
end

-- ============ 自动使用（设置界面分页与列表管理，新增功能） ============
local MAX_AUTO_ITEMS = 20  -- 自动使用物品名单最多保存条数
local autoUseContent = nil  -- 自动使用页控件引用（输入框 / 列表行），供刷新列表使用

-- 刷新已保存物品列表：按 DB.autoUseItems 填充固定行，多余行隐藏
local function RefreshAutoUseList()
    if not autoUseContent then return end
    local items = (type(DB.autoUseItems) == "table") and DB.autoUseItems or {}
    autoUseContent.listLabel:SetText("自动使用名单（" .. #items .. "/" .. MAX_AUTO_ITEMS .. "）")
    autoUseContent.listContent:SetHeight(math.max(36, #items * 36))
    for i, line in ipairs(autoUseContent.lines) do
        local itemName = items[i]
        if itemName then
            line.name:SetText(itemName)
            line.name:Show()
            line.removeBtn:Show()
            line.row:Show()
        else
            line.name:SetText("")
            line.name:Hide()
            line.removeBtn:Hide()
            line.row:Hide()
        end
    end
    if #items == 0 then autoUseContent.emptyHint:Show() else autoUseContent.emptyHint:Hide() end
    local scroll = autoUseContent.listScroll
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(),
        math.max(0, autoUseContent.listContent:GetHeight() - scroll:GetHeight())))
end

-- 添加物品到自动使用名单：去重 + 上限检查 + 保存备份 + 刷新列表
local function AddAutoUseItem(name)
    name = (type(name) == "string") and name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if name == "" then
        print("|cff4da6ff[GoldTargetTracker]|r 请输入物品名称")
        return
    end
    DB.autoUseItems = (type(DB.autoUseItems) == "table") and DB.autoUseItems or {}
    for _, v in ipairs(DB.autoUseItems) do
        if v == name then
            print("|cff4da6ff[GoldTargetTracker]|r 物品「" .. name .. "」已在自动使用名单中")
            return
        end
    end
    if #DB.autoUseItems >= MAX_AUTO_ITEMS then
        print("|cff4da6ff[GoldTargetTracker]|r 自动使用名单已满（最多 " .. MAX_AUTO_ITEMS .. " 项）")
        return
    end
    SnapshotBags()
    table.insert(DB.autoUseItems, name)
    SyncBackup()
    RefreshAutoUseList()
    print("|cff4da6ff[GoldTargetTracker]|r 已添加自动使用物品：「" .. name .. "」")
end

-- 按序号移除名单中的物品
local function RemoveAutoUseItem(index)
    DB.autoUseItems = (type(DB.autoUseItems) == "table") and DB.autoUseItems or {}
    local name = DB.autoUseItems[index]
    if not name then return end
    table.remove(DB.autoUseItems, index)
    SyncBackup()
    RefreshAutoUseList()
    print("|cff4da6ff[GoldTargetTracker]|r 已移除自动使用物品：「" .. name .. "」")
end

-- 清空自动使用名单
local function ClearAutoUseItems()
    DB.autoUseItems = {}
    DB.autoUseQueue = {}
    SyncBackup()
    RefreshAutoUseList()
    print("|cff4da6ff[GoldTargetTracker]|r 已清空自动使用物品名单")
end

-- 创建自动使用页内容：说明文字 + 输入框 + 确定按钮 + 已保存列表（每行移除按钮）+ 清空按钮
local function CreateAutoUseContent(containerFrame)
    local F = "Fonts\\ARIALN.TTF"
    -- 顶部说明
    local tip = containerFrame:CreateFontString(nil, "OVERLAY")
    tip:SetFont(F, 14)
    tip:SetTextColor(0.78, 0.80, 0.84)
    tip:SetPoint("TOPLEFT", containerFrame, "TOPLEFT", 16, -44)
    tip:SetPoint("TOPRIGHT", containerFrame, "TOPRIGHT", -16, -44)
    tip:SetJustifyH("LEFT")
    tip:SetText("填写与游戏内一致的物品名称。仅对新增数量尝试使用。")

    -- 物品名称输入框
    local input = CreateFrame("EditBox", nil, containerFrame, "InputBoxTemplate")
    input:SetSize(200, 30)
    input:SetFont(F, 14, "")
    input:SetPoint("TOPLEFT", containerFrame, "TOPLEFT", 16, -88)
    input:SetPoint("TOPRIGHT", containerFrame, "TOPRIGHT", -112, -88)
    input:SetAutoFocus(false)
    input:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    -- 确定按钮：把输入名称存入 DB.autoUseItems 并刷新列表
    local btnOK = CreateFrame("Button", nil, containerFrame, "UIPanelButtonTemplate")
    btnOK:SetSize(86, 30)
    btnOK:SetPoint("TOPRIGHT", containerFrame, "TOPRIGHT", -16, -88)
    btnOK:SetText("添加")
    local function AddInputItem()
        AddAutoUseItem(input:GetText())
        input:SetText("")
        input:ClearFocus()
    end
    btnOK:SetScript("OnClick", AddInputItem)
    input:SetScript("OnEnterPressed", AddInputItem)

    -- 总开关按钮：停用/启用自动使用（名单保留，随时可切换）
    local btnToggle = CreateFrame("Button", nil, containerFrame, "UIPanelButtonTemplate")
    btnToggle:SetSize(130, 26)
    btnToggle:SetPoint("TOPRIGHT", containerFrame, "TOPRIGHT", -16, -6)
    local function RefreshToggleText()
        if DB.autoUseEnabled == false then
            btnToggle:SetText("启用自动使用")
        else
            btnToggle:SetText("停用自动使用")
        end
    end
    RefreshToggleText()
    btnToggle:SetScript("OnClick", function()
        if DB.autoUseEnabled == false then
            SnapshotBags()
            DB.autoUseEnabled = true
            print("|cff4da6ff[GoldTargetTracker]|r 已启用自动使用")
        else
            SnapshotBags()
            DB.autoUseEnabled = false
            DB.autoUseQueue = {}
            print("|cff4da6ff[GoldTargetTracker]|r 已停用自动使用并清空待处理队列")
        end
        SyncBackup()
        RefreshToggleText()
    end)

    -- 已保存列表标题
    local listLabel = containerFrame:CreateFontString(nil, "OVERLAY")
    listLabel:SetFont(F, 14)
    listLabel:SetTextColor(1.0, 0.85, 0.5)
    listLabel:SetPoint("TOPLEFT", containerFrame, "TOPLEFT", 16, -140)

    -- 清空按钮：一键清空整个名单
    local btnClear = CreateFrame("Button", nil, containerFrame, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 26)
    btnClear:SetPoint("TOPRIGHT", containerFrame, "TOPRIGHT", -16, -132)
    btnClear:SetText("清空")
    btnClear:SetScript("OnClick", function()
        ClearAutoUseItems()
    end)

    local listScroll = CreateFrame("ScrollFrame", nil, containerFrame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", containerFrame, "TOPLEFT", 16, -172)
    listScroll:SetPoint("BOTTOMRIGHT", containerFrame, "BOTTOMRIGHT", -34, 16)
    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(math.max(1, listScroll:GetWidth()), 36)
    listScroll:SetScrollChild(listContent)
    listScroll:SetScript("OnSizeChanged", function(_, width)
        listContent:SetWidth(math.max(1, width))
    end)
    local emptyHint = listContent:CreateFontString(nil, "OVERLAY")
    emptyHint:SetFont(F, 14)
    emptyHint:SetTextColor(0.78, 0.80, 0.84)
    emptyHint:SetPoint("TOPLEFT", listContent, "TOPLEFT", 10, -10)
    emptyHint:SetText("尚未添加物品")

    -- 同行控件放在背景上层，名称与操作统一对齐；长名单在可用高度内滚动。
    local lines = {}
    for i = 1, MAX_AUTO_ITEMS do
        local row = CreateFrame("Frame", nil, listContent)
        row:SetHeight(34)
        row:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -(i - 1) * 36)
        row:SetPoint("TOPRIGHT", listContent, "TOPRIGHT", 0, -(i - 1) * 36)
        local background = row:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(row)
        background:SetColorTexture(0.10, 0.10, 0.12, 0.8)
        local nameLabel = row:CreateFontString(nil, "OVERLAY")
        nameLabel:SetFont(F, 14)
        nameLabel:SetTextColor(0.94, 0.94, 0.90)
        nameLabel:SetPoint("LEFT", row, "LEFT", 10, 0)
        nameLabel:SetPoint("RIGHT", row, "RIGHT", -90, 0)
        nameLabel:SetJustifyH("LEFT")
        nameLabel:SetWordWrap(false)
        nameLabel:SetText("")
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if nameLabel:GetText() == "" then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(nameLabel:GetText(), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local btnRemove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btnRemove:SetSize(70, 26)
        btnRemove:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        btnRemove:SetText("移除")
        btnRemove:SetScript("OnClick", function()
            RemoveAutoUseItem(i)
        end)

        lines[i] = { row = row, name = nameLabel, removeBtn = btnRemove }
    end

    autoUseContent = {
        input = input,
        lines = lines,
        listScroll = listScroll, listContent = listContent,
        listLabel = listLabel, emptyHint = emptyHint,
    }
    RefreshAutoUseList()
end

-- ============ 设置界面：WoW 原生风格四分类 ============
-- /gtt 主面板继续使用 CreatePanelContentV2Mini；这里只重构 Esc → 选项 → 插件设置页。
CreateSettingsPanel = function()
    local root = CreateFrame("Frame", "GoldTargetTrackerSettingsPanel", UIParent, "BackdropTemplate")
    settingsPanel = root
    root.name = DB.name or "金币攒钱计划"
    root:SetSize(770, 710)
    root:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    root:SetBackdropColor(0.035, 0.03, 0.025, 0.97)
    root:SetBackdropBorderColor(0.62, 0.47, 0.22, 1)

    local FONT = "Fonts\\ARIALN.TTF"
    local GOLD = { 1.0, 0.83, 0.38 }
    local PALE = { 0.91, 0.87, 0.76 }
    local MUTED = { 0.62, 0.62, 0.66 }
    local BLUE = { 0.38, 0.72, 1.0 }

    local function MakeText(parent, text, size, color, point, relative, relativePoint, x, y, flags)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, math.max(14, size or 14), flags or "")
        local c = color or PALE
        fs:SetTextColor(c[1], c[2], c[3])
        if point then fs:SetPoint(point, relative or parent, relativePoint or point, x or 0, y or 0) end
        fs:SetText(text or "")
        return fs
    end

    local function MakeSection(parent, title, top, height)
        parent = parent.content or parent
        local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        frame:SetSize(math.max(1, parent:GetWidth() - 8), height)
        frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, top)
        frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, top)
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0.035, 0.032, 0.027, 0.88)
        frame:SetBackdropBorderColor(0.46, 0.36, 0.19, 0.92)
        MakeText(frame, title, 13, GOLD, "TOPLEFT", frame, "TOPLEFT", 12, -8, "OUTLINE")
        return frame
    end

    local function MakeNote(parent, text, top, height)
        local note = MakeText(parent, text, 14, MUTED, "TOPLEFT", parent, "TOPLEFT", 14, top)
        note:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, top)
        note:SetJustifyH("LEFT")
        note:SetWordWrap(true)
        note:SetHeight(height)
        return note
    end

    local nav = CreateFrame("Frame", nil, root)
    nav:SetPoint("TOPLEFT", root, "TOPLEFT", 10, -12)
    nav:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 10, 12)
    nav:SetWidth(138)
    local navTitle = MakeText(nav, "金币攒钱计划", 14, GOLD, "TOPLEFT", nav, "TOPLEFT", 4, -2, "OUTLINE")

    local contentViewport = CreateFrame("Frame", nil, root)
    contentViewport:SetPoint("TOPLEFT", root, "TOPLEFT", 154, -12)
    contentViewport:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -12, 12)
    -- 固定14号正文：画布变小时滚动内容，不再缩小整页字体。
    local function CreateScrollPage(name, height)
        local page = CreateFrame("ScrollFrame", name, contentViewport, "UIPanelScrollFrameTemplate")
        page:SetPoint("TOPLEFT", contentViewport, "TOPLEFT", 0, 0)
        page:SetPoint("BOTTOMRIGHT", contentViewport, "BOTTOMRIGHT", -24, 0)
        local canvas = CreateFrame("Frame", nil, page)
        canvas:SetSize(math.max(1, page:GetWidth()), height)
        page:SetScrollChild(canvas)
        page.content = canvas
        local function FitPage()
            canvas:SetWidth(math.max(1, page:GetWidth()))
            local maxScroll = math.max(0, canvas:GetHeight() - page:GetHeight())
            page:SetVerticalScroll(math.min(page:GetVerticalScroll(), maxScroll))
        end
        page:HookScript("OnSizeChanged", FitPage)
        page:HookScript("OnShow", FitPage)
        return page
    end
    local pageGold = CreateScrollPage("GoldTargetTrackerOverviewPage", 726)
    local pageIncome = CreateScrollPage("GoldTargetTrackerIncomePage", 978)
    pageIncome:Hide()
    local pageAuto = CreateFrame("Frame", nil, contentViewport)
    pageAuto:SetAllPoints(contentViewport)
    pageAuto:Hide()
    local pageSettings = CreateScrollPage("GoldTargetTrackerOptionsPage", 988)
    pageSettings:Hide()

    local navButtons = {}
    local currentPage = pageGold
    local function StyleNavButton(btn, selected)
        if selected then
            btn:SetBackdropColor(0.22, 0.16, 0.07, 0.98)
            btn:SetBackdropBorderColor(0.92, 0.70, 0.29, 1)
            btn.label:SetTextColor(1.0, 0.91, 0.64)
        else
            btn:SetBackdropColor(0.07, 0.065, 0.055, 0.94)
            btn:SetBackdropBorderColor(0.34, 0.29, 0.21, 0.95)
            btn.label:SetTextColor(0.77, 0.74, 0.67)
        end
    end
    local function SelectPage(page, index)
        currentPage:Hide()
        currentPage = page
        currentPage:Show()
        for i, btn in ipairs(navButtons) do StyleNavButton(btn, i == index) end
        if page == pageAuto then RefreshAutoUseList() end
        if page == pageIncome and Income.Refresh then Income.Refresh() end
        if index == 1 and RefreshGoldTargetDashboard then RefreshGoldTargetDashboard() end
    end
    SelectSettingsPage = function() SelectPage(pageSettings, 4) end
    local navItems = {
        { text = "总览", page = pageGold },
        { text = "金币来源", page = pageIncome },
        { text = "自动使用", page = pageAuto },
        { text = "设置", page = pageSettings },
    }
    for i, item in ipairs(navItems) do
        local btn = CreateFrame("Button", nil, nav, "BackdropTemplate")
        btn:SetSize(132, 36)
        btn:SetPoint("TOPLEFT", nav, "TOPLEFT", 0, -28 - (i - 1) * 40)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        local label = MakeText(btn, item.text, 12, PALE, "CENTER", btn, "CENTER", 0, 0, "OUTLINE")
        btn.label = label
        btn:SetScript("OnClick", function() SelectPage(item.page, i) end)
        navButtons[i] = btn
    end

    -- ===== 总览：目标进度、收益表现、目标预测与趋势 =====
    local progressSection = MakeSection(pageGold, "目标进度", -4, 182)
    local dashboardTitle = MakeText(progressSection, DB.name or "金币攒钱计划", 14, PALE,
        "TOPLEFT", progressSection, "TOPLEFT", 14, -34, "OUTLINE")
    dashboardTitle:SetPoint("TOPRIGHT", progressSection, "TOPRIGHT", -14, -34)
    dashboardTitle:SetHeight(34)
    local totalLabel = MakeText(progressSection, "账号总金币：--", 13, GOLD,
        "TOPLEFT", progressSection, "TOPLEFT", 14, -72, "OUTLINE")
    local targetLabel = MakeText(progressSection, "当前目标：--", 11, MUTED,
        "TOPLEFT", progressSection, "TOPLEFT", 14, -96)
    local diffLabel = MakeText(progressSection, "距离目标：--", 11, PALE,
        "TOPLEFT", progressSection, "TOPLEFT", 14, -120)
    local progressBar = CreateFrame("StatusBar", nil, progressSection, "BackdropTemplate")
    progressBar:SetHeight(18)
    progressBar:SetPoint("BOTTOMLEFT", progressSection, "BOTTOMLEFT", 14, 15)
    progressBar:SetPoint("BOTTOMRIGHT", progressSection, "BOTTOMRIGHT", -14, 15)
    progressBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    progressBar:SetStatusBarColor(0.83, 0.65, 0.20, 1)
    progressBar:SetMinMaxValues(0, 1)
    progressBar:SetValue(0)
    progressBar:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 8 })
    progressBar:SetBackdropColor(0, 0, 0, 0.95)
    progressBar:SetBackdropBorderColor(0.28, 0.22, 0.12, 1)
    local progressText = MakeText(progressBar, "0.00%", 11, { 1.0, 0.94, 0.72 }, "CENTER", progressBar, "CENTER", 0, 0, "OUTLINE")

    local earningsSection = MakeSection(pageGold, "收益表现", -194, 118)
    local earnMetrics = {}
    local earnDefs = {
        { label = "今日收益", color = { 0.45, 1.0, 0.55 } },
        { label = "今日时均", color = BLUE },
        { label = "自然日平均", color = GOLD },
    }
    for i, def in ipairs(earnDefs) do
        local label = MakeText(earningsSection, def.label, 14, MUTED,
            "TOPLEFT", earningsSection, "TOPLEFT", 14, -32 - (i - 1) * 28)
        local value = MakeText(earningsSection, "--", 14, def.color,
            "TOPRIGHT", earningsSection, "TOPRIGHT", -14, -32 - (i - 1) * 28, "OUTLINE")
        earnMetrics[i] = { label = label, value = value }
    end

    local predictionSection = MakeSection(pageGold, "目标预测", -320, 168)
    local naturalForecastLabel = MakeText(predictionSection, "预计还需自然日", 11, MUTED,
        "TOPLEFT", predictionSection, "TOPLEFT", 14, -30)
    local naturalForecastValue = MakeText(predictionSection, "暂时无法估算", 14, GOLD,
        "TOPLEFT", predictionSection, "TOPLEFT", 14, -50, "OUTLINE")
    local gameForecastLabel = MakeText(predictionSection, "预计还需游戏时间", 11, MUTED,
        "TOPLEFT", predictionSection, "TOPLEFT", 14, -96)
    local gameForecastValue = MakeText(predictionSection, "暂时无法估算", 14, BLUE,
        "TOPLEFT", predictionSection, "TOPLEFT", 14, -116, "OUTLINE")
    naturalForecastValue:SetPoint("TOPRIGHT", predictionSection, "TOPRIGHT", -14, -50)
    gameForecastValue:SetPoint("TOPRIGHT", predictionSection, "TOPRIGHT", -14, -116)
    for _, value in ipairs({ naturalForecastValue, gameForecastValue }) do
        value:SetJustifyH("LEFT")
        value:SetWordWrap(true)
        value:SetHeight(40)
    end

    local trendSection = MakeSection(pageGold, "最近 7 天趋势", -496, 218)
    local legendGold = MakeText(trendSection, "● 每日总金币", 10, GOLD,
        "TOPLEFT", trendSection, "TOPLEFT", 14, -40)
    local legendGain = MakeText(trendSection, "● 每日收益", 10, BLUE,
        "TOPRIGHT", trendSection, "TOPRIGHT", -14, -40)
    local graph = CreateFrame("Frame", nil, trendSection, "BackdropTemplate")
    graph:SetSize(550, 134)
    graph:SetPoint("TOPLEFT", trendSection, "TOPLEFT", 14, -72)
    graph:SetPoint("BOTTOMRIGHT", trendSection, "BOTTOMRIGHT", -14, 12)
    graph:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
    graph:SetBackdropColor(0.012, 0.012, 0.015, 0.62)
    local graphLines = { total = {}, gain = {} }
    local graphDots = { total = {}, gain = {} }
    local dateLabels = {}
    local function MakeLineSeries(series, color)
        for i = 1, 6 do
            if graph.CreateLine then
                local line = graph:CreateLine(nil, "ARTWORK")
                line:SetThickness(2)
                line:SetColorTexture(color[1], color[2], color[3], 0.95)
                graphLines[series][i] = line
            end
        end
        for i = 1, 7 do
            local dot = CreateFrame("Button", nil, graph)
            dot:SetSize(8, 8)
            dot:SetFrameLevel(graph:GetFrameLevel() + 4)
            local tex = dot:CreateTexture(nil, "OVERLAY")
            tex:SetAllPoints(dot)
            tex:SetTexture("Interface\\Buttons\\WHITE8x8")
            tex:SetVertexColor(color[1], color[2], color[3], 1)
            dot.texture = tex
            dot:SetScript("OnEnter", function(self)
                local point = self.pointData
                if not point then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddDoubleLine("当日收益", FormatNumber(point.gain) .. " 金", 0.78, 0.78, 0.78, 0.45, 0.72, 1.0)
                GameTooltip:AddDoubleLine("当日总金币", FormatNumber(point.gold) .. " 金", 0.78, 0.78, 0.78, 1.0, 0.83, 0.38)
                GameTooltip:Show()
            end)
            dot:SetScript("OnLeave", function() GameTooltip:Hide() end)
            graphDots[series][i] = dot
        end
    end
    MakeLineSeries("total", GOLD)
    MakeLineSeries("gain", BLUE)
    for i = 1, 7 do
        dateLabels[i] = MakeText(graph, "", 8, MUTED, "BOTTOM", graph, "BOTTOMLEFT", 0, 1)
        dateLabels[i]:SetJustifyH("CENTER")
    end

    local roleSection = MakeSection(pageIncome, "角色资产", -798, 168)
    local expandRoles = CreateFrame("Button", nil, roleSection, "UIPanelButtonTemplate")
    expandRoles:SetSize(100, 26)
    expandRoles:SetPoint("TOPRIGHT", roleSection, "TOPRIGHT", -12, -6)
    expandRoles:SetText("展开全部")
    local roleContent = CreateFrame("Frame", nil, roleSection)
    roleContent:SetPoint("TOPLEFT", roleSection, "TOPLEFT", 14, -36)
    roleContent:SetPoint("TOPRIGHT", roleSection, "TOPRIGHT", -14, -36)
    roleContent:SetHeight(1)
    local roleRows = {}
    local rolesExpanded = false
    local function EnsureRoleRow(index)
        if roleRows[index] then return roleRows[index] end
        local row = CreateFrame("Frame", nil, roleContent)
        row:SetHeight(24)
        row:SetPoint("TOPLEFT", roleContent, "TOPLEFT", 0, -(index - 1) * 24)
        row:SetPoint("TOPRIGHT", roleContent, "TOPRIGHT", 0, -(index - 1) * 24)
        row.name = MakeText(row, "", 11, PALE, "LEFT", row, "LEFT", 2, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -150, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.gold = MakeText(row, "", 11, GOLD, "RIGHT", row, "RIGHT", -8, 0)
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(row.name:GetText(), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        roleRows[index] = row
        return row
    end
    expandRoles:SetScript("OnClick", function()
        rolesExpanded = not rolesExpanded
        expandRoles:SetText(rolesExpanded and "收起列表" or "展开全部")
        if RefreshGoldTargetDashboard then RefreshGoldTargetDashboard() end
    end)

    -- ===== 自动使用页：保留原有名单管理能力，并使用统一的暗色金属分区背景 =====
    local autoSection = MakeSection(pageAuto, "自动使用", -4, 660)
    autoSection:SetPoint("BOTTOMRIGHT", pageAuto, "BOTTOMRIGHT", -4, 4)
    CreateAutoUseContent(autoSection)

    -- ===== 设置页中的战斗隐藏设置 =====
    local interfaceSection = MakeSection(pageSettings, "战斗隐藏", -738, 238)
    MakeText(interfaceSection, "战斗期间自动隐藏金币目标主面板", 13, PALE,
        "TOPLEFT", interfaceSection, "TOPLEFT", 14, -38, "OUTLINE")
    MakeNote(interfaceSection, "开启后，战斗中不允许通过 /gtt 打开；脱离战斗后仅恢复战斗前已打开的面板。", -68, 66)
    combatCheckbox = CreateFrame("CheckButton", nil, interfaceSection, "UICheckButtonTemplate")
    combatCheckbox:SetPoint("TOPLEFT", interfaceSection, "TOPLEFT", 14, -146)
    combatCheckbox:SetChecked(DB.hidePanelInCombat ~= false)
    local combatCheckboxLabel = MakeText(interfaceSection, "启用战斗中自动隐藏（默认开启）", 12, GOLD,
        "TOPLEFT", interfaceSection, "TOPLEFT", 48, -138)
    combatCheckboxLabel:SetPoint("TOPRIGHT", interfaceSection, "TOPRIGHT", -14, -138)
    combatCheckboxLabel:SetJustifyH("LEFT")
    combatCheckboxLabel:SetHeight(42)
    combatCheckbox:SetScript("OnClick", function(self)
        SetCombatHidden(self:GetChecked() and true or false)
    end)
    MakeNote(interfaceSection, "小地图金币按钮与 /gtt 命令继续保留。", -184, 42)

    -- ===== 设置页：目标金额、插件名称、数据维护纵向分区 =====
    local targetSection = MakeSection(pageSettings, "目标金额", -4, 232)
    MakeNote(targetSection, "选择预设目标，或输入自定义金币金额。修改目标本身不会触发达标庆祝。", -34, 48)
    local customTarget
    local function SetTarget(value)
        if type(value) ~= "number" or value <= 0 or value ~= value then return end
        DB.target = math.floor(value)
        customTarget:SetText(tostring(DB.target))
        customTarget:ClearFocus()
        if ResetAchievementBaseline then ResetAchievementBaseline() end
        SyncBackup()
        RefreshPanel()
    end
    local target500 = CreateFrame("Button", nil, targetSection, "UIPanelButtonTemplate")
    target500:SetSize(150, 30)
    target500:SetPoint("TOPLEFT", targetSection, "TOPLEFT", 14, -86)
    target500:SetPoint("TOPRIGHT", targetSection, "TOPRIGHT", -14, -86)
    target500:SetText("坐骑本体（500万）")
    target500:SetScript("OnClick", function() SetTarget(5000000) end)
    local target700 = CreateFrame("Button", nil, targetSection, "UIPanelButtonTemplate")
    target700:SetSize(190, 30)
    target700:SetPoint("TOPLEFT", targetSection, "TOPLEFT", 14, -120)
    target700:SetPoint("TOPRIGHT", targetSection, "TOPRIGHT", -14, -120)
    target700:SetText("坐骑 + 全部额外NPC（700万）")
    target700:SetScript("OnClick", function() SetTarget(7000000) end)
    customTarget = CreateFrame("EditBox", nil, targetSection, "InputBoxTemplate")
    customTarget:SetSize(150, 24)
    customTarget:SetFont(FONT, 14, "")
    customTarget:SetAutoFocus(false)
    customTarget:SetPoint("TOPLEFT", targetSection, "TOPLEFT", 14, -162)
    customTarget:SetNumeric(true)
    customTarget:SetMaxLetters(12)
    customTarget:SetText(tostring(DB.target))
    customTarget:SetScript("OnEscapePressed", function(self) self:SetText(tostring(DB.target)); self:ClearFocus() end)
    customTarget:SetScript("OnEnterPressed", function(self)
        local value = tonumber(self:GetText())
        if value and value > 0 then SetTarget(value) else print("|cffff4040[GoldTargetTracker]|r 自定义目标必须是大于 0 的金币数。") end
        self:SetText(tostring(DB.target))
        self:ClearFocus()
    end)
    MakeNote(targetSection, "自定义金额（输入后按回车保存）", -194, 24)

    local nameSection = MakeSection(pageSettings, "插件名称", -244, 226)
    MakeNote(nameSection, "可选预设名称，也可以使用自定义名称。", -34, 40)
    local nameA = CreateFrame("Button", nil, nameSection, "UIPanelButtonTemplate")
    nameA:SetSize(150, 30)
    nameA:SetPoint("TOPLEFT", nameSection, "TOPLEFT", 14, -78)
    nameA:SetPoint("TOPRIGHT", nameSection, "TOPRIGHT", -14, -78)
    nameA:SetText("金币攒钱计划")
    local nameB = CreateFrame("Button", nil, nameSection, "UIPanelButtonTemplate")
    nameB:SetSize(150, 30)
    nameB:SetPoint("TOPLEFT", nameSection, "TOPLEFT", 14, -112)
    nameB:SetPoint("TOPRIGHT", nameSection, "TOPRIGHT", -14, -112)
    nameB:SetText("金币目标追踪")
    local customName = CreateFrame("EditBox", nil, nameSection, "InputBoxTemplate")
    customName:SetSize(220, 24)
    customName:SetFont(FONT, 14, "")
    customName:SetAutoFocus(false)
    customName:SetPoint("TOPLEFT", nameSection, "TOPLEFT", 14, -154)
    customName:SetPoint("TOPRIGHT", nameSection, "TOPRIGHT", -14, -154)
    customName:SetMaxLetters(48)
    customName:SetText(DB.name or "金币攒钱计划")
    local function SetName(value)
        value = type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if value == "" then return end
        DB.name = value
        root.name = value
        if settingsCategory then pcall(function() settingsCategory.name = value end) end
        customName:SetText(value)
        if dashboardTitle then dashboardTitle:SetText(value) end
        SyncBackup()
        RefreshPanel()
    end
    nameA:SetScript("OnClick", function() SetName("金币攒钱计划") end)
    nameB:SetScript("OnClick", function() SetName("金币目标追踪") end)
    customName:SetScript("OnEscapePressed", function(self) self:SetText(DB.name or "金币攒钱计划"); self:ClearFocus() end)
    customName:SetScript("OnEnterPressed", function(self) SetName(self:GetText()); self:ClearFocus() end)
    MakeNote(nameSection, "自定义名称（输入后按回车保存）", -186, 26)

    local maintenanceSection = MakeSection(pageSettings, "数据维护", -478, 252)
    MakeNote(maintenanceSection, "重置前会再次确认；角色金币快照与角色位置会按现有规则保留。", -34, 48)
    local resetStat = CreateFrame("Button", nil, maintenanceSection, "UIPanelButtonTemplate")
    resetStat:SetSize(130, 30)
    resetStat:SetPoint("TOPLEFT", maintenanceSection, "TOPLEFT", 14, -86)
    resetStat:SetPoint("TOPRIGHT", maintenanceSection, "TOPRIGHT", -14, -86)
    resetStat:SetText("重置统计")
    resetStat:SetScript("OnClick", function() StaticPopup_Show("GOLDTT_RESET_STAT") end)
    local resetAll = CreateFrame("Button", nil, maintenanceSection, "UIPanelButtonTemplate")
    resetAll:SetSize(130, 30)
    resetAll:SetPoint("TOPLEFT", maintenanceSection, "TOPLEFT", 14, -120)
    resetAll:SetPoint("TOPRIGHT", maintenanceSection, "TOPRIGHT", -14, -120)
    resetAll:SetText("重置所有")
    resetAll:SetScript("OnClick", function() StaticPopup_Show("GOLDTT_RESET_ALL") end)
    MakeNote(maintenanceSection, "重置统计：重新累计今日收益。\n重置所有：清除每日/小时历史及累计来源收入，并重新建立统计起点。", -162, 78)
    for _, button in ipairs({ target500, target700, nameA, nameB, resetStat, resetAll, expandRoles }) do
        button:GetFontString():SetFont(FONT, 14, "")
    end

    -- 图表点位与角色列表每次刷新只更新现有控件，不重复创建线条或行。
    local function UpdateSeries(seriesName, values, color, minY, maxY)
        local left, right = 24, math.max(24, graph:GetWidth() - 24)
        local bottom, top = 28, math.max(28, graph:GetHeight() - 12)
        local span = maxY - minY
        if span <= 0 then span = 1 end
        local positions = {}
        for i, value in ipairs(values) do
            local x = left + (right - left) * (i - 1) / 6
            local y = bottom + (top - bottom) * (value - minY) / span
            positions[i] = { x = x, y = y }
            local dot = graphDots[seriesName][i]
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", graph, "BOTTOMLEFT", x, y)
            dot:Show()
        end
        for i = 1, 6 do
            local line = graphLines[seriesName][i]
            if line then
                line:ClearAllPoints()
                line:SetStartPoint("BOTTOMLEFT", graph, positions[i].x, positions[i].y)
                line:SetEndPoint("BOTTOMLEFT", graph, positions[i + 1].x, positions[i + 1].y)
                line:SetThickness(2)
                line:SetColorTexture(color[1], color[2], color[3], 0.95)
                line:Show()
            end
        end
    end

    RefreshGoldTargetDashboard = function()
        target500:SetEnabled(DB.target ~= 5000000)
        target700:SetEnabled(DB.target ~= 7000000)
        local total = GetTotalGold()
        local need = (DB.target or DEFAULT_TARGET) - total
        local pctRaw = DB.target and DB.target > 0 and total / DB.target or 0
        local pct = math.max(0, math.min(1, pctRaw))
        local todayGain = GetTodayGain() or 0
        local todayAvg = GetTodayHourlyAvg()
        local naturalAvg, spanDays = GetNaturalDailyAvg()
        local preliminary = (spanDays or 0) < 7

        dashboardTitle:SetText(DB.name or "金币攒钱计划")
        totalLabel:SetText("账号总金币：" .. FormatNumber(total) .. " 金")
        targetLabel:SetText("当前目标：" .. FormatNumber(DB.target) .. " 金")
        if need > 0 then
            diffLabel:SetText("距离目标：" .. FormatNumber(need) .. " 金")
        else
            diffLabel:SetText("距离目标：已达成")
        end
        progressBar:SetValue(pct)
        progressText:SetText(FormatProgress(total, DB.target))

        earnMetrics[1].value:SetText(FormatGain(todayGain) .. " 金")
        earnMetrics[2].value:SetText(todayAvg and FormatNumber(math.floor(todayAvg)) .. " 金/小时" or "暂时无法估算")
        earnMetrics[3].value:SetText(naturalAvg and FormatGain(math.floor(naturalAvg)) .. " 金/天" or "暂时无法估算")

        if need <= 0 then
            naturalForecastValue:SetText("已达标")
            gameForecastValue:SetText("已达标")
        else
            if naturalAvg and naturalAvg > 0 then
                local days = math.ceil(need / naturalAvg)
                naturalForecastValue:SetText(FormatMonthsDays(days) .. (preliminary and "（初步估算）" or ""))
            else
                naturalForecastValue:SetText("暂时无法估算")
            end
            local onlineSec = GetTodayOnlineSeconds()
            if todayGain > 0 and onlineSec > 0 then
                local remainSec = (need / todayGain) * onlineSec
                gameForecastValue:SetText(FormatCountdown(remainSec) .. (preliminary and "（初步估算）" or ""))
            else
                gameForecastValue:SetText(todayGain <= 0 and "今日暂无正收益" or "正在采集时长")
            end
        end

        local chartData = GetRecent7DayData()
        local totalValues, gainValues = {}, {}
        local totalMin, totalMax, gainMin, gainMax = math.huge, -math.huge, math.huge, -math.huge
        for i, point in ipairs(chartData) do
            totalValues[i] = point.gold
            gainValues[i] = point.gain
            totalMin = math.min(totalMin, point.gold)
            totalMax = math.max(totalMax, point.gold)
            gainMin = math.min(gainMin, point.gain)
            gainMax = math.max(gainMax, point.gain)
            dateLabels[i]:SetText(point.day:sub(6))
            dateLabels[i]:ClearAllPoints()
            dateLabels[i]:SetPoint("BOTTOM", graph, "BOTTOMLEFT", 24 + math.max(0, graph:GetWidth() - 48) * (i - 1) / 6, 1)
            dateLabels[i]:SetShown(graph:GetWidth() >= 400 or i % 2 == 1)
            graphDots.total[i].pointData = point
            graphDots.gain[i].pointData = point
        end
        if totalMin == totalMax then totalMin, totalMax = totalMin - 1, totalMax + 1 end
        if gainMin == gainMax then gainMin, gainMax = gainMin - 1, gainMax + 1 end
        UpdateSeries("total", totalValues, GOLD, totalMin, totalMax)
        UpdateSeries("gain", gainValues, BLUE, gainMin, gainMax)

        local allRows = GetAllRoleRows()
        local visibleCount = rolesExpanded and #allRows or math.min(5, #allRows)
        roleContent:SetHeight(math.max(24, visibleCount * 24))
        roleSection:SetHeight(48 + math.max(1, visibleCount) * 24)
        pageIncome.content:SetHeight(798 + roleSection:GetHeight() + 12)
        pageIncome:SetVerticalScroll(math.max(0, math.min(pageIncome:GetVerticalScroll(), pageIncome.content:GetHeight() - pageIncome:GetHeight())))
        for i = 1, visibleCount do
            local rowData = allRows[i]
            local row = EnsureRoleRow(i)
            row.name:SetPoint("RIGHT", row, "RIGHT", -150, 0)
            row.name:SetText(rowData.name)
            row.name:SetTextColor(rowData.isMe and 0.45 or PALE[1], rowData.isMe and 1.0 or PALE[2], rowData.isMe and 0.55 or PALE[3])
            row.gold:SetText(FormatNumber(rowData.gold) .. " 金")
            row:Show()
        end
        for i = visibleCount + 1, #roleRows do roleRows[i]:Hide() end
        if #allRows > 5 then
            expandRoles:Show()
            expandRoles:SetText(rolesExpanded and "收起列表" or "展开全部")
        else
            expandRoles:Hide()
        end
        if #allRows == 0 then
            local row = EnsureRoleRow(1)
            row.name:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            row.name:SetText("暂无金币大于 0 的角色记录")
            row.name:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
            row.gold:SetText("")
            row:Show()
        end
    end

    -- 收入独立于余额净收益，只展示启用后实际到账的累计金额。
    graph:SetScript("OnSizeChanged", function() RefreshGoldTargetDashboard() end)

    local incomeHeader = MakeSection(pageIncome, "累计到账收入", 0, 138)
    local incomeTotal = MakeText(incomeHeader, "", 18, GOLD, "TOPLEFT", incomeHeader, "TOPLEFT", 14, -34)
    incomeTotal:SetPoint("TOPRIGHT", incomeHeader, "TOPRIGHT", -14, -34)
    incomeTotal:SetWordWrap(false)
    local incomeStarted = MakeText(incomeHeader, "", 12, PALE, "TOPLEFT", incomeHeader, "TOPLEFT", 14, -60)
    MakeNote(incomeHeader, "累计到账收入，不等于净利润；银行存取不计入。", -88, 40)
    local incomeSection = MakeSection(pageIncome, "来源构成", -146, 532)
    local incomeRows = {}
    for i, category in ipairs(Income.categories) do
        local top = -34 - (i - 1) * 56
        local name = MakeText(incomeSection, category.label, 14, PALE, "TOPLEFT", incomeSection, "TOPLEFT", 14, top)
        local amount = MakeText(incomeSection, "", 14, GOLD, "TOPLEFT", incomeSection, "TOPLEFT", 14, top - 22)
        amount:SetPoint("TOPRIGHT", incomeSection, "TOPRIGHT", -14, top - 22)
        amount:SetJustifyH("LEFT")
        amount:SetWordWrap(false)
        local percent = MakeText(incomeSection, "", 12, MUTED, "TOPRIGHT", incomeSection, "TOPRIGHT", -14, top)
        local bar = CreateFrame("StatusBar", nil, incomeSection)
        bar:SetPoint("TOPLEFT", incomeSection, "TOPLEFT", 14, top - 44)
        bar:SetPoint("TOPRIGHT", incomeSection, "TOPRIGHT", -14, top - 44)
        bar:SetHeight(6)
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        bar:SetStatusBarColor(0.95, 0.73, 0.22)
        bar:SetMinMaxValues(0, 1)
        incomeRows[i] = { amount = amount, percent = percent, bar = bar }
    end
    local incomeEmpty = MakeNote(incomeSection, "尚无收入；获得金币后自动累计，旧历史无法追溯。", -488, 34)
    local incomeNotes = MakeSection(pageIncome, "统计说明", -686, 104)
    MakeNote(incomeNotes, "邮件和交易均计入；小号转钱也会再次累计。拍卖按实际领款金额统计。", -34, 58)
    local function IncomeMoney(copper)
        return FormatNumber(math.floor(copper / 10000)) .. " 金 "
            .. math.floor(copper / 100) % 100 .. " 银 " .. copper % 100 .. " 铜"
    end
    Income.Refresh = function()
        local data, total = DB.incomeSources, Income.Total(DB.incomeSources)
        incomeTotal:SetText(IncomeMoney(total))
        incomeStarted:SetText("开始统计：" .. date("%Y-%m-%d %H:%M", data.startedAt))
        for i, category in ipairs(Income.categories) do
            local amount = data.totals[category.key] or 0
            local share = total > 0 and amount / total or 0
            incomeRows[i].amount:SetText(IncomeMoney(amount))
            incomeRows[i].percent:SetText(string.format("%.2f%%", share * 100))
            incomeRows[i].bar:SetValue(share)
        end
        incomeEmpty:SetShown(total == 0)
    end
    Income.Refresh()

    -- 导航按钮初始化完成后，默认选中总览页。
    for i, btn in ipairs(navButtons) do StyleNavButton(btn, i == 1) end
    pageGold:Show()
    if RefreshGoldTargetDashboard then RefreshGoldTargetDashboard() end
    return root
end

-- ============ 常驻定时刷新 ============
-- 原 OnUpdate 挂在主面板上，主面板隐藏时不会触发，因此把定时刷新挂到常驻 frame（无父级、默认显示）。
-- 记账与绘制分离：日/小时快照每秒采集，与主界面、设置界面是否可见无关（两个面板都隐藏时照样记账）；
-- 可见性只决定是否重绘界面。存档冲突/损坏导致暂停（dataReady=false）时不采集、不绘制。
local tickerFrame = CreateFrame("Frame")
tickerFrame:SetScript("OnUpdate", function(self, e)
    if not dataReady or not playerLoggedIn then return end
    elapsed = elapsed + e
    if elapsed >= 1 then
        elapsed = 0
        -- 小时快照：每次覆盖写当前小时键，跨小时自然新增并保留最近 MAX_HOURLY 条
        HourlyRecord()
        -- 日结快照：records[day] 持续更新为最新观测总金币；
        -- 重置统计/重置所有删除了 records[today] 后，下一个轮询即重新写入，
        -- 保证"最近 7 天"列表在重置后仍包含今天行并显示实时收益
        DailyRecord()
        if CheckAchievementCrossing then CheckAchievementCrossing(GetTotalGold()) end
        -- 清理过期"今日收益基准"：必须独立于界面可见性，
        -- 否则两个面板都隐藏时跨过午夜，旧基准会继续压制新一天的收益计算
        if type(DB.todayBase) == "table" and DB.todayBase.day ~= date("%Y-%m-%d") then
            DB.todayBase = nil
        end
        -- 绘制：仅当主界面或设置界面可见时刷新两份内容
        if (panel and panel:IsShown()) or (settingsPanel and settingsPanel:IsShown()) then
            RefreshPanel()
        end
    end
    -- 自动使用新增任务由 BAG_UPDATE_DELAYED 检测；队列处理使用独立的有限重试计时器，
    -- 不会把普通背包轮询当作“新获得物品”。
end)
