local ADDON, ESF = ...   -- the same ESF table is shared by all files of the addon

-- The settings page is our own canvas, styled like Blizzard's options (fonts, controls,
-- spacing). Features describe their rows in file order; the page is built at ADDON_LOADED
-- once the saved variables exist.
--
-- Row specs (all optional fields in brackets):
--   ESF:Section(name [, note])                     white header, small grey description below it
--   ESF:Checkbox{ key, label, default [, tooltip, perChar, onChange, parent, enabledIf] }
--   ESF:Dropdown{ key, label, default, options = { {value, text [, tooltip]}, ... } [, ...] }
--   ESF:Slider{ key, label, default, min, max, step [, format, ...] }
--   ESF:Custom{ label [, tooltip, create, update, parent, enabledIf] }
--       create(row) -> widget   builds the control once, placed in the control column of `row`
--       update(widget, enabled) refreshes it (value, enabled state)
-- onChange(value) runs once at load and after every change. perChar stores the value in
-- ESFCharDB instead of ESFDB. parent (a spec) greys the row out with it; enabledIf() greys it out.

ESF.rows = {}       -- ordered list of row specs
ESF.features = {}   -- specs with a saved value (key), for defaults/init
ESF.onLoad = {}     -- functions run after the saved variables are loaded, before defaults
local sectionByName = {}

local function AddRow(kind, spec)
    spec.kind = kind
    table.insert(ESF.rows, spec)
    if spec.key then table.insert(ESF.features, spec) end
    return spec
end

function ESF:Section(name, note)
    local s = sectionByName[name]
    if s then
        if note then s.note = note end
        return s
    end
    s = AddRow("section", { name = name, note = note })
    sectionByName[name] = s
    return s
end

function ESF:Checkbox(spec) return AddRow("checkbox", spec) end
function ESF:Dropdown(spec) return AddRow("dropdown", spec) end
function ESF:Slider(spec) return AddRow("slider", spec) end
function ESF:Custom(spec) return AddRow("custom", spec) end

-- Old style (kept for simple features): a checkbox under a section.
-- "Label (explanation)" becomes label + tooltip, as Blizzard's options do it.
function ESF:RegisterFeature(section, key, label, default, onToggle)
    self:Section(section)
    local text, tip = strmatch(label or "", "^(.-)%s*%((.+)%)$")
    return self:Checkbox({ key = key, label = text or label, tooltip = tip, default = default, onChange = onToggle })
end

function ESF:SetSectionNote(section, note)
    self:Section(section, note)
end

-- Saved-variables table a spec's value lives in.
function ESF:Store(spec)
    return spec.perChar and ESFCharDB or ESFDB
end

function ESF:Get(spec)
    return self:Store(spec)[spec.key]
end

----------------------------------------------------------------------
-- Building the page (our own canvas, styled like Blizzard's options)
----------------------------------------------------------------------
local GetMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

-- Layout, measured from Blizzard's options page
local ROW_H = 35            -- distance between rows
local HEADER_TO_ROW = 36    -- section header -> its first row (a bit tighter than Blizzard's)
local SECTION_GAP = 20      -- extra space between the last row of a section and the next header
local HEADER_X = 10         -- section header indent
local LABEL_X = 42          -- label indent, the same for every row (Blizzard: header + ~30)
local NOTE_H = 16           -- height of the description line under a header
local CONTROL_X = -80       -- controls start at the row's center + this

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function IsEnabled(spec)
    if spec.parent and not IsEnabled(spec.parent) then return false end
    if spec.parent and spec.parent.key and not spec.enabledIf and not ESF:Get(spec.parent) then return false end
    if spec.enabledIf and not spec.enabledIf() then return false end
    return true
end

local rowObjects = {}   -- every built row: { spec, Refresh(on) }

function ESF:RefreshSettings()
    for _, r in ipairs(rowObjects) do r.Refresh(IsEnabled(r.spec)) end
end

local function Set(spec, value)
    ESF:Store(spec)[spec.key] = value
    if spec.onChange then spec.onChange(value) end
    ESF:RefreshSettings()
end

local DROPDOWN_W = 218       -- Blizzard's dropdown width (fixed, whatever the entries need)
local MENU_TEXT_X = 18       -- text indent of the entries in the opened list

-- Tooltip just above where a checkbox sits in this row, like Blizzard's (title + description).
local function ShowTooltip(row, spec)
    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:SetPoint("BOTTOMLEFT", row.tipAnchor, "TOPLEFT", -14, -2)
    GameTooltip:SetText(spec.label or "", 1, 1, 1)
    if spec.tooltip then GameTooltip:AddLine(spec.tooltip, nil, nil, nil, true) end
    GameTooltip:Show()
end

-- Row hover, like Blizzard's: from the left edge up to and including the control the row is
-- highlighted and shows its tooltip; right of the control nothing happens.
-- `frames` are the control's mouse-enabled parts (they sit on top of the hover area).
local function AttachHover(row, spec, control, frames)
    local hover = CreateFrame("Frame", nil, row)
    hover:SetPoint("TOPLEFT")
    hover:SetPoint("BOTTOMLEFT")
    hover:SetPoint("RIGHT", control, "RIGHT")
    hover:SetFrameLevel(row:GetFrameLevel())
    hover:EnableMouse(true)

    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(row)
    hl:SetColorTexture(1, 1, 1, 0.07)
    hl:Hide()

    local function Update()
        local over = hover:IsMouseOver()
        hl:SetShown(over)
        if over then
            if not GameTooltip:IsOwned(row) then ShowTooltip(row, spec) end
        elseif GameTooltip:IsOwned(row) then
            GameTooltip:Hide()
        end
    end
    for _, f in ipairs({ hover, unpack(frames) }) do
        f:HookScript("OnEnter", Update)
        f:HookScript("OnLeave", Update)
    end
end

-- Row frame with the yellow label on the left; the control goes in at the center.
local function NewRow(content, spec)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)
    local label = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("LEFT", LABEL_X, 0)
    label:SetPoint("RIGHT", row, "CENTER", CONTROL_X - 10, 0)
    label:SetJustifyH("LEFT")
    label:SetText(spec.label or "")
    row.label = label
    -- where a checkbox sits in this row; tooltips are anchored to it
    local tip = CreateFrame("Frame", nil, row)
    tip:SetSize(30, 29)
    tip:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    row.tipAnchor = tip
    return row
end

local function SetLabelEnabled(row, on)
    row.label:SetFontObject(on and GameFontNormal or GameFontDisable)
end

local function BuildCheckbox(content, spec)
    local row = NewRow(content, spec)
    local cb = CreateFrame("CheckButton", nil, row)
    cb:SetSize(30, 29)
    cb:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    if HasAtlas("checkbox-minimal") then
        cb:SetNormalAtlas("checkbox-minimal")
        cb:SetPushedAtlas("checkbox-minimal")
        cb:SetCheckedTexture("checkmark-minimal")
        cb:SetDisabledCheckedTexture("checkmark-minimal-disabled")
        cb:SetHighlightAtlas("checkbox-minimal", "ADD")
        cb:GetHighlightTexture():SetAlpha(0.3)
    else
        cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cb:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
        cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    end
    cb:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        Set(spec, on)
    end)
    AttachHover(row, spec, cb, { cb })
    return row, function(on)
        cb:SetChecked(ESF:Get(spec) and true or false)
        cb:SetEnabled(on)
        cb:GetNormalTexture():SetDesaturated(not on)
        SetLabelEnabled(row, on)
    end
end

-- Blizzard's dropdown with step arrows (same control as in its options); our own arrows as fallback.
local function NewStepperDropdown(row)
    for _, template in ipairs({ "SettingsDropdownWithButtonsTemplate", "DropdownWithSteppersTemplate" }) do
        local ok, f = pcall(CreateFrame, "Frame", nil, row, template)
        if ok and f and f.Dropdown and f.DecrementButton and f.IncrementButton then
            f:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
            f.Dropdown:SetWidth(DROPDOWN_W)
            return f, f.Dropdown, f.DecrementButton, f.IncrementButton
        elseif ok and f then
            f:Hide()
        end
    end

    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, row, "WowStyle2DropdownTemplate")
    if not ok then dd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate") end
    dd:SetWidth(DROPDOWN_W)
    dd:SetPoint("LEFT", row, "CENTER", CONTROL_X + 22, 0)
    local function Arrow(dir, anchorPoint, relPoint, x)
        local b = CreateFrame("Button", nil, row)
        b:SetSize(20, 20)
        b:SetPoint(anchorPoint, dd, relPoint, x, 0)
        local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. (dir < 0 and "Prev" or "Next") .. "Page-"
        b:SetNormalTexture(base .. "Up")
        b:SetPushedTexture(base .. "Down")
        b:SetDisabledTexture(base .. "Disabled")
        return b
    end
    local prev = Arrow(-1, "RIGHT", "LEFT", -2)
    local nextB = Arrow(1, "LEFT", "RIGHT", 2)
    return dd, dd, prev, nextB
end

local function BuildDropdown(content, spec)
    local row = NewRow(content, spec)
    local function Index()
        for i, o in ipairs(spec.options) do
            if o[1] == ESF:Get(spec) then return i end
        end
        return 1
    end

    local control, dd, prev, nextB = NewStepperDropdown(row)
    -- entries like Blizzard's: no radio circles, the selected one in yellow
    dd:SetupMenu(function(_, root)
        for _, o in ipairs(spec.options) do
            local text = o[1] == ESF:Get(spec) and NORMAL_FONT_COLOR:WrapTextInColorCode(o[2]) or o[2]
            local entry = root:CreateButton(text, function() Set(spec, o[1]) end)
            if entry.AddInitializer then
                entry:AddInitializer(function(button)
                    local fs = button.fontString or button.Text
                    if fs then
                        fs:ClearAllPoints()
                        fs:SetPoint("LEFT", button, "LEFT", MENU_TEXT_X, 0)
                    end
                end)
            end
            if o[3] and entry.SetTooltip then
                entry:SetTooltip(function(tip)
                    GameTooltip_SetTitle(tip, o[2])
                    GameTooltip_AddNormalLine(tip, o[3])
                end)
            end
        end
    end)
    local function Step(dir)
        local o = spec.options[Index() + dir]
        if o then
            PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON)
            Set(spec, o[1])
        end
    end
    prev:SetScript("OnClick", function() Step(-1) end)
    nextB:SetScript("OnClick", function() Step(1) end)

    -- Blizzard's control may update its arrows itself (it expects radio entries); keep ours.
    local want, applying = {}, false
    local function SetArrow(b, on)
        want[b] = on
        applying = true
        b:SetEnabled(on)
        applying = false
    end
    for _, b in ipairs({ prev, nextB }) do
        for _, method in ipairs({ "SetEnabled", "Enable", "Disable" }) do
            hooksecurefunc(b, method, function(self)
                if not applying and want[self] ~= nil and self:IsEnabled() ~= want[self] then
                    SetArrow(self, want[self])
                end
            end)
        end
    end

    AttachHover(row, spec, nextB, { dd, prev, nextB })
    return row, function(on)
        -- the left arrow starts where checkboxes start (Blizzard's template may anchor the
        -- dropdown itself there instead); measured once the page is laid out
        local arrowX, columnX = prev:GetLeft(), row.tipAnchor:GetLeft()
        if arrowX and columnX and math.abs(arrowX - columnX) > 0.5 then
            control:AdjustPointsOffset(columnX - arrowX, 0)
        end
        local text = spec.options[Index()][2]
        if dd.OverrideText then dd:OverrideText(text) else dd:SetText(text) end
        dd:SetEnabled(on)
        local i = Index()
        SetArrow(prev, on and i > 1)
        SetArrow(nextB, on and i < #spec.options)
        SetLabelEnabled(row, on)
    end
end

local function BuildSlider(content, spec)
    local row = NewRow(content, spec)
    local s = CreateFrame("Frame", nil, row, "MinimalSliderWithSteppersTemplate")
    s:SetWidth(250)
    s:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    local steps = (spec.max - spec.min) / (spec.step or 1)
    local formatters = spec.format and { [MinimalSliderWithSteppersMixin.Label.Right] = spec.format } or nil
    s:Init(ESF:Get(spec) or spec.default, spec.min, spec.max, steps, formatters)
    local updating = false
    s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if not updating then Set(spec, value) end
    end, s)
    local parts = { s }
    for _, k in ipairs({ "Slider", "Back", "Forward" }) do
        if s[k] then table.insert(parts, s[k]) end
    end
    AttachHover(row, spec, s, parts)
    return row, function(on)
        updating = true
        s:SetValue(ESF:Get(spec) or spec.default)
        updating = false
        s:SetEnabled(on)
        SetLabelEnabled(row, on)
    end
end

local function BuildCustom(content, spec)
    local row = NewRow(content, spec)
    local w = spec.create and spec.create(row)
    AttachHover(row, spec, w or row, w and { w } or {})
    return row, function(on)
        if w and spec.update then spec.update(w, on) end
        SetLabelEnabled(row, on)
    end
end

local builders = { checkbox = BuildCheckbox, dropdown = BuildDropdown, slider = BuildSlider, custom = BuildCustom }

local function BuildPanel()
    local panel = CreateFrame("Frame")
    panel.name = "ExtraSausage"

    -- fixed header: icon, title, version, separator line (like Blizzard's page title)
    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", 10, -10)
    icon:SetTexture(GetMeta(ADDON, "IconTexture") or "Interface\\Icons\\INV_Misc_Food_66")
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("ExtraSausage")
    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 2)
    version:SetText("v" .. (GetMeta(ADDON, "Version") or "?"))
    local line = panel:CreateTexture(nil, "ARTWORK")
    if HasAtlas("Options_HorizontalDivider") then
        line:SetAtlas("Options_HorizontalDivider", true)
    else
        line:SetColorTexture(1, 1, 1, 0.15)
        line:SetHeight(1)
    end
    line:SetPoint("TOPLEFT", 0, -42)
    line:SetPoint("TOPRIGHT", -18, -42)

    -- scrolling area below the header (Blizzard's ScrollBox + MinimalScrollBar)
    local scroll = CreateFrame("Frame", nil, panel, "WowScrollBox")
    local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scroll:SetPoint("TOPLEFT", 0, -50)
    scroll:SetPoint("BOTTOMRIGHT", -24, 4)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, -4)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content.scrollable = true   -- tells the ScrollBox this frame is what scrolls
    content:SetSize(1, 1)
    ScrollUtil.InitScrollBoxWithScrollBar(scroll, bar, CreateScrollBoxLinearView())

    local y, prevKind = 0, nil
    for _, spec in ipairs(ESF.rows) do
        if spec.kind == "section" then
            y = y + (prevKind and SECTION_GAP or 10)
            local header = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
            header:SetPoint("TOPLEFT", HEADER_X, -y)
            header:SetText(spec.name)
            if spec.note then
                -- description: small grey line under the header
                local note = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
                note:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
                note:SetText(spec.note)
                y = y + NOTE_H
            end
            y = y + HEADER_TO_ROW - ROW_H / 2 + 8
        else
            local row, refresh = builders[spec.kind](content, spec)
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", content, "RIGHT")
            table.insert(rowObjects, { spec = spec, Refresh = refresh })
            y = y + ROW_H
        end
        prevKind = spec.kind
    end
    content:SetHeight(y + 16)

    panel:SetScript("OnShow", function()
        content:SetWidth(scroll:GetWidth())
        ESF:RefreshSettings()
        scroll:FullUpdate(ScrollBoxConstants.UpdateImmediately)
        C_Timer.After(0, function() ESF:RefreshSettings() end)   -- once positions are final
    end)

    ESF.category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(ESF.category)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    ESFDB = ESFDB or {}
    ESFCharDB = ESFCharDB or {}
    for _, fn in ipairs(ESF.onLoad) do fn() end
    for _, spec in ipairs(ESF.features) do
        local db = ESF:Store(spec)
        if db[spec.key] == nil then db[spec.key] = spec.default end
        if spec.onChange then spec.onChange(db[spec.key]) end
    end
    BuildPanel()
end)

-- Sub-commands: ESF.commands.name = function(rest) ... end  ->  /esf name rest
ESF.commands = {}

SLASH_ESF1 = "/esf"
SlashCmdList.ESF = function(msg)
    local cmd, rest = strmatch(msg or "", "^%s*(%S+)%s*(.-)%s*$")
    if cmd then
        local fn = ESF.commands[strlower(cmd)]
        if fn then
            fn(rest)
        else
            print("ESF: unknown command '" .. cmd .. "'")
        end
        return
    end
    if ESF.category then Settings.OpenToCategory(ESF.category:GetID()) end
end
