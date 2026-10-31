local _, addon = ...
local Cycle = {limit = 20, recycleRecipe = 1229930, profession = 202}
addon.Cycle = Cycle

local function PositiveID(value)
    return type(value) == "number" and value > 0 and value < 2147483647 and value == math.floor(value)
end

function Cycle:NewData()
    return {version = 1, enabled = true,
        recycle = {{id = 239700, name = "光明亚麻布卷"}, {id = 239701, name = "光明亚麻布卷"}},
        craft = {{id = 1229866, name = "永恒之核腕扣"}},
        disenchant = {{id = 245341, name = "永恒之核腕扣"}}}
end

function Cycle:Valid(data)
    if type(data) ~= "table" or data.version ~= 1 or type(data.enabled) ~= "boolean" then return false end
    for _, kind in ipairs({"recycle", "craft", "disenchant"}) do
        local list, seen, length = data[kind], {}, 0
        if type(list) ~= "table" or #list > self.limit then return false end
        for key, entry in pairs(list) do
            if not PositiveID(key) or key > #list or type(entry) ~= "table"
                or not PositiveID(entry.id) or type(entry.name) ~= "string" or seen[entry.id] then return false end
            seen[entry.id] = true
            length = length + 1
        end
        if length ~= #list then return false end
    end
    return true
end

function Cycle:Status(message)
    if self.lastMessage ~= message then
        print("|cff4da6ff[金币进度条·专业循环]|r " .. message)
        self.lastMessage = message
    end
    if self.ui then self.ui.message:SetText(message); self:RefreshSettings() end
end

function Cycle:IsBusy()
    return UnitCastingInfo("player") or UnitChannelInfo("player")
        or (self.batch and GetTime() < self.batch.deadline)
end

function Cycle:CanEdit()
    if not self.data then return false, "循环设置异常，已保留原数据，暂不可修改。" end
    if InCombatLockdown() then return false, "请脱战后修改列表。" end
    if self:IsBusy() then return false, "请先停止当前回收、制造或分解，再修改列表。" end
    return true
end

function Cycle:Add(kind, input)
    local ok, reason = self:CanEdit()
    if not ok then return false, reason end
    local list = self.data[kind]
    if type(list) ~= "table" then return false, "列表类型无效。" end
    local text = tostring(input or ""):match("^%s*(.-)%s*$")
    local id = tonumber(text) or tonumber(text:match(kind == "craft" and "enchant:(%d+)" or "item:(%d+)"))
    if kind ~= "craft" and not id and C_Item.GetItemInfoInstant then id = C_Item.GetItemInfoInstant(text) end
    if not PositiveID(id) then return false, kind == "craft" and "请填写配方编号，或添加当前工程配方。" or "请拖入背包物品，或填写物品名称、链接或编号。" end
    for _, entry in ipairs(list) do if entry.id == id then return false, "列表中已有这一项。" end end
    if #list >= self.limit then return false, "每个列表最多保存 " .. self.limit .. " 项。" end
    local name
    if kind == "craft" then
        local info = C_TradeSkillUI.GetRecipeInfo(id)
        if not info or not info.learned then return false, "请先打开工程学，选择已学会的制造配方。" end
        local profession = C_TradeSkillUI.GetProfessionInfoByRecipeID(id)
        if not profession or (profession.parentProfessionID or profession.professionID) ~= self.profession
            or info.isRecraft or info.isSalvageRecipe or info.isEnchantingRecipe or info.isGatheringRecipe
            or info.isDummyRecipe or info.disabled then return false, "制造列表只接受已学会的工程物品配方。" end
        name = info.name
    else
        name = C_Item.GetItemInfo(id)
        if not name then
            C_Item.RequestLoadItemDataByID(id)
            return false, "物品信息尚未就绪，请稍后再点添加。"
        end
        if kind == "recycle" then
            local allowed = C_TradeSkillUI.GetSalvagableItemIDs(self.recycleRecipe)
            if not allowed or #allowed == 0 then return false, "请先打开工程学的循环回收配方，再添加材料。" end
            local found = false
            for _, itemID in ipairs(allowed) do if itemID == id then found = true; break end end
            if not found then return false, "这件物品不在循环回收配方的材料范围内。" end
        end
    end
    if type(name) ~= "string" or name == "" then return false, "名称尚未加载，请稍后重试。" end
    list[#list + 1] = {id = id, name = name}
    if self.RefreshSettings then self:RefreshSettings() end
    return true, "已添加：" .. name
end

function Cycle:Remove(kind, index)
    local ok, reason = self:CanEdit()
    if not ok then return false, reason end
    local list = self.data[kind]
    if not list or not PositiveID(index) or not list[index] then return false, "该条目已不存在。" end
    table.remove(list, index)
    if self.RefreshSettings then self:RefreshSettings() end
    return true, "已移除；下一次触发按当前列表执行。"
end

function Cycle:SetEnabled(enabled)
    local ok, reason = self:CanEdit()
    if not ok then return false, reason end
    self.data.enabled = enabled == true
    if self.RefreshSettings then self:RefreshSettings() end
    return true, self.data.enabled and "专业循环已启用。" or "专业循环已停用，列表保留。"
end

function Cycle:EnsureMacro()
    if InCombatLockdown() then self.macroPending = true; return end
    self.macroPending = false
    local name, _, body = GetMacroInfo("安迪循环")
    local expected = "/stopmacro [combat]\n/click AndyCraftCycleButton"
    if name then
        if (body or ""):gsub("\r", ""):match("^%s*(.-)%s*$") ~= expected then
            self:Status("已有不同内容的“安迪循环”宏，已保留。改名后再点创建宏。")
        else self:Status("“安迪循环”宏已就绪，在 /m 的角色专用或通用宏页找到后拖到动作条。") end
        return
    end
    local _, count = GetNumMacros()
    local limit = Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS or MAX_CHARACTER_MACROS
    if not limit or count >= limit then self:Status("角色宏位不足或容量未知，请留出一个空位后再创建。"); return end
    local ok, index = pcall(CreateMacro, "安迪循环", 134400, expected, true)
    if not ok or not index or index == 0 then self:Status("创建宏失败：" .. tostring(index)); return end
    self:Status("已创建角色专用宏“安迪循环”，输入 /m 拖到动作条即可。")
end

function Cycle:Initialize()
    if self.initialized then return end
    self.initialized = true
    if GoldTargetTrackerCycleData == nil then GoldTargetTrackerCycleData = self:NewData() end
    if self:Valid(GoldTargetTrackerCycleData) then self.data = GoldTargetTrackerCycleData
    else self:Status("循环设置结构异常，原数据已保留，循环功能暂停。") end
    self.waitUntil, self.lootOpen = 0, false
    local watcher = CreateFrame("Frame")
    self.watcher = watcher
    watcher:SetScript("OnEvent", function(_, event, unit) self:OnEvent(event, unit) end)
    for _, event in ipairs({"PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "LOOT_OPENED", "LOOT_CLOSED",
        "BAG_UPDATE_DELAYED", "UPDATE_TRADESKILL_CAST_STOPPED"}) do watcher:RegisterEvent(event) end
    for _, event in ipairs({"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED"}) do watcher:RegisterUnitEvent(event, "player") end
    self:CreateButton()
end
