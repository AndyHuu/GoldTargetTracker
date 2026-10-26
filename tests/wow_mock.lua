-- Deliberately small WoW mock. Line anchors enforce Blizzard's documented signature.
local methods = {}
frames, messages, timers, uses = {}, {}, {}, {}
now, money, combat, bankMoney, bankReady = 0, 1000000, false, 0, false
bags, cooling, consumeCount, soundCount = {}, false, 1, 0
local wallTime = os.time({year=2026, month=10, day=25, hour=12})
date = function(format, stamp) return os.date(format, stamp or wallTime) end
time = function(value) return value and os.time(value) or wallTime end
setDay = function(day) wallTime = os.time({year=tonumber(day:sub(1,4)), month=tonumber(day:sub(6,7)), day=tonumber(day:sub(9,10)), hour=12}) end
GetTime = function() return now end
GetMoney = function() return money end
playerName, realmName = 'PlayerOne', 'Realm'
GetRealmName = function() return realmName end
UnitName = function() return playerName end
InCombatLockdown = function() return combat end
GetCursorPosition = function() return 0, 0 end
NUM_BAG_SLOTS, NUM_TOTAL_EQUIPPED_BAG_SLOTS = 4, 5
Enum = {BankType={Account=2}}
C_Bank = {FetchDepositedMoney=function() return bankMoney end, CanViewBank=function() return bankReady end,
    WithdrawMoney=function() end}
WithdrawGuildBankMoney = function() end
C_Timer = {After=function(delay, fn) timers[#timers+1]={at=now+delay, fn=fn} end}
function advance(seconds)
    local finish, guard = now+seconds, 0
    while true do
        local index
        for i, timer in ipairs(timers) do
            if timer.at <= finish and (not index or timer.at < timers[index].at) then index=i end
        end
        if not index then break end
        local timer=table.remove(timers,index)
        now=timer.at; timer.fn(); guard=guard+1
        assert(guard<1000, 'timer loop')
    end
    now=finish
end
function setItem(bag, slot, count, itemID, name, locked)
    bags[bag]=bags[bag] or {}
    bags[bag][slot]=count and count>0 and {itemID=itemID or 1, stackCount=count, itemName=name or 'Token', isLocked=locked or false} or nil
end
C_Container = {
    GetContainerNumSlots=function() return 8 end,
    GetContainerItemInfo=function(bag,slot) return bags[bag] and bags[bag][slot] end,
    GetContainerItemCooldown=function() return 0, cooling and 100 or 0, 1 end,
    UseContainerItem=function(bag,slot)
        uses[#uses+1]={bag=bag, slot=slot, at=now}
        if useError then error('temporarily unavailable') end
        local item=bags[bag][slot]
        if consumeCount>0 then setItem(bag,slot,item.stackCount-consumeCount,item.itemID,item.itemName) end
    end,
}
C_Item = {GetItemInfo=function() return itemInfoName end, RequestLoadItemDataByID=function() end}
worldQuests, inbox, mailRequests = {}, {}, {}
buybacks = {}
GetNumBuybackItems = function() return #buybacks end
GetBuybackItemLink = function(index) return 'item:'..buybacks[index].id end
GetBuybackItemInfo = function(index)
    local item=buybacks[index]
    return 'Item',nil,item.price,item.count
end
C_QuestLog = {IsWorldQuest=function(id) return worldQuests[id] or false end}
GetInboxNumItems = function() return #inbox end
GetInboxHeaderInfo = function(index)
    local mail = inbox[index]
    if mail then return nil,nil,nil,mail.subject or ('Mail'..index),mail.amount end
end
GetInboxInvoiceInfo = function(index) return inbox[index] and inbox[index].invoice end
TakeInboxMoney = function(index) mailRequests[#mailRequests+1]=index end
GetTargetTradeMoney = function() return tradeMoney or 0 end
GetGuildBankMoney = function() return guildMoney or 0 end
GOLD_AMOUNT, SILVER_AMOUNT, COPPER_AMOUNT = '%d金币', '%d银币', '%d铜币'
print = function(...) local parts={...}; for i,v in ipairs(parts) do parts[i]=tostring(v) end; messages[#messages+1]=table.concat(parts,' ') end
StaticPopupDialogs, SlashCmdList, UISpecialFrames = {}, {}, {}
StaticPopup_Show = function(key) lastPopup=key end
SOUNDKIT={UI_ACHIEVEMENT_EARNED=1}
PlaySound=function() soundCount=soundCount+1 end
ReloadUI=function() if reloadHook then reloadHook() end end
hooksecurefunc=function(target,name,fn)
    if target=='ReloadUI' then reloadHook=name; return end
    if type(target)=='string' then fn,name,target=name,target,_G end
    assert(type(target[name])=='function')
    local original=target[name]
    target[name]=function(...) original(...); fn(...) end
end
Settings={RegisterCanvasLayoutCategory=function(frame,name) return {name=name, GetID=function() return 1 end} end, RegisterAddOnCategory=function() end, OpenToCategory=function(id) openedSettingsCategory=id end}
MenuUtil={CreateContextMenu=function(owner,generator)
    local root={owner=owner,entries={}}
    function root:CreateCheckbox(text,selected,callback)
        local row={kind='checkbox',text=text,selected=selected,callback=callback}
        self.entries[#self.entries+1]=row
        return row
    end
    function root:CreateDivider() self.entries[#self.entries+1]={kind='divider'} end
    function root:CreateButton(text,callback)
        local row={kind='button',text=text,callback=callback}
        self.entries[#self.entries+1]=row
        return row
    end
    generator(owner,root)
    contextMenu=root
    return root
end}
local function object(kind, name, parent)
    local obj=setmetatable({kind=kind, scripts={}, events={}, parent=parent, shown=true, level=1, alpha=1}, {__index=methods})
    frames[#frames+1]=obj
    if name then _G[name]=obj end
    return obj
end
CreateFrame=function(kind,name,parent) return object(kind,name,parent) end
function methods:SetScript(key,fn) self.scripts[key]=fn end
function methods:HookScript(key,fn)
    local original=self.scripts[key]
    self.scripts[key]=function(...) if original then original(...) end; fn(...) end
end
function methods:GetScript(key) return self.scripts[key] end
function methods:RegisterEvent(event) self.events[event]=true end
function methods:UnregisterEvent(event) self.events[event]=nil end
function methods:UnregisterAllEvents() self.events={} end
function methods:SetText(text) self.text=text end
function methods:GetText() return self.text or '' end
function methods:GetStringHeight()
    local size=self.font and self.font[2] or 14
    local lines=0
    for line in (self:GetText()..'\n'):gmatch('(.-)\n') do
        lines=lines+(self.wordWrap and math.max(1,math.ceil(#line*size/2/math.max(1,self.width or 500))) or 1)
    end
    return math.max(1,lines)*size
end
function methods:SetChecked(value) self.checked=value end
function methods:GetChecked() return self.checked end
function methods:HasFocus() return false end
function methods:SetPoint(...)
    self.point={...}
    self.points=self.points or {}
    self.points[self.point[1]]=self.point
end
function methods:GetPoint() return 'CENTER',UIParent,'CENTER',0,0 end
function methods:SetSize(w,h)
    local changed=self.width~=w or self.height~=h
    self.width,self.height=w,h
    if changed and self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self,w,h) end
end
function methods:SetWidth(w) self.width=w end
function methods:SetHeight(h) self.height=h end
function methods:GetWidth() return self.width or 500 end
function methods:GetHeight() return self.height or 100 end
function methods:SetFrameLevel(level) self.level=level end
function methods:GetFrameLevel() return self.level end
function methods:SetAlpha(alpha) self.alpha=alpha end
function methods:GetAlpha() return self.alpha end
function methods:GetEffectiveScale() return 1 end
function methods:SetScale(scale) self.scale=scale end
function methods:GetScale() return self.scale or 1 end
function methods:SetEnabled(enabled) self.enabled=enabled end
function methods:IsEnabled() return self.enabled~=false end
function methods:GetCenter() return 0,0 end
function methods:SetTexture(texture) self.texture=texture end
function methods:GetTexture() return self.texture end
function methods:Show() local change=not self.shown; self.shown=true; if change and self.scripts.OnShow then self.scripts.OnShow(self) end end
function methods:Hide() self.shown=false end
function methods:SetShown(value) if value then self:Show() else self:Hide() end end
function methods:IsShown() return self.shown end
function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function methods:CreateFontString() return object('FontString',nil,self) end
function methods:GetFontString()
    if not self.fontString then
        self.fontString=object('FontString',nil,self)
        self.fontString:SetText(self:GetText())
    end
    return self.fontString
end
function methods:CreateTexture() return object('Texture',nil,self) end
function methods:CreateLine() return object('Line',nil,self) end
function methods:CreateAnimationGroup() return object('AnimationGroup',nil,self) end
function methods:CreateAnimation() return object('Animation',nil,self) end
function methods:SetStartPoint(point,relative,x,y,...)
    assert(type(point)=='string' and type(relative)=='table' and type(x)=='number' and type(y)=='number' and select('#',...)==0, 'invalid Line anchor signature')
    self.start={point,relative,x,y}
end
methods.SetEndPoint=methods.SetStartPoint
for _,name in ipairs({'ClearAllPoints','SetBackdrop','SetBackdropColor','SetBackdropBorderColor','SetFont','SetTextColor','SetJustifyH','SetJustifyV','SetStatusBarTexture','SetStatusBarColor','SetMinMaxValues','SetValue','SetAutoFocus','SetNumeric','SetMaxLetters','ClearFocus','SetClampedToScreen','EnableMouse','SetMovable','RegisterForDrag','RegisterForClicks','SetFrameStrata','SetTexCoord','SetAllPoints','SetNormalFontObject','SetHighlightTexture','SetOwner','AddLine','AddDoubleLine','SetVertexColor','SetColorTexture','SetThickness','SetScrollChild','SetVerticalScroll','SetFromAlpha','SetToAlpha','SetDuration','SetOffset','SetSmoothing','Stop','Play','StartMoving','StopMovingOrSizing','SetNormalTexture','SetPushedTexture','SetDisabledTexture'}) do
    methods[name]=function() end
end
UIParent=object('Frame','UIParent'); Minimap=object('Frame','Minimap'); GameTooltip=object('Frame','GameTooltip')
GameFontNormal={}
function methods:AddDoubleLine(left,right)
    self.tooltipRows=self.tooltipRows or {}
    self.tooltipRows[#self.tooltipRows+1]={left,right}
end
function methods:SetOwner() self.tooltipRows={} end
function methods:SetFont(file,height,flags)
    if self.kind=='EditBox' then assert(type(flags)=='string','EditBox:SetFont requires flags') end
    self.font={file,height,flags}
end
function methods:SetTextColor(...) self.textColor={...} end
function methods:SetWordWrap(value) self.wordWrap=value end
function methods:SetScrollChild(child) self.scrollChild=child end
function methods:GetScrollChild() return self.scrollChild end
function methods:SetVerticalScroll(value) self.verticalScroll=value end
function methods:GetVerticalScroll() return self.verticalScroll or 0 end
function methods:SetValue(value) self.value=value end
function methods:ClearAllPoints() self.point=nil; self.points={} end
function methods:SetMovable(value) self.movable=value end
function methods:StartMoving() assert(self.movable~=false); self.moving=true; self.moveCalls=(self.moveCalls or 0)+1 end
function methods:StopMovingOrSizing() self.moving=false end
function openPanelMenu()
    local panel=GoldTargetTrackerFrame
    assert(panel.scripts.OnMouseUp,'missing right-click handler')
    panel.scripts.OnMouseUp(panel,'RightButton')
    assert(contextMenu,'missing context menu')
    return contextMenu
end
function menuEntry(text)
    for _,row in ipairs(contextMenu.entries) do if row.text==text then return row end end
    error('missing menu entry: '..text)
end
function assertPercentLabels(main,settings)
    local found=0
    for _,frame in ipairs(frames) do
        if frame.kind=='FontString' and frame.parent.kind=='StatusBar' and frame:GetText():match('^[%d%.]+%%$') then
            local expected=frame.parent.parent==GoldTargetTrackerFrame and main or settings
            assert(frame:GetText()==expected, 'percent '..frame:GetText()..' expected '..expected)
            found=found+1
        end
    end
    assert(found==2,'expected main and settings percent labels')
end
function clickText(text)
    for _,frame in ipairs(frames) do
        if frame.text==text and frame.scripts.OnClick then frame.scripts.OnClick(frame); return frame end
    end
    error('button not found: '..text)
end
