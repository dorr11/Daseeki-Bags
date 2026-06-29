--[[
	A options frame toggle button.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local Toggle = Addon.Tipped:NewClass('OptionsToggle', 'Button', 'DaseekiBagsButtonTemplate')

function Toggle:New(parent)
	local b = self:Super(Toggle):New(parent)
	b.Icon:SetTexture('Interface/Icons/Trade_Engineering')
	return b
end

function Toggle:OnClick()
	Addon.GeneralOptions.frame = self:GetFrameID()
	Addon:ShowOptions()
end

function Toggle:OnEnter()
	self:ShowTooltip(OPTIONS)
end
