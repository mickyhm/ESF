-- Features\ChatAutoHide.lua
-- Fades the whole chat (window, tabs, buttons) to invisible.
-- Works with Chattynator (if loaded) or the native Blizzard chat.
local ADDON, ESF = ...

local MODES = {
    "Never Hide",
    "Hide When Idle (Shows on mouse over, blinking or new message)",
    "Hide After Timer (Shows on mouse over or blinking)",
    "Hide After Timer (Shows on mouse over only)",
}
local DEFAULT_SECONDS, MAX_SECONDS = 60, 3600
local FADE_IN, FADE_OUT = 0.15, 0.6      -- seconds
local SCAN_INTERVAL = 1                  -- Chattynator window scan

local mode = 1
local units = {}     -- key -> unit (one per chat window / native dock)
local hooked = {}    -- objects we already hooked
local useChattynator = false
local ui             -- settings widgets, once built

local function Seconds()
    return (ESFDB and ESFDB.chatHideSeconds) or DEFAULT_SECONDS
end

----------------------------------------------------------------------
-- Units: frames to fade + a mouse-over test + last-activity time
----------------------------------------------------------------------
local applying = false   -- true while we set alpha ourselves (see the SetAlpha hook in ScanNative)

local function Apply(u)
    applying = true
    for _, f in ipairs(u.frames) do
        f:SetAlpha(u.alpha * u.base[f])
    end
    applying = false
end

local function NewUnit(frames, over, editbox)
    local u = { frames = frames, over = over, editbox = editbox, last = GetTime(), alpha = 1, base = {} }
    for _, f in ipairs(frames) do
        local a = f:GetAlpha()
        u.base[f] = a > 0.05 and a or 1
    end
    return u
end

local function RemoveUnit(key)
    local u = units[key]
    if not u then return end
    u.alpha = 1
    Apply(u)
    units[key] = nil
end

-- /esf chatdebug: print what resets the hide timer (each reason at most once per second)
local debug = false
local lastReason, lastPrint = nil, 0
local ownPrint = false   -- our own chat output must not count as a new message

local function Print(msg)
    ownPrint = true
    print(msg)
    ownPrint = false
end

local function Reset(u, reason)
    local now = GetTime()
    u.last = now
    if debug and (reason ~= lastReason or now - lastPrint >= 1) then
        lastReason, lastPrint = reason, now
        Print("ESF chat timer reset: " .. reason)
    end
end

-- kind: "message" (new line in the current tab) or "blink" (a tab started blinking)
local function Poke(u, kind)
    if not u or ownPrint then return end
    if kind == "message" then
        if mode == 2 then Reset(u, "new message") end
    elseif kind == "blink" then
        if mode == 2 or mode == 3 then Reset(u, "tab blinking") end
    end
end

local function Tick(dt)
    local now = GetTime()
    local secs = Seconds()
    for _, u in pairs(units) do
        local target = 1
        if mode ~= 1 then
            local over = u.over()
            if over then
                Reset(u, type(over) == "string" and over or "mouse over")
            elseif u.editbox and u.editbox:IsShown() then
                Reset(u, "edit box shown")
            end
            if now - u.last >= secs then target = 0 end
        end
        local a = u.alpha
        if a ~= target then
            if target > a then
                a = math.min(target, a + dt / FADE_IN)
            else
                a = math.max(target, a - dt / FADE_OUT)
            end
            u.alpha = a
            Apply(u)
        end
    end
end

----------------------------------------------------------------------
-- Chattynator adapter
----------------------------------------------------------------------
-- Every Chattynator message has typeInfo.event (the CHAT_MSG_ event) and, for addon output,
-- typeInfo.source (the addon folder). A modifier (public API) sees each message before display;
-- we keep the recent ones and look up the newest shown line by its final text.
local PLAYER_EVENTS = {
    CHAT_MSG_SAY = true, CHAT_MSG_YELL = true, CHAT_MSG_WHISPER = true, CHAT_MSG_WHISPER_INFORM = true,
    CHAT_MSG_BN_WHISPER = true, CHAT_MSG_BN_WHISPER_INFORM = true,
    CHAT_MSG_PARTY = true, CHAT_MSG_PARTY_LEADER = true, CHAT_MSG_RAID = true, CHAT_MSG_RAID_LEADER = true,
    CHAT_MSG_RAID_WARNING = true, CHAT_MSG_INSTANCE_CHAT = true, CHAT_MSG_INSTANCE_CHAT_LEADER = true,
    CHAT_MSG_GUILD = true, CHAT_MSG_OFFICER = true, CHAT_MSG_CHANNEL = true,
}
local RECENT_MAX = 100
local recent = {}   -- { data = processed message, player = bool, own = bool }

local function RememberMessage(data)
    local info = data.typeInfo or {}
    recent[#recent + 1] = { data = data, player = PLAYER_EVENTS[info.event] or false, own = info.source == ADDON }
    if #recent > RECENT_MAX then table.remove(recent, 1) end
end

local function FindMessage(text)
    for i = #recent, 1, -1 do
        if recent[i].data.text == text then return recent[i] end
    end
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function HookTabs(u)
    local frame = u.frame
    local tabs = frame.TabsBar and frame.TabsBar.Tabs
    if not tabs then return end
    for _, tab in ipairs(tabs) do
        if not hooked[tab] and tab.SetFlashing then
            hooked[tab] = true
            hooksecurefunc(tab, "SetFlashing", function(_, state)
                if state then Poke(units[frame], "blink") end
            end)
        end
    end
end

local function AddChattynator(f)
    local u = NewUnit({ f }, function()
        return f:IsMouseOver() or (f.ButtonsBar and f.ButtonsBar:IsMouseOver())
    end, f:GetID() == 1 and ChatFrame1EditBox or nil)
    u.frame = f
    units[f] = u

    if not hooked[f] then
        hooked[f] = true
        -- New line in the current tab: Render only draws lines that pass the tab's filter,
        -- so a changed newest line means a new message for this tab.
        hooksecurefunc(f.ScrollingMessages, "Render", function(self, newMessages)
            local un = units[f]
            if not un then return end
            local top = self.visibleLines and self.visibleLines[1]
            local text = top and top:GetText()
            if IsSecret(text) then   -- can't compare or look it up; count it unless player-only
                if newMessages and not ESFDB.chatHidePlayerOnly then Poke(un, "message") end
                un.lastTop, un.lastText = top, nil
                return
            end
            if newMessages and top and (top ~= un.lastTop or text ~= un.lastText) then
                local m = FindMessage(text)
                if not (m and m.own) and (not ESFDB.chatHidePlayerOnly or (m and m.player)) then
                    Poke(un, "message")
                end
            end
            un.lastTop, un.lastText = top, text
        end)
        -- Tabs are recreated on refresh: hook the new ones right away.
        hooksecurefunc(f.TabsBar, "RefreshTabs", function()
            local un = units[f]
            if un then HookTabs(un) end
        end)
    end
    HookTabs(u)
end

local function ScanChattynator()
    local handler = _G.ChattynatorHyperlinkHandler
    if not handler then return end
    local seen = {}
    for _, f in ipairs({ handler:GetChildren() }) do
        if f.ScrollingMessages and f.TabsBar and f.GetID and f:GetID() ~= 0 then
            seen[f] = true
            if not units[f] then AddChattynator(f) end
        end
    end
    for key, u in pairs(units) do
        if u.frame and not seen[key] then RemoveUnit(key) end   -- window closed / released
    end
end

----------------------------------------------------------------------
-- Native adapter (docked chat frames share one unit)
-- Every docked tab is its own ChatFrameN (parent UIParent) with its own background and
-- side buttons, so all docked frames are faded, not just ChatFrame1. The list is rescanned
-- because whisper tabs (temporary windows) come and go.
----------------------------------------------------------------------
-- Buttons around the chat that are not children of a chat frame (only faded if parented to UIParent).
local EXTRA_FRAMES = {
    "QuickJoinToastButton", "FriendsMicroButton", "ChatFrameMenuButton", "ChatFrameChannelButton",
    "ChatFrameToggleVoiceDeafenButton", "ChatFrameToggleVoiceMuteButton",
}

local function DockedFrames()
    local list, inList = {}, {}
    local function add(f)
        if f and not inList[f] then
            inList[f] = true
            list[#list + 1] = f
        end
    end
    add(GeneralDockManager)
    local docked = (FCFDock_GetChatFrames and GENERAL_CHAT_DOCK) and FCFDock_GetChatFrames(GENERAL_CHAT_DOCK) or { ChatFrame1 }
    for _, cf in ipairs(docked) do
        add(cf)
        add(cf.editBox or _G[cf:GetName() .. "EditBox"])   -- parent is UIParent, so not faded with the frame
    end
    for _, name in ipairs(EXTRA_FRAMES) do
        local f = _G[name]
        if f and f:GetParent() == UIParent then add(f) end
    end
    return list
end

local function NativeOver(u)
    if GeneralDockManager:IsMouseOver() then return "mouse over tabs" end
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return "typing" end
    for _, f in ipairs(u.frames) do
        if f ~= GeneralDockManager and f:IsShown() then
            local name = f:GetName() or "chat element"
            if f:IsMouseOver() then return "mouse over " .. name end
            local buttons = f.buttonFrame or _G[name .. "ButtonFrame"]
            if buttons and buttons:IsMouseOver() then return "mouse over " .. name .. "ButtonFrame" end
        end
    end
    return false
end

local alphaHooked = {}

-- Chat types written by players (GMs whisper as WHISPER). Numbered channels are CHANNEL1..n.
local PLAYER_TYPES = {
    SAY = true, YELL = true, WHISPER = true, WHISPER_INFORM = true,
    BN_WHISPER = true, BN_WHISPER_INFORM = true,
    PARTY = true, PARTY_LEADER = true, RAID = true, RAID_LEADER = true, RAID_WARNING = true,
    INSTANCE_CHAT = true, INSTANCE_CHAT_LEADER = true,
    GUILD = true, OFFICER = true, CHANNEL = true,
}
local typeById = {}

-- Blizzard passes ChatTypeInfo[type].id as the 5th AddMessage argument.
local function IsPlayerChatType(id)
    if not id then return false end
    local t = typeById[id]
    if not t and ChatTypeInfo then
        for name, info in pairs(ChatTypeInfo) do
            if type(info) == "table" and info.id then typeById[info.id] = name end
        end
        t = typeById[id]
    end
    return t and (PLAYER_TYPES[t] or strmatch(t, "^CHANNEL%d+$")) and true or false
end

local function ScanNative()
    local u = units.native
    if not u then return end
    local frames, seen = DockedFrames(), {}
    for _, f in ipairs(frames) do
        seen[f] = true
        if not u.base[f] then
            local a = f:GetAlpha()
            u.base[f] = a > 0.05 and a or 1
        end
        if f:IsObjectType("ScrollingMessageFrame") and not hooked[f] then
            hooked[f] = true
            hooksecurefunc(f, "AddMessage", function(self, _, _, _, _, typeID)
                -- the shown docked frame is the current tab
                if not (self:IsShown() and (self.isDocked or self == ChatFrame1)) then return end
                if ESFDB.chatHidePlayerOnly and not IsPlayerChatType(typeID) then return end
                Poke(units.native, "message")
            end)
        end
        -- Blizzard sets alpha on some of these itself (e.g. the edit box dims when inactive):
        -- take its value as the new base and keep our fade on top.
        if not alphaHooked[f] then
            alphaHooked[f] = true
            hooksecurefunc(f, "SetAlpha", function(self, a)
                local un = units.native
                if applying or not (un and un.base[self]) then return end
                un.base[self] = a
                applying = true
                self:SetAlpha(a * un.alpha)
                applying = false
            end)
        end
    end
    applying = true
    for f, a in pairs(u.base) do
        if not seen[f] then   -- undocked or closed: give its alpha back
            f:SetAlpha(a)
            u.base[f] = nil
        end
    end
    applying = false
    u.frames = frames
    Apply(u)
end

local function SetupNative()
    local u = NewUnit({}, function() return NativeOver(units.native) end,
        not ChatEdit_GetActiveWindow and ChatFrame1EditBox or nil)
    units.native = u
    ScanNative()
    if FCF_StartAlertFlash then
        hooksecurefunc("FCF_StartAlertFlash", function() Poke(u, "blink") end)
    end
end

----------------------------------------------------------------------
-- Driver
----------------------------------------------------------------------
local driver = CreateFrame("Frame")
local scanAcc = 0
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if _G.ChattynatorHyperlinkHandler then
        useChattynator = true
        if Chattynator and Chattynator.API and Chattynator.API.AddModifier then
            Chattynator.API.AddModifier(RememberMessage)
        end
        ScanChattynator()
    else
        SetupNative()
    end
    self:SetScript("OnUpdate", function(_, dt)
        scanAcc = scanAcc + dt
        if scanAcc >= SCAN_INTERVAL then
            scanAcc = 0
            if useChattynator then ScanChattynator() else ScanNative() end
        end
        Tick(dt)
    end)
end)

local function SetMode(v)
    mode = MODES[v] and v or 1
    local now = GetTime()
    for _, u in pairs(units) do u.last = now end
    if ui then ui.Refresh() end
end

-- /esf testhide [seconds]: pretend the last activity was long ago, so the chat hides
-- after the given seconds (default 3). Mouse over or an open edit box still keeps it shown.
ESF.commands.testhide = function(rest)
    if mode == 1 then
        Print("ESF: Chat Auto-Hide is set to Never Hide, choose another mode first")
        return
    end
    local secs = tonumber(rest) or 3
    local now = GetTime()
    for _, u in pairs(units) do u.last = now - Seconds() + secs end
    Print("ESF: chat hides in " .. secs .. " s (move the mouse away from the chat)")
end

ESF.commands.chatdebug = function()
    debug = not debug
    lastReason = nil
    Print("ESF: chat debug " .. (debug and "on" or "off"))
end

----------------------------------------------------------------------
-- Settings widget: [<] [ dropdown ] [>]  +  seconds box
----------------------------------------------------------------------
local ROW_H = 22

local function BuildWidget(panel)
    local box = CreateFrame("Frame", nil, panel)
    box:SetSize(460, 88)

    local function Arrow(kind, anchorPoint, x)
        local b = CreateFrame("Button", nil, box)
        b:SetSize(24, 24)
        b:SetPoint("TOPLEFT", x, 0)
        local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. kind .. "Page-"
        b:SetNormalTexture(base .. "Up")
        b:SetPushedTexture(base .. "Down")
        b:SetDisabledTexture(base .. "Disabled")
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        return b
    end

    local prev = Arrow("Prev", "TOPLEFT", 0)
    local drop = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    drop:SetSize(400, 24)
    drop:SetPoint("TOPLEFT", 28, 0)
    drop:SetNormalFontObject(GameFontHighlightSmall)
    drop:SetHighlightFontObject(GameFontHighlightSmall)
    local nextB = Arrow("Next", "TOPLEFT", 432)

    -- player-only checkbox (only used by "Hide When Idle")
    local playerOnly = CreateFrame("CheckButton", "ESFChatPlayerOnly", box, "InterfaceOptionsCheckButtonTemplate")
    playerOnly:SetPoint("TOPLEFT", -2, -30)
    local playerOnlyText = _G[playerOnly:GetName() .. "Text"]
    playerOnlyText:SetText("Only Player Messages (Loot, XP and system messages are ignored)")
    playerOnly:SetChecked(ESFDB.chatHidePlayerOnly and true or false)
    playerOnly:SetScript("OnClick", function(self)
        ESFDB.chatHidePlayerOnly = self:GetChecked() and true or false
    end)

    -- seconds box
    local label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, -66)
    label:SetText("Seconds Until Hidden")

    local eb = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
    eb:SetSize(50, 20)
    eb:SetPoint("LEFT", label, "RIGHT", 14, 0)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(4)
    eb:SetText(tostring(Seconds()))

    local function Commit()
        local n = tonumber(eb:GetText())
        if n then
            n = math.max(1, math.min(MAX_SECONDS, math.floor(n)))
        else
            n = Seconds()
        end
        ESFDB.chatHideSeconds = n
        eb:SetText(tostring(n))
    end
    eb:SetScript("OnEnterPressed", function(self) Commit() self:ClearFocus() end)
    eb:SetScript("OnEditFocusLost", Commit)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(Seconds()))
        self:ClearFocus()
    end)
    -- Text set while the panel was never shown can stay invisible; set it again on show.
    eb:SetScript("OnShow", function(self)
        if not self:HasFocus() then
            self:SetText(tostring(Seconds()))
            self:SetCursorPosition(0)
        end
    end)

    -- popup list
    local list = CreateFrame("Frame", "ESFChatModeList", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    list:SetSize(420, #MODES * ROW_H + 12)
    list:SetFrameStrata("DIALOG")
    list:SetClampedToScreen(true)
    list:EnableMouse(true)
    list:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    list:Hide()
    tinsert(UISpecialFrames, "ESFChatModeList")
    panel:HookScript("OnHide", function() list:Hide() end)
    list:SetScript("OnShow", function(self) pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    list:SetScript("OnHide", function(self) pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    list:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not drop:IsMouseOver() then self:Hide() end
    end)

    local rows = {}
    local function Select(i)
        ESFDB.chatAutoHide = i
        SetMode(i)
    end
    for i, name in ipairs(MODES) do
        local r = CreateFrame("Button", nil, list)
        r:SetSize(404, ROW_H)
        r:SetPoint("TOPLEFT", 8, -6 - (i - 1) * ROW_H)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 6, 0)
        r.text:SetText(name)
        r:SetScript("OnClick", function() list:Hide() Select(i) end)
        rows[i] = r
    end

    drop:SetScript("OnClick", function(self)
        if list:IsShown() then list:Hide() return end
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        list:Show()
    end)
    prev:SetScript("OnClick", function() Select(mode - 1) end)
    nextB:SetScript("OnClick", function() Select(mode + 1) end)

    local function Refresh()
        drop:SetText(MODES[mode])
        prev:SetEnabled(mode > 1)
        nextB:SetEnabled(mode < #MODES)
        for i, r in ipairs(rows) do
            r.text:SetFontObject(i == mode and GameFontNormalSmall or GameFontHighlightSmall)
        end
        local on = mode ~= 1
        eb:SetAlpha(on and 1 or 0.5)
        label:SetTextColor((on and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR):GetRGB())
        eb:EnableMouse(on)
        if not on then eb:ClearFocus() end
        local idle = mode == 2
        playerOnly:SetEnabled(idle)
        playerOnlyText:SetTextColor((idle and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR):GetRGB())
    end
    ui = { Refresh = Refresh }
    Refresh()
    return box
end

ESF:SetSectionNote("Chat Auto-Hide", "(Also works with the Chattynator addon)")
ESF:RegisterCustomFeature("Chat Auto-Hide", "chatAutoHide", 1, function(v)
    if ESFDB.chatHideSeconds == nil then ESFDB.chatHideSeconds = DEFAULT_SECONDS end
    SetMode(v)
end, BuildWidget)
