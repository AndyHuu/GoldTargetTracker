local _, addon = ...
local Income = {}
addon.Income = Income

Income.categories = {
    { key = "vendor", label = "商人售卖" },
    { key = "worldQuest", label = "世界任务" },
    { key = "quest", label = "其他任务" },
    { key = "loot", label = "拾取金币" },
    { key = "auction", label = "拍卖到账" },
    { key = "mail", label = "邮件收款" },
    { key = "trade", label = "玩家交易" },
    { key = "other", label = "其他收入" },
}
local keys = {}
for _, category in ipairs(Income.categories) do keys[category.key] = true end
local MATCH_SECONDS = 1

local function Amount(value)
    if issecretvalue and issecretvalue(value) then return false end
    return type(value) == "number" and value == value and value >= 0
        and value < math.huge and value == math.floor(value)
end

function Income.Valid(data)
    if data == nil then return true end
    if type(data) ~= "table" or not Amount(data.startedAt) or type(data.totals) ~= "table" then return false end
    local sum = 0
    for key, value in pairs(data.totals) do
        if not keys[key] or not Amount(value) then return false end
        sum = sum + value
    end
    return sum < 9007199254740992
end

function Income.NewData()
    return { startedAt = time(), totals = {} }
end

function Income.Total(data)
    local total = 0
    for _, amount in pairs(data.totals) do total = total + amount end
    return total
end

local function Recent(entries)
    local kept = {}
    for _, entry in ipairs(entries) do
        if entry.amount > 0 and GetTime() - entry.at <= MATCH_SECONDS * 2 then kept[#kept + 1] = entry end
    end
    return kept
end

function Income:Evidence(category, amount)
    if not self.running or not Amount(amount) or amount == 0 then return end
    self.evidence = Recent(self.evidence)
    local entry = { category = category, amount = amount, at = GetTime() }
    self.evidence[#self.evidence + 1] = entry
    return entry
end

function Income:Schedule()
    if self.scheduled then return end
    self.scheduled = true
    local generation = self.generation
    C_Timer.After(MATCH_SECONDS, function()
        if self.generation ~= generation or not self.running then return end
        self.scheduled = false
        self:Flush(false)
    end)
end

function Income:Flush(force)
    local waiting, changed = {}, false
    -- Exact source amounts take priority over merchant bag differences.
    local priority = { "bank", "worldQuest", "quest", "auction", "mail", "trade", "loot", "vendor" }
    for _, gain in ipairs(self.gains) do
        if not force and GetTime() - gain.at < MATCH_SECONDS then
            waiting[#waiting + 1] = gain
        else
            for _, category in ipairs(priority) do
                for _, evidence in ipairs(self.evidence) do
                    if evidence.category == category and math.abs(evidence.at - gain.at) <= MATCH_SECONDS then
                        local amount = math.min(gain.amount, evidence.amount)
                        gain.amount, evidence.amount = gain.amount - amount, evidence.amount - amount
                        if amount > 0 and category ~= "bank" then
                            self.data.totals[category] = (self.data.totals[category] or 0) + amount
                            changed = true
                        end
                    end
                end
            end
            if gain.amount > 0 then
                self.data.totals.other = (self.data.totals.other or 0) + gain.amount
                changed = true
            end
        end
    end
    self.gains, self.evidence = waiting, Recent(self.evidence)
    if changed then self.changed() end
    if #waiting > 0 then self:Schedule() end
end

local function BankBalance(kind)
    if kind == "guild" then
        if not Income.guildOpen or not GetGuildBankMoney then return end
        local value = GetGuildBankMoney()
        if Amount(value) then return value end
    elseif C_Bank and C_Bank.FetchDepositedMoney then
        if C_Bank.CanViewBank then
            local ok, ready = pcall(C_Bank.CanViewBank, kind)
            if not ok or not ready then return end
        end
        local ok, value = pcall(C_Bank.FetchDepositedMoney, kind)
        if ok and Amount(value) then return value end
    end
end

function Income:ObserveBanks(baseline)
    local kinds = { "guild" }
    if Enum and Enum.BankType then
        for _, name in ipairs({ "Account", "Character" }) do
            local kind = Enum.BankType[name]
            if kind ~= nil then kinds[#kinds + 1] = kind end
        end
    end
    for _, kind in ipairs(kinds) do
        local value = BankBalance(kind)
        if value ~= nil then
            local previous = self.banks[kind]
            if not baseline and previous ~= nil and previous > value then
                self.bankDrops[#self.bankDrops + 1] = { kind = kind, amount = previous - value, at = GetTime() }
            end
            self.banks[kind] = value
        end
    end
    self.bankDrops, self.withdrawals = Recent(self.bankDrops), Recent(self.withdrawals)
    for _, request in ipairs(self.withdrawals) do
        for _, drop in ipairs(self.bankDrops) do
            if request.kind == drop.kind and math.abs(request.at - drop.at) <= MATCH_SECONDS then
                local amount = math.min(request.amount, drop.amount)
                request.amount, drop.amount = request.amount - amount, drop.amount - amount
                self:Evidence("bank", amount)
            end
        end
    end
end

function Income:Withdrawal(kind, amount)
    if not self.running or not Amount(amount) or amount == 0 then return end
    self.withdrawals[#self.withdrawals + 1] = { kind = kind, amount = amount, at = GetTime() }
    self:ObserveBanks(false)
end

local function BagSnapshot()
    local counts = {}
    if not C_Container then return counts end
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and Amount(info.stackCount) then
                counts[info.itemID] = (counts[info.itemID] or 0) + info.stackCount
            end
        end
    end
    return counts
end

local function Buybacks()
    local items = {}
    if not GetNumBuybackItems or not GetBuybackItemLink or not GetBuybackItemInfo then return items end
    for index = 1, GetNumBuybackItems() do
        local link = GetBuybackItemLink(index)
        local id = link and tonumber(link:match("item:(%d+)"))
        local _, _, price, count = GetBuybackItemInfo(index)
        if id and Amount(price) and Amount(count) and count > 0 then
            local key = link .. ":" .. price .. ":" .. count
            local item = items[key] or { id = id, price = price, count = count, copies = 0 }
            item.copies = item.copies + 1
            items[key] = item
        end
    end
    return items
end

function Income:ObserveSales()
    if not self.merchantBags then return end
    local current = BagSnapshot()
    for id, count in pairs(self.merchantBags) do
        local lost = count - (current[id] or 0)
        if lost > 0 then self.merchantLost[id] = (self.merchantLost[id] or 0) + lost end
    end
    self.merchantBags = current
    local buybacks = Buybacks()
    for key, item in pairs(buybacks) do
        local old = self.merchantBuybacks[key]
        for _ = 1, item.copies - (old and old.copies or 0) do
            self.merchantSales[#self.merchantSales + 1] = item
        end
    end
    self.merchantBuybacks = buybacks
    local waiting = {}
    for _, item in ipairs(self.merchantSales) do
        if (self.merchantLost[item.id] or 0) >= item.count then
            self.merchantLost[item.id] = self.merchantLost[item.id] - item.count
            self:Evidence("vendor", item.price)
        else waiting[#waiting + 1] = item end
    end
    self.merchantSales = waiting
    -- shortcut: identical sales in a full unchanged buyback list fall under Other; add action evidence if needed.
end

local function MailItem(index)
    if not GetInboxHeaderInfo then return end
    local _, _, _, subject, money = GetInboxHeaderInfo(index)
    if not Amount(money) or money == 0 then return end
    local invoice = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
    return { amount = money, subject = subject, category = invoice == "seller" and "auction" or "mail" }
end

function Income:SnapshotMail()
    if not GetInboxNumItems then return end
    local count = GetInboxNumItems()
    local current = {}
    for index = 1, count do
        local item, old = MailItem(index), self.mail[index]
        if count == self.mailCount and item and old and item.amount == old.amount and item.subject == old.subject
            and item.category == old.category then item = old end
        current[index] = item
    end
    self.mail, self.mailCount = current, count
end

function Income:InstallHooks()
    if self.hooksInstalled or not hooksecurefunc then return end
    if TakeInboxMoney then
        hooksecurefunc("TakeInboxMoney", function(index)
            if not self.running then return end
            local item = self.mail[index] or MailItem(index)
            if not item or item.requested then return end
            self.mail[index] = item
            item.requested = self:Evidence(item.category, item.amount)
        end)
    end
    if C_Bank and C_Bank.WithdrawMoney then
        hooksecurefunc(C_Bank, "WithdrawMoney", function(kind, amount) self:Withdrawal(kind, amount) end)
    end
    if WithdrawGuildBankMoney then
        hooksecurefunc("WithdrawGuildBankMoney", function(amount) self:Withdrawal("guild", amount) end)
    end
    self.hooksInstalled = true
end

local function LootMoney(message)
    if type(message) ~= "string" then return 0 end
    local copper = 0
    for _, unit in ipairs({ { "GOLD", 10000 }, { "SILVER", 100 }, { "COPPER", 1 } }) do
        for _, suffix in ipairs({ "_AMOUNT", "_AMOUNT_SYMBOL" }) do
            local format = _G[unit[1] .. suffix]
            if type(format) == "string" then
                local pattern = format:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
                pattern = pattern:gsub("%%%%d", "([%%d,]+)")
                local amount = message:match(pattern)
                if amount then copper = copper + (tonumber((amount:gsub(",", ""))) or 0) * unit[2]; break end
            end
        end
    end
    return copper
end

function Income:Start(data, changed)
    self.generation = (self.generation or 0) + 1
    self.data, self.changed, self.running = data, changed, true
    self.gains, self.evidence, self.quests, self.banks, self.mail = {}, {}, {}, {}, {}
    self.bankDrops, self.withdrawals = {}, {}
    self.scheduled, self.guildOpen, self.merchantBags, self.tradeAmount = false, false, nil, nil
    self.tradeAccepted, self.tradeEvidence, self.mailCount = false, nil, 0
    self.balance = GetMoney()
    if not Amount(self.balance) then self.balance = nil end
    self:ObserveBanks(true)
    self:InstallHooks()
end

function Income:Stop()
    self:Flush(true)
    self.running = false
    self.generation = self.generation + 1
end

function Income:OnEvent(event, ...)
    if not self.running then return end
    if event == "PLAYER_MONEY" then
        self:ObserveBanks(false)
        local balance = GetMoney()
        if not Amount(balance) then return end
        if self.balance and balance > self.balance then
            self.gains[#self.gains + 1] = { amount = balance - self.balance, at = GetTime() }
            self:Schedule()
        end
        self.balance = balance
    elseif event == "ACCOUNT_MONEY" or event == "GUILDBANK_UPDATE_MONEY" then
        self:ObserveBanks(false)
    elseif event == "BANKFRAME_OPENED" then
        self:ObserveBanks(true)
    elseif event == "GUILDBANKFRAME_OPENED" then
        self.guildOpen = true
        self:ObserveBanks(true)
    elseif event == "GUILDBANKFRAME_CLOSED" then
        -- Closing can clear the bank API to zero; this is not a withdrawal.
        self.guildOpen = false
        self.banks.guild = nil
    elseif event == "QUEST_TURNED_IN" then
        local questID, _, reward = ...
        local stamp = self.quests[questID]
        if stamp and GetTime() - stamp <= MATCH_SECONDS * 2 then return end
        -- Only a short deduplication window is needed, not a saved quest history.
        for id, seen in pairs(self.quests) do if GetTime() - seen > MATCH_SECONDS * 2 then self.quests[id] = nil end end
        self.quests[questID] = GetTime()
        local world = C_QuestLog.IsWorldQuest(questID)
        self:Evidence(world and "worldQuest" or "quest", reward)
    elseif event == "CHAT_MSG_MONEY" then
        self:Evidence("loot", LootMoney(...))
    elseif event == "MERCHANT_SHOW" then
        self.merchantBags = BagSnapshot()
        self.merchantBuybacks, self.merchantLost, self.merchantSales = Buybacks(), {}, {}
    elseif event == "BAG_UPDATE_DELAYED" or event == "MERCHANT_UPDATE" then
        self:ObserveSales()
    elseif event == "MERCHANT_CLOSED" then
        self:ObserveSales()
        self.merchantBags = nil
    elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
        self:SnapshotMail()
    elseif event == "MAIL_FAILED" then
        for _, item in pairs(self.mail) do
            if item.requested then item.requested.amount = 0; item.requested = nil end
        end
    elseif event == "MAIL_CLOSED" then
        self.mail = {}
    elseif event == "TRADE_SHOW" then
        self.tradeAmount, self.tradeAccepted = 0, false
    elseif event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        self.tradeAmount = GetTargetTradeMoney()
        if event == "TRADE_ACCEPT_UPDATE" then
            local player, target = ...
            self.tradeAccepted = player == 1 and target == 1
        else self.tradeAccepted = false end
    elseif event == "TRADE_CLOSED" then
        if self.tradeAccepted then self.tradeEvidence = self:Evidence("trade", self.tradeAmount) end
        self.tradeAmount, self.tradeAccepted = nil, false
    elseif event == "TRADE_REQUEST_CANCEL" then
        if self.tradeEvidence then self.tradeEvidence.amount = 0 end
        self.tradeAmount, self.tradeAccepted = nil, false
    end
end

Income.events = {
    "QUEST_TURNED_IN", "CHAT_MSG_MONEY", "MERCHANT_SHOW", "MERCHANT_UPDATE", "MAIL_SHOW", "MAIL_INBOX_UPDATE",
    "MAIL_FAILED", "TRADE_SHOW", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "TRADE_REQUEST_CANCEL",
    "BANKFRAME_OPENED", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "GUILDBANK_UPDATE_MONEY",
}
