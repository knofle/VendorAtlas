local addonName, VA = ...

-- Minimap button through LibDataBroker + LibDBIcon.
-- Left-click toggles the window, shift-right-click hides the button (/va minimap brings it back).

local ICON = "Interface\\AddOns\\" .. addonName .. "\\icon"
local PREFIX = "|cffccb084Vendor Atlas:|r "

local DBIcon

function VA:SetMinimapButtonShown(show)
    if not DBIcon then return end
    self.db.minimapButton.hide = not show
    if show then
        DBIcon:Show(addonName)
    else
        DBIcon:Hide(addonName)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then return end

    -- LibDBIcon keeps the button's position and hidden state here
    VA.db.minimapButton = VA.db.minimapButton or {}

    local launcher = LDB:NewDataObject(addonName, {
        type = "launcher",
        text = "Vendor Atlas",
        icon = ICON,
        OnClick = function(_, button)
            if button == "RightButton" and IsShiftKeyDown() then
                VA:SetMinimapButtonShown(false)
                print(PREFIX .. "minimap button hidden. Type /va minimap to show it again.")
            elseif button == "LeftButton" then
                VA:Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Vendor Atlas")
            tooltip:AddLine("Left-click: open or close", 1, 1, 1)
            tooltip:AddLine("Shift-right-click: hide this button", 1, 1, 1)
        end,
    })
    DBIcon:Register(addonName, launcher, VA.db.minimapButton)
end)
