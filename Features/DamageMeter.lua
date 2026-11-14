-- Minimap button that toggles Blizzard's damage meter between "maximized and visible"
-- and "invisible but still active". The native minimize button only hides it.
--
-- Taint note: the meter shows secret values in combat, and Blizzard's meter code does
-- math on them. If addon code calls into it (Show, SetSessionWindowMinimized, ...),
-- that code runs tainted and errors - even later, because values it writes stay tainted
-- (e.g. a window's isMinimized flag). So we only use plain widget calls on it:
-- SetAlpha / EnableMouse. The native minimize click is caught by our own invisible
-- button on top of it, so Blizzard's minimize code never runs.
local ADDON, ESF = ...

local BUTTON_NAME = "ESF_DamageMeterMinimapButton"   -- "MinimapButton" in the name: MinimapButtonButton collects it
local MINIMAP_ANGLE = 225                             -- degrees, bottom left
local MOUSE_SCAN_INTERVAL = 1                         -- seconds, while hidden

local enabled = false
local ready = false        -- Blizzard's meter found and hooked
local applying = false     -- true while we set the alpha ourselves
local overlays = {}        -- session window -> our button on its minimize button
local mouseOff = {}        -- frame -> { mouse = bool, wheel = bool } we turned off
local ticker
local minimapButton

local function IsHidden()
    return ESFCharDB and ESFCharDB.dmHidden or false
end

local function IsEditing()
    return DamageMeter.IsEditing and DamageMeter:IsEditing()
end

local function ForEachWindow(fn)
    for i = 1, 3 do
        local win = _G["DamageMeterSessionWindow" .. i]
        if win then fn(win) end
    end
end

----------------------------------------------------------------------
-- Mouse: an invisible meter must not catch clicks, tooltips or the mouse wheel
----------------------------------------------------------------------
local function DisableMouse(frame)
    if frame:IsForbidden() then return end
    local st = mouseOff[frame]
    if frame:IsMouseEnabled() then
        frame:EnableMouse(false)
        st = st or {}; st.mouse = true
    end
    if frame:IsMouseWheelEnabled() then
        frame:EnableMouseWheel(false)
        st = st or {}; st.wheel = true
    end
    mouseOff[frame] = st
    for _, child in ipairs({ frame:GetChildren() }) do
        DisableMouse(child)
    end
end

local function RestoreMouse()
    for frame, st in pairs(mouseOff) do
        if st.mouse then frame:EnableMouse(true) end
        if st.wheel then frame:EnableMouseWheel(true) end
    end
    wipe(mouseOff)
end

----------------------------------------------------------------------
-- Apply the current state
----------------------------------------------------------------------
local function UpdateOverlays()
    local editing = IsEditing()
    for win, o in pairs(overlays) do
        o:SetShown(enabled and not editing and not (win.IsMinimized and win:IsMinimized()))
    end
end

local function Apply()
    if not ready then return end
    local hide = enabled and IsHidden() and not IsEditing()

    applying = true
    DamageMeter:SetAlpha(hide and 0 or 1)
    applying = false

    if hide then
        DisableMouse(DamageMeter)
        -- entry frames get created as the list grows, catch those too
        ticker = ticker or C_Timer.NewTicker(MOUSE_SCAN_INTERVAL, function() DisableMouse(DamageMeter) end)
    else
        if ticker then ticker:Cancel(); ticker = nil end
        RestoreMouse()
    end

    UpdateOverlays()
end

local function SetHidden(hidden)
    ESFCharDB.dmHidden = hidden
    Apply()
end

----------------------------------------------------------------------
-- Our invisible button on top of the native minimize button
----------------------------------------------------------------------
local function AttachOverlay(win)
    if overlays[win] or not win.MinimizeButton then return end
    local native = win.MinimizeButton

    local o = CreateFrame("Button", nil, win)
    o:SetAllPoints(native)
    o:SetFrameLevel(native:GetFrameLevel() + 5)
    o:RegisterForClicks("LeftButtonUp")
    -- forward the visuals to the native button (plain widget calls, no Blizzard code)
    o:SetScript("OnEnter", function() native:LockHighlight() end)
    o:SetScript("OnLeave", function() native:UnlockHighlight(); native:SetButtonState("NORMAL") end)
    o:SetScript("OnMouseDown", function() native:SetButtonState("PUSHED") end)
    o:SetScript("OnMouseUp", function() native:SetButtonState("NORMAL") end)
    o:SetScript("OnClick", function() SetHidden(true) end)
    overlays[win] = o

    -- a minimized window (e.g. from before ESF) shows the native expand button instead
    if win.SetMinimized then
        hooksecurefunc(win, "SetMinimized", UpdateOverlays)
    end
end

----------------------------------------------------------------------
-- Minimap button: dark grey circle with a green "D"
----------------------------------------------------------------------
local function CreateMinimapButton()
    local b = CreateFrame("Button", BUTTON_NAME, Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER", 0, 1)
    bg:SetColorTexture(0.11, 0.11, 0.12)
    local mask = b:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bg)
    bg:AddMaskTexture(mask)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local text = b:CreateFontString(nil, "ARTWORK")
    text:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
    text:SetPoint("CENTER", 0.5, 1)
    text:SetText("D")
    local g = GREEN_FONT_COLOR
    text:SetTextColor(g and g.r or 0.1, g and g.g or 1, g and g.b or 0.1)
    text:SetShadowColor(0, 0, 0, 0.9)
    text:SetShadowOffset(1, -1)

    b:SetScript("OnMouseDown", function() text:SetPoint("CENTER", 1.5, 0) end)
    b:SetScript("OnMouseUp", function() text:SetPoint("CENTER", 0.5, 1) end)
    b:SetScript("OnClick", function()
        if not ready then
            print("ESF: Blizzard's damage meter was not found.")
            return
        end
        SetHidden(not IsHidden())
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Damage Meter")
        GameTooltip:AddLine("Click to show or hide", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    return b
end

minimapButton = CreateMinimapButton()
minimapButton:Hide()

----------------------------------------------------------------------
-- Position on the minimap border; drag to move it along the border.
-- Only while the button is still on the Minimap: once MinimapButtonButton
-- has collected it, MBB owns the position and dragging is off.
----------------------------------------------------------------------
local function OnMinimap()
    return minimapButton:GetParent() == Minimap
end

local function PlaceAt(deg)
    local a = math.rad(deg)
    local r = Minimap:GetWidth() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function SavedAngle()
    return ESFDB and ESFDB.dmMinimapAngle or MINIMAP_ANGLE
end

local function CursorAngle()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    return math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
end

local dragged = false
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetScript("OnDragStart", function(self)
    if not OnMinimap() then return end
    dragged = true
    GameTooltip:Hide()
    self:SetScript("OnUpdate", function() PlaceAt(CursorAngle()) end)
end)
minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    if not OnMinimap() then return end
    ESFDB.dmMinimapAngle = CursorAngle()
    PlaceAt(ESFDB.dmMinimapAngle)
end)

-- a drag must not also toggle the meter
local onClick = minimapButton:GetScript("OnClick")
minimapButton:SetScript("OnClick", function(...)
    if dragged then dragged = false return end
    onClick(...)
end)
minimapButton:HookScript("OnMouseDown", function() dragged = false end)

PlaceAt(MINIMAP_ANGLE)   -- saved angle is applied at login

-- The button only shows while the meter is enabled in Blizzard's options (CVar damageMeterEnabled).
local function MeterEnabled()
    if C_CVar and C_CVar.GetCVarBool then return C_CVar.GetCVarBool("damageMeterEnabled") and true or false end
    return GetCVarBool and GetCVarBool("damageMeterEnabled") and true or false
end

-- Show/Hide, not SetShown: MinimapButtonButton hooks Show and Hide to update its layout.
local function UpdateButton()
    if enabled and MeterEnabled() then
        minimapButton:Show()
    else
        minimapButton:Hide()
    end
end

----------------------------------------------------------------------
-- Hook Blizzard's meter once it is loaded
----------------------------------------------------------------------
local function Init()
    if ready then return end
    if not (DamageMeter and DamageMeter.SetAlpha) then return end
    ready = true

    ForEachWindow(AttachOverlay)
    if DamageMeter.SetupSessionWindow then   -- secondary windows are created later
        hooksecurefunc(DamageMeter, "SetupSessionWindow", function(_, _, windowData)
            if windowData and windowData.sessionWindow then AttachOverlay(windowData.sessionWindow) end
            Apply()
        end)
    end
    -- Blizzard re-checks the enabled setting here too (e.g. when the option is changed)
    if DamageMeter.UpdateShownState then
        hooksecurefunc(DamageMeter, "UpdateShownState", UpdateButton)
    end
    if DamageMeter.SetIsEditing then
        hooksecurefunc(DamageMeter, "SetIsEditing", Apply)
    end
    hooksecurefunc(DamageMeter, "SetAlpha", function()
        if not applying then Apply() end
    end)

    -- A window that is still minimized (from before ESF) is left alone: our overlay stays
    -- hidden then, so the native expand button works. Expanding it ourselves would taint it.
    Apply()
end

-- At login our settings are loaded and Blizzard's meter normally exists already.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CVAR_UPDATE")
ev:SetScript("OnEvent", function(_, event, name)
    if event == "CVAR_UPDATE" then
        if name == "damageMeterEnabled" then UpdateButton() end
        return
    end
    if OnMinimap() then PlaceAt(SavedAngle()) end
    UpdateButton()
    if DamageMeter then
        Init()
    elseif EventUtil and EventUtil.ContinueOnAddOnLoaded then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_DamageMeter", Init)
    end
end)

ESF:Module({
    name = "Damage Meter Button", key = "dmMinimapButton",
    desc = "Minimap button that shows or hides the damage meter completely",
    note = "A minimap button: click shows the damage meter maximized or hides it completely.",
    onChange = function(on)
        enabled = on
        UpdateButton()
        if not on and ESFCharDB then ESFCharDB.dmHidden = false end
        Apply()
    end,
})
