-- Hide Chat: fades the whole chat (window, tabs, buttons) to invisible, manually (hide button) or after a timer.
-- Works with Chattynator (if loaded) or the native Blizzard chat.
local ADDON, ESF = ...

local HIDE_MANUAL, HIDE_TIMER = 1, 2
local WAKE_ALL, WAKE_BLINK, WAKE_MOUSE = 1, 2, 3   -- wake on: mouse + blink + message / mouse + blink / mouse only
local DEFAULT_SECONDS, MAX_SECONDS = 60, 3600
local FADE_IN, FADE_OUT = 0.15, 0.6      -- seconds
local SCAN_INTERVAL = 1                  -- Chattynator window scan

local units = {}     -- key -> unit (one per chat window / native dock)
local hooked = {}    -- objects we already hooked
local useChattynator = false

local function Seconds()
    return (ESFDB and ESFDB.chatHideSeconds) or DEFAULT_SECONDS
end

local function Enabled() return ESFDB and ESFDB.chatHide end
local function TimerMode() return ESFDB and ESFDB.chatHideMode == HIDE_TIMER end
local function Wake() return (ESFDB and ESFDB.chatWake) or WAKE_ALL end

----------------------------------------------------------------------
-- Units: frames to fade + a mouse-over test + last-activity time
----------------------------------------------------------------------
local applying = false   -- true while we set alpha ourselves (see the SetAlpha hook in ScanNative)

-- Typing wakes the chat unless "Show Chat While Typing" is off.
local function TypingWakes()
    return ESFDB.chatShowWhileTyping ~= false
end

local function ActiveEditBox()
    return ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
end

-- Fade for one frame of a unit. With typing not waking the chat, the edit box you are
-- typing in stays fully visible on its own.
local function FadeOf(u, f)
    if not TypingWakes() and f == ActiveEditBox() then return 1 end
    return u.alpha
end

local function Apply(u)
    applying = true
    for _, f in ipairs(u.frames) do
        f:SetAlpha(FadeOf(u, f) * u.base[f])
    end
    applying = false
end

-- Frames whose alpha Blizzard also changes itself: its value becomes the base,
-- our fade is applied on top (owner = the unit fading the frame).
local owner = {}
local alphaHooked = {}

local function HookAlpha(f)
    if alphaHooked[f] then return end
    alphaHooked[f] = true
    -- Blizzard sets alpha on some of these itself (e.g. the edit box dims when inactive):
    -- take its value as the new base and keep our fade on top.
    hooksecurefunc(f, "SetAlpha", function(self, a)
        local un = owner[self]
        if applying or not un then return end
        un.base[self] = a
        applying = true
        self:SetAlpha(a * FadeOf(un, self))
        applying = false
    end)
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
    for _, f in ipairs(u.frames) do
        if owner[f] == u then owner[f] = nil end
    end
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
    u.manual = nil   -- anything that wakes the chat ends a hide by the button
    if debug and (reason ~= lastReason or now - lastPrint >= 1) then
        lastReason, lastPrint = reason, now
        Print("ESF chat timer reset: " .. reason)
    end
end

-- kind: "message" (new line in the current tab) or "blink" (a tab started blinking)
local function Poke(u, kind)
    if not u or ownPrint then return end
    if kind == "message" then
        if Wake() == WAKE_ALL then Reset(u, "new message") end
    elseif kind == "blink" then
        if Wake() <= WAKE_BLINK then Reset(u, "tab blinking") end
    end
end

-- Hide button (built at login): hovering it never counts as mouse over the chat.
-- After a click, mouse over only works again once the mouse has left the chat (armed).
local hideButtons = {}   -- key -> button ("main", or the chat window it sits on)
local armed = true

local function HideButtonOver()
    for _, b in pairs(hideButtons) do
        if b:IsShown() and b:IsMouseOver() then return true end
    end
    return false
end

-- The frame the mouse is really on (topmost mouse-enabled frame); nil or WorldFrame if none.
local function MouseFocus()
    if GetMouseFoci then return (GetMouseFoci())[1] end
    return GetMouseFocus and GetMouseFocus()
end

local function IsChatFrame(f)
    return units[f] or owner[f] or f.esfHideButton
        or f == _G.ChattynatorHyperlinkHandler or f == GeneralDockManager
end

-- False when another window lies on top of the chat under the mouse (character panel, bags,
-- ...): being inside the chat's rectangle alone does not count then.
local function MouseOnChat()
    local f = MouseFocus()
    if not f or f == WorldFrame then return true end
    if f.IsForbidden and f:IsForbidden() then return false end
    while f and f ~= UIParent do
        if IsChatFrame(f) then return true end
        f = f:GetParent()
    end
    return false
end

local function MouseOver(u)
    local over = u.over()
    if over == "typing" then return over end
    if HideButtonOver() then return false end
    if over and not MouseOnChat() then return false end
    return armed and over
end

local lastActiveEditBox

-- Chattynator: the shared input box isn't part of any window and gets dimmed (alpha < 1)
-- by Blizzard/Chattynator. While typing with the chat kept hidden there is no dark window
-- behind it, so keep it fully opaque then.
local function KeepInputOpaque(box)
    if useChattynator and box and box == ActiveEditBox() and not TypingWakes() and box:GetAlpha() < 1 then
        applying = true
        box:SetAlpha(1)
        applying = false
    end
end

local inputHooked = false
local function HookInputBox()
    if inputHooked or not ChatFrame1EditBox then return end
    inputHooked = true
    hooksecurefunc(ChatFrame1EditBox, "SetAlpha", function(self)
        if not applying then KeepInputOpaque(self) end
    end)
end

local function Tick(dt)
    local active = ActiveEditBox()
    if active ~= lastActiveEditBox then
        lastActiveEditBox = active
        for _, u in pairs(units) do Apply(u) end
        KeepInputOpaque(active)
        if debug and active then
            C_Timer.After(0.2, function()   -- after Blizzard/Chattynator finished showing it
                Print(("ESF chat: input box alpha %.2f, effective %.2f"):format(
                    active:GetAlpha(), active:GetEffectiveAlpha()))
            end)
        end
    end
    local now = GetTime()
    local secs = Seconds()
    local paused = ESFDB.chatHideNoInstance and IsInInstance()
    local anyOver = HideButtonOver()
    for _, u in pairs(units) do
        local target = 1
        if not armed and u.over() then anyOver = true end
        if u.manual or (Enabled() and TimerMode() and not paused) then
            local over = MouseOver(u)
            if over then
                Reset(u, type(over) == "string" and over or "mouse over")
            elseif u.editbox and u.editbox:IsShown() and TypingWakes() then
                Reset(u, "edit box shown")
            end
            if u.manual or now - u.last >= secs then target = 0 end
        else
            u.last = now   -- paused in an instance: timer starts fresh afterwards
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
    if not armed and not anyOver then armed = true end
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
    -- Chattynator changes the window alpha itself (its own fade option): take its value as
    -- the base and keep our fade on top instead of fighting over it.
    owner[f] = u
    HookAlpha(f)

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

----------------------------------------------------------------------
-- Workaround for a Chattynator bug (Blizzard skin): the unnamed FloatingBorderedFrame backgrounds
-- share global texture names, so every extra window anchors its border to the first window.
-- Re-anchor each border to the window's own textures. Remove once fixed upstream.
----------------------------------------------------------------------
local borderFixed = {}

local function FixChattynatorBorder(f)
    local bg = f.background
    if not bg or borderFixed[bg] or not bg.GetRegions then return end
    borderFixed[bg] = true
    local own = {}   -- texture name -> this window's texture with that name
    for _, r in ipairs({ bg:GetRegions() }) do
        local name = r:GetName()
        if name then own[name] = r end
    end
    for _, r in ipairs({ bg:GetRegions() }) do
        local points, wrong = {}, false
        for i = 1, r:GetNumPoints() do
            local point, rel, relPoint, x, y = r:GetPoint(i)
            local relName = rel and rel.GetName and rel:GetName()
            if relName and own[relName] and own[relName] ~= rel then
                rel, wrong = own[relName], true   -- points at another window's texture
            end
            points[i] = { point, rel, relPoint, x, y }
        end
        if wrong then
            r:ClearAllPoints()
            for _, pt in ipairs(points) do r:SetPoint(unpack(pt)) end
        end
    end
end

local function ScanChattynator()
    local handler = _G.ChattynatorHyperlinkHandler
    if not handler then return end
    local seen = {}
    for _, f in ipairs({ handler:GetChildren() }) do
        if f.ScrollingMessages and f.TabsBar and f.GetID and f:GetID() ~= 0 then
            seen[f] = true
            if not units[f] then AddChattynator(f) end
            FixChattynatorBorder(f)
        end
    end
    for key, u in pairs(units) do
        if u.frame and not seen[key] then RemoveUnit(key) end   -- window closed / released
    end
end

----------------------------------------------------------------------
-- Native adapter
-- units.native: the dock (tab bar, every docked ChatFrameN with its edit box, extra buttons).
-- Every docked tab is its own ChatFrameN (parent UIParent) with its own background and
-- side buttons, so all docked frames are faded, not just ChatFrame1.
-- units["float:<name>"]: one unit per detached (floating) chat window.
-- Rescanned every second because whisper tabs come and go and windows get (un)docked.
----------------------------------------------------------------------
-- Buttons around the chat that are not children of a chat frame (only faded if parented to UIParent).
local EXTRA_FRAMES = {
    "QuickJoinToastButton", "FriendsMicroButton", "ChatFrameMenuButton", "ChatFrameChannelButton",
    "ChatFrameToggleVoiceDeafenButton", "ChatFrameToggleVoiceMuteButton",
}

local function EditBoxOf(cf)
    return cf.editBox or _G[cf:GetName() .. "EditBox"]
end

local function AllChatFrames()
    local list = {}
    if CHAT_FRAMES then
        for _, name in ipairs(CHAT_FRAMES) do
            if _G[name] then list[#list + 1] = _G[name] end
        end
    else
        for i = 1, NUM_CHAT_WINDOWS do
            if _G["ChatFrame" .. i] then list[#list + 1] = _G["ChatFrame" .. i] end
        end
    end
    return list
end

-- key -> list of frames, for the dock and every shown floating window
local function DesiredUnits()
    local want = { native = {} }
    local owned = {}
    local function add(key, f)
        if f and not owned[f] then
            owned[f] = true
            table.insert(want[key], f)
        end
    end

    add("native", GeneralDockManager)
    local docked = (FCFDock_GetChatFrames and GENERAL_CHAT_DOCK) and FCFDock_GetChatFrames(GENERAL_CHAT_DOCK) or { ChatFrame1 }
    for _, cf in ipairs(docked) do
        add("native", cf)
        add("native", EditBoxOf(cf))   -- parent is UIParent, so not faded with the frame
    end
    for _, name in ipairs(EXTRA_FRAMES) do
        local f = _G[name]
        if f and f:GetParent() == UIParent then add("native", f) end
    end

    for _, cf in ipairs(AllChatFrames()) do
        if not owned[cf] and cf:IsShown() then
            local key = "float:" .. cf:GetName()
            want[key] = {}
            add(key, cf)
            local tab = _G[cf:GetName() .. "Tab"]
            if tab and tab:GetParent() ~= GeneralDockManager then add(key, tab) end
            add(key, EditBoxOf(cf))
        end
    end
    return want
end

local function UnitOfChatFrame(cf)
    if cf.isDocked or cf == ChatFrame1 then return units.native end
    return units["float:" .. cf:GetName()]
end

local function NativeOver(u)
    if TypingWakes() and ActiveEditBox() then return "typing" end
    if u == units.native and GeneralDockManager:IsMouseOver() then return "mouse over tabs" end
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


local function HookChatFrame(cf)
    if hooked[cf] then return end
    hooked[cf] = true
    hooksecurefunc(cf, "AddMessage", function(self, _, _, _, _, typeID)
        -- a shown docked frame is the current tab; a floating window is always "current"
        if not self:IsShown() then return end
        if ESFDB.chatHidePlayerOnly and not IsPlayerChatType(typeID) then return end
        Poke(UnitOfChatFrame(self), "message")
    end)
end

local function ScanNative()
    if not units.native then return end
    local want = DesiredUnits()
    local newOwner = {}
    for key, frames in pairs(want) do
        if not units[key] then
            local u = NewUnit({}, nil, nil)
            u.over = function() return NativeOver(u) end
            units[key] = u
        end
        for _, f in ipairs(frames) do newOwner[f] = units[key] end
    end

    -- 1) give frames back whose owner changes (docked <-> floating) or that are gone
    applying = true
    for f, u in pairs(owner) do
        if newOwner[f] ~= u then
            f:SetAlpha(u.base[f])
            u.base[f] = nil
            owner[f] = nil
        end
    end
    applying = false

    -- 2) take over new frames, then apply each unit's fade
    for key, frames in pairs(want) do
        local u = units[key]
        for _, f in ipairs(frames) do
            if not owner[f] then
                local a = f:GetAlpha()
                u.base[f] = a > 0.05 and a or 1
                owner[f] = u
                HookAlpha(f)
            end
            if f:IsObjectType("ScrollingMessageFrame") then HookChatFrame(f) end
        end
        u.frames = frames
        Apply(u)
    end

    -- 3) drop units of windows that were closed or docked again
    for key in pairs(units) do
        if strfind(key, "^float:") and not want[key] then units[key] = nil end
    end
end

local function SetupNative()
    units.native = NewUnit({}, nil, not ChatEdit_GetActiveWindow and ChatFrame1EditBox or nil)
    units.native.over = function() return NativeOver(units.native) end
    ScanNative()
    if FCF_StartAlertFlash then
        hooksecurefunc("FCF_StartAlertFlash", function(cf)
            Poke(cf and UnitOfChatFrame(cf) or units.native, "blink")
        end)
    end
end

----------------------------------------------------------------------
-- Hide button: fades every chat window out at once.
-- Child of the social button, so it follows that button's position, alpha and
-- visibility (Chattynator's show/fade rules, our own native fade).
----------------------------------------------------------------------
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\HideChat.tga"
local ICON_COLOR = { 0.925, 0.804, 0.063 }   -- same yellow as Chattynator's button icons

local function HideAllNow()
    for _, u in pairs(units) do u.manual = true end
    armed = false
    if debug then
        lastReason = nil   -- show the next reset reason even if it repeats
        Print("ESF chat: hide button clicked")
    end
end

-- A styled hide button, child of `anchor` (so it follows its position, alpha and visibility).
local function NewHideButton(anchor)
    local b = CreateFrame("Button", nil, anchor)
    b.esfHideButton = true
    local size = useChattynator and 12 or 16   -- icon size
    if useChattynator then
        b:SetSize(26, 28)   -- Chattynator's chat button size
    else
        b:SetSize(32, 32)   -- native chat button size
    end

    -- same calls as Chattynator's Blizzard skin, so the art renders the same way
    b:SetNormalTexture("chatframe-button-up")
    b:SetPushedTexture("chatframe-button-down")
    if useChattynator then
        b:SetHighlightTexture("chatframe-button-highlight")
    else
        b:SetHighlightTexture(130757, "ADD")   -- highlight of the native chat buttons
    end

    local icon = b:CreateTexture(nil, "OVERLAY")
    icon:SetTexture(ICON)
    icon:SetSize(size, size)
    icon:SetPoint("CENTER")
    icon:SetVertexColor(unpack(ICON_COLOR))
    b:SetScript("OnMouseDown", function() icon:SetPoint("CENTER", 2, -2) end)
    b:SetScript("OnMouseUp", function() icon:SetPoint("CENTER") end)

    b:SetScript("OnClick", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        HideAllNow()
    end)
    -- Chattynator "show on hover": keep its buttons shown while ours is hovered
    local bar = anchor:GetParent()
    local function BarScript(name)
        local fn = useChattynator and bar and bar ~= UIParent and bar:GetScript(name)
        if fn then fn(bar) end
    end
    b:SetScript("OnEnter", function(self)
        -- no tooltip while the button is faded out with the chat
        if self:GetEffectiveAlpha() > 0.5 then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(WHITE_FONT_COLOR:WrapTextInColorCode("Hide Chat"))
            GameTooltip:Show()
        end
        BarScript("OnEnter")
    end)
    b:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        BarScript("OnLeave")
    end)
    return b
end

-- Buttons show when hiding is on; with manual hiding they are the only way to hide, so always.
local function ShowButtons()
    return Enabled() and (not TimerMode() or ESFDB.chatHideButton ~= false)
end

-- Main window: next to (native) or above (Chattynator) the social button.
local function CreateMainHideButton()
    local social = QuickJoinToastButton or FriendsMicroButton
    local anchor = social or (useChattynator and ChattynatorHyperlinkHandler) or GeneralDockManager
    local b = NewHideButton(anchor)
    if social and useChattynator then
        b:SetPoint("BOTTOM", social, "TOP", 0, 5)   -- column above the social button
    elseif social then
        b:SetPoint("LEFT", social, "RIGHT", 2, 0)
    elseif useChattynator then
        b:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
    else
        b:SetPoint("BOTTOMRIGHT", anchor, "TOPLEFT", -2, 2)
    end
    hideButtons.main = b
end

-- Every other window gets its own button (each hides all chats):
-- Chattynator: above that window's button column (its top button is the search button).
-- Native: above a floating window's side buttons; hidden while the window is docked.
local function UpdateHideButtons()
    if useChattynator then
        for key, u in pairs(units) do
            local f = u.frame
            local top = f and f:GetID() ~= 1 and f.ButtonsBar and f.ButtonsBar.SearchButton
            if top and not hideButtons[f] then
                local b = NewHideButton(top)
                b:SetPoint("BOTTOM", top, "TOP", 0, 5)
                hideButtons[f] = b
            end
        end
    else
        for key in pairs(units) do
            local cf = strmatch(key, "^float:(.+)$") and _G[strmatch(key, "^float:(.+)$")]
            local side = cf and (cf.buttonFrame or _G[cf:GetName() .. "ButtonFrame"])
            if side and not hideButtons[cf] then
                local b = NewHideButton(side)
                b:SetPoint("BOTTOM", side, "TOP", 0, 2)
                b.chatFrame = cf
                hideButtons[cf] = b
            end
        end
    end
    for key, b in pairs(hideButtons) do
        local show = ShowButtons()
        if b.chatFrame then   -- native: only while that window floats
            show = show and units["float:" .. b.chatFrame:GetName()] ~= nil
        end
        b:SetShown(show)
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
    if useChattynator then HookInputBox() end
    CreateMainHideButton()
    UpdateHideButtons()
    self:SetScript("OnUpdate", function(_, dt)
        scanAcc = scanAcc + dt
        if scanAcc >= SCAN_INTERVAL then
            scanAcc = 0
            if useChattynator then ScanChattynator() else ScanNative() end
            UpdateHideButtons()
        end
        Tick(dt)
    end)
end)

-- Any change to the hide/wake settings: start the timer fresh, end a manual hide when switched off.
local function SettingsChanged()
    local now = GetTime()
    for _, u in pairs(units) do
        u.last = now
        if not Enabled() then u.manual = nil end
    end
    if hideButtons.main then UpdateHideButtons() end
end

-- /esf testhide [seconds]: pretend the last activity was long ago, so the chat hides
-- after the given seconds (default 3). Mouse over or an open edit box still keeps it shown.
ESF.commands.testhide = function(rest)
    if not (Enabled() and TimerMode()) then
        Print("ESF: Hide Chat must be enabled and set to After Timer first")
        return
    end
    local secs = tonumber(rest) or 3
    local now = GetTime()
    for _, u in pairs(units) do u.last = now - Seconds() + secs end
    Print("ESF: chat hides in " .. secs .. " s (move the mouse away from the chat)")
end

-- /esf hidechat: hide the chat instantly (no fade). Works with both hide modes, also in instances.
ESF.commands.hidechat = function()
    if not Enabled() then return end
    for _, u in pairs(units) do
        u.manual = true
        u.alpha = 0
        Apply(u)
    end
end

ESF.commands.chatdebug = function()
    debug = not debug
    lastReason = nil
    Print("ESF: chat debug " .. (debug and "on" or "off"))
end

----------------------------------------------------------------------
-- Settings rows
----------------------------------------------------------------------
-- Old saved setting (one 4-step mode) -> new settings. Runs once.
table.insert(ESF.onLoad, function()
    local old = ESFDB.chatAutoHide
    if old == nil or ESFDB.chatHide ~= nil then return end
    ESFDB.chatHide = old ~= 1
    ESFDB.chatHideMode = HIDE_TIMER
    ESFDB.chatWake = ({ [2] = WAKE_ALL, [3] = WAKE_BLINK, [4] = WAKE_MOUSE })[old] or WAKE_ALL
    ESFDB.chatAutoHide = nil
end)

local enable = ESF:Module({
    name = "Hide Chat", key = "chatHide",
    desc = "Fades the chat out after a timer or on click",
    note = "Fades the whole chat out: tabs, windows, buttons and the input box.",
    onChange = SettingsChanged,
})

local hideMode = ESF:Dropdown({
    key = "chatHideMode", label = "Hide", default = HIDE_TIMER, parent = enable,
    enabledIf = Enabled, noRowTooltip = true,
    options = {
        { HIDE_MANUAL, "Manually", "Only the hide button hides the chat." },
        { HIDE_TIMER, "After Timer", "Hides the chat after the seconds below without activity." },
    },
    onChange = SettingsChanged,
})

ESF:Custom({
    label = "Seconds Until Hidden", parent = hideMode,
    tooltip = "Seconds without activity until the chat hides (1 - " .. MAX_SECONDS .. ").",
    enabledIf = function() return Enabled() and TimerMode() end,
    create = function(row)
        local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        eb:SetSize(60, 20)
        eb:SetPoint("LEFT", row, "CENTER", -76, 0)
        eb:SetAutoFocus(false)
        eb:SetNumeric(true)
        eb:SetMaxLetters(4)
        local function Commit()
            local n = tonumber(eb:GetText())
            n = n and math.max(1, math.min(MAX_SECONDS, math.floor(n))) or Seconds()
            ESFDB.chatHideSeconds = n
            eb:SetText(tostring(n))
        end
        eb:SetScript("OnEnterPressed", function(self) Commit() self:ClearFocus() end)
        eb:SetScript("OnEditFocusLost", Commit)
        eb:SetScript("OnEscapePressed", function(self)
            self:SetText(tostring(Seconds()))
            self:ClearFocus()
        end)
        return eb
    end,
    update = function(eb, on)
        if not eb:HasFocus() then
            eb:SetText(tostring(Seconds()))
            eb:SetCursorPosition(0)
        end
        eb:EnableMouse(on)
        eb:SetAlpha(on and 1 or 0.5)
        if not on then eb:ClearFocus() end
    end,
})

local wake = ESF:Dropdown({
    key = "chatWake", label = "Wake Up", default = WAKE_ALL, parent = enable,
    enabledIf = Enabled, noRowTooltip = true,
    options = {
        { WAKE_ALL, "Mouse Over, Blinking or New Message", "New messages in the selected tab also restart the timer." },
        { WAKE_BLINK, "Mouse Over or Blinking" },
        { WAKE_MOUSE, "Mouse Over Only" },
    },
    onChange = SettingsChanged,
})

ESF:Checkbox({
    key = "chatHidePlayerOnly", label = "Only Player Messages", default = false, parent = wake,
    tooltip = "Only messages written by players wake the chat. Loot, XP, emotes and system messages are ignored.",
    enabledIf = function() return Enabled() and Wake() == WAKE_ALL end,
})

ESF:Checkbox({
    key = "chatHideNoInstance", label = "Never Auto-Hide in Instances", default = false, parent = enable,
    tooltip = "The timer does not hide the chat in dungeons, raids, battlegrounds and arenas. The hide button still works.",
    enabledIf = function() return Enabled() and TimerMode() end,
})

ESF:Checkbox({
    key = "chatHideButton", label = "Show Hide Button", default = true, parent = enable,
    tooltip = "A button on each chat window that fades the chat out instantly. Always shown when hiding manually.",
    enabledIf = function() return Enabled() and TimerMode() end,
    onChange = function() if hideButtons.main then UpdateHideButtons() end end,
})

ESF:Checkbox({
    key = "chatShowWhileTyping", label = "Show Chat While Typing", default = true, parent = enable,
    tooltip = "Pressing Enter brings the chat back. Off: only the input box appears.",
    enabledIf = Enabled,
    onChange = function() for _, u in pairs(units) do Apply(u) end end,
})

-- seconds default, so the box never starts empty
table.insert(ESF.onLoad, function()
    if ESFDB.chatHideSeconds == nil then ESFDB.chatHideSeconds = DEFAULT_SECONDS end
end)
