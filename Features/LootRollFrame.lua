local ADDON, ESF = ...

-- Moves and resizes the Need/Greed/Pass roll windows (GroupLootFrame1-4) through Edit Mode.
-- Settings (position, size, growth direction) are kept per Edit Mode layout:
--   account and preset layouts in ESFDB.lootRollLayouts, character layouts in ESFCharDB.lootRollLayouts,
--   keyed "preset:<index>", "account:<name>", "char:<name>". A missing entry = Blizzard's defaults.
--
-- While Edit Mode is open, changes go to a working copy (`work`). They are written to the saved
-- variables only when Blizzard's Save is used (or "Save and Exit").
--
-- Edit Mode integration without registering a Blizzard system (that would taint Edit Mode):
-- a mock roll window with Blizzard's selection look, our own copies of Blizzard's dialogs, and
-- hooks on Save / Revert All / layout rename, delete and creation. Buttons that have to make
-- Blizzard act (open or close Edit Mode) are secure buttons, so Blizzard's code runs untainted.

local NAME = "Loot Roll Frame"
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 50, 200, 5   -- percent
local DEFAULT_DIR = "UP"
local SLOT_SPACING = 100                             -- Blizzard's GroupLootContainer.reservedSize
local TEST_DURATION = 30                             -- seconds a test roll stays up
local MOCK_TEMPLATES = { "MKBGroupLootFrameTemplate", "GroupLootFrameTemplate" }   -- Forever, retail

local mod
local function On() return mod and mod:IsOn() end

local LayoutType = Enum and Enum.EditModeLayoutType or {}

local function InEditMode()
    return EditModeManagerFrame and EditModeManagerFrame.IsEditModeActive
        and EditModeManagerFrame:IsEditModeActive() or false
end

local function BlizzardHasChanges()
    return EditModeManagerFrame and EditModeManagerFrame.HasActiveChanges
        and EditModeManagerFrame:HasActiveChanges() or false
end

----------------------------------------------------------------------
-- Layouts and per-layout settings
----------------------------------------------------------------------
local function Layouts()
    local li = EditModeManagerFrame and EditModeManagerFrame.layoutInfo
    return li and li.layouts
end

local function KeyOf(info, index)
    if not info then return nil end
    if info.layoutType == LayoutType.Preset then return "preset:" .. index end
    if info.layoutType == LayoutType.Character then return "char:" .. tostring(info.layoutName) end
    return "account:" .. tostring(info.layoutName)
end

local function ActiveKey()
    local li = EditModeManagerFrame and EditModeManagerFrame.layoutInfo
    if not (li and li.layouts and li.activeLayout) then return nil end
    return KeyOf(li.layouts[li.activeLayout], li.activeLayout)
end

local function StoreFor(key)
    if strsub(key, 1, 5) == "char:" then return ESFCharDB.lootRollLayouts end
    return ESFDB.lootRollLayouts
end

local function Stores()
    return { ESFDB.lootRollLayouts, ESFCharDB.lootRollLayouts }
end

-- x, y (nil = Blizzard's position), scale, direction
local function Values(e)
    return e and e.x, e and e.y, (e and e.scale) or 1, (e and e.dir) or DEFAULT_DIR
end

local function IsDefault(e)
    local x, y, scale, dir = Values(e)
    return x == nil and y == nil and scale == 1 and dir == DEFAULT_DIR
end

local function Clean(e)
    return (not IsDefault(e)) and CopyTable(e) or nil
end

local function Near(a, b)
    if a == nil or b == nil then return a == b end
    return math.abs(a - b) < 0.05
end

local function Same(a, b)
    local ax, ay, as, ad = Values(a)
    local bx, by, bs, bd = Values(b)
    return Near(ax, bx) and Near(ay, by) and Near(as, bs) and ad == bd
end

local work   -- pending settings per layout key while Edit Mode is open, nil otherwise

local function Stored(key)
    return key and StoreFor(key)[key]
end

local function Entry(key)
    if not key then return nil end
    if work then return work[key] end
    return StoreFor(key)[key]
end

local function SetEntry(key, e)          -- pending while in Edit Mode, saved otherwise
    if work then work[key] = Clean(e) else StoreFor(key)[key] = Clean(e) end
end

local function SetBoth(key, e)           -- saved and pending
    StoreFor(key)[key] = Clean(e)
    if work then work[key] = Clean(e) end
end

local function BeginWork()
    work = {}
    for _, store in ipairs(Stores()) do
        for k, e in pairs(store) do work[k] = CopyTable(e) end
    end
end

local function Commit()
    if not work then return end
    wipe(ESFDB.lootRollLayouts)
    wipe(ESFCharDB.lootRollLayouts)
    for k, e in pairs(work) do StoreFor(k)[k] = CopyTable(e) end
end

local function Discard()
    if work then BeginWork() end
end

local function IsDirty(key)
    if not work then return false end
    if key then return not Same(work[key], Stored(key)) end
    for k, e in pairs(work) do
        if not Same(e, Stored(k)) then return true end
    end
    for _, store in ipairs(Stores()) do
        for k, e in pairs(store) do
            if not Same(e, work[k]) then return true end
        end
    end
    return false
end

----------------------------------------------------------------------
-- Positioning (real roll windows, the Edit Mode mock and test rolls use the same slots)
----------------------------------------------------------------------
-- Slot 1 sits where the frame was placed; further slots stack up or down from it.
-- Offsets are converted into the frame's own (scaled) coordinates.
local function PlaceSlot(frame, slot, key)
    local x, y, scale, dir = Values(Entry(key))
    local c = GroupLootContainer
    local spacing = (c and c.reservedSize) or SLOT_SPACING
    local offset = (dir == "DOWN" and -1 or 1) * (slot - 1) * spacing * scale

    frame:SetScale(scale)
    frame:ClearAllPoints()
    if x and y then
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, (y + offset) / scale)
    elseif c and c:GetBottom() then
        -- Blizzard's spot (the container only has a position after its first roll)
        frame:SetPoint("CENTER", c, "BOTTOM", 0, (spacing * 0.5 + offset) / scale)
    elseif UIParentBottomManagedFrameContainer and UIParentBottomManagedFrameContainer:GetTop() then
        frame:SetPoint("CENTER", UIParentBottomManagedFrameContainer, "TOP", 0, (spacing * 0.5 + offset) / scale)
    else
        frame:SetPoint("CENTER", UIParent, "BOTTOM", 0, (250 + offset) / scale)
    end
end

-- Real roll windows. Disabled: back to Blizzard's anchors (same formula as GroupLootContainer_Update).
local function ApplyRollFrames()
    local c = GroupLootContainer
    if not (c and c.rollFrames) then return end
    local key, on = ActiveKey(), On()
    for i = 1, c.maxIndex or 0 do
        local f = c.rollFrames[i]
        if f then
            if on then
                PlaceSlot(f, i, key)
            else
                f:SetScale(1)
                f:ClearAllPoints()
                f:SetPoint("CENTER", c, "BOTTOM", 0, (c.reservedSize or SLOT_SPACING) * (i - 0.5))
            end
        end
    end
end

----------------------------------------------------------------------
-- Mock roll windows (Blizzard's template with its scripts removed, so they never touch real rolls)
----------------------------------------------------------------------
local SAMPLES = {
    { icon = "Interface\\Icons\\INV_Sword_39", name = "Sample Sword", quality = 4 },
    { icon = "Interface\\Icons\\INV_Chest_Plate06", name = "Sample Breastplate", quality = 3 },
    { icon = "Interface\\Icons\\INV_Jewelry_Ring_03", name = "Sample Ring", quality = 2 },
    { icon = "Interface\\Icons\\INV_Misc_Gem_Ruby_02", name = "Sample Gem", quality = 3 },
}
local QUALITY_RGB = { [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 } }

local function SetMockItem(f, sample)
    if f.IconFrame then
        if f.IconFrame.Icon then f.IconFrame.Icon:SetTexture(sample.icon) end
        if f.IconFrame.Border and ColorManager and ColorManager.GetAtlasDataForLootBorderItemQuality then
            local atlas = ColorManager.GetAtlasDataForLootBorderItemQuality(sample.quality)
            if atlas then f.IconFrame.Border:SetAtlas(atlas) end
        end
    end
    local r, g, b = unpack(QUALITY_RGB[sample.quality] or QUALITY_RGB[2])
    if ColorManager and ColorManager.GetColorDataForItemQuality then
        local c = ColorManager.GetColorDataForItemQuality(sample.quality)
        if c then r, g, b = c.r, c.g, c.b end
    end
    if f.Name then
        f.Name:SetText(sample.name)
        f.Name:SetVertexColor(r, g, b)
    end
    if f.Border then f.Border:SetVertexColor(r, g, b) end
end

local function CreateMock()
    local f
    for _, template in ipairs(MOCK_TEMPLATES) do
        local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent, template)
        if ok and frame then f = frame break end
    end

    if f then
        for _, script in ipairs({ "OnShow", "OnHide", "OnEvent", "OnUpdate" }) do f:SetScript(script, nil) end
        if EventRegistry and EventRegistry.UnregisterFrameEventAndCallback then
            pcall(EventRegistry.UnregisterFrameEventAndCallback, EventRegistry, "OPEN_MASTER_LOOT_LIST", f)
        end
        local bc = f.LootButtonContainer or f
        f.rollButtons = {}
        for _, k in ipairs({ "NeedButton", "GreedButton", "PassButton" }) do
            local b = bc[k]
            if b then
                b:SetScript("OnClick", nil)   -- the template's OnClick would call RollOnLoot
                table.insert(f.rollButtons, b)
            end
        end
        if bc.TransmogButton then bc.TransmogButton:Hide() end
        if f.IconFrame then
            for _, script in ipairs({ "OnEnter", "OnLeave", "OnUpdate", "OnClick" }) do f.IconFrame:SetScript(script, nil) end
        end
        if f.Timer then f.Timer:SetMinMaxValues(0, 1) f.Timer:SetValue(0.6) end
        SetMockItem(f, SAMPLES[1])
    else
        -- fallback if no template exists on this client
        f = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(277, 67)
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            f:SetBackdropColor(0, 0, 0, 0.8)
        end
        f.rollButtons = {}
    end
    f:SetClampedToScreen(true)
    if f.SetDontSavePosition then f:SetDontSavePosition(true) end
    f:Hide()
    return f
end

----------------------------------------------------------------------
-- Test rolls (button in the options): three mock rolls at the current position
----------------------------------------------------------------------
local TEST_COUNT = 3
local testRolls = {}
local testButton

local function TestRollsShown()
    for _, f in ipairs(testRolls) do
        if f:IsShown() then return true end
    end
    return false
end

local function UpdateTestButton()
    if testButton then testButton:SetText(TestRollsShown() and "Hide Test Rolls" or "Show Test Rolls") end
end

local function PlaceTestRolls()
    local key = On() and ActiveKey() or nil   -- disabled module: Blizzard's position and size
    for i, f in ipairs(testRolls) do
        if f:IsShown() then PlaceSlot(f, i, key) end
    end
end

local function ShowTestRolls(count)
    for i = 1, TEST_COUNT do
        local f = testRolls[i]
        if i <= count then
            if not f then
                f = CreateMock()
                f:SetFrameStrata("DIALOG")
                for _, b in ipairs(f.rollButtons) do
                    b:SetScript("OnClick", function() f:Hide() end)   -- "rolling" closes it, the slot stays free
                end
                if f.Timer then f.Timer:SetMinMaxValues(0, TEST_DURATION) end
                f:HookScript("OnHide", UpdateTestButton)
                f:SetScript("OnUpdate", function(self, elapsed)
                    self.remaining = self.remaining - elapsed
                    if self.Timer then self.Timer:SetValue(math.max(0, self.remaining)) end
                    if self.remaining <= 0 then self:Hide() end
                end)
                testRolls[i] = f
            end
            SetMockItem(f, SAMPLES[i])
            f.remaining = TEST_DURATION
            f:Show()
        elseif f then
            f:Hide()
        end
    end
    PlaceTestRolls()
    UpdateTestButton()
end

----------------------------------------------------------------------
-- Edit Mode mock with Blizzard's selection look
----------------------------------------------------------------------
local SELECTION_LAYOUT = {   -- Blizzard's EditModeSystemSelectionLayout
    TopRightCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = 8 },
    TopLeftCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = 8 },
    BottomLeftCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = -8 },
    BottomRightCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = -8 },
    TopEdge = { atlas = "_%s-NineSlice-EdgeTop" },
    BottomEdge = { atlas = "_%s-NineSlice-EdgeBottom" },
    LeftEdge = { atlas = "!%s-NineSlice-EdgeLeft" },
    RightEdge = { atlas = "!%s-NineSlice-EdgeRight" },
    Center = { atlas = "%s-NineSlice-Center", x = -8, y = 8, x1 = 8, y1 = -8 },
}
local KIT_HIGHLIGHT = "editmode-actionbar-highlight"
local KIT_SELECTED = "editmode-actionbar-selected"

local preview, selection, dialog
local selected, dragging, clearingBlizzard = false, false, false
local resetDialogAnchor = true
local Changed, RefreshDialog, ShowDialog   -- defined below

local function ApplyKit(frame, kit)
    if frame.kit ~= kit and NineSliceUtil then
        NineSliceUtil.ApplyLayout(frame, SELECTION_LAYOUT, kit)
        frame.kit = kit
    end
end

local function UpdateSelectionLook()
    if not selection then return end
    local hover = selection:IsMouseOver()
    ApplyKit(selection, selected and KIT_SELECTED or KIT_HIGHLIGHT)
    selection.Highlight:SetShown(hover and not selected)
    selection.Label:SetText(selected and NAME or (HUD_EDIT_MODE_INSTRUCTIONS_CLICK_TO_EDIT or "Click to Edit"))
    selection.Label:SetShown(selected or hover)   -- name when selected, hint on hover
end

local function Deselect()
    if not selected then return end
    selected = false
    if dialog then dialog:Hide() end
    UpdateSelectionLook()
end

local function Select()
    if selected then return end
    -- Blizzard's own call for this; it runs through a secure delegate
    clearingBlizzard = true
    if EditModeManagerFrame and EditModeManagerFrame.ClearSelectedSystem then
        EditModeManagerFrame:ClearSelectedSystem()
    end
    clearingBlizzard = false
    selected = true
    UpdateSelectionLook()
    GameTooltip:Hide()
    ShowDialog()
end

local function BuildPreview()
    local f = CreateMock()
    f:SetFrameStrata("MEDIUM")   -- same strata as Blizzard's Edit Mode selections (below the HUD Edit Mode window)
    f:SetToplevel(false)
    f:SetMovable(true)
    for _, b in ipairs(f.rollButtons) do b:EnableMouse(false) end
    if f.IconFrame then f.IconFrame:EnableMouse(false) end
    preview = f

    local sel = CreateFrame("Frame", nil, f, "NineSliceCodeTemplate")
    sel:SetAllPoints()
    sel:SetFrameLevel(f:GetFrameLevel() + 50)
    sel:EnableMouse(true)
    sel:RegisterForDrag("LeftButton")

    sel.Highlight = CreateFrame("Frame", nil, sel, "NineSliceCodeTemplate")
    sel.Highlight:SetAllPoints()
    sel.Highlight:SetAlpha(0.4)
    ApplyKit(sel.Highlight, KIT_HIGHLIGHT)
    if sel.Highlight.SetBlendMode then sel.Highlight:SetBlendMode("ADD") end
    sel.Highlight:Hide()

    sel.Label = sel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    sel.Label:SetAllPoints()
    if sel.Label.SetIgnoreParentScale then sel.Label:SetIgnoreParentScale(true) end

    sel:SetScript("OnMouseDown", Select)
    sel:SetScript("OnEnter", function(self)
        UpdateSelectionLook()
        if not selected then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText(NAME)
            GameTooltip:Show()
        end
    end)
    sel:SetScript("OnLeave", function()
        UpdateSelectionLook()
        GameTooltip:Hide()
    end)
    sel:SetScript("OnDragStart", function()
        if selected then
            f:StartMoving()
            dragging = true
        end
    end)
    sel:SetScript("OnDragStop", function()
        if not dragging then return end
        f:StopMovingOrSizing()
        dragging = false
        local key = ActiveKey()
        local cx, cy = f:GetCenter()
        if key and cx then
            local s = f:GetScale()
            local e = CopyTable(Entry(key) or {})
            e.x, e.y = cx * s, cy * s   -- stored in UIParent units
            SetEntry(key, e)
        end
        Changed()
    end)
    selection = sel
end

local function ShowPreview()
    if not preview then BuildPreview() end
    selected = false
    PlaceSlot(preview, 1, ActiveKey())
    preview:Show()
    UpdateSelectionLook()
end

local function HidePreview()
    Deselect()
    if preview then preview:Hide() end
end

----------------------------------------------------------------------
-- Settings dialog (copy of Blizzard's Edit Mode settings dialog)
----------------------------------------------------------------------
local DIALOG_W, LABEL_W, ROW_H, PAD = 370, 110, 32, 20
local VALUE_W = 40   -- width of the "100%" text right of the slider

-- Escape on our own frames: a keyboard-enabled frame
-- swallows Escape and lets every other key through. (Keyboard propagation can't be changed in
-- combat; these frames are only shown in Edit Mode and hidden when combat starts.)
local function EscapeHandler(onEscape)
    return function(self, key)
        if InCombatLockdown() then return end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            onEscape()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end
end

local function EnableEscape(frame, onEscape)
    frame:EnableKeyboard(true)
    frame:SetPropagateKeyboardInput(true)
    frame:SetScript("OnKeyDown", EscapeHandler(onEscape))
end

local function Write(field, value)
    local key = ActiveKey()
    if not key then return end
    local e = CopyTable(Entry(key) or {})
    e[field] = value
    SetEntry(key, e)
    Changed()
end

local function NewBorder(frame, template)
    local ok, border = pcall(CreateFrame, "Frame", nil, frame, template)
    if ok and border then
        border:SetAllPoints()
        return
    end
    Mixin(frame, BackdropTemplateMixin)
    frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 } })
end

local function BuildDialog()
    local d = CreateFrame("Frame", "ESFLootRollDialog", UIParent)
    d:SetSize(DIALOG_W, 203)
    d:SetFrameStrata("DIALOG")
    d:SetFrameLevel(200)
    d:SetClampedToScreen(true)
    d:SetMovable(true)
    d:EnableMouse(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:Hide()
    EnableEscape(d, function() d:Hide() end)
    NewBorder(d, "DialogBorderTranslucentTemplate")

    -- everything else on a child above the border
    local inner = CreateFrame("Frame", nil, d)
    inner:SetAllPoints()
    inner:SetFrameLevel(d:GetFrameLevel() + 10)

    local title = inner:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText(NAME)

    local close = CreateFrame("Button", nil, inner, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT")
    close:SetScript("OnClick", function() d:Hide() end)

    local function Row(y, text)
        local label = inner:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
        label:SetSize(LABEL_W, ROW_H)
        label:SetPoint("TOPLEFT", PAD, y)
        label:SetJustifyH("LEFT")
        label:SetText(text)
        return label
    end

    local dirLabel = Row(-45, "Growth Direction")
    local dd = CreateFrame("DropdownButton", nil, inner, "WowStyle1DropdownTemplate")
    dd:SetPoint("LEFT", dirLabel, "RIGHT", 5, 0)
    dd:SetPoint("RIGHT", inner, "RIGHT", -PAD, 0)
    local function IsDir(value) return select(4, Values(Entry(ActiveKey()))) == value end
    local function SetDir(value) Write("dir", value) end
    dd:SetupMenu(function(_, root)
        root:CreateRadio("Up", IsDir, SetDir, "UP")
        root:CreateRadio("Down", IsDir, SetDir, "DOWN")
    end)

    -- Size: the value text ends at the same right edge as the dropdown and the buttons
    local sizeLabel = Row(-45 - ROW_H - 2, "Size")
    local slider = CreateFrame("Frame", nil, inner, "MinimalSliderWithSteppersTemplate")
    slider:SetHeight(ROW_H)
    slider:SetPoint("LEFT", sizeLabel, "RIGHT", 5, 0)
    slider:SetPoint("RIGHT", inner, "RIGHT", -PAD, 0)
    local formatters = { [MinimalSliderWithSteppersMixin.Label.Right] = function(v) return math.floor(v + 0.5) .. "%" end }
    slider:Init(100, SCALE_MIN, SCALE_MAX, (SCALE_MAX - SCALE_MIN) / SCALE_STEP, formatters)
    if slider.Slider and slider.RightText then
        -- bar ends early enough that arrow + gap + value text fit inside the slider frame
        slider.Slider:ClearAllPoints()
        slider.Slider:SetPoint("TOPLEFT", 19, 0)
        slider.Slider:SetPoint("BOTTOMRIGHT", -(VALUE_W + 12 + 13), 0)
        slider.RightText:ClearAllPoints()
        slider.RightText:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
        slider.RightText:SetWidth(VALUE_W)
        slider.RightText:SetJustifyH("RIGHT")
    end
    local updating = false
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v)
        if updating then return end
        v = math.floor(v / SCALE_STEP + 0.5) * SCALE_STEP
        Write("scale", v / 100)
    end, slider)

    local revert = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    revert:SetSize(180, 28)
    revert:SetPoint("TOPLEFT", PAD, -45 - 2 * (ROW_H + 2) - 12)
    revert:SetText(HUD_EDIT_MODE_REVERT_CHANGES or "Revert Changes")
    revert:SetScript("OnClick", function()
        local key = ActiveKey()
        if key then
            SetEntry(key, Stored(key))
            Changed()
        end
    end)

    local reset = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    reset:SetSize(DIALOG_W - 2 * PAD, 28)
    reset:SetPoint("TOPLEFT", revert, "BOTTOMLEFT", 0, -4)
    reset:SetText(HUD_EDIT_MODE_RESET_POSITION or "Reset To Default Position")
    reset:SetScript("OnClick", function()
        local key = ActiveKey()
        if not key then return end
        local e = CopyTable(Entry(key) or {})
        e.x, e.y = nil, nil
        SetEntry(key, e)
        Changed()
    end)

    d:SetScript("OnHide", Deselect)

    function d:Refresh()
        local key = ActiveKey()
        local x, _, scale = Values(Entry(key))
        updating = true
        slider:SetValue(math.floor(scale * 100 + 0.5))
        updating = false
        dd:GenerateMenu()
        dd:SetEnabled(key ~= nil)
        slider:SetEnabled(key ~= nil)
        revert:SetEnabled(key ~= nil and IsDirty(key))
        reset:SetEnabled(x ~= nil)
    end

    dialog = d
end

function ShowDialog()
    if not dialog then BuildDialog() end
    if resetDialogAnchor then
        dialog:ClearAllPoints()
        dialog:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 200)   -- Blizzard's default spot
        resetDialogAnchor = false
    end
    dialog:Refresh()
    dialog:Show()
end

function RefreshDialog()
    if dialog and dialog:IsShown() then dialog:Refresh() end
end

----------------------------------------------------------------------
-- Unsaved changes on exit, when only our frame changed (Blizzard only asks for its own changes).
-- A copy of Blizzard's dialog; Save and Exit / Exit click Blizzard's close button through
-- secure buttons, so Edit Mode closes the same way as with its own dialog.
----------------------------------------------------------------------
local prompt, closeGuard

local function NeedsPrompt()
    return On() and InEditMode() and IsDirty() and not BlizzardHasChanges()
end

local function HidePrompt()
    if prompt and prompt:IsShown() and not InCombatLockdown() then prompt:Hide() end
end

local function BuildPrompt()
    local m = EditModeManagerFrame
    local p = CreateFrame("Frame", "ESFLootRollUnsavedDialog", UIParent)
    p:SetSize(450, 130)
    p:SetPoint("TOP", UIParent, "TOP", 0, -135)   -- where Blizzard's static popups (and its own dialog) sit
    p:SetFrameStrata("DIALOG")
    p:SetFrameLevel(300)
    p:EnableMouse(true)
    p:Hide()
    EnableEscape(p, HidePrompt)
    NewBorder(p, "DialogBorderTemplate")

    local inner = CreateFrame("Frame", nil, p)
    inner:SetAllPoints()
    inner:SetFrameLevel(p:GetFrameLevel() + 10)

    local title = inner:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetWidth(400)
    title:SetPoint("TOP", 0, -25)
    title:SetSpacing(10)
    title:SetText(HUD_EDIT_MODE_UNSAVED_CHANGES_EXIT_DIALOG_TITLE
        or "If you exit now you will lose any unsaved changes.\nHow would you like to proceed?")

    local function SecureClose(text, width, onPreClick)
        local b = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate, SecureActionButtonTemplate")
        b:SetSize(width, 22)
        b:SetText(text)
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type", "click")
        b:SetAttribute("clickbutton", m.CloseButton)
        b:SetScript("PreClick", onPreClick)   -- runs before Blizzard's close (safe to run twice)
        return b
    end

    local save = SecureClose(HUD_EDIT_MODE_SAVE_AND_EXIT or "Save and Exit", 160, function() Commit() end)
    save:SetPoint("BOTTOMLEFT", 25, 25)

    local exit = SecureClose(HUD_EDIT_MODE_EXIT or "Exit", 115, function() Discard() end)
    exit:SetPoint("BOTTOM", 22, 25)

    local cancel = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    cancel:SetSize(115, 22)
    cancel:SetText(CANCEL or "Cancel")
    cancel:SetPoint("BOTTOMRIGHT", -25, 25)
    cancel:SetScript("OnClick", HidePrompt)

    prompt = p
end

local function ShowPrompt()
    if InCombatLockdown() then return end
    if not prompt then BuildPrompt() end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
    prompt:Show()
end

-- Invisible button over Blizzard's close button, only while just our changes are unsaved
local function UpdateCloseGuard()
    local m = EditModeManagerFrame
    if not (m and m.CloseButton) then return end
    if not closeGuard then
        local g = CreateFrame("Button", nil, m)
        g:SetAllPoints(m.CloseButton)
        g:SetFrameLevel(m.CloseButton:GetFrameLevel() + 5)
        g:SetScript("OnClick", ShowPrompt)
        g:SetScript("OnEnter", function(self)
            m.CloseButton:LockHighlight()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip_AddNormalLine(GameTooltip, HUD_EDIT_MODE_UNSAVED_CHANGES or "You have unsaved changes")
            GameTooltip:Show()
        end)
        g:SetScript("OnLeave", function()
            m.CloseButton:UnlockHighlight()
            GameTooltip:Hide()
        end)
        EnableEscape(g, ShowPrompt)   -- Escape asks too
        g:Hide()
        closeGuard = g
    end
    closeGuard:SetShown(NeedsPrompt())
end

----------------------------------------------------------------------
-- Blizzard's Save / Revert All buttons light up for our changes too
----------------------------------------------------------------------
local function UpdateBlizzardButtons()
    local m = EditModeManagerFrame
    if not (m and m.SaveChangesButton and m.RevertAllChangesButton and InEditMode()) then return end
    if On() and IsDirty() then
        m.SaveChangesButton:SetEnabled(true)
        m.RevertAllChangesButton:SetEnabled(true)
    elseif not BlizzardHasChanges() then
        m.SaveChangesButton:SetEnabled(false)
        m.RevertAllChangesButton:SetEnabled(false)
    end
    UpdateCloseGuard()
end

function Changed()
    if preview and preview:IsShown() then PlaceSlot(preview, 1, ActiveKey()) end
    if On() then ApplyRollFrames() end
    PlaceTestRolls()
    RefreshDialog()
    UpdateBlizzardButtons()
end

----------------------------------------------------------------------
-- Layout list changes: rename, delete, create (copy)
----------------------------------------------------------------------
local knownKeys      -- layout keys by index, as last seen
local pendingSource  -- layout a new one is being created from (nil = import / defaults)

local function CurrentKeys()
    local list = Layouts()
    if not list then return nil end
    local keys = {}
    for i, info in ipairs(list) do keys[i] = KeyOf(info, i) end
    return keys
end

local function MoveKey(from, to)
    local e = StoreFor(from)[from]
    StoreFor(from)[from] = nil
    if e and StoreFor(to)[to] == nil then StoreFor(to)[to] = e end
    if work then
        local w = work[from]
        work[from] = nil
        if w and work[to] == nil then work[to] = w end
    end
end

local function DropKey(key)
    StoreFor(key)[key] = nil
    if work then work[key] = nil end
end

local function SyncLayouts()
    local keys = CurrentKeys()
    if not keys then return end
    if knownKeys then
        local now, before = {}, {}
        for _, k in ipairs(keys) do now[k] = true end
        for _, k in ipairs(knownKeys) do before[k] = true end

        if #keys == #knownKeys then
            -- same count: a different name at the same index is a rename
            for i, k in ipairs(keys) do
                local old = knownKeys[i]
                if old ~= k and not now[old] and not before[k] then MoveKey(old, k) end
            end
        elseif #keys < #knownKeys then
            for _, old in ipairs(knownKeys) do
                if not now[old] then DropKey(old) end
            end
        else
            for _, k in ipairs(keys) do
                if not before[k] then
                    -- new layout: saved with the source's current (also unsaved) settings
                    if pendingSource then SetBoth(k, Entry(pendingSource)) end
                    -- Blizzard drops unsaved changes of the other layouts when one is created
                    if work then
                        for _, other in ipairs(keys) do
                            if before[other] then work[other] = Clean(Stored(other)) end
                        end
                    end
                end
            end
            pendingSource = nil
        end
    end
    knownKeys = keys
end

local function SourceKey(info)
    local list = Layouts()
    if not info then return ActiveKey() end
    if list then
        for i, l in ipairs(list) do
            if l == info or (l.layoutType == info.layoutType and l.layoutName == info.layoutName) then
                return KeyOf(l, i)
            end
        end
    end
    return ActiveKey()
end

----------------------------------------------------------------------
-- Events and hooks
----------------------------------------------------------------------
local function OnEditModeEnter()
    if not ESFDB then return end
    BeginWork()
    resetDialogAnchor = true
    if On() then ShowPreview() end
    UpdateBlizzardButtons()
end

local function OnEditModeExit()
    HidePreview()
    HidePrompt()
    work = nil   -- anything not saved is dropped
    if closeGuard then closeGuard:Hide() end
    Changed()
end

local function OnSavedLayouts()
    if not ESFDB then return end
    SyncLayouts()
    Commit()
    Changed()
end

local function InstallHooks()
    if type(GroupLootContainer_Update) == "function" then
        hooksecurefunc("GroupLootContainer_Update", function()
            if On() then ApplyRollFrames() end
        end)
    end

    local m = EditModeManagerFrame
    if not m then return end

    EventRegistry:RegisterCallback("EditMode.Enter", OnEditModeEnter, ESF)
    EventRegistry:RegisterCallback("EditMode.Exit", OnEditModeExit, ESF)
    EventRegistry:RegisterCallback("EditMode.SavedLayouts", OnSavedLayouts, ESF)

    -- Blizzard selects or clears its own systems -> ours gets deselected
    hooksecurefunc(m, "SelectSystem", function()
        resetDialogAnchor = true
        Deselect()
    end)
    hooksecurefunc(m, "ClearSelectedSystem", function()
        if not clearingBlizzard then Deselect() end
    end)
    hooksecurefunc(m, "SetHasActiveChanges", UpdateBlizzardButtons)

    -- where a new layout comes from
    if m.ShowNewLayoutDialog then
        hooksecurefunc(m, "ShowNewLayoutDialog", function(_, info) pendingSource = SourceKey(info) end)
    end
    if m.ShowImportLayoutDialog then
        hooksecurefunc(m, "ShowImportLayoutDialog", function() pendingSource = nil end)
    end

    if m.RevertAllChangesButton then
        m.RevertAllChangesButton:HookScript("OnClick", function()
            Discard()
            Changed()
        end)
    end

    -- "Exit" / "Switch" without saving in Blizzard's own unsaved-changes dialog
    local unsaved = EditModeUnsavedChangesDialog
    if unsaved and unsaved.ProceedButton then
        unsaved.ProceedButton:HookScript("PreClick", function()
            Discard()
            Changed()
        end)
    end
end

----------------------------------------------------------------------
-- "Open Edit Mode" in the ESF options: a secure /editmode macro button.
-- It is parented to UIParent and only laid over the visible (normal) button out of combat,
-- so the options frames never become protected.
----------------------------------------------------------------------
local inCombat = InCombatLockdown()
local openPlaceholder, openSecure

local function UpdateOpenButton()
    if not openPlaceholder or InCombatLockdown() then return end
    local onPage = openPlaceholder:IsVisible()
    local usable = onPage and On() and not inCombat
    if not openSecure then
        local b = CreateFrame("Button", "ESFOpenEditModeButton", UIParent, "UIPanelButtonTemplate, SecureActionButtonTemplate")
        b:SetText("Open Edit Mode")
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", _G.SLASH_EDITMODE1 or "/editmode")
        -- close the options once Edit Mode is open
        b:SetScript("PostClick", function()
            if EditModeManagerFrame and EditModeManagerFrame:IsShown() and SettingsPanel and SettingsPanel:IsShown() then
                SettingsPanel:Close(true)
            end
        end)
        b:Hide()
        openSecure = b
    end
    if usable then
        openSecure:ClearAllPoints()
        openSecure:SetAllPoints(openPlaceholder)
        -- one strata above the options panel (HIGH), so the panel can never be raised above it
        openSecure:SetFrameStrata("DIALOG")
        openSecure:Show()
    else
        openSecure:Hide()
        openSecure:ClearAllPoints()   -- no anchor to the options frames while hidden
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        InstallHooks()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- secure buttons can still be changed here, right before the lockdown starts
        inCombat = true
        if openSecure then
            openSecure:Hide()
            openSecure:ClearAllPoints()
        end
        if prompt then prompt:Hide() end
        if closeGuard then closeGuard:Hide() end
        if dialog then dialog:Hide() end
        ESF:RefreshSettings()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        ESF:RefreshSettings()
        UpdateOpenButton()
    else
        -- let Blizzard's manager process the event first
        C_Timer.After(0, function()
            if not ESFDB then return end
            SyncLayouts()
            Changed()
        end)
    end
end)

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
table.insert(ESF.onLoad, function()
    ESFDB.lootRollLayouts = ESFDB.lootRollLayouts or {}
    ESFCharDB.lootRollLayouts = ESFCharDB.lootRollLayouts or {}
end)

mod = ESF:Module({
    name = NAME, key = "lootRollFrame",
    desc = "Move and resize the loot roll windows in Edit Mode",
    note = "Move and resize the Need/Greed/Pass roll windows in Edit Mode.",
    onChange = function(on)
        if InEditMode() then
            if on then ShowPreview() else HidePreview() end
            UpdateBlizzardButtons()
        end
        ApplyRollFrames()   -- disabled: back to Blizzard's position and size
        PlaceTestRolls()
        UpdateOpenButton()
    end,
})

ESF:Custom({
    noLabel = true,
    create = function(row)
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", row, "LEFT", row.labelX, 0)
        text:SetText("Saved per Edit Mode layout. Select the Loot Roll Frame in Edit Mode to change it.")
        return text
    end,
    update = function(text, on) text:SetFontObject(on and GameFontHighlight or GameFontDisable) end,
})

ESF:Custom({
    noLabel = true,
    create = function(row)
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(200, 22)
        btn:SetPoint("LEFT", row, "LEFT", row.labelX, 0)
        btn:SetScript("OnClick", function() ShowTestRolls(TestRollsShown() and 0 or TEST_COUNT) end)
        testButton = btn
        UpdateTestButton()
        return btn
    end,
    update = function(btn, on) btn:SetEnabled(on) end,
})

ESF:Custom({
    noLabel = true,
    create = function(row)
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(200, 22)
        btn:SetPoint("LEFT", row, "LEFT", row.labelX, 0)
        btn:SetText("Open Edit Mode")
        btn:HookScript("OnShow", function() C_Timer.After(0, UpdateOpenButton) end)
        btn:HookScript("OnHide", UpdateOpenButton)

        btn.hint = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        btn.hint:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 2, -4)
        btn.hint:SetText("Edit Mode is not available during combat.")
        btn.hint:Hide()

        openPlaceholder = btn
        return btn
    end,
    update = function(btn, on)
        btn.hint:SetShown(inCombat)
        btn:SetEnabled(on and not inCombat)
        UpdateOpenButton()
    end,
})
