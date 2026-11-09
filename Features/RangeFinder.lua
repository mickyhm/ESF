-- Features\RangeFinder.lua
local ADDON, ESF = ...

-- Default dot position relative to the target frame (used until the dot is moved).
local DOT_GAP_ABOVE = -20
local DOT_TEXTURE = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\Dot.tga"
local RADIUS_DEFAULT, RADIUS_MIN, RADIUS_MAX = 6, 2, 14

local enabled = { Hostile = false, Friendly = false }
local unlocked = false
local buttons = {}   -- kind -> picker button in the settings panel

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
dot:SetFrameStrata("HIGH")
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

local function ApplySize()
    local r = Radius()
    dot:SetSize(r * 2, r * 2)
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

local function ApplyPosition()
    local pos = ESFDB and ESFDB.rangeDotPos
    dot:ClearAllPoints()
    if pos then
        dot:SetPoint("CENTER", TargetFrame, "CENTER", pos.x, pos.y)
        return
    end
    -- Horizontal offset of the health bar's center from the frame's center (portrait ignored).
    local dx = 0
    local bar = TargetHealthBar()
    if bar then
        local bx, tx = bar:GetCenter(), TargetFrame:GetCenter()
        if bx and tx then
            dx = bx * bar:GetEffectiveScale() / TargetFrame:GetEffectiveScale() - tx
        end
    end
    dot:SetPoint("BOTTOM", TargetFrame, "TOP", dx, DOT_GAP_ABOVE)
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
    if not ESFDB then return end
    if unlocked then dot:Show() return end   -- always visible while positioning

    local out = false
    if UnitExists("target") then
        local kind
        if UnitCanAttack("player", "target") then
            kind = "Hostile"
        elseif UnitCanAssist("player", "target") then
            kind = "Friendly"
        end
        local spell = kind and enabled[kind] and ESFDB["range" .. kind .. "Spell"]
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
    if event == "PLAYER_ENTERING_WORLD"
        or (event == "PLAYER_TARGET_CHANGED" and not (ESFDB and ESFDB.rangeDotPos)) then
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
-- Feature registration
----------------------------------------------------------------------
local function Register(kind, label)
    local dbKey = "range" .. kind

    local function extra(cb, panel)
        local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        btn:SetSize(240, 22)
        local spell = ESFDB[dbKey .. "Spell"]
        btn:SetText(spell and spell.name or "Choose Ability...")
        btn:SetEnabled(ESFDB[dbKey] and true or false)
        btn:SetScript("OnClick", function(self)
            GetPicker(panel):Open(self, function(chosen)
                ESFDB[dbKey .. "Spell"] = chosen
                self:SetText(chosen.name)
                Refresh()
            end)
        end)
        buttons[kind] = btn
        return btn
    end

    ESF:RegisterFeature("Range Finder", dbKey, label, false, function(on)
        enabled[kind] = on
        if buttons[kind] then buttons[kind]:SetEnabled(on) end
        Refresh()
    end, extra)
end

Register("Hostile", "Hostile Target Ability (Dot shows when out of range)")
Register("Friendly", "Friendly Target Ability (Dot shows when out of range)")

-- Slider for the dot radius, placed under the unlock checkbox.
local function SizeSlider(cb, panel)
    local box = CreateFrame("Frame", nil, panel)
    box:SetSize(320, 56)

    local reset = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    reset:SetSize(240, 22)
    reset:SetPoint("TOPLEFT", 0, 0)
    reset:SetText("Reset Position and Size")
    reset:SetScript("OnClick", function()
        ESFDB.rangeDotPos = nil
        ESFDB.rangeDotRadius = nil
        ReloadUI()
    end)

    local s = CreateFrame("Slider", nil, box)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(180, 16)
    s:SetPoint("LEFT", box, "BOTTOMLEFT", 0, 12)
    s:SetMinMaxValues(RADIUS_MIN, RADIUS_MAX)
    s:SetValueStep(1)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    track:SetColorTexture(0.4, 0.4, 0.4, 0.8)

    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

    local text = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", s, "RIGHT", 12, 0)

    s:SetValue(Radius())
    text:SetText("Dot Radius: " .. Radius() .. " px")
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v + 0.5)
        ESFDB.rangeDotRadius = v
        text:SetText("Dot Radius: " .. v .. " px")
        ApplySize()
    end)
    return box
end

ESF:RegisterFeature("Range Finder", "rangeUnlock", "Unlock Dot (Drag to move it)", false, function(on)
    unlocked = on
    dot:EnableMouse(on)
    Refresh()
end, SizeSlider)