local ADDON, ESF = ...

-- The settings pages are our own canvases, styled like Blizzard's options (fonts, controls,
-- spacing). Features describe their rows in file order; the pages are built at ADDON_LOADED
-- once the saved variables exist.
--
-- The main page shows a tile per module (click = enable/disable). Every module gets its own
-- sub-entry with an Enable checkbox in the page header and the module's rows below it.
--   ESF:Module{ name, key, desc [, default, note, tooltip, icon, perChar, onChange] }
--       starts a module; the rows that follow belong to it. ESF:Module(name) continues an
--       existing one (e.g. a second file adding rows). desc goes on the tile, note (default:
--       desc) under the page title. Switching the module runs onChange(on) and then the
--       onChange of all its rows again, so features can use value and module:IsOn().
--       Rows of a disabled module are greyed out; their saved values stay as they are.
--
-- Row specs (all optional fields in brackets):
--   ESF:Section(name [, note])                     white header, small grey description below it
--   ESF:Checkbox{ key, label, default [, tooltip, perChar, onChange, parent, enabledIf] }
--   ESF:Dropdown{ key, label, default, options = { {value, text [, tooltip]}, ... } [, ...] }
--   ESF:Slider{ key, label, default, min, max, step [, format, ...] }
--   ESF:Custom{ label [, tooltip, create, update, parent, enabledIf, noLabel] }
--       create(row) -> widget   builds the control once, placed in the control column of `row`
--       noLabel: no label and no hover/tooltip; place the control at row.labelX (label indent)
--       update(widget, enabled) refreshes it (value, enabled state)
-- onChange(value) runs once at load and after every change. perChar stores the value in
-- ESFCharDB instead of ESFDB. parent (a spec) greys the row out with it; enabledIf() greys it out.

ESF.rows = {}       -- ordered list of row specs
ESF.features = {}   -- specs with a saved value (key), for defaults/init
ESF.onLoad = {}     -- functions run after the saved variables are loaded, before defaults
ESF.modules = {}    -- module specs in registration order (tiles / sub-entries)
local sectionByName = {}
local moduleByName = {}
local currentModule  -- module the next rows belong to

local function AddRow(kind, spec)
    spec.kind = kind
    spec.module = currentModule
    table.insert(ESF.rows, spec)
    if currentModule then table.insert(currentModule.rows, spec) end
    if spec.key then table.insert(ESF.features, spec) end
    return spec
end

local function ModuleIsOn(self)
    return ESF:Get(self) and true or false
end

function ESF:Module(spec)
    local name = type(spec) == "table" and spec.name or spec
    local m = moduleByName[name]
    if not m then
        assert(type(spec) == "table", "ESF: unknown module " .. tostring(name))
        m = spec
        m.kind = "module"
        m.rows = {}
        m.IsOn = ModuleIsOn
        if m.default == nil then m.default = false end
        moduleByName[name] = m
        table.insert(self.modules, m)
        if m.key then table.insert(self.features, m) end
    end
    currentModule = m
    return m
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

-- Shorthand: a checkbox under a section.
-- "Label (explanation)" becomes label + tooltip.
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
-- Building the page
----------------------------------------------------------------------
local GetMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

-- Layout
local ROW_H = 35            -- distance between rows
local HEADER_TO_ROW = 36    -- section header -> its first row
local SECTION_GAP = 20      -- extra space between the last row of a section and the next header
local HEADER_X = 10         -- section header indent
local LABEL_X = 42          -- label indent, the same for every row (Blizzard: header + ~30)
local NOTE_H = 16           -- height of the description line under a header
local CONTROL_X = -80       -- controls start at the row's center + this

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function IsEnabled(spec)
    if spec.module and not ESF:Get(spec.module) then return false end
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
    if spec.kind == "module" then
        -- let the module's rows apply their (unchanged) values with the new module state
        for _, r in ipairs(spec.rows) do
            if r.key and r.onChange then r.onChange(ESF:Get(r)) end
        end
    end
    ESF:RefreshSettings()
end

local DROPDOWN_W = 218       -- Blizzard's dropdown width (fixed, whatever the entries need)
local MENU_TEXT_X = 18       -- text indent of the entries in the opened list

-- Tooltip just above where a checkbox sits in this row (title + description).
local function ShowTooltip(row, spec)
    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:SetPoint("BOTTOMLEFT", row.tipAnchor, "TOPLEFT", -14, -2)
    GameTooltip:SetText(spec.label or "", 1, 1, 1)
    if spec.tooltip then GameTooltip:AddLine(spec.tooltip, nil, nil, nil, true) end
    GameTooltip:Show()
end

-- Row hover: from the left edge up to and including the control the row is
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
    -- entries: no radio circles, the selected one in yellow
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
    row.labelX = LABEL_X
    local w = spec.create and spec.create(row)
    if not spec.noLabel then AttachHover(row, spec, w or row, w and { w } or {}) end
    return row, function(on)
        if w and spec.update then spec.update(w, on) end
        SetLabelEnabled(row, on)
    end
end

local builders = { checkbox = BuildCheckbox, dropdown = BuildDropdown, slider = BuildSlider, custom = BuildCustom }

local function NewCheckButton(parent)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(30, 29)
    if HasAtlas("checkbox-minimal") then
        cb:SetNormalAtlas("checkbox-minimal")
        cb:SetPushedAtlas("checkbox-minimal")
        cb:SetCheckedTexture("checkmark-minimal")
        cb:SetHighlightAtlas("checkbox-minimal", "ADD")
        cb:GetHighlightTexture():SetAlpha(0.3)
    else
        cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    end
    return cb
end

local function NewDivider(panel, y)
    local line = panel:CreateTexture(nil, "ARTWORK")
    if HasAtlas("Options_HorizontalDivider") then
        line:SetAtlas("Options_HorizontalDivider", true)
    else
        line:SetColorTexture(1, 1, 1, 0.15)
        line:SetHeight(1)
    end
    line:SetPoint("TOPLEFT", 0, y)
    line:SetPoint("TOPRIGHT", -18, y)
    return line
end

-- Rows of a list, laid out top to bottom in `content`. Returns the height used.
local function BuildRows(content, rows)
    local y, prevKind = 6, nil
    for _, spec in ipairs(rows) do
        if spec.kind == "section" then
            y = y + (prevKind and SECTION_GAP or 4)
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
    return y
end

-- Scrolling area below a page header (Blizzard's ScrollBox + MinimalScrollBar).
local function NewScrollArea(panel, top)
    local scroll = CreateFrame("Frame", nil, panel, "WowScrollBox")
    local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scroll:SetPoint("TOPLEFT", 0, top)
    scroll:SetPoint("BOTTOMRIGHT", -24, 4)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, -4)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content.scrollable = true   -- tells the ScrollBox this frame is what scrolls
    content:SetSize(1, 1)
    ScrollUtil.InitScrollBoxWithScrollBar(scroll, bar, CreateScrollBoxLinearView())
    return scroll, content
end

local function OnPageShow(scroll, content)
    if content then content:SetWidth(scroll:GetWidth()) end
    ESF:RefreshSettings()
    if scroll then scroll:FullUpdate(ScrollBoxConstants.UpdateImmediately) end
    C_Timer.After(0, function() ESF:RefreshSettings() end)   -- once positions are final
end

----------------------------------------------------------------------
-- Module page (sub-entry): title + note on the left, Enable checkbox on the right, rows below
----------------------------------------------------------------------
local MODULE_HEADER_H = 58

local function BuildModulePage(m)
    local panel = CreateFrame("Frame")
    panel.name = m.name

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", 10, -12)
    title:SetText(m.name)
    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    note:SetText(m.note or m.desc or "")

    -- master switch: right-aligned with the title, green "Enabled" / grey "Disabled"
    local cb = NewCheckButton(panel)
    cb:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -24, -8)
    local state = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    state:SetPoint("RIGHT", cb, "LEFT", -2, 0)
    cb:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        Set(m, on)
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(m.name, 1, 1, 1)
        GameTooltip:AddLine(m.tooltip or m.desc, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(rowObjects, { spec = m, Refresh = function()
        local on = m:IsOn()
        cb:SetChecked(on)
        state:SetText(on and "Enabled" or "Disabled")
        if on then state:SetTextColor(GREEN_FONT_COLOR:GetRGB()) else state:SetTextColor(0.5, 0.5, 0.5) end
    end })

    NewDivider(panel, -MODULE_HEADER_H)

    local scroll, content = NewScrollArea(panel, -MODULE_HEADER_H - 8)
    local y = BuildRows(content, m.rows)
    if #m.rows == 0 then
        local none = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        none:SetPoint("TOPLEFT", LABEL_X, -16)
        none:SetText("No further settings.")
        y = 40
    end
    content:SetHeight(y + 16)

    panel:SetScript("OnShow", function() OnPageShow(scroll, content) end)
    return panel
end

----------------------------------------------------------------------
-- Main page: addon title + version, one tile per module
-- (click = open the module's page, checkbox = enable/disable)
----------------------------------------------------------------------
local TILE_COLUMNS = 2
local TILE_H = 92
local TILE_GAP = 14
local TILE_TOP = 86          -- first tile row, from the top of the page
local TILE_ICON = 56
local TILE_PAD = 16          -- inner padding (icon left, text top)
local TILE_TEXT_RIGHT = 44   -- title and description end this far from the right edge (checkbox column)
local PLACEHOLDER_ICON = "Interface\\Icons\\INV_Misc_Bag_08"

local function BuildTile(parent, m)
    local tile = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tile:SetHeight(TILE_H)
    tile:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local icon = tile:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TILE_ICON, TILE_ICON)
    icon:SetPoint("LEFT", TILE_PAD, 0)
    icon:SetTexture(m.icon or PLACEHOLDER_ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- crop the icon's built-in border

    -- placeholder marker: dark banner with "PLACEHOLDER" across the bottom of the icon
    local banner, bannerText
    if not m.icon then
        banner = tile:CreateTexture(nil, "OVERLAY")
        banner:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT")
        banner:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT")
        banner:SetHeight(12)
        banner:SetColorTexture(0.08, 0.08, 0.08, 0.9)
        bannerText = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        local fontFile, _, fontFlags = bannerText:GetFont()
        bannerText:SetFont(fontFile, 7, fontFlags)
        bannerText:SetPoint("CENTER", banner, "CENTER", 0, 0)
        bannerText:SetText("PLACEHOLDER")
    end

    local title = tile:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", TILE_PAD + TILE_ICON + 14, -TILE_PAD)
    title:SetPoint("RIGHT", -TILE_TEXT_RIGHT, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(m.name)

    local desc = tile:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    desc:SetPoint("RIGHT", -TILE_TEXT_RIGHT, 0)   -- same right edge as the title, clear of the checkbox
    desc:SetJustifyH("LEFT")
    desc:SetJustifyV("TOP")
    if desc.SetMaxLines then desc:SetMaxLines(3) end
    desc:SetText(m.desc or "")

    -- enable/disable: the same checkbox as on the module pages, centered on the title line
    local cb = NewCheckButton(tile)
    cb:SetPoint("RIGHT", tile, "TOPRIGHT", -8, -TILE_PAD - title:GetStringHeight() / 2)
    cb:SetFrameLevel(tile:GetFrameLevel() + 2)
    local function ShowCheckTip(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(m:IsOn() and "Click to disable" or "Click to enable", 1, 1, 1)
        GameTooltip:Show()
    end
    cb:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        Set(m, on)
        if GameTooltip:IsOwned(self) then ShowCheckTip(self) end   -- new state while still hovering
    end)
    cb:SetScript("OnEnter", ShowCheckTip)
    cb:SetScript("OnLeave", GameTooltip_Hide)

    local hl = tile:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 4, -4)
    hl:SetPoint("BOTTOMRIGHT", -4, 4)
    hl:SetColorTexture(1, 1, 1, 0.08)

    tile:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
        if m.category then Settings.OpenToCategory(m.category:GetID()) end
    end)

    table.insert(rowObjects, { spec = m, Refresh = function()
        local on = m:IsOn()
        icon:SetDesaturated(not on)
        icon:SetAlpha(on and 1 or 0.5)
        if banner then
            banner:SetAlpha(on and 1 or 0.5)
            bannerText:SetAlpha(on and 1 or 0.5)
        end
        title:SetFontObject(on and GameFontNormalLarge or GameFontDisableLarge)
        if on then desc:SetTextColor(0.85, 0.85, 0.85) else desc:SetTextColor(0.4, 0.4, 0.4) end
        tile:SetBackdropColor(on and 0.12 or 0.05, on and 0.10 or 0.05, on and 0.05 or 0.05, on and 0.9 or 0.6)
        if on then tile:SetBackdropBorderColor(1, 0.82, 0) else tile:SetBackdropBorderColor(0.35, 0.35, 0.35) end
        cb:SetChecked(on)
    end })
    return tile
end

local function BuildMainPage()
    local panel = CreateFrame("Frame")
    panel.name = "ExtraSausage"

    -- header: icon, title, version, separator line
    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", 10, -5)
    icon:SetTexture(GetMeta(ADDON, "IconTexture") or "Interface\\Icons\\INV_Misc_Food_66")
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    local fontFile, _, fontFlags = title:GetFont()
    title:SetFont(fontFile, 28, fontFlags)
    title:SetShadowColor(0, 0, 0, 1)
    title:SetShadowOffset(1, -1)
    title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    title:SetText("ExtraSausage")
    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 5)   -- on the title's baseline
    version:SetText("v" .. (GetMeta(ADDON, "Version") or "?"))

    title:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
    NewDivider(panel, -42)

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")   -- same size as the tile descriptions
    hint:SetPoint("TOPLEFT", 10, -54)
    hint:SetText("Click a module to open its settings. The checkbox enables or disables it.")

    local tiles = {}
    for _, m in ipairs(ESF.modules) do table.insert(tiles, BuildTile(panel, m)) end

    local function Layout()
        local width = panel:GetWidth() - 20 - 18
        if width <= 0 then return end
        local w = (width - (TILE_COLUMNS - 1) * TILE_GAP) / TILE_COLUMNS
        for i, tile in ipairs(tiles) do
            local col, row = (i - 1) % TILE_COLUMNS, math.floor((i - 1) / TILE_COLUMNS)
            tile:ClearAllPoints()
            tile:SetWidth(w)
            tile:SetPoint("TOPLEFT", 10 + col * (w + TILE_GAP), -TILE_TOP - row * (TILE_H + TILE_GAP))
        end
    end
    panel:SetScript("OnSizeChanged", Layout)
    panel:SetScript("OnShow", function()
        Layout()
        OnPageShow()
    end)
    return panel
end

local function BuildPanel()
    local main = BuildMainPage()
    ESF.category = Settings.RegisterCanvasLayoutCategory(main, main.name)
    for _, m in ipairs(ESF.modules) do
        local page = BuildModulePage(m)
        m.category = Settings.RegisterCanvasLayoutSubcategory(ESF.category, page, page.name)
    end
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
