local _, addon = ...
local Cycle = addon.Cycle

function Cycle:Inventory()
    local items, free = {}, 0
    for bag = 0, 5 do
        local slots, family = C_Container.GetContainerNumFreeSlots(bag)
        if family == 0 then free = free + (slots or 0) end
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and not info.isLocked then
                items[#items + 1] = {id = info.itemID, count = info.stackCount, bag = bag, slot = slot}
            end
        end
    end
    local function Find(list, minimum)
        for _, entry in ipairs(list) do
            for _, item in ipairs(items) do
                if entry.id == item.id and item.count >= minimum then return item end
            end
        end
    end
    return Find(self.data.disenchant, 1), Find(self.data.recycle, 5), free
end

function Cycle:Step(button, mouseButton, down)
    if InCombatLockdown() then return end
    button:SetAttribute("type", nil)
    button:SetAttribute("target-bag", nil)
    button:SetAttribute("target-slot", nil)
    if down or mouseButton ~= "LeftButton" or not self.data or not self.data.enabled then return end
    local now = GetTime()
    if self:IsBusy() or self.lootOpen or GetCursorInfo() or SpellIsTargeting() or now < self.waitUntil then return end
    -- shortcut: the stop event is primary; 3 quiet seconds recover a lost event, pending live latency testing.
    self.batch = nil
    local target, material, free = self:Inventory()
    if target then
        button:SetAttribute("target-bag", target.bag)
        button:SetAttribute("target-slot", target.slot)
        button:SetAttribute("type", "spell")
        self.waitUntil = now + 0.75
        self:Status("分解列表中的物品")
        return
    end
    if not material and #self.data.craft == 0 then self:Status("没有可处理的物品或制造配方。"); return end
    if free < 3 then self:Status("普通背包至少留 3 个空格，再继续回收或制造。"); return end
    local profession = C_TradeSkillUI.GetBaseProfessionInfo()
    if not profession or profession.professionID ~= self.profession then
        C_TradeSkillUI.OpenTradeSkill(self.profession)
        self.waitUntil = now + 0.75
        self:Status("打开工程学；下次触发继续。")
        return
    end
    if material then
        local info = C_TradeSkillUI.GetRecipeInfo(self.recycleRecipe)
        if not info or not info.learned or info.disabled then self:Status("循环回收配方尚未就绪或未学会。"); return end
        local eligible = false
        for _, id in ipairs(C_TradeSkillUI.GetSalvagableItemIDs(self.recycleRecipe) or {}) do
            if id == material.id then eligible = true; break end
        end
        if not eligible then self:Status("当前材料不能循环回收或配方未加载，请检查回收列表。"); return end
        self.batch = {deadline = now + 3}
        self.waitUntil = now + 0.75
        self:Status("批量回收当前材料堆叠")
        C_TradeSkillUI.CraftSalvage(self.recycleRecipe, math.floor(material.count / 5),
            ItemLocation:CreateFromBagAndSlot(material.bag, material.slot))
        return
    end
    for _, entry in ipairs(self.data.craft) do
        local info = C_TradeSkillUI.GetRecipeInfo(entry.id)
        local professionInfo = info and C_TradeSkillUI.GetProfessionInfoByRecipeID(entry.id)
        if info and info.learned and not info.disabled and not info.isRecraft and not info.isSalvageRecipe
            and not info.isEnchantingRecipe and not info.isGatheringRecipe and not info.isDummyRecipe
            and professionInfo and (professionInfo.parentProfessionID or professionInfo.professionID) == self.profession then
            local schematic = C_TradeSkillUI.GetRecipeSchematic(entry.id, false)
            if schematic and schematic.quantityMax and schematic.quantityMax >= 1 then
                local count = math.min(C_TradeSkillUI.GetCraftableCount(entry.id) or 0,
                    math.floor((free - 2) / schematic.quantityMax))
                if info.canCreateMultiple == false then count = math.min(count, 1) end
                if count > 0 then
                    self.batch = {deadline = now + 3}
                    self.waitUntil = now + 0.75
                    self:Status("批量制造：" .. entry.name)
                    C_TradeSkillUI.CraftRecipe(entry.id, count)
                    return
                end
            end
        end
    end
    self:Status("没有可制造的配方：请检查材料、配方和背包空间。")
end

function Cycle:CreateButton()
    if InCombatLockdown() then self.buttonPending = true; return end
    self.buttonPending = false
    -- Keep the existing macro target. OptionalDeps loads the old addon first; replace its handlers once.
    local button = _G.AndyCraftCycleButton or CreateFrame("Button", "AndyCraftCycleButton", UIParent,
        "SecureActionButtonTemplate,SecureHandlerStateTemplate")
    button:UnregisterAllEvents()
    button:SetScript("OnEvent", nil)
    button:SetAttribute("type", nil)
    button:SetAttribute("target-bag", nil)
    button:SetAttribute("target-slot", nil)
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("useOnKeyDown", false)
    button:SetAttribute("spell", 13262)
    button:SetAttribute("_onstate-combat", [[
        if newstate == "combat" then
            self:SetAttribute("type", nil)
            self:SetAttribute("target-bag", nil)
            self:SetAttribute("target-slot", nil)
        end
    ]])
    RegisterStateDriver(button, "combat", "[combat] combat; safe")
    button:SetScript("PreClick", function(...) self:Step(...) end)
    self.button = button
end

function Cycle:OnEvent(event, unit)
    local now = GetTime()
    if event == "PLAYER_LOGIN" then self:EnsureMacro()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if self.buttonPending then self:CreateButton() end
        if self.macroPending then self:EnsureMacro() end
    elseif event == "LOOT_OPENED" then self.lootOpen = true
    elseif event == "LOOT_CLOSED" then
        self.lootOpen = false
        self.waitUntil = math.max(self.waitUntil, now + 0.5)
    elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" then
        self.batch = nil
        self.waitUntil = math.max(self.waitUntil, now + 0.75)
    elseif event == "BAG_UPDATE_DELAYED" then self.waitUntil = math.max(self.waitUntil, now + 0.25)
    elseif unit == "player" then
        self.waitUntil = math.max(self.waitUntil, now + 0.75)
        if self.batch then self.batch.deadline = now + 3 end
    end
end
