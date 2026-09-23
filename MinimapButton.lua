-- MinimapButton.lua
-- Flat DUI-styled launcher on the minimap rim.
-- Left-click toggles the main window (/dan), right-click the inspect/ready
-- check panel (/duirc), drag moves it around the rim.

local btn

local function UpdatePosition()
    local angle = math.rad(DanUIDB.MinimapButton.angle or 220)
    local radius = (Minimap:GetWidth() / 2) + 5
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function DUI_InitMinimapButton()
    if btn then return end
    DanUIDB.MinimapButton = DanUIDB.MinimapButton or { angle = 220 }

    btn = CreateFrame("Button", "DUI_MinimapButton", Minimap)
    btn:SetSize(22, 22)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(Minimap:GetFrameLevel() + 8)

    -- Custom DUI icon (pre-downscaled 64x64 PNG with a transparent circular edge).
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\AddOns\\DanUI\\MinimapIcon.png")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if DUI_ReadyCheckFrame and DUI_ReadyCheckFrame:IsShown() then
                DUI_ReadyCheckFrame:Hide()
            elseif DUI_ReadyCheckFrame then
                DUI_ReadyCheckFrame:Show()
                if UpdateRCWindow then UpdateRCWindow() end
            end
        else
            if DUI_MainFrame:IsShown() then DUI_MainFrame:Hide() else DUI_MainFrame:Show() end
            if UpdateFloatingBar then UpdateFloatingBar() end
        end
    end)

    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            DanUIDB.MinimapButton.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            UpdatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Dan UI", 1, 1, 1)
        GameTooltip:AddLine("Left-click: toggle the DUI window.", nil, nil, nil, true)
        GameTooltip:AddLine("Right-click: raid inspection panel.", nil, nil, nil, true)
        GameTooltip:AddLine("Drag: move this button.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
end
