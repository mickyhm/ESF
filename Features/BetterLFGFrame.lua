-- Group Browser tweaks for the Looking For Group window:
--   * a handle at the bottom edge to make the window taller on the browse tab
--     (the other tabs keep Blizzard's size; their layouts are built for it)
--   * compact entries: smaller fonts, icons and spacing, so more groups fit in the list
local ADDON, ESF = ...

local GROUP_FINDER = "Blizzard_GroupFinder_VanillaStyle"
local DEFAULT_HEIGHT = 535   -- LFGParentFrame's size in Blizzard_LFGVanilla_ParentFrame.xml
local MAX_HEIGHT = 1200
local SCREEN_MARGIN = 4      -- keep this much space to the bottom of the screen

local mod
local enabled, handleOn, compactOn = false, false, false
local height = DEFAULT_HEIGHT
local hooked = false
local grip

-- Tallest the window can get without leaving the screen.
local function MaxHeight()
    local top = LFGParentFrame:GetTop()
    local max = MAX_HEIGHT
    if top then max = math.min(max, math.max(top - SCREEN_MARGIN, DEFAULT_HEIGHT)) end
    return max
end

local function Apply()
    local parent, browse = LFGParentFrame, LFGBrowseFrame
    if not parent or not browse then return end
    -- IsShown, not IsVisible: the browse tab stays selected while the window is closed
    local active = enabled and handleOn and browse:IsShown()
    local h = active and math.min(math.max(height, DEFAULT_HEIGHT), MaxHeight()) or DEFAULT_HEIGHT
    if math.abs(parent:GetHeight() - h) > 0.5 then
        -- the window isn't always anchored at its top (moved with BlizzMove: CENTER), so
        -- shift it back afterwards to keep the top edge in place
        local top = parent:GetTop()
        parent:SetHeight(h)
        local newTop = parent:GetTop()
        if top and newTop and math.abs(newTop - top) > 0.1 then
            parent:AdjustPointsOffset(0, top - newTop)
        end
    end
    if grip then grip:SetShown(active) end
    -- Blizzard's separator above the buttons sits 21 px above the list's bottom edge, so it
    -- shows through the gaps between rows
    if browse.BarMiddle then browse.BarMiddle:SetShown(not enabled) end
end

----------------------------------------------------------------------
-- Resize grip at the bottom edge. Apply keeps the top edge in place,
-- so dragging only moves the bottom edge.
----------------------------------------------------------------------
local function CursorY()
    local _, y = GetCursorPosition()
    return y / LFGParentFrame:GetEffectiveScale()
end

local GRIP_W, GRIP_H = 112, 20
local GRIP_LINE_W = 28
-- 45 degree sides: the edges then step exactly one pixel across per pixel down
local GRIP_SLANT = GRIP_H
local BORDER_HOVER = { 0.78, 0.63, 0.42 }
local LINE_COLOR, LINE_HOVER = { 0.6, 0.5, 0.35 }, { 0.88, 0.78, 0.58 }
-- Edge bands from the outside in, sampled from the window frame's metal border:
-- dim rim, bright metal, dark brown, darker brown, then the fill.
local GRIP_BANDS = {
    { width = 1, color = { 0.19, 0.14, 0.08 } },
    { width = 2, color = { 0.53, 0.42, 0.28 }, metal = true },
    { width = 1, color = { 0.26, 0.17, 0.06 } },
    { width = 1, color = { 0.16, 0.11, 0.05 } },
}
local GRIP_FILL = { 0.06, 0.05, 0.04 }

local LOWER_LEFT = LOWER_LEFT_VERTEX or 2
local LOWER_RIGHT = LOWER_RIGHT_VERTEX or 4

-- Trapezoid hanging from the window's bottom edge: \___/
-- Layers are inset along the slanted sides and the bottom; the top has no border.
-- Side insets are rounded to whole pixels so every band's edge stays on the pixel grid.
local function Trapezoid(parent, subLevel, color, inset)
    local t = parent:CreateTexture(nil, "ARTWORK", nil, subLevel)
    t:SetColorTexture(1, 1, 1)
    t:SetVertexColor(color[1], color[2], color[3])
    local side = math.floor(inset * math.sqrt(GRIP_H ^ 2 + GRIP_SLANT ^ 2) / GRIP_H + 0.5)
    local h = GRIP_H - inset
    t:SetPoint("TOPLEFT", side, 0)
    t:SetPoint("TOPRIGHT", -side, 0)
    t:SetHeight(h)
    local slant = GRIP_SLANT * h / GRIP_H
    t:SetVertexOffset(LOWER_LEFT, slant, 0)
    t:SetVertexOffset(LOWER_RIGHT, -slant, 0)
    return t
end

local function SetColor(parts, c)
    for _, t in ipairs(parts) do t:SetVertexColor(c[1], c[2], c[3]) end
end

local function CreateGrip()
    grip = CreateFrame("Button", nil, LFGBrowseFrame)
    grip:SetSize(GRIP_W, GRIP_H)
    grip:SetPoint("TOP", LFGBrowseFrame, "BOTTOM", 0, 4)
    grip:SetFrameLevel(LFGBrowseFrame:GetFrameLevel() + 20)

    local inset, metal = 0, nil
    for i, band in ipairs(GRIP_BANDS) do
        local t = Trapezoid(grip, i - 1, band.color, inset)
        if band.metal then metal = t end
        inset = inset + band.width
    end
    Trapezoid(grip, #GRIP_BANDS, GRIP_FILL, inset)
    local lines = {}
    for i = -1, 1 do
        local line = grip:CreateTexture(nil, "OVERLAY")
        line:SetColorTexture(1, 1, 1)
        line:SetSize(GRIP_LINE_W, 1)
        line:SetPoint("CENTER", 0, i * 3)
        table.insert(lines, line)
    end
    local function Highlight(on)
        local c = on and BORDER_HOVER or GRIP_BANDS[2].color
        metal:SetVertexColor(c[1], c[2], c[3])
        SetColor(lines, on and LINE_HOVER or LINE_COLOR)
    end
    Highlight(false)
    grip:SetScript("OnEnter", function() Highlight(true) end)
    grip:SetScript("OnLeave", function(self)
        if not self.startY then Highlight(false) end
    end)

    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.startY, self.startH = CursorY(), LFGParentFrame:GetHeight()
        self:SetScript("OnUpdate", function()
            local h = math.floor(self.startH + (self.startY - CursorY()) + 0.5)
            height = math.min(math.max(h, DEFAULT_HEIGHT), MaxHeight())
            Apply()
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        if not self.startY then return end
        self:SetScript("OnUpdate", nil)
        self.startY, self.startH = nil, nil
        if not self:IsMouseOver() then Highlight(false) end
        ESFDB.lfgFrameHeight = height
    end)
    grip:SetScript("OnHide", grip:GetScript("OnMouseUp"))
end

----------------------------------------------------------------------
-- Background art: keep the picture at its normal size at the top and
-- fill the extra space below it with the dark tone from its top edge.
----------------------------------------------------------------------
-- Inset.CustomBG at the default window height (Blizzard_LFGVanilla_Browse.xml):
-- BackgroundArt is 80 below the top and 3 above the bottom, CustomBG 3 inside it.
local BG_HEIGHT = DEFAULT_HEIGHT - 80 - 3 - 2 * 3

local function ExtendBackground()
    local inset = LFGBrowseFrame.Inset
    local bg = inset and inset.CustomBG
    if not bg then return end

    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
    bg:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -3, -3)
    bg:SetHeight(BG_HEIGHT)

    local fill = inset:CreateTexture(nil, "BACKGROUND")
    fill:SetColorTexture(0.047, 0.039, 0.035)
    fill:SetPoint("TOPLEFT", bg, "BOTTOMLEFT")
    fill:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)
end

----------------------------------------------------------------------
-- Compact entries. Rows come from a pool and are reused, so every row is
-- laid out again after Blizzard's LFGBrowseSearchEntry_Init, compact or not.
-- Default values are LFGBrowseSearchEntryBaseTemplate's (Blizzard_LFGVanilla_Browse.xml).
----------------------------------------------------------------------
local COMPACT_ROW_H = 60
local COMPACT = {
    nameSize = 14, textSize = 11,
    top = -9, lineGap = -1, lineH = 13,
    leaderScale = 0.85,
    roleIcon = 22, soloRole = 19, classIcon = 20, newPlayerIcon = 16, discordIcon = 14,
}
local DEFAULT = {
    top = -14, lineGap = -2, lineH = 15,
    leaderScale = 1,
    roleIcon = 27, soloRole = 23, soloRoleStep = 24, classIcon = 24, newPlayerIcon = 20, discordIcon = 16,
}

local listHooked = false

local function IsCompact() return enabled and compactOn end

-- Font size; nil restores the size the font string was created with.
local function SetFontSize(fs, size)
    if not fs then return end
    fs.esfFont = fs.esfFont or { fs:GetFont() }
    local file, original, flags = unpack(fs.esfFont)
    fs:SetFont(file, size or original, flags)
end

local leaderW, leaderH
local function LeaderIconSize()
    if not leaderW then
        local info = C_Texture.GetAtlasInfo("groupfinder-icon-leader")
        leaderW, leaderH = info and info.width or 16, info and info.height or 16
    end
    return leaderW, leaderH
end

local function LayoutEntry(row)
    local c = IsCompact()
    local v = c and COMPACT or DEFAULT

    local w, h = LeaderIconSize()
    row.PartyIcon:SetSize(w * v.leaderScale, h * v.leaderScale)
    row.PartyIcon:SetPoint("TOPLEFT", 8, v.top)

    SetFontSize(row.Name, c and COMPACT.nameSize)
    SetFontSize(row.Level, c and COMPACT.textSize)
    SetFontSize(row.ActivityName, c and COMPACT.textSize)
    row.ActivityName:SetHeight(v.lineH)
    row.ActivityName:SetPoint("TOPLEFT", row.Name, "BOTTOMLEFT", 0, v.lineGap)
    if row.PlaystyleLabel then
        SetFontSize(row.PlaystyleLabel, c and COMPACT.textSize)
        row.PlaystyleLabel:SetHeight(v.lineH)
        row.PlaystyleLabel:SetPoint("TOPLEFT", row.ActivityName, "BOTTOMLEFT", 0, v.lineGap)
    end

    row.ClassIcon:SetSize(v.classIcon, v.classIcon)
    row.NewPlayerFriendlyIcon:SetSize(v.newPlayerIcon, v.newPlayerIcon)
    if row.DiscordIcon then row.DiscordIcon:SetSize(v.discordIcon, v.discordIcon) end

    local data = row.DataDisplay
    if data and data.Enumerate and data.Enumerate.Icons then
        local icons = data.Enumerate.Icons
        for i, icon in ipairs(icons) do
            icon:SetSize(v.roleIcon, v.roleIcon)
            if i > 1 then icon:SetPoint("CENTER", icons[i - 1], "CENTER", -v.roleIcon, 0) end
        end
    end
    if data and data.Solo and data.Solo.Roles then
        SetFontSize(data.Solo.RolesText, c and COMPACT.textSize)
        local roles = data.Solo.Roles
        local step = c and (COMPACT.soloRole + 1) or DEFAULT.soloRoleStep
        for i, role in ipairs(roles) do
            role:SetSize(v.soloRole, v.soloRole)
            if i > 1 then role:SetPoint("CENTER", roles[i - 1], "CENTER", step, 0) end
        end
    end
end

-- Row heights. Headers and everything else keep their template's height.
local function ElementExtent(_, elementData)
    local view = LFGBrowseFrame.ScrollBox:GetView()
    local data = elementData.data or (elementData.GetData and elementData:GetData())
    if IsCompact() and data and data.category and not data.dividerType then
        return COMPACT_ROW_H
    end
    return view:GetTemplateExtentFromElementData(elementData)
end

local function RefreshList()
    if not hooked then return end
    local box = LFGBrowseFrame.ScrollBox
    if not listHooked then
        if not IsCompact() then return end   -- leave Blizzard's list alone until first used
        listHooked = true
        hooksecurefunc("LFGBrowseSearchEntry_Init", LayoutEntry)
        -- set once: setting it drops the cached row heights, and until they are recalculated
        -- every row counts as 0 tall, which breaks the list's scroll range
        box:GetView():SetElementExtentCalculator(ElementExtent)
    end
    box:FullUpdate(ScrollBoxConstants.UpdateImmediately)   -- recalculates the row heights
    if LFGBrowseFrame:IsVisible() then LFGBrowseFrame:UpdateResults() end
end

local function Hook()
    if hooked or not LFGParentFrame or not LFGBrowseFrame then return end
    hooked = true
    CreateGrip()
    ExtendBackground()
    LFGBrowseFrame:HookScript("OnShow", Apply)
    LFGBrowseFrame:HookScript("OnHide", Apply)
    -- the window is placed by the UI panel manager after OnShow; clamp again once it's there
    LFGParentFrame:HookScript("OnShow", function() C_Timer.After(0, Apply) end)
    Apply()
    RefreshList()
end

local IsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
if IsLoaded(GROUP_FINDER) then
    Hook()
else
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, _, name)
        if name == GROUP_FINDER then
            self:UnregisterEvent("ADDON_LOADED")
            Hook()
        end
    end)
end

mod = ESF:Module({
    name = "Better LFG Frame", key = "betterLFGFrame",
    desc = "Allows more entries to be shown in the group browser",
    note = "Allows more entries to be shown at once in the group browser.",
    onChange = function(on)
        enabled = on
        height = ESFDB.lfgFrameHeight or DEFAULT_HEIGHT
    end,
})

ESF:Checkbox({
    key = "lfgResizeHandle", label = "Expand Handle", default = true,
    tooltip = "Drag the handle at the bottom of the Group Browser to make the window taller.",
    onChange = function(on)
        handleOn = on
        Apply()
    end,
})

ESF:Checkbox({
    key = "lfgCompactEntries", label = "Compact Entries", default = true,
    tooltip = "Smaller text, icons and spacing, so more groups fit in the list.",
    onChange = function(on)
        compactOn = on
        RefreshList()
    end,
})
