-- Small tweaks that don't need their own module:
-- bars that only show on mouseover, and pet keybinds that toggle autocast.
local ADDON, ESF = ...

local TICK = 0.05          -- seconds between mouse checks
local HIDE_DELAY = 0.4     -- seconds a bar stays visible after the mouse left
local FADE_TIME = 1        -- seconds the fade out takes after that
local TOUCH_GAP = 8        -- bars closer than this count as touching (UIParent units)
local EDGE_GAP = 3         -- bars closer than this to a screen edge are hoverable up to and past it

local mod

----------------------------------------------------------------------
-- Mouseover bars
----------------------------------------------------------------------
-- Each element is one Edit Mode system. Elements that touch form a group
-- and show together. Status bar containers run Blizzard's fade animations
-- on their own alpha, so for those only the contents are faded.
local elements = {
    { key = "miscHideBags", frame = function() return BagsBar end, art = true,
      managed = { bartender = "BagBar", dominos = "Dominos" } },
    { key = "miscHideMicroMenu", frame = function() return MicroMenuContainer end, art = true,
      managed = { bartender = "MicroMenu", dominos = "Dominos" } },
    { key = "miscHideStatusBars", frame = function() return MainStatusTrackingBarContainer end, contents = true,
      managed = { bartender = { "StatusTrackingBar", "XPBar" }, dominos = "Dominos_Progress" } },
    { key = "miscHideStatusBars", frame = function() return SecondaryStatusTrackingBarContainer end, contents = true,
      managed = { bartender = { "StatusTrackingBar", "RepBar" }, dominos = "Dominos_Progress" } },
}

local IsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded

local function BartenderModuleOn(names)
    local bt = _G.Bartender4
    if not (bt and bt.GetModule) then return false end
    for _, name in ipairs(type(names) == "table" and names or { names }) do
        local m = bt:GetModule(name, true)
        if m and m:IsEnabled() then return true end
    end
    return false
end

-- Name of the addon that replaces this bar, or nil.
local function ManagedBy(e)
    if BartenderModuleOn(e.managed.bartender) then return "Bartender" end
    if IsLoaded(e.managed.dominos) then return "Dominos" end
end

local function ManagedByKey(key)
    for _, e in ipairs(elements) do
        if e.key == key then
            local by = ManagedBy(e)
            if by then return by end
        end
    end
end

local editing = false
local applied = {}    -- element -> alpha we set last (nil = untouched)

local function SetElementAlpha(e, alpha)
    if applied[e] == alpha then return end
    local f = e.frame()
    if not f then return end
    applied[e] = alpha
    if e.contents then
        for _, child in ipairs({ f:GetChildren() }) do
            if child ~= f.Selection then child:SetAlpha(alpha) end   -- keep the Edit Mode overlay
        end
        for _, region in ipairs({ f:GetRegions() }) do region:SetAlpha(alpha) end
    else
        f:SetAlpha(alpha)
    end
end

-- Bounds in UIParent units. With depth > 0 this includes visible child frames
-- and textures, since the bag bar and Micro Menu draw their border art
-- outside their own rect.
local function Bounds(f, depth, box)
    local l, b, w, h = f:GetRect()
    if l then
        local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
        l, b, w, h = l * s, b * s, w * s, h * s
        if not box then
            box = { l, b, l + w, b + h }
        else
            box[1], box[2] = math.min(box[1], l), math.min(box[2], b)
            box[3], box[4] = math.max(box[3], l + w), math.max(box[4], b + h)
        end
    end
    if depth > 0 then
        for _, region in ipairs({ f:GetRegions() }) do
            if region:IsVisible() then
                local rl, rb, rw, rh = region:GetRect()
                if rl and box then
                    local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
                    box[1], box[2] = math.min(box[1], rl * s), math.min(box[2], rb * s)
                    box[3], box[4] = math.max(box[3], (rl + rw) * s), math.max(box[4], (rb + rh) * s)
                end
            end
        end
        for _, child in ipairs({ f:GetChildren() }) do
            if child:IsVisible() and child ~= f.Selection then box = Bounds(child, depth - 1, box) end
        end
    end
    return box
end

local function Rect(e)
    local f = e.frame()
    if not (f and f:IsVisible()) then return end
    local box = Bounds(f, e.art and 2 or 0)
    if box then return box[1], box[2], box[3], box[4] end
end

local function Touch(a, b)
    return a[1] <= b[3] + TOUCH_GAP and b[1] <= a[3] + TOUCH_GAP
       and a[2] <= b[4] + TOUCH_GAP and b[2] <= a[4] + TOUCH_GAP
end

local active = {}       -- elements we currently hide
local lastHover = {}    -- element -> GetTime() of the last mouseover of its group

-- Returns true while a bar is fading out.
local function Tick()
    local now = GetTime()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    x, y = x / s, y / s

    -- current rects; hidden bars take no part in grouping
    local list = {}
    for _, e in ipairs(active) do
        local l, b, r, t = Rect(e)
        if l then table.insert(list, { e = e, l, b, r, t }) end
    end

    -- groups of touching bars (union-find)
    local root = {}
    for i = 1, #list do root[i] = i end
    local function Find(i)
        while root[i] ~= i do i = root[i] end
        return i
    end
    for i = 1, #list do
        for j = i + 1, #list do
            if Touch(list[i], list[j]) then root[Find(i)] = Find(j) end
        end
    end

    -- Edit Mode tends to leave a pixel or so between a bar and the screen edge,
    -- so a cursor pushed against that edge would miss the bar.
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local hovered = {}
    for i, r in ipairs(list) do
        local l = r[1] <= EDGE_GAP and -math.huge or r[1]
        local b = r[2] <= EDGE_GAP and -math.huge or r[2]
        local rt = r[3] >= w - EDGE_GAP and math.huge or r[3]
        local t = r[4] >= h - EDGE_GAP and math.huge or r[4]
        if x >= l and x <= rt and y >= b and y <= t then hovered[Find(i)] = true end
    end
    for i, r in ipairs(list) do
        if hovered[Find(i)] then lastHover[r.e] = now end
    end

    local fading = false
    for _, e in ipairs(active) do
        local alpha = 0
        if editing then
            alpha = 1
        elseif lastHover[e] then
            alpha = 1 - (now - lastHover[e] - HIDE_DELAY) / FADE_TIME
            if alpha >= 1 then
                alpha = 1
            elseif alpha <= 0 then
                alpha = 0
                lastHover[e] = nil
            else
                fading = true
            end
        end
        SetElementAlpha(e, alpha)
    end
    return fading
end

local ticker = CreateFrame("Frame")
local elapsed, fading = 0, false
local function OnUpdate(_, dt)
    elapsed = elapsed + dt
    if elapsed < TICK and not fading then return end   -- every frame while fading, for a smooth fade
    elapsed = 0
    fading = Tick()
end

local function UpdateBars()
    wipe(active)
    if ESFDB and mod and mod:IsOn() then
        for _, e in ipairs(elements) do
            if ESFDB[e.key] and e.frame() and not ManagedBy(e) then table.insert(active, e) end
        end
    end
    -- bars we no longer handle go back to normal
    for e in pairs(applied) do
        if not tContains(active, e) then
            SetElementAlpha(e, 1)
            applied[e] = nil
        end
    end
    if #active > 0 then
        ticker:SetScript("OnUpdate", OnUpdate)
        fading = Tick()
    else
        ticker:SetScript("OnUpdate", nil)
    end
end

if EventRegistry then
    EventRegistry:RegisterCallback("EditMode.Enter", function() editing = true end, ticker)
    EventRegistry:RegisterCallback("EditMode.Exit", function() editing = false end, ticker)
end

----------------------------------------------------------------------
-- Pet keybinds toggle autocast
----------------------------------------------------------------------
-- The keys bound to Blizzard's pet action slots are overridden with our own
-- secure buttons that run /petautocasttoggle. Clicking the pet button still
-- casts. Bindings can't change in combat, so changes wait until it ends.
local NUM_PET_SLOTS = NUM_PET_ACTION_SLOTS or 10

local petToggle = false
local petOwner = CreateFrame("Frame")
local petButtons = {}
for i = 1, NUM_PET_SLOTS do
    local b = CreateFrame("Button", "ESF_PetAutocastButton" .. i, UIParent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "macro")
    petButtons[i] = b
end

local petApplied = ""   -- what was bound last; UPDATE_BINDINGS also fires for our own overrides
local petPending = false

local function UpdatePetBindings()
    if InCombatLockdown() then
        petPending = true
        return
    end
    petPending = false

    local wanted, parts = {}, {}
    if petToggle and ESFDB and mod:IsOn() then
        for i = 1, NUM_PET_SLOTS do
            local name, _, isToken, _, autoCastAllowed = GetPetActionInfo(i)
            if name and not isToken and autoCastAllowed then
                for _, key in ipairs({ GetBindingKey("BONUSACTIONBUTTON" .. i) }) do
                    table.insert(wanted, { slot = i, key = key, name = name })
                    table.insert(parts, key .. "=" .. name)
                end
            end
        end
    end
    local sig = table.concat(parts, ";")
    if sig == petApplied then return end
    petApplied = sig

    ClearOverrideBindings(petOwner)
    for _, w in ipairs(wanted) do
        local b = petButtons[w.slot]
        b:SetAttribute("macrotext", "/petautocasttoggle " .. w.name)
        SetOverrideBindingClick(petOwner, true, w.key, b:GetName())
    end
end

petOwner:RegisterEvent("PLAYER_LOGIN")
petOwner:RegisterEvent("PET_BAR_UPDATE")
petOwner:RegisterUnitEvent("UNIT_PET", "player")
petOwner:RegisterEvent("UPDATE_BINDINGS")
petOwner:RegisterEvent("PLAYER_REGEN_ENABLED")
petOwner:RegisterEvent("ADDON_LOADED")
petOwner:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if petPending then UpdatePetBindings() end
        return
    end
    if event == "ADDON_LOADED" then
        UpdateBars()
        return
    end
    if event == "PLAYER_LOGIN" then
        C_Timer.After(0, UpdateBars)   -- Bartender enables its modules at login
    end
    UpdatePetBindings()
end)

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
mod = ESF:Module({
    name = "Misc", key = "misc",
    desc = "Small tweaks that don't need their own module",
    note = "Small tweaks that don't need their own module.",
})

ESF:Section("Hide UI Elements", "Mouseover will bring the elements back temporarily.")

local function BarCheckbox(key, label, tooltip)
    ESF:Checkbox({
        key = key, label = label, default = false,
        tooltip = function()
            local by = ManagedByKey(key)
            return by and ("Managed by " .. by .. ".") or tooltip
        end,
        enabledIf = function() return not ManagedByKey(key) end,
        onChange = UpdateBars,
    })
end

BarCheckbox("miscHideBags", "Bag Bar", "Backpack, bag slots, reagent bag and key ring.")
BarCheckbox("miscHideMicroMenu", "Micro Menu", "Character, Spellbook, Talents, Guild and the other menu buttons.")
BarCheckbox("miscHideStatusBars", "Experience Bar", "Also the second status bar, such as a tracked reputation.")

ESF:Section("Pet Bar")

ESF:Checkbox({
    key = "miscPetAutocastKeys", label = "Keybinds Toggle Autocast", default = false,
    tooltip = "Keybinds of pet abilities that can autocast turn autocast on or off instead of using the ability. Clicking the button still uses it.",
    onChange = function(on)
        petToggle = on
        UpdatePetBindings()
    end,
})
