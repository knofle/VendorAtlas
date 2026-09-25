local addonName, VA = ...

-- Fonts ------------------------------------------------------------------
-- Copies of the Blizzard font objects we use, switched to the addon's font.

local FONT = "Interface\\AddOns\\" .. addonName .. "\\fonts\\Expressway.ttf"

-- Earthy palette shared by the window and the map widgets
VA.COLORS = {
    accent = { 0.80, 0.69, 0.52 },   -- sand: titles, selection, highlights
    text = { 0.86, 0.80, 0.70 },     -- warm off-white for "Normal" fonts
    border = { 0.36, 0.31, 0.25 },   -- muted bronze
    bg = { 0.105, 0.095, 0.085 },    -- warm charcoal
    header = { 0.17, 0.15, 0.125 },  -- lighter band behind the title
    inset = { 0.065, 0.06, 0.055 },  -- list and tree wells
    button = { 0.17, 0.15, 0.125 },
    buttonTop = { 0.235, 0.205, 0.17 },
}
-- Tiled grain laid over flat backgrounds
VA.GRAIN = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark"

for _, name in ipairs({
    "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge",
    "GameFontHighlight", "GameFontHighlightSmall",
    "GameFontDisable", "GameFontDisableSmall", "GameFontDisableLarge",
    "ChatFontNormal",
}) do
    local font = CreateFont("VA_" .. name)
    font:CopyFontObject(_G[name])
    local _, size, flags = font:GetFont()
    font:SetFont(FONT, size, flags)
    -- Blizzard's "Normal" fonts are gold; use the warm off-white instead
    if name:find("Normal", 1, true) and name ~= "ChatFontNormal" then
        font:SetTextColor(unpack(VA.COLORS.text))
    end
end

local db
local scanPending, scanIncomplete, scanAttempts = false, false, 0

-- Helpers ---------------------------------------------------------------

local function VendorKey()
    local name = UnitName("npc")
    if not name then return end
    local guid = UnitGUID("npc")
    if guid and not (issecretvalue and issecretvalue(guid)) then
        local unitType, _, _, _, _, npcID = strsplit("-", guid)
        if unitType == "Creature" or unitType == "Vehicle" or unitType == "GameObject" then
            return tonumber(npcID), name
        end
    end
    return name, name
end

local function MerchantItem(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if info then
            return info.name, info.texture, info.price, info.numAvailable, info.hasExtendedCost
        end
    elseif GetMerchantItemInfo then
        local name, texture, price, _, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
        return name, texture, price, numAvailable, extendedCost
    end
end

-- Returns cost text, and whether it is paid in honor or battleground marks
local function ExtendedCost(i)
    local parts, pvp = {}, false
    for c = 1, GetMerchantItemCostInfo(i) or 0 do
        local texture, amount, link, currencyName = GetMerchantItemCostItem(i, c)
        if texture and amount then
            parts[#parts + 1] = amount .. " |T" .. texture .. ":0|t"
        end
        if strlower(currencyName or link or ""):find("honor", 1, true) then pvp = true end
    end
    return #parts > 0 and table.concat(parts, " ") or nil, pvp
end

local function ZoneOf(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    while info and info.mapType > Enum.UIMapType.Zone and info.parentMapID and info.parentMapID ~= 0 do
        info = C_Map.GetMapInfo(info.parentMapID)
    end
    return info and info.mapID
end

-- Takes over the Classic seed for this vendor when the in-game ID differs from the Classic one,
-- matching by name in the same zone. Its offers move to the new key until the scan replaces them.
local function AdoptSeed(key, name, zone)
    for seedID, seed in pairs(db.vendors) do
        if seedID ~= key and seed.unverified and seed.name == name and (not seed.mapID or seed.mapID == zone) then
            db.vendors[seedID] = nil
            for itemID in pairs(seed.items) do
                local item = db.items[itemID]
                if item and item.vendors[seedID] then
                    item.vendors[key] = item.vendors[key] or item.vendors[seedID]
                    item.vendors[seedID] = nil
                end
            end
            seed.seedID = seedID
            return seed
        end
    end
end

function VA:ZoneOf(mapID)
    return ZoneOf(mapID)
end

-- Scanning --------------------------------------------------------------

function VA:ScanMerchant()
    scanPending = false
    local key, vendorName = VendorKey()
    if not key then return end

    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")

    local vendor = db.vendors[key]
    local seed = AdoptSeed(key, vendorName, ZoneOf(mapID))
    if not vendor then
        vendor = seed or { items = {} }
    elseif seed then
        vendor.seedID = seed.seedID
        for itemID in pairs(seed.items) do vendor.items[itemID] = true end
    end
    db.vendors[key] = vendor
    vendor.name = vendorName
    vendor.lastSeen = time()
    vendor.unverified, vendor.shipped = nil, nil

    if pos then
        vendor.mapID, vendor.x, vendor.y = mapID, pos:GetXY()
    end

    -- Class filter hides items from the merchant list, so scan unfiltered
    local oldFilter
    if GetMerchantFilter and SetMerchantFilter and LE_LOOT_FILTER_ALL then
        oldFilter = GetMerchantFilter()
        if oldFilter ~= LE_LOOT_FILTER_ALL then
            SetMerchantFilter(LE_LOOT_FILTER_ALL)
        else
            oldFilter = nil
        end
    end

    local seen, complete = {}, true
    for i = 1, GetMerchantNumItems() do
        local itemID = GetMerchantItemID(i)
        local name, icon, price, numAvailable, hasCost = MerchantItem(i)
        if itemID and name then
            seen[itemID] = true
            local item = db.items[itemID] or { vendors = {} }
            db.items[itemID] = item
            item.name, item.icon = name, icon
            item.link = GetMerchantItemLink(i) or item.link
            item.quality = item.quality or C_Item.GetItemQualityByID(itemID)
            local cost, pvp
            if hasCost then cost, pvp = ExtendedCost(i) end
            item.vendors[key] = {
                price = price,
                cost = cost,
                pvp = pvp or nil,
                limited = (numAvailable and numAvailable >= 0) or nil,
            }
            VA:QueueAutoCategorize(itemID)
        else
            complete = false
        end
    end

    if oldFilter then SetMerchantFilter(oldFilter) end

    if complete then
        -- Drop items this vendor no longer sells
        for itemID in pairs(vendor.items) do
            local item = not seen[itemID] and db.items[itemID]
            if item then
                item.vendors[key] = nil
                if not next(item.vendors) then db.items[itemID] = nil end
            end
        end
        vendor.items = seen
    else
        for itemID in pairs(seen) do vendor.items[itemID] = true end
    end

    scanIncomplete = not complete
    self:OnDataChanged()
end

local function QueueScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(0.3, function()
        if MerchantFrame and MerchantFrame:IsShown() then VA:ScanMerchant() end
        scanPending = false
    end)
end

-- Shared formatting -------------------------------------------------------

function VA:MoneyText(copper)
    if GetMoneyString then return GetMoneyString(copper, true) end
    return C_CurrencyInfo.GetCoinTextureString(copper)
end

VA.UNVERIFIED = "|cffff5a4dunverified|r"

function VA:OfferVisible(offer)
    return not (offer.unverified and self.db.hideUnverified)
end

function VA:ItemVisible(item)
    for _, offer in pairs(item.vendors) do
        if self:OfferVisible(offer) then return true end
    end
    return false
end

function VA:PriceText(offer)
    if offer.unverified then return self.UNVERIFIED end
    local text = offer.cost
    if offer.price and offer.price > 0 then
        text = text and (self:MoneyText(offer.price) .. " " .. text) or self:MoneyText(offer.price)
    end
    text = text or "Free"
    if offer.limited then text = text .. " |cffff8040(limited)|r" end
    return text
end

function VA:LocationText(vendor)
    local info = vendor.mapID and C_Map.GetMapInfo(vendor.mapID)
    if not info then return "Unknown location" end
    return ("%s %.1f, %.1f"):format(info.name, vendor.x * 100, vendor.y * 100)
end

function VA:ZoneName(vendor)
    local info = vendor.mapID and C_Map.GetMapInfo(vendor.mapID)
    return info and info.name or "Unknown"
end

-- Events ------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_UPDATE")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        VendorAtlasDB = VendorAtlasDB or {}
        db = VendorAtlasDB
        db.vendors = db.vendors or {}
        db.items = db.items or {}
        db.hiddenVendors = db.hiddenVendors or {}
        db.verifiedServices = db.verifiedServices or {}
        VA.db = db
        VA:InitCategories()
        events:UnregisterEvent("ADDON_LOADED")
    elseif event == "MERCHANT_SHOW" then
        scanAttempts = 0
        VA:ScanMerchant()
    elseif scanIncomplete and not scanPending and scanAttempts < 5 then
        -- Retry only while item data is still loading
        scanAttempts = scanAttempts + 1
        QueueScan()
    end
end)
