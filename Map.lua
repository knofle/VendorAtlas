local _, VA = ...

local MAX_TOOLTIP_ITEMS = 30

-- Map helpers ---------------------------------------------------------------

-- The map tree never changes during a session, so lookups on it are cached

local ancestorCache = {}

-- Walks up the map tree until mapType is at or above the wanted level
local function Ancestor(mapID, mapType)
    local byType = ancestorCache[mapType]
    if not byType then
        byType = {}
        ancestorCache[mapType] = byType
    end
    local found = byType[mapID]
    if found == nil then
        local info = C_Map.GetMapInfo(mapID)
        while info and info.mapType > mapType and info.parentMapID and info.parentMapID ~= 0 do
            info = C_Map.GetMapInfo(info.parentMapID)
        end
        found = info and info.mapID or false
        byType[mapID] = found
    end
    return found or nil
end

-- Where a child map sits on one of its parent maps, or false if mapID isn't a parent
local rectCache = {}
local function MapRect(child, mapID)
    local byParent = rectCache[child]
    if not byParent then
        byParent = {}
        rectCache[child] = byParent
    end
    local rect = byParent[mapID]
    if rect == nil then
        rect = false
        local parent, depth = child, 0
        repeat
            local info = C_Map.GetMapInfo(parent)
            parent = info and info.parentMapID
            depth = depth + 1
        until not parent or parent == 0 or parent == mapID or depth > 10
        if parent == mapID then
            local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(child, mapID)
            if minX then rect = { minX, maxX - minX, minY, maxY - minY } end
        end
        byParent[mapID] = rect
    end
    return rect
end

-- Vendor position on mapID, if mapID is the vendor's map or one of its parents
local function PosOnMap(vendor, mapID)
    if not vendor.mapID then return end
    if vendor.mapID == mapID then return vendor.x, vendor.y end
    local rect = MapRect(vendor.mapID, mapID)
    if rect then return rect[1] + vendor.x * rect[2], rect[3] + vendor.y * rect[4] end
end

-- Pin styling and actions -------------------------------------------------------

local PIN = "VendorAtlasPinTemplate"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"
local C = VA.COLORS
local ACCENT, BORDER = C.accent, C.border

local PIN_STYLES = {
    visited = { ring = { 0.85, 0.68, 0.2 }, icon = { 1, 1, 1 }, desaturate = false, alpha = 1 },
    unvisited = { ring = { 0.9, 0.15, 0.1 }, icon = { 1, 0.35, 0.3 }, desaturate = true, alpha = 1 },
    hidden = { ring = { 0.4, 0.4, 0.4 }, icon = { 0.6, 0.6, 0.6 }, desaturate = true, alpha = 0.7 },
    service = { ring = { 0.45, 0.72, 0.78 }, icon = { 1, 1, 1 }, desaturate = false, alpha = 1 },
    serviceUnverified = { ring = { 0.9, 0.15, 0.1 }, icon = { 1, 1, 1 }, desaturate = false, alpha = 1 },
}

-- Works on map pins and spread buttons, which share Ring/Icon textures
local function ApplyStyle(frame, state)
    local style = PIN_STYLES[state]
    frame.Ring:SetVertexColor(unpack(style.ring))
    frame.Icon:SetDesaturated(style.desaturate)
    frame.Icon:SetVertexColor(unpack(style.icon))
    frame:SetAlpha(style.alpha)
end

local NAME_COLORS = { service = { 0.55, 0.85, 0.9 }, serviceUnverified = { 1, 0.35, 0.3 }, visited = { 0.86, 0.80, 0.70 }, unvisited = { 1, 0.35, 0.3 }, hidden = { 0.6, 0.6, 0.6 } }

local spread

local function StyleRow(row)
    ApplyStyle(row, row.state)
    row.name:SetTextColor(unpack(NAME_COLORS[row.state]))
end

-- Shift-click sets a waypoint, alt-click hides or enables the vendor. Returns true if handled.
local function PinAction(frame)
    if IsAltKeyDown() then
        local hide = frame.state ~= "hidden"
        VA.db.hiddenVendors[frame.key] = hide or nil
        GameTooltip:Hide()
        -- Stack list rows update in place so the list stays open
        if frame.name then
            local v = frame.vendor
            frame.state = hide and "hidden"
                or (v.service and (v.unverified and "serviceUnverified" or "service"))
                or (v.unverified and "unvisited" or "visited")
            StyleRow(frame)
        end
        VA:RefreshMap()
        return true
    elseif IsShiftKeyDown() then
        VA:SetWaypoint(frame.vendor)
        if spread then spread:Hide() end
        return true
    end
end

-- Stack list: click a pin covering others to pick between them --------------------

local ROW_W, ROW_H = 230, 22
local rows = {}

local function ScreenCenter(frame)
    local x, y = frame:GetCenter()
    local scale = frame:GetEffectiveScale()
    return x * scale, y * scale
end

-- Pins whose centers are within 40% of a pin's width, which is roughly more than half their area overlapping
local function OverlappingPins(pin)
    local px, py = ScreenCenter(pin)
    local radius = pin:GetWidth() * pin:GetEffectiveScale() * 0.4
    local list = {}
    for other in pin:GetMap():EnumeratePinsByTemplate(PIN) do
        local x, y = ScreenCenter(other)
        if (x - px) ^ 2 + (y - py) ^ 2 <= radius ^ 2 then list[#list + 1] = other end
    end
    table.sort(list, function(a, b) return a.vendor.name < b.vendor.name end)
    return list
end

local function SolidBox(frame, alpha)
    local border = frame:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
    local bg = frame:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], alpha)
    local grain = frame:CreateTexture(nil, "BORDER", nil, 1)
    grain:SetPoint("TOPLEFT", 1, -1)
    grain:SetPoint("BOTTOMRIGHT", -1, 1)
    grain:SetTexture(VA.GRAIN, "REPEAT", "REPEAT")
    grain:SetHorizTile(true)
    grain:SetVertTile(true)
    grain:SetAlpha(0.35)
end

local function CreateSpread()
    spread = CreateFrame("Frame", nil, WorldMapFrame)
    spread:SetFrameStrata("FULLSCREEN_DIALOG")
    spread:SetWidth(ROW_W)
    spread:SetClampedToScreen(true)
    spread:EnableMouse(true)
    spread:Hide()
    SolidBox(spread, 0.95)

    spread.header = spread:CreateFontString(nil, "OVERLAY", "VA_GameFontNormalSmall")
    spread.header:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
    spread.header:SetPoint("TOPLEFT", 8, -7)

    local close = CreateFrame("Button", nil, spread)
    close:SetSize(18, 18)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetNormalFontObject("VA_GameFontDisable")
    close:SetHighlightFontObject("VA_GameFontNormal")
    close:SetText("x")
    close:SetScript("OnClick", function() spread:Hide() end)

    local line = spread:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 6, -22)
    line:SetPoint("TOPRIGHT", -6, -22)

    local footer = spread:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 8, 7)
    footer:SetText("Shift-click: waypoint    Alt-click: hide")

    -- Stays open until you click somewhere else
    spread:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    spread:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    spread:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() then self:Hide() end
    end)
end

-- Highest frame level among our pins; the minimap vendor sits just above it, a hovered pin above that
local topPinLevel = 0

-- Outlines a map pin and lifts it above the pins around it
local function RaisePin(pin, on)
    pin.Hover:SetShown(on)
    if on then
        pin.baseLevel = pin.baseLevel or pin:GetFrameLevel()
        pin:SetFrameLevel(math.max(pin.baseLevel + 50, topPinLevel + 2))
    elseif pin.baseLevel then
        pin:SetFrameLevel(pin.baseLevel)
        pin.baseLevel = nil
    end
end

local function HighlightPin(key, on)
    for pin in WorldMapFrame:EnumeratePinsByTemplate(PIN) do
        if pin.key == key then RaisePin(pin, on) end
    end
end

-- Targeting: a secure button laid over the hovered pin or list row. -------------------
-- Targeting is protected, so a plain click runs a macro that targets the vendor by name
-- and marks it with a skull (only if the target was found); shift/alt clicks fall through to PinAction.

local targetButton

-- Name of the vendor the last targeting click tried to skull-mark
local lastMarked
local AimButton -- defined below, once the macro builders exist

local function NotSecret(value)
    return not (issecretvalue and issecretvalue(value))
end

-- The target's name and raid icon, when readable
local function TargetMark()
    if not UnitExists("target") then return end
    local name, icon = UnitName("target"), GetRaidTargetIndex("target")
    if NotSecret(name) and NotSecret(icon) then return name, icon end
end

-- Target the vendor by name and skull them. /tm toggles an existing skull off, so the vendor we
-- believe has our skull is only targeted. Otherwise the new vendor is targeted and marked, which moves
-- the skull over by itself. Only if they can't be found does the macro go back and take the skull off
-- the previous vendor. Every /targetexact is preceded by a cleared target so a failed lookup never
-- leaves some other unit targeted or marked.
local function TargetMacro(name)
    local macro = "/cleartarget\n/targetexact " .. name
    if lastMarked == name then return macro end
    macro = macro .. "\n/tm [@target,exists] 8"
    if lastMarked then
        macro = macro .. "\n/stopmacro [@target,exists]\n/targetexact " .. lastMarked
            .. "\n/tm [@target,exists] 0\n/cleartarget"
    end
    return macro
end

-- Takes our skull off the vendor, if they're the one that has it and can be found
local function UnmarkMacro(name)
    if not name or lastMarked ~= name then return end
    return "/cleartarget\n/targetexact " .. name .. "\n/tm [@target,exists] 0"
end

-- Sets the button's macros from the current skull state: left targets (and marks) targetName,
-- right takes the skull off unmarkName when removing the marker
function AimButton(b)
    b:SetAttribute("macrotext", b.targetName and TargetMacro(b.targetName) or "")
    b.rightMacro = UnmarkMacro(b.unmarkName)
    b:SetAttribute("type2", b.rightMacro and "macro" or nil)
    b:SetAttribute("macrotext2", b.rightMacro)
end

-- /va debug prints what the targeting sees, to track down skull problems
local function Debug(...)
    if VA.debug then print("|cffccb084VA debug:|r", ...) end
end

local markEvents = CreateFrame("Frame")
markEvents:RegisterEvent("RAID_TARGET_UPDATE")
markEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
markEvents:SetScript("OnEvent", function(_, event)
    local name, icon = TargetMark()
    Debug(event, "target:", tostring(name), "icon:", tostring(icon), "lastMarked:", tostring(lastMarked))
end)

-- The raid icon can't be read reliably right after marking, so after a click that included /tm 8:
-- vendor targeted means they have the skull; not found means the old skull was taken off instead.
local function RememberMark(name)
    C_Timer.After(0.3, function()
        local target = UnitExists("target") and UnitName("target")
        if not (target and NotSecret(target)) then target = nil end
        Debug("check", "target:", tostring(target), "wanted:", name)
        if target == name then
            lastMarked = name
        else
            lastMarked = nil
        end
        local b = targetButton
        if b and b:IsShown() and not InCombatLockdown() then AimButton(b) end
    end)
end

local function TargetButton()
    if targetButton then return targetButton end
    local b = CreateFrame("Button", "VendorAtlasTargetButton", UIParent, "SecureActionButtonTemplate")
    b:SetFrameStrata("TOOLTIP")
    -- Secure buttons only act on the press or the release, depending on the "cast on key down"
    -- setting, so register both and ask for the release
    b:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    b:SetAttribute("useOnKeyDown", false)
    b:SetAttribute("type1", "macro")
    -- Modified clicks never target; they are handled by the owner
    b:SetAttribute("shift-type1", "noop")
    b:SetAttribute("alt-type1", "noop")
    b:SetAttribute("ctrl-type1", "noop")
    b:Hide()
    b:HookScript("OnClick", function(self, button, down)
        Debug("click", button, down and "down" or "up", "shown macro:", ((self:GetAttribute("macrotext") or ""):gsub("\n", " | ")))
        if down then return end
        if button == "LeftButton" and self.targetName and self.targetName ~= lastMarked
            and not (IsShiftKeyDown() or IsAltKeyDown() or IsControlKeyDown()) then
            RememberMark(self.targetName)
        end
        local opts = self.opts
        if button == "RightButton" and self.rightMacro and opts.onClick then lastMarked = nil end
        if opts.onClick then
            opts.onClick(self.owner, button)
        elseif button == "RightButton" then
            -- Right-click clears the minimap marker; elsewhere it zooms the map out as usual
            if self.owner.key == VA.minimapKey then
                if self.rightMacro then lastMarked = nil end
                VA:ClearMinimapVendor()
            else
                WorldMapFrame:NavigateToParentMap()
            end
        elseif PinAction(self.owner) then
            -- Step aside after shift/alt actions; the frame underneath re-attaches on hover
            self:Hide()
        else
            VA:SetMinimapVendor(self.owner.vendor, self.owner.key)
        end
    end)
    -- Owner callbacks; map pins don't need them since the hover tracker handles them
    b:SetScript("OnEnter", function(self)
        if self.opts.onEnter then self.opts.onEnter(self.owner) end
    end)
    b:SetScript("OnLeave", function(self)
        if self.dragging then return end
        self:Hide()
        if self.opts.onLeave then self.opts.onLeave(self.owner) end
    end)
    b:SetScript("OnDragStart", function(self)
        if not self.opts.onDragStart then return end
        self.dragging = true
        self.opts.onDragStart(self.owner)
    end)
    b:SetScript("OnDragStop", function(self)
        -- Hiding the button below fires OnDragStop again; only handle the real one
        if not self.dragging then return end
        self.dragging = nil
        if self.opts.onDragStop then self.opts.onDragStop(self.owner) end
        if not self:IsMouseOver() then self:GetScript("OnLeave")(self) end
    end)
    -- Secure frames can't be hidden in combat, so get out of the way first
    b:RegisterEvent("PLAYER_REGEN_DISABLED")
    b:SetScript("OnEvent", b.Hide)
    targetButton = b
    return b
end

local function IsTargetOwner(frame)
    return targetButton and targetButton.owner == frame and targetButton:IsShown()
end

-- Placed by screen position rather than anchored, since the owner is not a secure frame
local function PlaceTargetButton(owner)
    local b = targetButton
    local scale = owner:GetEffectiveScale() / b:GetEffectiveScale()
    local x, y = owner:GetCenter()
    b:SetSize(owner:GetWidth() * scale, owner:GetHeight() * scale)
    b:ClearAllPoints()
    b:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * scale, y * scale)
end

local function HideTargetButton()
    if targetButton and not InCombatLockdown() then targetButton:Hide() end
end

-- opts: name (defaults to the owner's vendor), rightClick, onEnter, onLeave, onClick, onDragStart, onDragStop
local function AttachTargetButton(owner, opts)
    if InCombatLockdown() then return end
    opts = opts or {}
    local b = TargetButton()
    b.owner, b.opts, b.dragging = owner, opts, nil
    local name = opts.name or (owner.vendor and owner.vendor.name)
    b.targetName = name or nil
    b.unmarkName = opts.unmarkName
    AimButton(b)
    -- Map pins leave right-click to the map, which zooms out with it
    if opts.rightClick then
        b:RegisterForClicks("LeftButtonUp", "LeftButtonDown", "RightButtonUp", "RightButtonDown")
    else
        b:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    end
    if opts.onDragStart then b:RegisterForDrag("LeftButton") else b:RegisterForDrag() end
    PlaceTargetButton(owner)
    b:Show()
end

local function SpreadRow(i)
    local row = CreateFrame("Button", nil, spread)
    row:SetSize(ROW_W - 8, ROW_H)
    row:SetPoint("TOPLEFT", 4, -26 - (i - 1) * ROW_H)
    -- Shown by hand, since the targeting button covers the row while hovered
    local hl = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hl:SetAllPoints()
    hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.15)
    hl:Hide()
    local accent = row:CreateTexture(nil, "ARTWORK")
    accent:SetWidth(2)
    accent:SetPoint("TOPLEFT")
    accent:SetPoint("BOTTOMLEFT")
    accent:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    accent:Hide()

    row.Ring = row:CreateTexture(nil, "BACKGROUND")
    row.Ring:SetSize(16, 16)
    row.Ring:SetPoint("LEFT", 4, 0)
    row.Ring:SetTexture(CIRCLE)
    local disc = row:CreateTexture(nil, "BORDER")
    disc:SetSize(14, 14)
    disc:SetPoint("CENTER", row.Ring)
    disc:SetTexture(CIRCLE)
    disc:SetVertexColor(0.05, 0.05, 0.07, 0.9)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(10, 10)
    row.Icon:SetPoint("CENTER", row.Ring)
    row.Icon:SetTexture(COIN)

    row.title = row:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
    row.title:SetPoint("RIGHT", -6, 0)
    row.title:SetWidth(90)
    row.title:SetJustifyH("RIGHT")
    row.title:SetWordWrap(false)

    row.name = row:CreateFontString(nil, "OVERLAY", "VA_GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.Ring, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.title, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    local function Enter()
        hl:Show()
        accent:Show()
        HighlightPin(row.key, true)
        VA:ShowVendorTooltip(row, row.key)
    end
    local function Leave()
        hl:Hide()
        accent:Hide()
        HighlightPin(row.key, false)
        GameTooltip:Hide()
    end
    row:SetScript("OnEnter", function(self)
        Enter()
        AttachTargetButton(self, { onEnter = Enter, onLeave = Leave })
    end)
    row:SetScript("OnLeave", function(self)
        if not IsTargetOwner(self) then Leave() end
    end)
    row:SetScript("OnClick", PinAction)
    return row
end

local function ShowSpread(anchor, pins)
    if not spread then CreateSpread() end
    for i, pin in ipairs(pins) do
        local row = rows[i] or SpreadRow(i)
        rows[i] = row
        row.key, row.vendor, row.state = pin.key, pin.vendor, pin.state
        row.name:SetText(pin.vendor.name)
        row.Icon:SetTexture(pin.vendor.icon or COIN)
        StyleRow(row)
        row.title:SetText(pin.vendor.title or "")
        row:Show()
    end
    for i = #pins + 1, #rows do rows[i]:Hide() end

    spread.header:SetText(("%d vendors here"):format(#pins))
    spread:SetHeight(26 + #pins * ROW_H + 22)
    -- Fixed screen position, so it survives the pins being redrawn
    local scale = anchor:GetEffectiveScale() / spread:GetEffectiveScale()
    spread:ClearAllPoints()
    spread:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", anchor:GetCenter() * scale, anchor:GetTop() * scale + 6)
    spread:Show()
end

-- Pin -------------------------------------------------------------------------

VendorAtlasPinMixin = CreateFromMixins(MapCanvasPinMixin)

function VendorAtlasPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_VIGNETTE")
    self:SetScalingLimits(1, 1.0, 1.3)
    self.Disc:SetVertexColor(0.05, 0.05, 0.07, 0.9)
    -- White outline shown on hover, or when the vendor is hovered in the overlap list
    self.Hover = self:CreateTexture(nil, "BACKGROUND", nil, -1)
    self.Hover:SetSize(26, 26)
    self.Hover:SetPoint("CENTER")
    self.Hover:SetTexture(CIRCLE)
    self.Hover:Hide()
    -- Green ring over the normal ring for the vendor currently on the minimap
    self.Marked = self:CreateTexture(nil, "BACKGROUND", nil, 1)
    self.Marked:SetSize(22, 22)
    self.Marked:SetPoint("CENTER")
    self.Marked:SetTexture(CIRCLE)
    self.Marked:SetVertexColor(0.35, 0.85, 0.35)
    self.Marked:Hide()
end

local function PinAlpha(pin)
    return PIN_STYLES[pin.state].alpha
end

function VendorAtlasPinMixin:OnAcquired(key, vendor, state, x, y)
    self.key, self.vendor, self.state, self.baseLevel = key, vendor, state, nil
    -- Services show their own icon (trainer, flight master...), vendors the coin
    self.Icon:SetTexture(vendor.icon or COIN)
    self.Icon:SetSize(vendor.icon and 15 or 13, vendor.icon and 15 or 13)
    ApplyStyle(self, state)
    self:SetAlpha(PinAlpha(self))
    self.Hover:Hide()
    self.Marked:SetShown(key == VA.minimapKey)
    self:SetPosition(x, y)
end

-- Hover tracker: among the pins under the cursor, the one whose center is closest wins, -------
-- so overlapping pins don't flicker as the raised one changes what's under the mouse.

local hovered
local tracker = CreateFrame("Frame")
tracker:Hide()

local function MouseOnPins()
    local focus = GetMouseFoci and GetMouseFoci()[1] or (GetMouseFocus and GetMouseFocus())
    if focus and focus == targetButton then focus = focus.owner end
    return focus and focus.GetMap and focus.key ~= nil
end

local function NearestPin()
    if not (WorldMapFrame:IsVisible() and MouseOnPins()) then return end
    local x, y = GetCursorPosition()
    local best, bestDist
    for pin in WorldMapFrame:EnumeratePinsByTemplate(PIN) do
        if pin:IsVisible() and pin:IsMouseOver() then
            local px, py = ScreenCenter(pin)
            local dist = (px - x) ^ 2 + (py - y) ^ 2
            if not bestDist or dist < bestDist then best, bestDist = pin, dist end
        end
    end
    return best
end

local function SetHovered(pin)
    if pin == hovered then return end
    if hovered then
        RaisePin(hovered, false)
        GameTooltip:Hide()
    end
    hovered = pin
    if not pin then
        HideTargetButton()
        tracker:Hide()
        return
    end

    RaisePin(pin, true)
    local stacked = #OverlappingPins(pin)
    VA:ShowVendorTooltip(pin, pin.key, stacked)
    -- Stacked pins keep their plain click for the overlap list
    if stacked == 1 then
        AttachTargetButton(pin, {
            rightClick = true,
            unmarkName = pin.key == VA.minimapKey and pin.vendor.name or nil,
        })
    else
        HideTargetButton()
    end
    tracker:Show()
end

local elapsed, lastX, lastY, lastScale = 0, nil, nil, nil
tracker:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.05 then return end
    elapsed = 0
    -- Nothing to recheck while the cursor and zoom stay put
    local x, y = GetCursorPosition()
    local scale = WorldMapFrame:GetCanvasScale()
    if hovered and x == lastX and y == lastY and scale == lastScale then return end
    lastX, lastY, lastScale = x, y, scale
    SetHovered(NearestPin())
    -- Follow the pin if the map is zoomed or panned under the cursor
    if hovered and IsTargetOwner(hovered) and not InCombatLockdown() then PlaceTargetButton(hovered) end
end)

function VendorAtlasPinMixin:OnMouseEnter()
    SetHovered(NearestPin() or self)
end

function VendorAtlasPinMixin:OnMouseLeave()
    -- The tracker notices when the cursor leaves all pins
end

-- The map canvas owns the pin's mouse scripts and forwards to these methods
-- The map gives each pin its own frame level and reassigns them at times;
-- the minimap vendor is always lifted above the rest
function VendorAtlasPinMixin:ApplyFrameLevel()
    if MapCanvasPinMixin.ApplyFrameLevel then MapCanvasPinMixin.ApplyFrameLevel(self) end
    if self.key == VA.minimapKey then
        self:SetFrameLevel(math.max(self:GetFrameLevel(), topPinLevel + 1))
    end
end

-- Right-click passes through to the map (zoom out), except on the minimap vendor's pin
function VendorAtlasPinMixin:ShouldMouseButtonBePassthrough(button)
    return button == "RightButton" and self.key ~= VA.minimapKey
end

function VendorAtlasPinMixin:OnMouseClickAction(button)
    if button == "RightButton" then
        if self.key == VA.minimapKey then VA:ClearMinimapVendor() end
        return
    end
    if button ~= "LeftButton" or PinAction(self) then return end
    local cluster = OverlappingPins(self)
    if #cluster > 1 then
        GameTooltip:Hide()
        ShowSpread(self, cluster)
    end
end

-- Data provider ---------------------------------------------------------------

local Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function Provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN)
end

-- Search results, or every vendor with its full stock when the map toggle is on
local function VendorItems(key, vendor)
    local ids = {}
    for itemID in pairs(vendor.items) do
        local item = VA.db.items[itemID]
        if item and item.vendors[key] then ids[#ids + 1] = itemID end
    end
    table.sort(ids, function(a, b) return VA.db.items[a].name < VA.db.items[b].name end)
    return ids
end

local function PinState(key, vendor)
    if VA.db.hiddenVendors[key] then return "hidden" end
    if vendor.service then return vendor.unverified and "serviceUnverified" or "service" end
    return vendor.unverified and "unvisited" or "visited"
end

-- Search results or all visited vendors (Vendors), plus unvisited (Unvisited Vendors) and hidden (Show hidden)
local function PinnedVendors()
    local db = VA.db
    local pinned = {}
    for key, ids in pairs(VA.activeVendors or {}) do pinned[key] = ids end
    for key, vendor in pairs(db.vendors) do
        local state = PinState(key, vendor)
        -- While searching, only vendors selling the matched items are pinned
        local wanted = not VA.activeVendors and ((state == "visited" and db.showAllVendors)
            or (state == "unvisited" and db.showUnvisited)
            or (state == "hidden" and db.showHidden))
        if wanted and not pinned[key] then
            -- Item list is built on first hover, not for every pin
            pinned[key] = true
        elseif state == "hidden" and not db.showHidden then
            pinned[key] = nil
        end
    end
    -- Hidden service NPCs from a search stay hidden unless "Show hidden" is on
    if not db.showHidden then
        for key in pairs(pinned) do
            if db.hiddenVendors[key] and not db.vendors[key] then pinned[key] = nil end
        end
    end
    -- The vendor on the minimap always shows, whatever the toggles
    local marked = VA.minimapKey
    if marked and VA:GetNPC(marked) and not pinned[marked] then pinned[marked] = true end
    return pinned
end

function Provider:OnMapChanged()
    if spread then spread:Hide() end
    MapCanvasDataProviderMixin.OnMapChanged(self)
end

function Provider:RefreshAllData()
    SetHovered(nil)
    self:RemoveAllData()
    local map = self:GetMap()
    local mapID = map:GetMapID()

    VA.pinned = PinnedVendors()
    for key in pairs(VA.pinned) do
        local vendor = VA:GetNPC(key)
        local x, y
        if vendor then x, y = PosOnMap(vendor, mapID) end
        if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            map:AcquirePin(PIN, key, vendor, PinState(key, vendor), x, y)
        end
    end

    -- Lift the minimap vendor above every other pin
    local marked
    topPinLevel = 0
    for pin in map:EnumeratePinsByTemplate(PIN) do
        if pin.key == VA.minimapKey then
            marked = pin
        else
            topPinLevel = math.max(topPinLevel, pin:GetFrameLevel())
        end
    end
    if marked then marked:SetFrameLevel(math.max(marked:GetFrameLevel(), topPinLevel + 1)) end
    tracker:Show()
end

-- Map menu: one "Vendor Atlas" button with the layer toggles and a shortcut to the window --------


local OPTIONS = {
    { text = "Open Vendor Atlas", note = "Search and browse everything you've recorded.",
      action = function() VA:Toggle() end },
    { text = "Vendors", setting = "showAllVendors", color = { 1, 0.82, 0 },
      note = "Show every vendor you've visited. While searching in the Vendor Atlas window, only matching vendors are shown." },
    { text = "Unvisited Vendors", setting = "showUnvisited", color = { 1, 0.35, 0.3 },
      note = "Red pins use Classic data and turn into normal vendors once you open their shop." },
    { text = "Show hidden", setting = "showHidden", color = { 0.75, 0.75, 0.75 },
      note = "Grey pins are vendors you've hidden. Alt-click a pin to hide or enable it." },
}

local MENU_W, OPTION_H = 190, 24

local function CreateMenuRow(menu, option, y)
    local row = CreateFrame("Button", nil, menu)
    row:SetSize(MENU_W - 8, OPTION_H)
    row:SetPoint("TOPLEFT", 4, y)
    local hl = row:CreateTexture()
    hl:SetColorTexture(1, 1, 1, 0.07)
    row:SetHighlightTexture(hl)

    local label = row:CreateFontString(nil, "OVERLAY", "VA_GameFontHighlightSmall")
    label:SetPoint("LEFT", 26, 0)
    label:SetText(option.text)

    if option.setting then
        -- Custom checkbox: bordered square, filled with the layer color when on
        local box = row:CreateTexture(nil, "BORDER")
        box:SetSize(12, 12)
        box:SetPoint("LEFT", 8, 0)
        box:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
        local inner = row:CreateTexture(nil, "ARTWORK")
        inner:SetPoint("TOPLEFT", box, 1, -1)
        inner:SetPoint("BOTTOMRIGHT", box, -1, 1)
        inner:SetColorTexture(0.03, 0.03, 0.04, 1)
        local fill = row:CreateTexture(nil, "OVERLAY")
        fill:SetPoint("TOPLEFT", box, 3, -3)
        fill:SetPoint("BOTTOMRIGHT", box, -3, 3)
        fill:SetColorTexture(option.color[1], option.color[2], option.color[3])

        function row:Update()
            local on = VA.db[option.setting]
            fill:SetShown(on)
            if on then
                label:SetTextColor(option.color[1], option.color[2], option.color[3])
            else
                label:SetTextColor(0.6, 0.6, 0.6)
            end
        end
        row:SetScript("OnClick", function(self)
            VA.db[option.setting] = not VA.db[option.setting] or nil
            self:Update()
            VA:RefreshMap()
        end)
    else
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", 7, 0)
        icon:SetTexture(COIN)
        label:SetTextColor(1, 1, 1)
        row:SetScript("OnClick", function()
            menu:Hide()
            option.action()
        end)
    end

    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(option.text, 1, 1, 1)
        GameTooltip:AddLine(option.note, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

local function MenuLine(menu, y)
    local line = menu:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 8, y - 3)
    line:SetPoint("TOPRIGHT", -8, y - 3)
    return y - 7
end

local function CreateMapMenu()
    local container = WorldMapFrame.ScrollContainer or WorldMapFrame

    -- Top right corner of the map
    local button = CreateFrame("Button", nil, WorldMapFrame)
    button:SetSize(52, 22)
    button:SetPoint("TOPRIGHT", container, "TOPRIGHT", -4, -4)
    button:SetFrameLevel(container:GetFrameLevel() + 20)
    SolidBox(button, 0.9)
    local hl = button:CreateTexture()
    hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.12)
    button:SetHighlightTexture(hl)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(12, 12)
    icon:SetPoint("LEFT", 7, 0)
    icon:SetTexture(COIN)
    local label = button:CreateFontString(nil, "OVERLAY", "VA_GameFontNormalSmall")
    label:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
    label:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    label:SetText("VA")
    local arrow = button:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
    arrow:SetPoint("RIGHT", -7, 0)
    arrow:SetText("v")

    local menu = CreateFrame("Frame", nil, button)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetWidth(MENU_W)
    menu:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -3)
    menu:EnableMouse(true)
    menu:Hide()
    SolidBox(menu, 0.95)

    local rows, y = {}, -4
    for i, option in ipairs(OPTIONS) do
        rows[i] = CreateMenuRow(menu, option, y)
        y = y - OPTION_H
        if i == 1 then y = MenuLine(menu, y) end
    end
    menu:SetHeight(-y + 4)

    -- Stays open while toggling; closes on a click anywhere else
    menu:SetScript("OnShow", function(self)
        for _, row in ipairs(rows) do
            if row.Update then row:Update() end
        end
        arrow:SetText("^")
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    menu:SetScript("OnHide", function(self)
        arrow:SetText("v")
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    menu:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not button:IsMouseOver() then self:Hide() end
    end)
    button:SetScript("OnClick", function() menu:SetShown(not menu:IsShown()) end)
end

local function Attach()
    WorldMapFrame:AddDataProvider(Provider)
    WorldMapFrame:HookScript("OnHide", function() SetHovered(nil) end)
    CreateMapMenu()
end

if WorldMapFrame then
    Attach()
else
    EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", Attach)
end

-- API used by the UI ------------------------------------------------------------

function VA:PosOnMap(vendor, mapID)
    return PosOnMap(vendor, mapID)
end

-- Vendors are keyed by NPC ID, service NPCs (trainers etc.) by "s" .. NPC ID
function VA:GetNPC(key)
    return self.db.vendors[key] or (self.services and self.services[key])
end

-- Tooltip for a trainer, flight master or other service NPC
function VA:ShowServiceTooltip(owner, key, stacked, anchor)
    local npc = self.services and self.services[key]
    if not npc then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    if npc.unverified then
        GameTooltip:AddLine(npc.name, 1, 0.35, 0.3)
    else
        GameTooltip:AddLine(npc.name, 0.55, 0.85, 0.9)
    end
    if npc.title then GameTooltip:AddLine("<" .. npc.title .. ">", 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(self:LocationText(npc), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(" ")
    for _, path in ipairs(npc.paths) do
        GameTooltip:AddLine((path:gsub("^Services/", ""):gsub("/", " > ")), 1, 1, 1)
    end
    if npc.unverified then
        GameTooltip:AddLine("Not verified yet. Location is from Classic and may have changed. Talk to them to confirm.",
            1, 0.35, 0.3, true)
    end
    GameTooltip:AddLine(" ")
    if stacked and stacked > 1 then
        GameTooltip:AddLine(("Click to pick between %d overlapping vendors"):format(stacked), 1, 0.82, 0)
    else
        GameTooltip:AddLine("Click to target and mark with a skull (when nearby)", 0.5, 0.5, 0.5)
    end
    GameTooltip:AddLine("Shift-click to set waypoint", 0.5, 0.5, 0.5)
    if key == self.minimapKey then
        GameTooltip:AddLine("Right-click to remove the minimap marker", 0.35, 0.85, 0.35)
    end
    GameTooltip:AddLine(self.db.hiddenVendors[key] and "Alt-click to enable" or "Alt-click to hide", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function VA:AttachTargetButton(owner, opts)
    AttachTargetButton(owner, opts)
end

function VA:IsTargetOwner(frame)
    return IsTargetOwner(frame)
end

function VA:RefreshMap()
    if Provider:GetMap() and WorldMapFrame:IsShown() then
        Provider:RefreshAllData()
    end
end

function VA:ShowVendorTooltip(owner, key, stacked)
    if self.services and self.services[key] then return self:ShowServiceTooltip(owner, key, stacked) end
    local vendor = self.db.vendors[key]
    local matched = self.pinned and self.pinned[key]
    if not (vendor and matched) then return end

    -- Full stock, with the items you searched for or selected listed first and marked
    local itemIDs, isMatch = VendorItems(key, vendor), {}
    if matched ~= true then
        for _, itemID in ipairs(matched) do isMatch[itemID] = true end
        local first, rest = {}, {}
        for _, itemID in ipairs(itemIDs) do
            local list = isMatch[itemID] and first or rest
            list[#list + 1] = itemID
        end
        for _, itemID in ipairs(rest) do first[#first + 1] = itemID end
        itemIDs = first
    end

    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if vendor.unverified then
        GameTooltip:AddLine(vendor.name, 1, 0.35, 0.3)
    else
        GameTooltip:AddLine(vendor.name, 1, 0.82, 0)
    end
    if vendor.title then GameTooltip:AddLine("<" .. vendor.title .. ">", 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(self:LocationText(vendor), 0.8, 0.8, 0.8)
    if vendor.unverified then
        GameTooltip:AddLine("Not visited yet. Stock is from Classic and may have changed.", 1, 0.35, 0.3, true)
    end
    GameTooltip:AddLine(" ")

    for i, itemID in ipairs(itemIDs) do
        if i > MAX_TOOLTIP_ITEMS then
            GameTooltip:AddLine(("... and %d more"):format(#itemIDs - MAX_TOOLTIP_ITEMS), 0.6, 0.6, 0.6)
            break
        end
        local item = self.db.items[itemID]
        local color = ITEM_QUALITY_COLORS[item.quality or 1] or ITEM_QUALITY_COLORS[1]
        local marker = isMatch[itemID] and "|cff8fd18f>|r " or ""
        GameTooltip:AddDoubleLine(marker .. "|T" .. (item.icon or 134400) .. ":0|t " .. item.name,
            self:PriceText(item.vendors[key]), color.r, color.g, color.b, 1, 1, 1)
    end

    GameTooltip:AddLine(" ")
    if stacked and stacked > 1 then
        GameTooltip:AddLine(("Click to pick between %d overlapping vendors"):format(stacked), 1, 0.82, 0)
    else
        GameTooltip:AddLine("Click to target and mark with a skull (when nearby)", 0.5, 0.5, 0.5)
    end
    GameTooltip:AddLine("Shift-click to set waypoint", 0.5, 0.5, 0.5)
    if key == self.minimapKey then
        GameTooltip:AddLine("Right-click to remove the minimap marker", 0.35, 0.85, 0.35)
    end
    GameTooltip:AddLine(self.db.hiddenVendors[key] and "Alt-click to enable" or "Alt-click to hide", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function VA:SetWaypoint(vendor)
    if not (vendor and vendor.mapID and C_Map.CanSetUserWaypointOnMap) then return end

    -- Micro maps often reject waypoints, so climb until one accepts
    local mapID, depth = vendor.mapID, 0
    while mapID and mapID ~= 0 and depth < 10 do
        if C_Map.CanSetUserWaypointOnMap(mapID) then
            local x, y = PosOnMap(vendor, mapID)
            if x then
                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
            return
        end
        local info = C_Map.GetMapInfo(mapID)
        mapID = info and info.parentMapID
        depth = depth + 1
    end
end

-- Map IDs from the root down to mapID
local function MapChain(mapID)
    local chain, info = {}, C_Map.GetMapInfo(mapID)
    while info do
        table.insert(chain, 1, info.mapID)
        if not info.parentMapID or info.parentMapID == 0 then break end
        info = C_Map.GetMapInfo(info.parentMapID)
    end
    return chain
end

-- Smallest map containing all the given maps: a zone, a continent, or the world
local function CommonMap(maps)
    local common
    for mapID in pairs(maps) do
        local chain = MapChain(mapID)
        if not common then
            common = chain
        else
            local depth = 0
            while common[depth + 1] and common[depth + 1] == chain[depth + 1] do depth = depth + 1 end
            for i = #common, depth + 1, -1 do common[i] = nil end
        end
    end
    return common and common[#common]
end

-- Closest of the keys (NPC key -> value) on your continent. visible(value) can filter them.
local function ClosestNPC(keys, visible)
    local playerMap = C_Map.GetBestMapForUnit("player")
    local continent = playerMap and Ancestor(playerMap, Enum.UIMapType.Continent)
    local pos = continent and C_Map.GetPlayerMapPosition(continent, "player")
    if not pos then return end
    local width, height = C_Map.GetMapWorldSize(continent)
    if not width or width == 0 then return end
    local px, py = pos:GetXY()

    local best, bestDist
    for key, value in pairs(keys) do
        local npc = VA:GetNPC(key)
        local shown = (not visible or visible(value)) and (VA.db.showHidden or not VA.db.hiddenVendors[key])
        local x, y
        if shown and npc then x, y = PosOnMap(npc, continent) end
        if x then
            local dist = ((x - px) * width) ^ 2 + ((y - py) * height) ^ 2
            if not bestDist or dist < bestDist then best, bestDist = key, dist end
        end
    end
    return best
end

local function OfferVisible(offer) return VA:OfferVisible(offer) end

local function ClosestVendor(item)
    return ClosestNPC(item.vendors, OfferVisible)
end

function VA:ClosestVendorKey(itemID)
    local item = self.db.items[itemID]
    return item and ClosestVendor(item)
end

-- Closest of a set of service NPC keys
function VA:ClosestServiceKey(keys)
    return ClosestNPC(keys)
end

-- Opens your zone if a vendor there sells the item, otherwise the smallest map showing all its vendors.
-- The closest vendor on your continent also goes on the minimap.
-- If the click managed to target the closest vendor, it's right there, so the map stays closed.
-- The target check waits a moment for the targeting macro to take effect.
local function OpenMapAt(mapID)
    if WorldMapFrame:IsShown() then
        WorldMapFrame:SetMapID(mapID)
    elseif not InCombatLockdown() then
        if OpenWorldMap then
            OpenWorldMap(mapID)
        else
            ShowUIPanel(WorldMapFrame)
            WorldMapFrame:SetMapID(mapID)
        end
    end
end

-- True if the click's targeting found this NPC; an open map then just shows your zone
local function TargetIsHere(name)
    local target = UnitExists("target") and UnitName("target")
    if not (name and target and not (issecretvalue and issecretvalue(target)) and target == name) then
        return false
    end
    local zone = WorldMapFrame:IsShown() and C_Map.GetBestMapForUnit("player")
    zone = zone and Ancestor(zone, Enum.UIMapType.Zone)
    if zone then WorldMapFrame:SetMapID(zone) end
    return true
end

-- Same as items: minimap marker, target and skull, and the map on their zone unless they're right here
function VA:ShowServiceOnMap(key)
    local npc = self.services and self.services[key]
    if not npc then return end
    self:SetMinimapVendor(npc, key)
    C_Timer.After(0.1, function()
        if TargetIsHere(npc.name) then return end
        local zone = Ancestor(npc.mapID, Enum.UIMapType.Zone)
        if zone then OpenMapAt(zone) end
    end)
end

function VA:ShowItemOnMap(itemID)
    local item = self.db.items[itemID]
    if not item then return end

    local closest = ClosestVendor(item)
    local name = closest and self.db.vendors[closest].name
    -- A new item replaces the old marker, or clears it when nobody on this continent sells it
    if closest then
        self:SetMinimapVendor(self.db.vendors[closest], closest)
    else
        self:ClearMinimapVendor()
    end

    C_Timer.After(0.1, function()
        -- Vendor is right here: leave a closed map closed, show an open one on your zone
        if TargetIsHere(name) then return end
        VA:OpenMapForItem(itemID)
    end)
end

-- Your zone if one of the NPCs is there, otherwise the smallest map showing them all
local function OpenMapForNPCs(keys, visible)
    local playerMap = C_Map.GetBestMapForUnit("player")
    local playerZone = playerMap and Ancestor(playerMap, Enum.UIMapType.Zone)
    local zones = {}
    for key, value in pairs(keys) do
        local npc = VA:GetNPC(key)
        local shown = (not visible or visible(value)) and (VA.db.showHidden or not VA.db.hiddenVendors[key])
        if shown and npc and npc.mapID then
            local zone = Ancestor(npc.mapID, Enum.UIMapType.Zone)
            if zone then zones[zone] = true end
        end
    end
    if not next(zones) then return end

    OpenMapAt((playerZone and zones[playerZone]) and playerZone or CommonMap(zones) or next(zones))
end

function VA:OpenMapForItem(itemID)
    local item = self.db.items[itemID]
    if item then OpenMapForNPCs(item.vendors, OfferVisible) end
end

-- A set of service NPCs, like an item's vendors: closest on the minimap, map showing them all
function VA:ShowServicesOnMap(keys)
    local closest = ClosestNPC(keys)
    local name = closest and self.services[closest].name
    if closest then
        self:SetMinimapVendor(self.services[closest], closest)
    else
        self:ClearMinimapVendor()
    end
    C_Timer.After(0.1, function()
        if TargetIsHere(name) then return end
        OpenMapForNPCs(keys)
    end)
end

-- When the map is already open, shows the smallest map holding every pinned vendor
function VA:FitMapToActive()
    if not (WorldMapFrame:IsShown() and self.activeVendors) then return end
    local zones = {}
    for key in pairs(self.activeVendors) do
        local npc = self:GetNPC(key)
        local zone = npc and npc.mapID and Ancestor(npc.mapID, Enum.UIMapType.Zone)
        if zone and (self.db.showHidden or not self.db.hiddenVendors[key]) then zones[zone] = true end
    end
    local mapID = CommonMap(zones)
    if mapID then WorldMapFrame:SetMapID(mapID) end
end