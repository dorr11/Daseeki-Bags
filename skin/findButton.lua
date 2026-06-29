--[[
	A button that opens the cross-character item search window.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local L = LibStub('AceLocale-3.0'):GetLocale(ADDON)
local Toggle = Addon.Tipped:NewClass('FindButton', 'Button', 'DaseekiBagsButtonTemplate')

function Toggle:New(parent)
	local b = self:Super(Toggle):New(parent)
	b.Icon:SetTexture('Interface/Icons/INV_Misc_Bag_07')
	return b
end

function Toggle:OnEnter()
	self:ShowTooltip(L.FindItem, L.FindItemTip)
end

function Toggle:OnClick()
	if not Addon.SearchResultsFrame then
		Addon.SearchResultsFrame = Addon.SearchResults:New(UIParent)
	elseif Addon.SearchResultsFrame:IsShown() then
		Addon.SearchResultsFrame:Hide()
	else
		Addon.SearchResultsFrame:Show()
		Addon.SearchResultsFrame.SearchBox:SetFocus()
	end
end
