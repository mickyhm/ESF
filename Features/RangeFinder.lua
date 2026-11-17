local ADDON, ESF = ...

-- Default dot position relative to the target frame (used until the dot is moved).
local DOT_GAP_ABOVE = -20
local DOT_TEXTURE = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\Dot.tga"
local RADIUS_DEFAULT, RADIUS_MIN, RADIUS_MAX = 4, 2, 14
local HANDLE_TEXTURE = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\Move.tga"
local HANDLE_SIZE, HANDLE_GAP = 36, 4
local HANDLE_REACH = 4.5   -- from the handle center to the visible edge of the cross along the diagonal
local HANDLE_DISTANCE = 3   -- multiplier on the minimum distance from the dot
local TICK_SIZE, TICK_STEP = 2, 6.5   -- screen pixels (step is per axis)

local enabled = { Hostile = false, Friendly = false }
local unlocked = false

----------------------------------------------------------------------
-- Spell helpers (modern C_Spell/C_SpellBook with fallbacks to old globals)
----------------------------------------------------------------------
local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return (GetSpellInfo(id))
end

local function SpellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    return GetSpellTexture(id)
end

-- All known active (non-passive) spells, one entry per name (ranks collapse), sorted.
local function CollectSpells()
    local list, seen = {}, {}
    local function add(id)
        if not id then return end
        local name = SpellName(id)
        if not name or seen[name] then return end
        seen[name] = true
        list[#list + 1] = { id = id, name = name }
    end

    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if li then
                for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                    local info = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    if info and info.itemType == Enum.SpellBookItemType.Spell
                        and not info.isPassive and not info.isOffSpec then
                        add(info.spellID)
                    end
                end
            end
        end
    elseif GetNumSpellTabs then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, num = GetSpellTabInfo(tab)
            for i = offset + 1, offset + num do
                local t, id = GetSpellBookItemInfo(i, "spell")
                if t == "SPELL" and not IsPassiveSpell(i, "spell") then add(id) end
            end
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

----------------------------------------------------------------------
-- The dot (parented to UIParent so it can show while unlocked without a target;
-- anchored to TargetFrame so it follows that frame)
----------------------------------------------------------------------
local dot = CreateFrame("Frame", "ESFRangeDot", UIParent)
dot:SetFrameStrata("MEDIUM")
dot:SetFrameLevel(900)
dot:SetClampedToScreen(true)
dot:SetMovable(true)
dot:RegisterForDrag("LeftButton")
dot:SetPoint("BOTTOM", TargetFrame, "TOP", 0, DOT_GAP_ABOVE)   -- refined by ApplyPosition

local dotTex = dot:CreateTexture(nil, "OVERLAY")
dotTex:SetAllPoints()
dotTex:SetTexture(DOT_TEXTURE)
dotTex:SetVertexColor(1, 0, 0, 1)   -- white fill -> red, black border stays black
if dotTex.SetSnapToPixelGrid then
    dotTex:SetSnapToPixelGrid(false)
    dotTex:SetTexelSnappingBias(0)
end
dot:Hide()

local function Radius()
    return (ESFDB and ESFDB.rangeDotRadius) or RADIUS_DEFAULT
end

local UpdateHandle

local function ApplySize()
    local r = Radius()
    dot:SetSize(r * 2, r * 2)
    if UpdateHandle then UpdateHandle() end
end
ApplySize()

local function TargetHealthBar()
    local obj = TargetFrame
    for _, k in ipairs({ "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar" }) do
        if type(obj) ~= "table" then return nil end
        obj = obj[k]
    end
    return type(obj) == "table" and obj or nil
end

-- Horizontal offset of the health bar's center from the frame's center (portrait ignored).
-- Measured once; nil until a measurement succeeds. The bar's position can be a secret
-- value (no arithmetic allowed), so the math runs in pcall and failures are retried later.
local barDx

local function MeasureBarDx()
    if barDx then return end
    local bar = TargetHealthBar()
    if not bar then return end
    local ok, dx = pcall(function()
        local bx, tx = bar:GetCenter(), TargetFrame:GetCenter()
        if bx and tx then
            return bx * bar:GetEffectiveScale() / TargetFrame:GetEffectiveScale() - tx
        end
    end)
    if ok and dx then barDx = dx end
end

local function ApplyPosition()
    local pos = ESFDB and ESFDB.rangeDotPos
    dot:ClearAllPoints()
    if pos then
        dot:SetPoint("CENTER", TargetFrame, "CENTER", pos.x, pos.y)
        return
    end
    MeasureBarDx()
    dot:SetPoint("BOTTOM", TargetFrame, "TOP", barDx or 0, DOT_GAP_ABOVE)
end

dot:SetScript("OnDragStart", function(self)
    if unlocked then self:StartMoving() end
end)
dot:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save the offset from TargetFrame's center, converted to the dot's scale.
    local dx, dy = self:GetCenter()
    local tx, ty = TargetFrame:GetCenter()
    if dx and tx then
        local k = TargetFrame:GetEffectiveScale() / self:GetEffectiveScale()
        ESFDB.rangeDotPos = { x = dx - tx * k, y = dy - ty * k }
    end
    ApplyPosition()
end)

----------------------------------------------------------------------
-- Move handle (visible while unlocked)
----------------------------------------------------------------------
local handle = CreateFrame("Frame", "ESFRangeDotHandle", dot)
handle:SetSize(HANDLE_SIZE, HANDLE_SIZE)
handle:EnableMouse(true)
handle:RegisterForDrag("LeftButton")
handle:Hide()

local handleTex = handle:CreateTexture(nil, "ARTWORK")
handleTex:SetAllPoints()
handleTex:SetTexture(HANDLE_TEXTURE)
handleTex:SetAlpha(0.85)

local ticks = {}
local function GetTick(i)
    local tick = ticks[i]
    if not tick then
        tick = handle:CreateTexture(nil, "ARTWORK")
        tick:SetColorTexture(0.75, 0.75, 0.75, 0.5)
        ticks[i] = tick
    end
    return tick
end

-- Sits diagonally up and right of the dot, flipped when that side would leave the screen.
UpdateHandle = function()
    handle:SetShown(unlocked)
    if not unlocked then return end
    local root2 = math.sqrt(2)
    local px = (PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor() or 1)
        / dot:GetEffectiveScale()
    local r, R = Radius(), HANDLE_SIZE / 2
    local half = TICK_SIZE * px * root2 / 2   -- half a tick along the diagonal
    local dist = (r + R + HANDLE_GAP) * HANDLE_DISTANCE
    -- The visible gaps (dot to first tick, tick to tick, last tick to handle) are all equal.
    -- Steps are whole screen pixels per axis so the ticks stay evenly spaced.
    local free = dist - r - HANDLE_REACH + 2 * half
    local n = math.max(1, math.floor(free / (TICK_STEP * px * root2) - 1 + 0.5))
    local s = math.max(1, math.floor(free / (n + 1) / (root2 * px) + 0.5))
    local c = s * px * root2
    local first = math.floor((r + c - half) / (root2 * px) + 0.5)
    local d = math.floor((r + (n + 1) * c + HANDLE_REACH - 2 * half) / (root2 * px) + 0.5) * px
    local sx, sy = 1, 1
    local cx, cy = dot:GetCenter()
    if cx then
        local k = UIParent:GetEffectiveScale() / dot:GetEffectiveScale()
        local reach = d + R
        if cx + reach > UIParent:GetWidth() * k then sx = -1 end
        if cy + reach > UIParent:GetHeight() * k then sy = -1 end
    end
    handle:ClearAllPoints()
    handle:SetPoint("CENTER", dot, "CENTER", d * sx, d * sy)

    for i = 1, n do
        local tick = GetTick(i)
        local off = (first + (i - 1) * s) * px
        tick:SetSize(TICK_SIZE * px, TICK_SIZE * px)
        tick:ClearAllPoints()
        tick:SetPoint("CENTER", dot, "CENTER", off * sx, off * sy)
        tick:Show()
    end
    for i = n + 1, #ticks do ticks[i]:Hide() end
end

handle:SetScript("OnDragStart", function()
    dot:GetScript("OnDragStart")(dot)
    handle:SetScript("OnUpdate", UpdateHandle)
end)
handle:SetScript("OnDragStop", function()
    handle:SetScript("OnUpdate", nil)
    dot:GetScript("OnDragStop")(dot)
    UpdateHandle()
end)
handle:SetScript("OnEnter", function() handleTex:SetAlpha(1) end)
handle:SetScript("OnLeave", function() handleTex:SetAlpha(0.85) end)

----------------------------------------------------------------------
-- Range logic
----------------------------------------------------------------------
-- true if the spell is valid on the target but out of range.
-- Returns nil/1/0 on old clients, nil/true/false on new ones.
local function IsOutOfRange(spellName)
    local ok, out = pcall(function()
        local r
        if C_Spell and C_Spell.IsSpellInRange then
            r = C_Spell.IsSpellInRange(spellName, "target")
        else
            r = IsSpellInRange(spellName, "target")
        end
        return r == false or r == 0
    end)
    return ok and out
end

local function Update()
    if not ESFCharDB then return end
    if unlocked then dot:Show() return end   -- always visible while positioning

    local out = false
    if UnitExists("target") then
        local kind
        if UnitCanAttack("player", "target") then
            kind = "Hostile"
        elseif UnitCanAssist("player", "target") then
            kind = "Friendly"
        end
        local spell = kind and enabled[kind] and ESFCharDB["range" .. kind .. "Spell"]
        if spell and spell.name then out = IsOutOfRange(spell.name) end
    end
    dot:SetShown(out)
end

-- Range changes without events, so poll while a target exists and a finder is on.
local driver = CreateFrame("Frame")
local acc = 0
local function OnUpdate(_, elapsed)
    acc = acc + elapsed
    if acc < 0.1 then return end
    acc = 0
    Update()
end

local function Refresh()
    ApplySize()
    local active = (enabled.Hostile or enabled.Friendly) and UnitExists("target")
    driver:SetScript("OnUpdate", active and OnUpdate or nil)
    Update()
end

driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterEvent("SPELLS_CHANGED")
driver:SetScript("OnEvent", function(_, event)
    -- Re-anchor on target change only while the default offset is still unmeasured.
    if event == "PLAYER_ENTERING_WORLD"
        or (event == "PLAYER_TARGET_CHANGED" and not barDx and not (ESFDB and ESFDB.rangeDotPos)) then
        ApplyPosition()
    end
    Refresh()
end)

----------------------------------------------------------------------
-- Spell picker popup (search field + scrolling list), shared by both pickers
----------------------------------------------------------------------
local ROW_H = 20
local picker

local function GetPicker(panel)
    if picker then return picker end

    local f = CreateFrame("Frame", "ESFSpellPicker", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(280, 320)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:Hide()
    tinsert(UISpecialFrames, "ESFSpellPicker")   -- Escape closes it
    panel:HookScript("OnHide", function() f:Hide() end)

    local label = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 16, -12)
    label:SetText("Search")

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(236, 20)
    eb:SetPoint("TOPLEFT", 20, -26)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 14, -56)
    sf:SetPoint("BOTTOMRIGHT", -32, 12)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(226, 1)
    sf:SetScrollChild(content)

    local rows, all = {}, {}

    local function GetRow(i)
        local r = rows[i]
        if r then return r end
        r = CreateFrame("Button", nil, content)
        r:SetSize(226, ROW_H)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(ROW_H - 2, ROW_H - 2)
        r.icon:SetPoint("LEFT", 1, 0)
        r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
        r.text:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        r.text:SetJustifyH("LEFT")
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r:SetScript("OnClick", function(self)
            local cb = f.callback
            f:Hide()
            if cb then cb({ id = self.spell.id, name = self.spell.name }) end
        end)
        rows[i] = r
        return r
    end

    local function Fill()
        local q = strlower(eb:GetText() or "")
        local n = 0
        for _, s in ipairs(all) do
            if q == "" or strfind(strlower(s.name), q, 1, true) then
                n = n + 1
                local r = GetRow(n)
                r.spell = s
                r.icon:SetTexture(SpellIcon(s.id))
                r.text:SetText(s.name)
                r:Show()
            end
        end
        for i = n + 1, #rows do rows[i]:Hide() end
        content:SetHeight(math.max(1, n * ROW_H))
    end

    eb:SetScript("OnTextChanged", function()
        sf:SetVerticalScroll(0)
        Fill()
    end)

    function f:Open(anchor, callback)
        if self:IsShown() and self.anchor == anchor then self:Hide() return end
        self.anchor, self.callback = anchor, callback
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        all = CollectSpells()
        eb:SetText("")
        sf:SetVerticalScroll(0)
        Fill()
        self:Show()
        eb:SetFocus()
    end

    picker = f
    return f
end

----------------------------------------------------------------------
-- Settings rows
----------------------------------------------------------------------
local mod = ESF:Module({
    name = "Range Finder", key = "rangeFinder",
    desc = "A movable dot that indicates when the target is out of range",
    note = "Shows a dot when the target is out of range of the chosen ability. Abilities are saved per character.",
})

-- A button in the control column that opens the spell picker.
local function AbilityRow(kind, parentSpec)
    local dbKey = "range" .. kind .. "Spell"
    ESF:Custom({
        label = "Ability",
        tooltip = "The ability whose range is checked.",
        parent = parentSpec,
        create = function(row)
            local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            btn:SetSize(200, 22)
            btn:SetPoint("LEFT", row, "CENTER", -80, 0)
            btn:SetScript("OnClick", function(self)
                GetPicker(SettingsPanel):Open(self, function(chosen)
                    ESFCharDB[dbKey] = chosen
                    self:SetText(chosen.name)
                    Refresh()
                end)
            end)
            return btn
        end,
        update = function(btn, on)
            local spell = ESFCharDB[dbKey]
            btn:SetText(spell and spell.name or "Choose Ability...")
            btn:SetEnabled(on)
        end,
    })
end

local function Register(kind, label, tooltip)
    local spec = ESF:Checkbox({
        key = "range" .. kind, label = label, tooltip = tooltip, default = false, perChar = true,
        onChange = function(on)
            enabled[kind] = on and mod:IsOn()
            Refresh()
        end,
    })
    AbilityRow(kind, spec)
end

Register("Hostile", "Hostile Target", "Shows the dot when the chosen ability is out of range of a hostile target.")
Register("Friendly", "Friendly Target", "Shows the dot when the chosen ability is out of range of a friendly target.")

ESF:Slider({
    key = "rangeDotRadius", label = "Dot Radius", default = RADIUS_DEFAULT,
    min = RADIUS_MIN, max = RADIUS_MAX, step = 1,
    format = function(v) return math.floor(v + 0.5) .. " px" end,
    onChange = function() ApplySize() end,
})

ESF:Custom({
    label = "Dot Position",
    tooltip = "Moves the dot back above the target frame and restores the default size (reloads the UI).",
    create = function(row)
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(200, 22)
        btn:SetPoint("LEFT", row, "CENTER", -80, 0)
        btn:SetText("Reset Position and Size")
        btn:SetScript("OnClick", function()
            ESFDB.rangeDotPos = nil
            ESFDB.rangeDotRadius = nil
            ReloadUI()
        end)
        return btn
    end,
})

-- Keep this as the last row.
ESF:Checkbox({
    key = "rangeUnlock", label = "Test and Unlock", default = false,
    tooltip = "Shows the dot and lets you drag it to a new position.",
    onChange = function(on)
        unlocked = on and mod:IsOn()
        dot:EnableMouse(unlocked)
        UpdateHandle()
        Refresh()
    end,
})
