local _, VA = ...

-- Minimap pin for the last vendor you clicked on the world map.
-- Cleared by right-clicking it, or by opening that vendor's shop.

local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"
local INTERVAL = 0.05

-- Minimap diameter in yards per zoom level
local SIZES = {
    outdoor = { 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 6, 200, 133 + 1 / 3 },
    indoor = { 300, 240, 180, 120, 80, 50 },
}

local target

local pin = CreateFrame("Button", nil, Minimap)
pin:SetSize(16, 16)
pin:SetFrameLevel(Minimap:GetFrameLevel() + 10)
pin:RegisterForClicks("RightButtonUp")
pin:Hide()

-- Green ring over the normal ring, matching the marked pin on the world map
local outline = pin:CreateTexture(nil, "BACKGROUND", nil, 1)
outline:SetSize(16, 16)
outline:SetPoint("CENTER")
outline:SetTexture(CIRCLE)
outline:SetVertexColor(0.35, 0.85, 0.35)
local ring = pin:CreateTexture(nil, "BACKGROUND")
ring:SetAllPoints()
ring:SetTexture(CIRCLE)
local disc = pin:CreateTexture(nil, "BORDER")
disc:SetSize(13, 13)
disc:SetPoint("CENTER")
disc:SetTexture(CIRCLE)
disc:SetVertexColor(0.05, 0.05, 0.07, 0.9)
local icon = pin:CreateTexture(nil, "ARTWORK")
icon:SetSize(9, 9)
icon:SetPoint("CENTER")
icon:SetTexture(COIN)

local continents = {}
local function Continent(mapID)
    local found = continents[mapID]
    if found == nil then
        local info = C_Map.GetMapInfo(mapID)
        while info and info.mapType > Enum.UIMapType.Continent and info.parentMapID and info.parentMapID ~= 0 do
            info = C_Map.GetMapInfo(info.parentMapID)
        end
        found = info and info.mapID or false
        continents[mapID] = found
    end
    return found or nil
end

-- The target's spot on a continent and the continent's size only change when either changes
local cached = {}

-- Yards east and south from the player to the vendor, measured on the shared continent map
local function Offset()
    local mapID = C_Map.GetBestMapForUnit("player")
    local continent = mapID and Continent(mapID)
    if not continent then return end
    if cached.continent ~= continent then
        cached.continent = continent
        cached.vx, cached.vy = VA:PosOnMap(target, continent)
        cached.width, cached.height = C_Map.GetMapWorldSize(continent)
    end
    local player = C_Map.GetPlayerMapPosition(continent, "player")
    if not (player and cached.vx and cached.width and cached.width > 0) then return end
    local px, py = player:GetXY()
    return (cached.vx - px) * cached.width, (cached.vy - py) * cached.height
end

-- Minimap settings, refreshed when they can change rather than every update
local rotate, square
local function ReadSettings()
    rotate = GetCVar("rotateMinimap") == "1"
    square = GetMinimapShape and GetMinimapShape() == "SQUARE"
end

local function Update()
    local east, south = Offset()
    -- Different continent: keep the target but show nothing
    pin:EnableMouse(east ~= nil)
    if not east then
        pin:SetAlpha(0)
        return
    end

    local zoom = Minimap:GetZoom()
    local diameter = SIZES[IsIndoors() and "indoor" or "outdoor"][zoom + 1] or SIZES.outdoor[1]
    local scale = Minimap:GetWidth() / diameter
    local x, y = east * scale, -south * scale

    -- Rotating minimaps turn the world so your facing points up
    if rotate then
        local facing = GetPlayerFacing()
        if facing and not (issecretvalue and issecretvalue(facing)) then
            local s, c = math.sin(-facing), math.cos(-facing)
            x, y = x * c - y * s, x * s + y * c
        end
    end

    -- Beyond minimap range: park on the edge, dimmed
    local radius = Minimap:GetWidth() / 2 - 6
    local outside
    if square then
        outside = math.abs(x) > radius or math.abs(y) > radius
        x, y = math.max(-radius, math.min(radius, x)), math.max(-radius, math.min(radius, y))
    else
        local dist = math.sqrt(x * x + y * y)
        outside = dist > radius
        if outside then x, y = x / dist * radius, y / dist * radius end
    end

    pin:SetAlpha(outside and 0.6 or 1)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local elapsed = 0
pin:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < INTERVAL then return end
    elapsed = 0
    Update()
end)

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(target.name, 1, 0.82, 0)
    if target.title then GameTooltip:AddLine("<" .. target.title .. ">", 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(VA:LocationText(target), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click to remove", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- Removing the marker also takes the skull off the vendor, which needs the secure targeting
-- button laid over the pin while it's hovered
pin:SetScript("OnEnter", function(self)
    ShowTooltip(self)
    VA:AttachTargetButton(self, {
        rightClick = true,
        unmarkName = target.name,
        onEnter = ShowTooltip,
        onLeave = GameTooltip_Hide,
        onClick = function(_, button)
            if button == "RightButton" then VA:ClearMinimapVendor() end
        end,
    })
end)
pin:SetScript("OnLeave", function(self)
    if not VA:IsTargetOwner(self) then GameTooltip:Hide() end
end)

function VA:ClearMinimapVendor()
    target, VA.minimapKey = nil, nil
    pin:Hide()
    VA:RefreshMap()
end

pin:SetScript("OnClick", function() VA:ClearMinimapVendor() end)

function VA:SetMinimapVendor(vendor, key)
    if not (vendor and vendor.mapID) then return end
    target, VA.minimapKey = vendor, key
    wipe(cached)
    ReadSettings()
    icon:SetTexture(vendor.icon or COIN)
    if vendor.unverified then
        ring:SetVertexColor(0.9, 0.15, 0.1)
    else
        ring:SetVertexColor(0.85, 0.68, 0.2)
    end
    pin:Show()
    Update()
    VA:RefreshMap()
end

-- Reaching the vendor clears the pin
local events = CreateFrame("Frame")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("CVAR_UPDATE")
events:SetScript("OnEvent", function(_, event)
    if event == "CVAR_UPDATE" then
        ReadSettings()
    elseif target and UnitName("npc") == target.name then
        VA:ClearMinimapVendor()
    end
end)
