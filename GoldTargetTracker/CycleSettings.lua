local _, addon = ...
local Cycle = addon.Cycle
local FONT = "Fonts\\ARIALN.TTF"

function Cycle:BuildSettings(page, MakeSection, MakeText, StackSections)
    local ui = {page = page, cards = {}, sections = {}, layout = StackSections}
    self.ui = ui
    local function Text(parent, text, y)
        local label = MakeText(parent, text, 14, nil, "TOPLEFT", parent, "TOPLEFT", 14, y)
        label:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(true)
        return label
    end
    local function Button(parent, text, width, click)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(width, 24)
        button:SetText(text)
        button:GetFontString():SetFont(FONT, 14, "")
        button:SetScript("OnClick", click)
        return button
    end
    local header = MakeSection(page, "专业循环", 0, 180)
    ui.sections[1] = header
    ui.description = Text(header, "按角色保存。优先分解，其次回收，最后制造；各列表按添加顺序处理。分解列表中的同款物品均可能被拆，请先移走要保留的装备。", -32)
    ui.toggle = Button(header, "停用循环", 100, function()
        local _, message = self:SetEnabled(not self.data.enabled)
        self:Status(message)
    end)
    ui.macro = Button(header, "创建循环宏", 120, function() self:EnsureMacro() end)
    ui.message = Text(header, self.lastMessage or "输入 /m，将“安迪循环”宏拖到动作条。", -118)
    local definitions = {
        {kind = "recycle", title = "回收材料", hint = "工程学循环回收，每 5 个一组。高低星需分别添加。"},
        {kind = "craft", title = "制造配方", hint = "工程物品配方。材料不足时尝试下一项；成品不会自动加入分解列表。"},
        {kind = "disenchant", title = "分解物品", hint = "只分解列表中的背包物品。添加前请确认该物品可以分解。"},
    }
    for _, definition in ipairs(definitions) do
        local kind = definition.kind
        local card = MakeSection(page, definition.title, 0, 200)
        ui.sections[#ui.sections + 1] = card
        local controls = {frame = card, rows = {}, definition = definition}
        ui.cards[kind] = controls
        controls.hint = Text(card, definition.hint, -32)
        local input = CreateFrame("EditBox", nil, card, "InputBoxTemplate")
        controls.input = input
        input:SetHeight(24)
        input:SetFont(FONT, 14, "")
        input:SetAutoFocus(false)
        input:SetMaxLetters(255)
        input:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
        local function AddInput()
            local ok, message = self:Add(kind, input:GetText())
            if ok then input:SetText(""); input:ClearFocus() end
            self:Status(message)
        end
        input:SetScript("OnEnterPressed", AddInput)
        controls.add = Button(card, "添加", 70, AddInput)
        controls.help = Text(card, kind == "craft" and "填写配方编号，或使用“添加当前配方”。" or "把背包物品拖到输入框，或填写名称 / 编号。", -96)
        if kind == "craft" then
            controls.current = Button(card, "添加当前配方", 132, function()
                local crafting = ProfessionsFrame and ProfessionsFrame.CraftingPage
                local info = crafting and crafting.GetRecipeInfo and crafting:GetRecipeInfo()
                if not info then self:Status("请先在工程学窗口选中要制造的配方。"); return end
                local _, message = self:Add("craft", info.recipeID)
                self:Status(message)
            end)
        else
            local function ReceiveItem()
                local cursor, id = GetCursorInfo()
                if cursor == "item" then input:SetText(tostring(id)); ClearCursor() end
            end
            input:SetScript("OnReceiveDrag", ReceiveItem)
            input:SetScript("OnMouseDown", ReceiveItem)
        end
        controls.empty = Text(card, "列表为空，此步骤跳过。", -140)
        controls.count = Text(card, "", -120)
    end
    page.Reflow = function() self:RefreshSettings() end
    self:RefreshSettings()
end

function Cycle:RefreshSettings()
    local ui = self.ui
    if not ui then return end
    local valid = self.data ~= nil
    ui.toggle:SetEnabled(valid)
    ui.toggle:SetText(valid and self.data.enabled and "停用循环" or "启用循环")
    local width = math.max(160, ui.page.content:GetWidth() - 36)
    ui.description:SetWidth(width)
    local top = 36 + ui.description:GetStringHeight() + 8
    ui.toggle:ClearAllPoints(); ui.toggle:SetPoint("TOPLEFT", ui.sections[1], "TOPLEFT", 14, -top)
    ui.macro:ClearAllPoints(); ui.macro:SetPoint("TOPLEFT", ui.toggle, "TOPRIGHT", 8, 0)
    ui.message:ClearAllPoints()
    ui.message:SetPoint("TOPLEFT", ui.sections[1], "TOPLEFT", 14, -top - 32)
    ui.message:SetPoint("TOPRIGHT", ui.sections[1], "TOPRIGHT", -14, -top - 32)
    ui.message:SetWidth(width)
    ui.sections[1]:SetHeight(top + 40 + math.max(32, ui.message:GetStringHeight()))
    for _, kind in ipairs({"recycle", "craft", "disenchant"}) do
        local c = ui.cards[kind]
        local list = valid and self.data[kind] or {}
        c.hint:SetWidth(width)
        local inputY = 36 + c.hint:GetStringHeight() + 8
        c.input:ClearAllPoints()
        c.input:SetPoint("TOPLEFT", c.frame, "TOPLEFT", 14, -inputY)
        c.input:SetPoint("TOPRIGHT", c.frame, "TOPRIGHT", -94, -inputY)
        c.add:ClearAllPoints(); c.add:SetPoint("TOPRIGHT", c.frame, "TOPRIGHT", -14, -inputY)
        c.add:SetEnabled(valid)
        c.help:ClearAllPoints()
        c.help:SetPoint("TOPLEFT", c.frame, "TOPLEFT", 14, -inputY - 32)
        c.help:SetPoint("TOPRIGHT", c.frame, "TOPRIGHT", -14, -inputY - 32)
        c.help:SetWidth(width)
        local listY = inputY + 36 + c.help:GetStringHeight()
        if c.current then
            c.current:ClearAllPoints(); c.current:SetPoint("TOPLEFT", c.frame, "TOPLEFT", 14, -listY)
            c.current:SetEnabled(valid)
            listY = listY + 32
        end
        c.count:ClearAllPoints(); c.count:SetPoint("TOPLEFT", c.frame, "TOPLEFT", 14, -listY)
        c.count:SetText("已添加 " .. #list .. " / " .. self.limit)
        listY = listY + 24
        c.empty:ClearAllPoints(); c.empty:SetPoint("TOPLEFT", c.frame, "TOPLEFT", 14, -listY)
        c.empty:SetShown(#list == 0)
        for index, entry in ipairs(list) do
            if not c.rows[index] then
                local row = CreateFrame("Frame", nil, c.frame)
                row:SetHeight(28)
                row.label = row:CreateFontString(nil, "OVERLAY")
                row.label:SetFont(FONT, 14, "")
                row.label:SetTextColor(0.94, 0.94, 0.90)
                row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
                row.label:SetPoint("RIGHT", row, "RIGHT", -78, 0)
                row.label:SetJustifyH("LEFT"); row.label:SetWordWrap(false)
                row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.remove:SetSize(70, 24); row.remove:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                row.remove:SetText("移除"); row.remove:GetFontString():SetFont(FONT, 14, "")
                row.remove:SetScript("OnClick", function()
                    local _, message = self:Remove(kind, index); self:Status(message)
                end)
                row:EnableMouse(true)
                row:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(row, "ANCHOR_TOP"); GameTooltip:AddLine(row.label:GetText(), 1, 1, 1, true); GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                c.rows[index] = row
            end
            local row = c.rows[index]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", c.frame, "TOPLEFT", 14, -listY - (index - 1) * 28)
            row:SetPoint("TOPRIGHT", c.frame, "TOPRIGHT", -14, -listY - (index - 1) * 28)
            row.label:SetText(entry.name .. " [" .. entry.id .. "]")
            row:Show()
        end
        for i = #list + 1, #c.rows do c.rows[i]:Hide() end
        c.frame:SetHeight(listY + math.max(1, #list) * 28 + 12)
    end
    ui.layout(ui.page, ui.sections)
end
