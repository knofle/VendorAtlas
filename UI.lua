local _, VA = ...

local ROW_H = 20
-- Visible rows; recalculated when the window is resized
local ROWS, TREE_ROWS = 18, 16
local TREE_W, LIST_W = 180, 360
local C = VA.COLORS
local ACCENT, BORDER = C.accent, C.border
local MAX_TOOLTIP_VENDORS = 12
local ALL, UNCAT = VA.ALL, VA.UNCAT

local results, offset, selected = {}, 0, nil
local nodes, treeOffset, category = {}, 0, ALL

-- The compact view always lists all items; the chosen category comes back with the full view
local function ActiveCategory()
    return VA.db.compact and ALL or category
end
local counts, lowerNames, lowerPaths, sortKeys = {}, {}, {}, {}
local editMode
-- Tree and counts only change with data or category edits, not while typing or scrolling
local treeDirty, countsDirty = true, true
local refreshTimer

local function MarkDirty()
    treeDirty, countsDirty = true, true
end

-- Widgets -----------------------------------------------------------------

local function Border(frame, r, g, b, a)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, a or 1)
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
            t:SetHeight(1)
        else
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
            t:SetWidth(1)
        end
    end
end

local function Background(frame, r, g, b, a)
    local t = frame:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(r, g, b, a)
    return t
end

local function Fill(frame, color, alpha)
    return Background(frame, color[1], color[2], color[3], alpha or 1)
end

local function Outline(frame, color, alpha)
    Border(frame, color[1], color[2], color[3], alpha or 1)
end

-- Subtle tiled grain over a flat fill
local function Grain(frame, alpha)
    local t = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetAllPoints()
    t:SetTexture(VA.GRAIN, "REPEAT", "REPEAT")
    t:SetHorizTile(true)
    t:SetVertTile(true)
    t:SetAlpha(alpha)
end

-- Vertical gradient between two colors, lighter at the top
local function Gradient(frame, bottom, top, layer, sublevel)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel or 2)
    t:SetAllPoints()
    t:SetColorTexture(1, 1, 1, 1)
    if t.SetGradient and CreateColor then
        t:SetGradient("VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], 1),
            CreateColor(top[1], top[2], top[3], 1))
    else
        t:SetColorTexture(bottom[1], bottom[2], bottom[3], 1)
    end
    return t
end

-- Raised button look: gradient face, bronze edge, soft hover
local function SkinButton(b)
    Gradient(b, C.button, C.buttonTop)
    Outline(b, BORDER)
    local hl = b:CreateTexture()
    hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.12)
    b:SetHighlightTexture(hl)
end

local function EditBox(parent)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetFontObject("VA_ChatFontNormal")
    box:SetAutoFocus(false)
    box:SetTextInsets(6, 6, 0, 0)
    Fill(box, C.inset, 0.95)
    Outline(box, BORDER)
    return box
end

local function TextButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 20)
    SkinButton(b)
    b:SetNormalFontObject("VA_GameFontHighlightSmall")
    b:SetHighlightFontObject("VA_GameFontNormalSmall")
    b:SetDisabledFontObject("VA_GameFontDisableSmall")
    b:SetText(text)
    return b
end

local function SetTooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

local SCROLL_W = 8

-- Thin track with a draggable thumb. frame.onScroll(pos) is set once the frame's draw function exists.
local function AddScrollbar(frame)
    frame.track = frame:CreateTexture(nil, "ARTWORK")
    frame.track:SetPoint("TOPRIGHT")
    frame.track:SetPoint("BOTTOMRIGHT")
    frame.track:SetWidth(SCROLL_W)
    frame.track:SetColorTexture(1, 1, 1, 0.05)

    local thumb = CreateFrame("Frame", nil, frame)
    thumb:SetWidth(SCROLL_W)
    thumb:EnableMouse(true)
    local tex = thumb:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.7)

    thumb:SetScript("OnEnter", function() tex:SetAlpha(1) end)
    thumb:SetScript("OnLeave", function(self)
        if not self.dragY then tex:SetAlpha(0.7) end
    end)
    -- OnUpdate only runs while dragging
    local function Drag(self)
        local _, y = GetCursorPosition()
        local travel = frame:GetHeight() - self:GetHeight()
        if travel > 0 then
            local moved = (self.dragY - y / self:GetEffectiveScale()) / travel
            frame.onScroll(math.floor(self.dragPos + moved * (frame.scrollTotal - frame.scrollVisible) + 0.5))
        end
    end
    thumb:SetScript("OnMouseDown", function(self)
        local _, y = GetCursorPosition()
        self.dragY, self.dragPos = y / self:GetEffectiveScale(), frame.scrollPos
        self:SetScript("OnUpdate", Drag)
    end)
    thumb:SetScript("OnMouseUp", function(self)
        self.dragY = nil
        self:SetScript("OnUpdate", nil)
        if not self:IsMouseOver() then tex:SetAlpha(0.7) end
    end)
    frame.thumb = thumb
end

local function UpdateScrollbar(frame, pos, total, visible)
    frame.scrollPos, frame.scrollTotal, frame.scrollVisible = pos, total, visible
    local scrolls = total > visible
    frame.track:SetShown(scrolls)
    frame.thumb:SetShown(scrolls)
    if scrolls then
        local h = frame:GetHeight()
        local size = math.max(20, h * visible / total)
        frame.thumb:SetHeight(size)
        frame.thumb:ClearAllPoints()
        frame.thumb:SetPoint("TOPRIGHT", 0, -(h - size) * pos / (total - visible))
    end
end

-- Layout ------------------------------------------------------------------

local panel = CreateFrame("Frame", "VendorAtlasFrame", UIParent)
panel:SetSize(10 + TREE_W + 8 + LIST_W + 10, 76 + ROWS * ROW_H + 26)
panel:SetPoint("CENTER")
panel:SetFrameStrata("FULLSCREEN_DIALOG")
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:Hide()
Fill(panel, C.bg, 0.97)
Grain(panel, 0.35)
Outline(panel, BORDER)

-- Header band behind the title, with a thin rule under it
local header = CreateFrame("Frame", nil, panel)
header:SetPoint("TOPLEFT", 1, -1)
header:SetPoint("TOPRIGHT", -1, -1)
header:SetHeight(25)
Gradient(header, C.bg, C.header)
local rule = header:CreateTexture(nil, "ARTWORK")
rule:SetHeight(1)
rule:SetPoint("BOTTOMLEFT")
rule:SetPoint("BOTTOMRIGHT")
rule:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
tinsert(UISpecialFrames, "VendorAtlasFrame")

-- Position is shared; the full and compact views each remember their own size
local function SaveGeometry()
    local point, _, relPoint, x, y = panel:GetPoint()
    VA.db.point = { point, relPoint, x, y }
    local size = { panel:GetWidth(), panel:GetHeight() }
    if VA.db.compact then VA.db.compactSize = size else VA.db.size = size end
end

panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveGeometry()
end)

-- Resizable from the bottom right; the category column keeps its width.
-- The corner follows the cursor itself, so after hitting the minimum size it only
-- grows again once the cursor is back past the corner.
local MIN_FULL = { 10 + TREE_W + 8 + 220 + 10, 76 + 8 * ROW_H + 26 }
local MIN_COMPACT = { 200, 30 + 4 * ROW_H + 16 }
local DEFAULT_FULL = { 10 + TREE_W + 8 + LIST_W + 10, 76 + 18 * ROW_H + 26 }
local DEFAULT_COMPACT = { 260, 30 + 14 * ROW_H + 16 }
local MAX_W, MAX_H = 1400, 1100

local grip = CreateFrame("Button", nil, panel)
grip:SetSize(14, 14)
grip:SetPoint("BOTTOMRIGHT", -3, 3)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:GetNormalTexture():SetVertexColor(BORDER[1] * 1.6, BORDER[2] * 1.6, BORDER[3] * 1.6)

local function CursorXY()
    local x, y = GetCursorPosition()
    local scale = panel:GetEffectiveScale()
    return x / scale, y / scale
end

local function Resize(self)
    local x, y = CursorXY()
    local min = VA.db.compact and MIN_COMPACT or MIN_FULL
    local w = math.max(min[1], math.min(MAX_W, x + self.offX - self.left))
    local h = math.max(min[2], math.min(MAX_H, self.top - (y - self.offY)))
    panel:SetSize(w, h)
end

grip:SetScript("OnMouseDown", function(self)
    local x, y = CursorXY()
    self.offX, self.offY = panel:GetRight() - x, y - panel:GetBottom()
    self.left, self.top = panel:GetLeft(), panel:GetTop()
    -- Pin the top left corner so only the bottom right moves
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", self.left, self.top)
    self:SetScript("OnUpdate", Resize)
end)
grip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    SaveGeometry()
end)

local title = header:CreateFontString(nil, "OVERLAY", "VA_GameFontNormal")
title:SetPoint("TOPLEFT", 10, -7)
title:SetText("Vendor Atlas")
title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

local close = CreateFrame("Button", nil, header)
close:SetSize(20, 20)
close:SetPoint("TOPRIGHT", -4, -4)
close:SetNormalFontObject("VA_GameFontHighlight")
close:SetHighlightFontObject("VA_GameFontNormal")
close:SetText("x")
close:SetScript("OnClick", function() panel:Hide() end)

-- Small square buttons for switching between the full and compact views
local function SquareButton(parent, text, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    SkinButton(b)
    b:SetNormalFontObject("VA_GameFontHighlightSmall")
    b:SetText(text)
    SetTooltip(b, tip)
    return b
end

local compactBtn = SquareButton(header, "-", "Compact view: just the search box and the item list.")
compactBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)

-- Shows or hides items and vendors only known from Classic data
local unverifiedBtn = CreateFrame("Button", nil, header)
unverifiedBtn:SetSize(112, 18)
unverifiedBtn:SetPoint("RIGHT", compactBtn, "LEFT", -6, 0)
SkinButton(unverifiedBtn)
local unverifiedLabel = unverifiedBtn:CreateFontString(nil, "OVERLAY", "VA_GameFontNormalSmall")
unverifiedLabel:SetPoint("CENTER")
unverifiedLabel:SetText("Toggle Unverified")
SetTooltip(unverifiedBtn, "Show or hide Classic vendor data you haven't confirmed by visiting. It may have changed in Forever.")

local box = EditBox(panel)
box:SetPoint("TOPLEFT", 10, -30)
box:SetPoint("TOPRIGHT", -10, -30)
box:SetHeight(22)

box:SetTextInsets(6, 22, 0, 0)

local placeholder = box:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
placeholder:SetPoint("LEFT", 7, 0)

local clear = CreateFrame("Button", nil, box)
clear:SetSize(20, 20)
clear:SetPoint("RIGHT", -1, 0)
clear:SetNormalFontObject("VA_GameFontDisable")
clear:SetHighlightFontObject("VA_GameFontNormal")
clear:SetText("x")
clear:Hide()
clear:SetScript("OnClick", function() box:SetText("") end)

local status = panel:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -6)

local tree = CreateFrame("Frame", nil, panel)
tree:SetPoint("TOPLEFT", 10, -76)
tree:SetPoint("BOTTOMLEFT", 10, 52)
tree:SetWidth(TREE_W)
tree:EnableMouseWheel(true)
Fill(tree, C.inset, 0.85)
Outline(tree, BORDER, 0.6)
AddScrollbar(tree)

local list = CreateFrame("Frame", nil, panel)
list:SetPoint("TOPLEFT", tree, "TOPRIGHT", 8, 0)
list:SetPoint("BOTTOMRIGHT", -10, 26)
list:EnableMouseWheel(true)
Fill(list, C.inset, 0.85)
Outline(list, BORDER, 0.6)
AddScrollbar(list)

local empty = list:CreateFontString(nil, "OVERLAY", "VA_GameFontDisable")
empty:SetPoint("CENTER")

local newBtn = TextButton(panel, "New", 56)
newBtn:SetPoint("TOPLEFT", tree, "BOTTOMLEFT", 0, -6)
local renameBtn = TextButton(panel, "Rename", 56)
renameBtn:SetPoint("LEFT", newBtn, "RIGHT", 6, 0)
local deleteBtn = TextButton(panel, "Delete", 56)
deleteBtn:SetPoint("LEFT", renameBtn, "RIGHT", 6, 0)
SetTooltip(newBtn, "New subcategory under the selected one. Use / for nesting, e.g. Base/Consumables/Ammo")
SetTooltip(renameBtn, "Rename or move the selected category. Items and subcategories follow.")
SetTooltip(deleteBtn, "Shift-click to delete the selected category and its subcategories.")

local editor = EditBox(panel)
editor:SetPoint("TOPLEFT", tree, "BOTTOMLEFT", 0, -6)
editor:SetSize(TREE_W, 20)
editor:Hide()

local hint = panel:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", 10, 8)
hint:SetPoint("RIGHT", -22, 0)
hint:SetJustifyH("LEFT")
hint:SetWordWrap(false)
hint:SetText("Click: show on map   Drag onto category: add   Right-click: remove   Shift-click: link")

-- Compact view controls: close and back to the full view, beside the search box
local miniClose = CreateFrame("Button", nil, panel)
miniClose:SetSize(18, 18)
miniClose:SetPoint("TOPRIGHT", -5, -6)
miniClose:SetNormalFontObject("VA_GameFontHighlight")
miniClose:SetHighlightFontObject("VA_GameFontNormal")
miniClose:SetText("x")
miniClose:SetScript("OnClick", function() panel:Hide() end)
miniClose:Hide()

local expandBtn = SquareButton(panel, "+", "Full view: categories, status and hints.")
expandBtn:SetPoint("RIGHT", miniClose, "LEFT", -3, 0)
expandBtn:Hide()

local dragIcon = CreateFrame("Frame", nil, UIParent)
dragIcon:SetSize(20, 20)
dragIcon:SetFrameStrata("TOOLTIP")
dragIcon:Hide()
dragIcon.tex = dragIcon:CreateTexture(nil, "ARTWORK")
dragIcon.tex:SetAllPoints()
dragIcon:SetScript("OnUpdate", function(self)
    -- Safety net: if the drag ended without us hearing about it, drop the icon
    if not IsMouseButtonDown("LeftButton") then
        self:Hide()
        return
    end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale + 14, y / scale - 14)
end)

local treeRows, rows = {}, {}

-- Data --------------------------------------------------------------------

local function LowerName(itemID)
    local name = lowerNames[itemID]
    if not name then
        name = strlower(VA.db.items[itemID].name or "")
        lowerNames[itemID] = name
    end
    return name
end

-- Search shorthands; two-letter ones only match their expansion
local ALIASES = {
    alch = "alchemy", bs = "blacksmithing", cook = "cooking", ench = "enchanting", engi = "engineering",
    fish = "fishing", lw = "leatherworking", herb = "herbalism", mine = "mining", skin = "skinning",
    mats = "materials",
}

local function Tokens(query)
    local tokens = {}
    for word in query:gmatch("%S+") do
        tokens[#tokens + 1] = { word = word, alias = ALIASES[word] }
    end
    return tokens
end

local function TokenIn(text, t)
    return (t.alias and text:find(t.alias, 1, true))
        or ((not t.alias or #t.word > 2) and text:find(t.word, 1, true))
end

local function LowerPath(path)
    local lower = lowerPaths[path]
    if not lower then
        lower = strlower(path)
        lowerPaths[path] = lower
    end
    return lower
end

-- A level range like "1-15", "over 30", "under 30" (or a single level like "45") in the search keeps items whose
-- required level, or profession skill for recipes, is inside it; items with no requirement are left out
local function ParseQuery(query)
    local low, high
    local rest = query:gsub("(%d+)%s*%-%s*(%d+)", function(a, b)
        low, high = tonumber(a), tonumber(b)
        return " "
    end)
    if low and high and low > high then low, high = high, low end

    -- "over 30" and "under 30" (both including 30), alone or together with each other
    rest = rest:gsub("over%s+(%d+)", function(n)
        low, high = tonumber(n), high or math.huge
        return " "
    end)
    rest = rest:gsub("under%s+(%d+)", function(n)
        low, high = low or 1, tonumber(n)
        return " "
    end)

    -- A number on its own is an exact level: "45" is the same as "45-45"
    local words = {}
    for word in rest:gmatch("%S+") do
        local level = not low and word:match("^%d+$") and tonumber(word)
        if level then
            low, high = level, level
        else
            words[#words + 1] = word
        end
    end
    return table.concat(words, " "), low, high
end

-- Required levels come from the item cache; uncached items are requested and fill in later.
-- For recipes the "level" is the profession skill they need, read from the tooltip.
local levels, pendingLevels = {}, {}
local RECIPE_CLASS = 9

local function RecipeSkill(itemID)
    local data = C_TooltipInfo and C_TooltipInfo.GetItemByID(itemID)
    for _, line in ipairs(data and data.lines or {}) do
        local skill = line.leftText and line.leftText:match("^Requires .- %((%d+)%)$")
        if skill then return tonumber(skill) end
    end
    return 0
end

local function RequiredLevel(itemID)
    local level = levels[itemID]
    if level == nil then
        if not C_Item.IsItemDataCachedByID(itemID) then
            pendingLevels[itemID] = true
            C_Item.RequestLoadItemDataByID(itemID)
            return
        end
        local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
        if classID == RECIPE_CLASS then
            level = RecipeSkill(itemID)
        else
            level = select(5, C_Item.GetItemInfo(itemID)) or 0
        end
        levels[itemID] = level
    end
    return level
end

local function LevelOK(itemID, low, high)
    local level = RequiredLevel(itemID)
    if not level then return false end
    return level >= low and level <= high
end

-- Item type, subtype and slot words, so "staff", "mail legs" or "2h sword" find gear
local SLOT_WORDS = {
    INVTYPE_HEAD = "head helm", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulder",
    INVTYPE_CLOAK = "back cloak", INVTYPE_CHEST = "chest", INVTYPE_ROBE = "chest robe",
    INVTYPE_BODY = "shirt", INVTYPE_TABARD = "tabard", INVTYPE_WRIST = "wrist bracers",
    INVTYPE_HAND = "hands gloves", INVTYPE_WAIST = "waist belt", INVTYPE_LEGS = "legs pants",
    INVTYPE_FEET = "feet boots", INVTYPE_FINGER = "finger ring", INVTYPE_TRINKET = "trinket",
    INVTYPE_WEAPON = "one-hand 1h", INVTYPE_2HWEAPON = "two-hand 2h",
    INVTYPE_WEAPONMAINHAND = "main hand 1h", INVTYPE_WEAPONOFFHAND = "off hand 1h",
    INVTYPE_SHIELD = "shield off hand", INVTYPE_HOLDABLE = "off hand held",
    INVTYPE_RANGED = "ranged", INVTYPE_RANGEDRIGHT = "ranged", INVTYPE_THROWN = "thrown ranged",
}
-- Singular forms that aren't already part of the plural subtype name
local SUBTYPE_WORDS = { staves = "staff" }

local gearWords = {}
local function GearWords(itemID)
    local words = gearWords[itemID]
    if not words then
        local _, itemType, subType, equipLoc = C_Item.GetItemInfoInstant(itemID)
        local sub = strlower(subType or "")
        words = strlower(itemType or "") .. " " .. sub .. " " .. (SUBTYPE_WORDS[sub] or "")
            .. " " .. (SLOT_WORDS[equipLoc] or "")
        gearWords[itemID] = words
    end
    return words
end

-- Every word must match the item's name or gear words, or those plus one of its category paths
local function Matches(itemID, tokens)
    local name, gear = LowerName(itemID), GearWords(itemID)
    local missing = false
    for _, t in ipairs(tokens) do
        if not (TokenIn(name, t) or TokenIn(gear, t)) then
            missing = true
            break
        end
    end
    if not missing then return true end

    local set = VA.db.itemCats[itemID]
    if not set then return false end
    for path in pairs(set) do
        local lower, ok = LowerPath(path), true
        for _, t in ipairs(tokens) do
            if not (TokenIn(name, t) or TokenIn(gear, t) or TokenIn(lower, t)) then
                ok = false
                break
            end
        end
        if ok then return true end
    end
    return false
end

-- Service NPCs ------------------------------------------------------------
-- Trainers, flight masters and the like are listed as "s" .. npcID keys next to item IDs,
-- under a "Services" category tree that isn't saved and can't be edited.

local SERVICE_WORDS = {
    ["Services/Flight Masters"] = "flight path fp gryphon wind rider",
    ["Services/Innkeepers"] = "inn hearthstone",
    ["Services/Bankers"] = "bank",
    ["Services/Auctioneers"] = "auction ah",
    ["Services/Battlemasters"] = "battleground bg pvp",
    ["Services/Guild Masters"] = "guild tabard charter",
    ["Services/Stable Masters"] = "stable pet",
}

local function IsService(id)
    return type(id) == "string"
end

local function IsVirtual(path)
    return path == "Services" or path:sub(1, 9) == "Services/"
end

local servicePaths
local function ServicePaths()
    if not servicePaths and next(VA.services) then
        servicePaths = {}
        for _, npc in pairs(VA.services) do
            for _, path in ipairs(npc.paths) do
                local p = path
                while p and not servicePaths[p] do
                    servicePaths[p] = true
                    p = VA:ParentPath(p)
                end
            end
        end
    end
    return servicePaths or {}
end

local function ServiceText(npc)
    if not npc.search then
        local parts = { npc.name, npc.title or "" }
        for _, path in ipairs(npc.paths) do
            parts[#parts + 1] = path
            parts[#parts + 1] = SERVICE_WORDS[path] or ""
        end
        npc.search = strlower(table.concat(parts, " "))
    end
    return npc.search
end

local function ServiceMatches(npc, tokens)
    local text = ServiceText(npc)
    for _, t in ipairs(tokens) do
        if not TokenIn(text, t) then return false end
    end
    return true
end

local function ServiceInCategory(npc, cat)
    if cat == ALL then return true end
    for _, path in ipairs(npc.paths) do
        if path == cat or path:sub(1, #cat + 1) == cat .. "/" then return true end
    end
    return false
end

-- Group rows stand for every service NPC in one category: "n:" .. path for the nearest one,
-- "a:" .. path for all of them
local groups, groupSizes, groupIcons = {}, {}, {}

local function IsGroup(id)
    return type(id) == "string" and (id:sub(1, 2) == "n:" or id:sub(1, 2) == "a:")
end

local function IsNearest(id)
    return type(id) == "string" and id:sub(1, 2) == "n:"
end

local function GroupLabel(id)
    local path = id:sub(3)
    local leaf = path:match("[^/]+$")
    local trainer = path:find("^Services/Trainers/") and not leaf:find("Master")
    if IsNearest(id) then
        return "Nearest " .. (trainer and (leaf .. " Trainer") or leaf:gsub("s$", ""))
    end
    return "All " .. (trainer and (leaf .. " Trainers") or leaf == "Repair" and "Repairs" or leaf)
end

-- The service NPC a row stands for: itself, or the closest one of a group row
local function ServiceKey(id)
    if not IsGroup(id) then return id end
    local group = groups[id:sub(3)]
    return group and VA:ClosestServiceKey(group)
end

-- Category paths of shown service NPCs, grouped for the group rows
local function BuildGroups()
    wipe(groups)
    wipe(groupSizes)
    for key, npc in pairs(VA.services) do
        if not (npc.unverified and VA.db.hideUnverified) then
            for _, path in ipairs(npc.paths) do
                local group = groups[path] or {}
                groups[path] = group
                group[key] = true
                groupSizes[path] = (groupSizes[path] or 0) + 1
                groupIcons[path] = groupIcons[path] or npc.icon
            end
        end
    end
end

local function SortName(id)
    -- Nearest and All rows of a category stay together
    if IsGroup(id) then return strlower(id:sub(3)) .. (IsNearest(id) and "1" or "2") end
    if IsService(id) then return strlower(VA.services[id].name) end
    return LowerName(id)
end

local ROOT_COLORS = {
    ["Consumables"] = { 0.55, 0.85, 0.55 },
    ["Professions"] = { 0.55, 0.75, 1.0 },
    ["Gear"] = { 0.8, 0.8, 0.85 },
    ["Leveling"] = { 0.5, 0.9, 0.85 },
    ["PvP"] = { 1.0, 0.5, 0.45 },
    ["Reputation"] = { 0.75, 0.6, 1.0 },
    ["Mounts"] = { 1.0, 0.75, 0.45 },
    ["Pets"] = { 1.0, 0.65, 0.8 },
    ["Class Supplies"] = { 0.95, 0.9, 0.5 },
    ["Quest Items"] = { 1.0, 0.85, 0.3 },
    ["Services"] = { 0.55, 0.85, 0.9 },
}
local PALETTE = { { 0.6, 0.8, 0.95 }, { 0.9, 0.7, 0.6 }, { 0.7, 0.9, 0.6 }, { 0.85, 0.7, 0.95 } }

-- Tint by root category, fading toward grey with depth
local function CategoryColor(path, depth)
    local root = path:match("^[^/]+")
    local c = ROOT_COLORS[root]
    if not c then
        local sum = 0
        for i = 1, #root do sum = sum + root:byte(i) end
        c = PALETTE[sum % #PALETTE + 1]
    end
    local fade = math.min(depth * 0.2, 0.6)
    return c[1] + (0.8 - c[1]) * fade, c[2] + (0.8 - c[2]) * fade, c[3] + (0.8 - c[3]) * fade
end

-- Category icons by name: item IDs, "spell:ID" or texture paths.
-- Categories without one use their parent's; class trainers use the class icon.
local ICONS = "Interface\\Icons\\"
local CATEGORY_ICONS = {
    ["Consumables"] = 118, ["Food & Drink"] = 4540, ["Food"] = 117, ["Mana"] = 159, ["Buff Food"] = 2680,
    ["Ammo"] = 2512, ["Arrows"] = 2512, ["Bullets"] = 2516, ["Potions"] = 118, ["Elixirs"] = 5997,
    ["Flasks"] = 13510, ["Scrolls"] = 955, ["Bandages"] = 1251, ["Explosives"] = 4358,
    ["Weapon Enhancements"] = 2862,
    ["Professions"] = ICONS .. "Trade_Engineering", ["Materials"] = 2320, ["Recipes"] = 2598,
    ["Tools"] = 2901, ["Lures"] = 6529, ["Poles"] = 6256,
    ["Tailoring"] = "spell:3908", ["Leatherworking"] = "spell:2108", ["Blacksmithing"] = "spell:2018",
    ["Alchemy"] = "spell:2259", ["Enchanting"] = "spell:7411", ["Engineering"] = "spell:4036",
    ["Cooking"] = "spell:2550", ["First Aid"] = "spell:3273", ["Fishing"] = "spell:7620",
    ["Mining"] = "spell:2575", ["Herbalism"] = "spell:2366", ["Skinning"] = "spell:8613",
    ["Gear"] = 1364, ["Armor"] = 1364, ["Weapons"] = 25, ["Bags"] = 4496, ["Quivers & Pouches"] = 2101,
    ["Leveling"] = ICONS .. "Spell_Holy_SurgeOfLight",
    ["PvP"] = ICONS .. "INV_BannerPVP_02",
    ["Reputation"] = ICONS .. "Achievement_Reputation_01",
    ["Mounts"] = ICONS .. "Ability_Mount_RidingHorse",
    ["Pets"] = 8485,
    ["Class Supplies"] = 17031, ["Reagents"] = 17031, ["Poisons"] = 2892, ["Books"] = ICONS .. "INV_Misc_Book_09",
    ["Quest Items"] = ICONS .. "INV_Misc_Note_01",
    ["Services"] = ICONS .. "INV_Misc_GroupLooking",
}
local iconCache = {}

local function IconOf(spec)
    if type(spec) == "number" then return C_Item.GetItemIconByID(spec) end
    local spell = tonumber(spec:match("^spell:(%d+)$"))
    if spell then return C_Spell.GetSpellTexture(spell) end
    return spec
end

local function CategoryIcon(path)
    if iconCache[path] == nil then
        local leaf, parent = path:match("[^/]+$"), VA:ParentPath(path)
        local spec = CATEGORY_ICONS[leaf]
        if parent and parent:match("/Classes$") then spec = ICONS .. "ClassIcon_" .. leaf end
        local icon = spec and IconOf(spec)
            or (IsVirtual(path) and VA:ServiceIcon(path))
            or (parent and CategoryIcon(parent))
        iconCache[path] = icon or false
    end
    return iconCache[path] or nil
end

-- Sorts children directly after their parent ("A/B" before "A B")
local function SortKey(path)
    local key = sortKeys[path]
    if not key then
        -- "Other ..." categories sort after their siblings
        key = ("/" .. strlower(path)):gsub("/other", "/\127other"):gsub("/", "\001"):sub(2)
        sortKeys[path] = key
    end
    return key
end

local function SortedPaths(set)
    local out = {}
    for path in pairs(set) do out[#out + 1] = path end
    table.sort(out, function(a, b) return SortKey(a) < SortKey(b) end)
    return out
end

local function BuildTree()
    local db = VA.db
    wipe(nodes)
    nodes[1] = { path = ALL, label = "All items", depth = 0 }

    local all, hasKids = {}, {}
    for path in pairs(db.categories) do all[path] = true end
    for path in pairs(ServicePaths()) do all[path] = true end
    for path in pairs(all) do
        local parent = VA:ParentPath(path)
        if parent then hasKids[parent] = true end
    end

    for _, path in ipairs(SortedPaths(all)) do
        local hidden, parent = false, VA:ParentPath(path)
        while parent and not hidden do
            hidden = db.collapsed[parent]
            parent = VA:ParentPath(parent)
        end
        if not hidden then
            local _, depth = path:gsub("/", "")
            nodes[#nodes + 1] = { path = path, label = path:match("[^/]+$"), depth = depth, kids = hasKids[path] == true }
        end
    end

    nodes[#nodes + 1] = { path = UNCAT, label = "Uncategorized", depth = 0 }
end

local seen = {}

local function CountItems()
    local db = VA.db
    wipe(counts)
    for itemID, item in pairs(db.items) do
        if VA:ItemVisible(item) then
            counts[ALL] = (counts[ALL] or 0) + 1
            local set = db.itemCats[itemID]
            if set then
                wipe(seen)
                for path in pairs(set) do
                    local p = path
                    while p and not seen[p] do
                        seen[p] = true
                        counts[p] = (counts[p] or 0) + 1
                        p = VA:ParentPath(p)
                    end
                end
            else
                counts[UNCAT] = (counts[UNCAT] or 0) + 1
            end
        end
    end
    for _, npc in pairs(VA.services) do
        if not (npc.unverified and db.hideUnverified) then
            wipe(seen)
            for _, path in ipairs(npc.paths) do
                local p = path
                while p and not seen[p] do
                    seen[p] = true
                    counts[p] = (counts[p] or 0) + 1
                    p = VA:ParentPath(p)
                end
            end
        end
    end
end

-- Drawing -----------------------------------------------------------------

local function DrawTree()
    treeOffset = math.max(0, math.min(treeOffset, #nodes - TREE_ROWS))
    for i, row in ipairs(treeRows) do
        local node = i <= TREE_ROWS and nodes[treeOffset + i]
        if node then
            row.path = node.path
            row.toggle:SetPoint("LEFT", 2 + node.depth * 12, 0)
            row.toggle:SetShown(node.kids == true)
            row.toggle:SetText(VA.db.collapsed[node.path] and "+" or "-")
            row.label:SetText(node.label)
            row.icon:SetTexture(node.path == ALL and ICONS .. "INV_Misc_Bag_08"
                or node.path == UNCAT and 134400 or CategoryIcon(node.path))
            if VA:IsCategory(node.path) then
                row.label:SetTextColor(CategoryColor(node.path, node.depth))
            else
                row.label:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
            end
            row.count:SetText(counts[node.path] or "")
            row.sel:SetShown(node.path == category)
            row:Show()
        else
            row.path = nil
            row:Hide()
        end
    end
    UpdateScrollbar(tree, treeOffset, #nodes, TREE_ROWS)
    local editable = VA:IsCategory(category) and not IsVirtual(category)
    renameBtn:SetEnabled(editable)
    deleteBtn:SetEnabled(editable)
end

local Row_Hover -- defined with the item rows below

local function DrawRows()
    offset = math.max(0, math.min(offset, #results - ROWS))
    for i, row in ipairs(rows) do
        local itemID = i <= ROWS and results[offset + i]
        local group = IsGroup(itemID)
        local npc = itemID and not group and IsService(itemID) and VA.services[itemID]
        local item = itemID and not npc and not group and VA.db.items[itemID]
        if group then
            local path = itemID:sub(3)
            local key = IsNearest(itemID) and ServiceKey(itemID)
            local closest = key and VA.services[key]
            row.itemID = itemID
            row.icon:SetTexture(groupIcons[path] or 134400)
            row.name:SetText(GroupLabel(itemID))
            row.name:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
            if not IsNearest(itemID) then
                row.info:SetText(groupSizes[path] .. " NPCs")
            elseif not closest then
                row.info:SetText("Not on this continent")
            else
                local zone = VA:ZoneName(closest)
                row.info:SetText(closest.unverified and ("|cffff5a4d" .. zone .. "|r") or zone)
            end
            row.sel:SetShown(itemID == selected)
            row:Show()
        elseif npc then
            row.itemID = itemID
            row.icon:SetTexture(npc.icon or 134400)
            -- Unverified ones get the same red "?" tag as unverified items
            local tag = npc.unverified and " |cffff5a4d?|r" or ""
            row.name:SetText(npc.name .. tag .. (npc.title and (" |cff8a8a8a<" .. npc.title .. ">|r") or ""))
            row.name:SetTextColor(0.55, 0.85, 0.9)
            local zone = VA:ZoneName(npc)
            row.info:SetText(npc.unverified and ("|cffff5a4d" .. zone .. "|r") or zone)
            row.sel:SetShown(itemID == selected)
            row:Show()
        elseif item then
            if not item.quality then item.quality = C_Item.GetItemQualityByID(itemID) end
            local color = ITEM_QUALITY_COLORS[item.quality or 1] or ITEM_QUALITY_COLORS[1]
            row.itemID = itemID
            row.icon:SetTexture(item.icon or 134400)
            row.name:SetText(item.name)
            row.name:SetTextColor(color.r, color.g, color.b)

            local count, onlyKey, verified = 0, nil, false
            for key, offer in pairs(item.vendors) do
                if VA:OfferVisible(offer) then
                    count, onlyKey = count + 1, key
                    verified = verified or not offer.unverified
                end
            end
            local info = count == 1 and VA:ZoneName(VA.db.vendors[onlyKey] or {}) or (count .. " vendors")
            -- Items only known from Classic data are tagged red until a vendor confirms them
            row.info:SetText(verified and info or ("|cffff5a4d" .. info .. "|r"))
            if not verified then row.name:SetText(item.name .. " |cffff5a4d?|r") end
            row.sel:SetShown(itemID == selected)
            row:Show()
        else
            row.itemID = nil
            row:Hide()
        end
    end
    UpdateScrollbar(list, offset, #results, ROWS)
    -- Rows shift under a still cursor when scrolling or refreshing; re-aim the targeting
    for _, row in ipairs(rows) do
        if VA:IsTargetOwner(row) then Row_Hover(row) end
    end
end

function VA:RefreshList()
    if refreshTimer then
        refreshTimer:Cancel()
        refreshTimer = nil
    end
    if not panel:IsShown() then return end
    local db = self.db
    local query, low, high = ParseQuery(strlower(strtrim(box:GetText())))
    local tokens = Tokens(query)

    if category ~= ALL and category ~= UNCAT and not db.categories[category] and not ServicePaths()[category] then
        category = ALL
    end
    if treeDirty then
        BuildTree()
        treeDirty = false
    end
    if countsDirty then
        CountItems()
        countsDirty = false
    end

    local cat = ActiveCategory()
    local scope = cat == ALL and "all items" or cat == UNCAT and "Uncategorized" or cat:match("[^/]+$")
    placeholder:SetText("Search " .. scope .. "...")

    wipe(results)
    for itemID, item in pairs(db.items) do
        if self:ItemVisible(item) and self:ItemInCategory(itemID, cat)
            and (query == "" or Matches(itemID, tokens))
            and (not low or LevelOK(itemID, low, high)) then
            results[#results + 1] = itemID
        end
    end
    -- Service NPCs show up when searching or browsing Services, but not under level filters
    if not low and (query ~= "" or IsVirtual(cat)) then
        BuildGroups()
        local paths = {}
        for key, npc in pairs(VA.services) do
            if not (npc.unverified and db.hideUnverified) and ServiceInCategory(npc, cat)
                and (query == "" or ServiceMatches(npc, tokens)) then
                results[#results + 1] = key
                for _, path in ipairs(npc.paths) do paths[path] = true end
            end
        end
        -- An "All" row for each matching category with more than one NPC, and "Nearest" when searching
        for path in pairs(paths) do
            if groupSizes[path] > 1 and ServiceInCategory({ paths = { path } }, cat)
                and ServiceMatches({ paths = { path }, name = "" }, tokens) then
                results[#results + 1] = "a:" .. path
                if query ~= "" then results[#results + 1] = "n:" .. path end
            end
        end
    end
    -- Items first, then group rows, then service NPCs, each alphabetical
    local function Rank(id) return IsGroup(id) and 1 or IsService(id) and 2 or 0 end
    table.sort(results, function(a, b)
        local ra, rb = Rank(a), Rank(b)
        if ra ~= rb then return ra < rb end
        local na, nb = SortName(a), SortName(b)
        if na == nb then return tostring(a) < tostring(b) end
        return na < nb
    end)

    -- Pin the selected item, or everything shown when searching or browsing a category
    local source = selected and { selected } or ((query ~= "" or low or cat ~= ALL) and results) or nil
    if source then
        self.activeVendors = {}
        for _, id in ipairs(source) do
            if IsGroup(id) and not IsNearest(id) then
                -- An "All" row pins the whole category
                for key in pairs(groups[id:sub(3)] or {}) do
                    self.activeVendors[key] = self.activeVendors[key] or {}
                end
            elseif IsService(id) then
                -- A service NPC is pinned itself, a "Nearest" row pins the closest one
                local key = ServiceKey(id)
                if key then self.activeVendors[key] = self.activeVendors[key] or {} end
            else
                for key, offer in pairs(db.items[id].vendors) do
                    if self:OfferVisible(offer) then
                        local ids = self.activeVendors[key] or {}
                        self.activeVendors[key] = ids
                        ids[#ids + 1] = id
                    end
                end
            end
        end
    else
        self.activeVendors = nil
    end
    self:RefreshMap()

    local vendorCount = 0
    for _ in pairs(self.activeVendors or {}) do vendorCount = vendorCount + 1 end
    status:SetText(("%d items   %d vendors on map"):format(#results, vendorCount))
    if db.hideUnverified then
        unverifiedLabel:SetTextColor(0.5, 0.5, 0.5)
    else
        unverifiedLabel:SetTextColor(0.85, 0.45, 0.35)
    end

    if not next(db.items) then
        empty:SetText("Open a vendor to start recording.")
    elseif #results == 0 then
        empty:SetText("No matches.")
    else
        empty:SetText("")
    end

    DrawTree()
    DrawRows()
end

-- Scans and auto-categorizing can fire in bursts, so refresh at most every quarter second
local dataTimer
function VA:OnDataChanged()
    MarkDirty()
    wipe(lowerNames)
    if dataTimer then return end
    dataTimer = C_Timer.NewTimer(0.25, function()
        dataTimer = nil
        if panel:IsShown() then
            VA:RefreshList()
        else
            VA:RefreshMap()
        end
    end)
end

function VA:Toggle()
    panel:SetShown(not panel:IsShown())
end

-- Category tree -----------------------------------------------------------

local function ExpandTo(path)
    local parent = VA:ParentPath(path)
    while parent do
        VA.db.collapsed[parent] = nil
        parent = VA:ParentPath(parent)
    end
end

local function SelectCategory(path)
    if path ~= category or selected then VA:ClearMinimapVendor() end
    category, selected, offset = path, nil, 0
    box:SetText("")
    VA:RefreshList()
    VA:FitMapToActive()
end

local function Node_OnClick(self)
    if self.path then SelectCategory(self.path) end
end

local function Toggle_OnClick(self)
    local path = self:GetParent().path
    VA.db.collapsed[path] = not VA.db.collapsed[path] or nil
    treeDirty = true
    VA:RefreshList()
end

local function CreateTreeRow(i)
    local row = CreateFrame("Button", nil, tree)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", -(SCROLL_W + 4), 0)

    local hl = row:CreateTexture()
    hl:SetColorTexture(1, 1, 1, 0.06)
    row:SetHighlightTexture(hl)

    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.2)

    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(16, ROW_H)
    row.toggle:SetNormalFontObject("VA_GameFontDisableLarge")
    row.toggle:SetHighlightFontObject("VA_GameFontNormalLarge")
    row.toggle:SetText("-")
    row.toggle:SetScript("OnClick", Toggle_OnClick)

    row.count = row:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
    row.count:SetPoint("RIGHT", -4, 0)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("LEFT", row.toggle, "RIGHT", 1, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.label = row:CreateFontString(nil, "OVERLAY", "VA_GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row:SetScript("OnClick", Node_OnClick)
    return row
end

local function OpenEditor(mode, text)
    editMode = mode
    newBtn:Hide()
    renameBtn:Hide()
    deleteBtn:Hide()
    editor:SetText(text)
    editor:Show()
    editor:SetFocus()
    editor:SetCursorPosition(#text)
end

local function CloseEditor()
    editMode = nil
    editor:ClearFocus()
    editor:Hide()
    local full = not VA.db.compact
    newBtn:SetShown(full)
    renameBtn:SetShown(full)
    deleteBtn:SetShown(full)
end

newBtn:SetScript("OnClick", function()
    OpenEditor("new", VA:IsCategory(category) and (category .. "/") or "")
end)

renameBtn:SetScript("OnClick", function()
    OpenEditor("rename", category)
end)

deleteBtn:SetScript("OnClick", function()
    if not IsShiftKeyDown() then return end
    VA:DeleteCategory(category)
    MarkDirty()
    SelectCategory(ALL)
end)

editor:SetScript("OnEnterPressed", function(self)
    local text = self:GetText()
    local path
    if editMode == "new" then
        path = VA:AddCategory(text)
    elseif editMode == "rename" then
        path = VA:RenameCategory(category, text)
    end
    CloseEditor()
    if path then
        MarkDirty()
        ExpandTo(path)
        SelectCategory(path)
    end
end)
editor:SetScript("OnEscapePressed", CloseEditor)
editor:SetScript("OnEditFocusLost", CloseEditor)

tree:SetScript("OnMouseWheel", function(_, delta)
    treeOffset = treeOffset - delta * 3
    DrawTree()
end)
tree.onScroll = function(pos)
    treeOffset = pos
    DrawTree()
end

-- Item rows ---------------------------------------------------------------

local function Row_OnEnter(self)
    if IsGroup(self.itemID) and not IsNearest(self.itemID) then
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", 0, -4)
        GameTooltip:AddLine(GroupLabel(self.itemID), ACCENT[1], ACCENT[2], ACCENT[3])
        GameTooltip:AddLine(("%d NPCs"):format(groupSizes[self.itemID:sub(3)] or 0), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Click to show them all on the map and target the closest", 0.5, 0.5, 0.5)
        GameTooltip:Show()
        return
    end
    if IsService(self.itemID) then
        local key = ServiceKey(self.itemID)
        if not key or dragIcon:IsShown() then return end
        VA:ShowServiceTooltip(self, key, nil, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", 0, -4)
        return
    end
    local item = VA.db.items[self.itemID]
    if not item or dragIcon:IsShown() then return end
    -- Below the window, right-aligned, so comparison tooltips don't cover it
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", 0, -4)
    GameTooltip:SetItemByID(self.itemID)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Sold by:", ACCENT[1], ACCENT[2], ACCENT[3])

    local keys, where, unverified = {}, {}, false
    for key, offer in pairs(item.vendors) do
        local vendor = VA.db.vendors[key]
        if vendor and VA:OfferVisible(offer) then
            keys[#keys + 1] = key
            where[key] = VA:LocationText(vendor)
        end
    end
    table.sort(keys, function(a, b) return where[a] < where[b] end)
    for i, key in ipairs(keys) do
        if i > MAX_TOOLTIP_VENDORS then
            GameTooltip:AddLine(("... and %d more"):format(#keys - MAX_TOOLTIP_VENDORS), 0.6, 0.6, 0.6)
            break
        end
        local vendor = VA.db.vendors[key]
        local g = vendor.unverified and 0.35 or 1
        GameTooltip:AddDoubleLine(vendor.name .. " |cff999999" .. where[key] .. "|r",
            VA:PriceText(item.vendors[key]), 1, g, g, 1, 1, 1)
        unverified = unverified or vendor.unverified
    end
    if unverified then
        GameTooltip:AddLine("Red vendors are from Classic and may have changed. Visit them to confirm.", 0.6, 0.6, 0.6, true)
    end

    local set = VA.db.itemCats[self.itemID]
    if set then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Categories:", ACCENT[1], ACCENT[2], ACCENT[3])
        for _, path in ipairs(SortedPaths(set)) do
            GameTooltip:AddLine(path, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:Show()
end

-- Small "Remove from <category>" button shown at the cursor on right-click
local removeBtn = CreateFrame("Button", nil, panel)
removeBtn:SetHeight(22)
removeBtn:SetFrameStrata("TOOLTIP")
removeBtn:Hide()
SkinButton(removeBtn)
removeBtn.label = removeBtn:CreateFontString(nil, "OVERLAY", "VA_GameFontHighlightSmall")
removeBtn.label:SetPoint("CENTER")

removeBtn:SetScript("OnClick", function(self)
    self:Hide()
    VA:UnassignItem(self.itemID, ActiveCategory())
    countsDirty = true
    if selected == self.itemID then selected = nil end
    VA:RefreshList()
end)
-- Closes on any click elsewhere, or when the window closes
removeBtn:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
removeBtn:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
removeBtn:SetScript("OnEvent", function(self)
    if not self:IsMouseOver() then self:Hide() end
end)

local function ShowRemoveButton(itemID)
    local x, y = GetCursorPosition()
    local scale = removeBtn:GetEffectiveScale()
    removeBtn.itemID = itemID
    removeBtn.label:SetText("Remove from " .. ActiveCategory():match("[^/]+$"))
    removeBtn:SetWidth(removeBtn.label:GetStringWidth() + 20)
    removeBtn:ClearAllPoints()
    removeBtn:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 4, y / scale - 4)
    removeBtn:Show()
end

local function Row_OnClick(self, button)
    local itemID = self.itemID
    if not itemID then return end

    -- Service NPCs: click to show and mark them, right-click to clear the selection
    if IsService(itemID) then
        if IsModifiedClick() then return end
        if button == "RightButton" or selected == itemID then
            selected = nil
            VA:ClearMinimapVendor()
            VA:RefreshList()
            VA:FitMapToActive()
            return
        else
            selected = itemID
            local key = ServiceKey(itemID)
            if IsGroup(itemID) and not IsNearest(itemID) then
                VA:ShowServicesOnMap(groups[itemID:sub(3)])
            elseif key then
                VA:ShowServiceOnMap(key)
            end
        end
        VA:RefreshList()
        return
    end

    if IsModifiedClick() then
        local link = VA.db.items[itemID].link or select(2, C_Item.GetItemInfo(itemID))
        if link then HandleModifiedItemClick(link) end
        return
    end

    if button == "RightButton" then
        if VA:IsCategory(ActiveCategory()) then
            ShowRemoveButton(itemID)
            return
        end
        selected = nil
        VA:ClearMinimapVendor()
        VA:RefreshList()
        VA:FitMapToActive()
        return
    elseif selected == itemID then
        selected = nil
        VA:ClearMinimapVendor()
        VA:RefreshList()
        VA:FitMapToActive()
        return
    else
        selected = itemID
        VA:ShowItemOnMap(itemID)
    end
    VA:RefreshList()
end

local function Row_OnDragStart(self)
    if not self.itemID or IsService(self.itemID) then return end
    GameTooltip:Hide()
    dragIcon.itemID = self.itemID
    dragIcon.tex:SetTexture(VA.db.items[self.itemID].icon or 134400)
    dragIcon:Show()
end

local function Row_OnDragStop()
    dragIcon:Hide()
    if not dragIcon.itemID then return end
    for _, node in ipairs(treeRows) do
        if node:IsVisible() and node.path and VA:IsCategory(node.path) and not IsVirtual(node.path)
            and node:IsMouseOver() then
            VA:AssignItem(dragIcon.itemID, node.path)
            countsDirty = true
            VA:RefreshList()
            break
        end
    end
    dragIcon.itemID = nil
end

local function Row_Enter(self)
    self.hover:Show()
    Row_OnEnter(self)
end

local function Row_Leave(self)
    self.hover:Hide()
    GameTooltip:Hide()
end

-- A plain click also targets and skull-marks the item's closest vendor, which needs the
-- secure targeting button laid over the row; it passes every other click and drag back here.
function Row_Hover(self)
    Row_Enter(self)
    if not self.itemID then return end
    -- Items target their closest vendor, service NPCs themselves
    local vendor
    if IsService(self.itemID) then
        local key = ServiceKey(self.itemID)
        vendor = key and VA.services[key]
    else
        local key = VA:ClosestVendorKey(self.itemID)
        vendor = key and VA.db.vendors[key]
    end
    VA:AttachTargetButton(self, {
        name = vendor and vendor.name or false,
        rightClick = true,
        onEnter = Row_Enter,
        onLeave = Row_Leave,
        onClick = Row_OnClick,
        onDragStart = Row_OnDragStart,
        onDragStop = Row_OnDragStop,
    })
end

local function CreateItemRow(i)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", -(SCROLL_W + 4), 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:RegisterForDrag("LeftButton")

    -- Shown by hand, since the targeting button covers the row while hovered
    row.hover = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1, 1, 1, 0.06)
    row.hover:Hide()

    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.2)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.info = row:CreateFontString(nil, "OVERLAY", "VA_GameFontDisableSmall")
    row.info:SetPoint("RIGHT", -4, 0)
    row.info:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "VA_GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.info, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row:SetScript("OnEnter", Row_Hover)
    row:SetScript("OnLeave", function(self)
        if not VA:IsTargetOwner(self) then Row_Leave(self) end
    end)
    row:SetScript("OnClick", Row_OnClick)
    row:SetScript("OnDragStart", Row_OnDragStart)
    row:SetScript("OnDragStop", Row_OnDragStop)
    return row
end

list:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    DrawRows()
end)
list.onScroll = function(pos)
    offset = pos
    DrawRows()
end

-- Panel -------------------------------------------------------------------

unverifiedBtn:SetScript("OnClick", function()
    VA.db.hideUnverified = not VA.db.hideUnverified or nil
    selected = nil
    countsDirty = true
    VA:RefreshList()
end)

-- Items whose required level was still loading show up once it arrives
local levelEvents = CreateFrame("Frame")
levelEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
levelEvents:SetScript("OnEvent", function(_, _, itemID)
    if not pendingLevels[itemID] then return end
    pendingLevels[itemID] = nil
    if panel:IsShown() and not refreshTimer then
        refreshTimer = C_Timer.NewTimer(0.2, function() VA:RefreshList() end)
    end
end)

SetTooltip(box, "Search item names and categories")

-- Typing refreshes once the keys settle, instead of on every keystroke
box:SetScript("OnTextChanged", function(self)
    placeholder:SetShown(self:GetText() == "")
    clear:SetShown(self:GetText() ~= "")
    selected, offset = nil, 0
    if refreshTimer then refreshTimer:Cancel() end
    refreshTimer = C_Timer.NewTimer(0.12, function() VA:RefreshList() end)
end)
box:SetScript("OnEscapePressed", box.ClearFocus)
box:SetScript("OnEnterPressed", box.ClearFocus)

-- Row counts follow the window height; extra rows are created as it grows
local function Relayout()
    ROWS = math.max(1, math.floor(list:GetHeight() / ROW_H))
    TREE_ROWS = math.max(1, math.floor(tree:GetHeight() / ROW_H))
    for i = #rows + 1, ROWS do rows[i] = CreateItemRow(i) end
    for i = #treeRows + 1, TREE_ROWS do treeRows[i] = CreateTreeRow(i) end
    if panel:IsShown() then
        DrawTree()
        DrawRows()
    end
end
list:SetScript("OnSizeChanged", Relayout)

-- Every category starts folded the first time the window opens each session
local foldedThisSession
local function FoldAll()
    local collapsed = VA.db.collapsed
    wipe(collapsed)
    for _, set in ipairs({ VA.db.categories, ServicePaths() }) do
        for path in pairs(set) do
            local parent = VA:ParentPath(path)
            if parent then collapsed[parent] = true end
        end
    end
    treeDirty = true
end

-- Full view <-> compact view: same list and search, compact hides everything else
local fullOnly = { header, status, tree, newBtn, renameBtn, deleteBtn, hint }

local function ApplyMode()
    local compact = VA.db.compact
    for _, f in ipairs(fullOnly) do f:SetShown(not compact) end
    miniClose:SetShown(compact == true)
    expandBtn:SetShown(compact == true)
    box:ClearAllPoints()
    list:ClearAllPoints()
    if compact then
        box:SetPoint("TOPLEFT", 6, -6)
        box:SetPoint("RIGHT", expandBtn, "LEFT", -4, 0)
        box:SetHeight(18)
        list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -6)
        list:SetPoint("BOTTOMRIGHT", -6, 16)
    else
        box:SetPoint("TOPLEFT", 10, -30)
        box:SetPoint("TOPRIGHT", -10, -30)
        box:SetHeight(22)
        list:SetPoint("TOPLEFT", tree, "TOPRIGHT", 8, 0)
        list:SetPoint("BOTTOMRIGHT", -10, 26)
    end
end

local function ApplySize()
    local db = VA.db
    local size = db.compact and (db.compactSize or DEFAULT_COMPACT) or (db.size or DEFAULT_FULL)
    panel:SetSize(size[1], size[2])
end

local function SetCompact(on)
    SaveGeometry()
    VA.db.compact = on or nil
    -- Keep the top left corner where it is while the size changes
    local left, top = panel:GetLeft(), panel:GetTop()
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    CloseEditor()
    ApplyMode()
    ApplySize()
    SaveGeometry()
    Relayout()
    VA:RefreshList()
end

compactBtn:SetScript("OnClick", function() SetCompact(true) end)
expandBtn:SetScript("OnClick", function() SetCompact(false) end)

panel:SetScript("OnShow", function()
    local db = VA.db
    ApplyMode()
    ApplySize()
    local p = db.point
    if p then
        panel:ClearAllPoints()
        panel:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end
    if not foldedThisSession then
        FoldAll()
        foldedThisSession = true
    end
    CloseEditor()
    Relayout()
    VA:RefreshList()
end)

panel:SetScript("OnHide", function()
    dragIcon:Hide()
    dragIcon.itemID = nil
    box:ClearFocus()
    CloseEditor()
    VA.activeVendors = nil
    VA:RefreshMap()
end)

SLASH_VENDORATLAS1 = "/va"
SLASH_VENDORATLAS2 = "/vendoratlas"
SlashCmdList.VENDORATLAS = function(msg)
    msg = strtrim(strlower(msg or ""))
    if msg == "debug" then
        VA.debug = not VA.debug
        print(("|cffccb084Vendor Atlas:|r targeting debug %s."):format(VA.debug and "on" or "off"))
    elseif msg == "minimap" then
        VA:SetMinimapButtonShown(true)
    elseif msg == "auto" then
        local count = VA:AutoCategorizeUncategorized()
        print(("|cffccb084Vendor Atlas:|r auto-categorizing %d uncategorized items."):format(count))
    else
        VA:Toggle()
    end
end