--[[
	Component proprieties to implement a dynamic frame with a static item grid.
	All Rights Reserved
--]]

local ADDON, Addon = ...

function Addon.ItemGroup:LayoutTraits()
	local profile = self:GetProfile()
	return profile.columns, profile.itemScale, 37 + profile.spacing, self.Transposed
end

function Addon.TabGroup:LayoutTraits()
	return 0,1, 0,6
end

function Addon.CurrencyTracker:MaxWidth()
	return self.frame.ItemGroup:GetWidth() - 20
end

-- Slot count display (free/total) replacing the data broker carrousel
local SlotCount = Addon.Base:NewClass('SlotCount', 'Frame')

function SlotCount:New(parent)
	local f = self:Super(SlotCount):New(parent)
	f.frame = parent

	f.Text = f:CreateFontString(nil, 'OVERLAY', 'NumberFontNormalRight')
	f.Text:SetJustifyH('CENTER')
	f.Text:SetAllPoints()

	local listener = CreateFrame('Frame')
	listener:SetScript('OnEvent', function() f:Update() end)
	listener:RegisterEvent('BAG_UPDATE_DELAYED')
	listener:RegisterEvent('PLAYER_LOGIN')
	f.listener = listener

	f:Update()
	return f
end

function SlotCount:Update()
	local bags = self.frame and self.frame.Bags
	if not bags then return end

	local free, total = 0, 0
	for _, bag in ipairs(bags) do
		local size = C_Container and C_Container.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)
		if size and size > 0 then
			local numFree = C_Container and C_Container.GetContainerNumFreeSlots(bag) or GetContainerNumFreeSlots(bag)
			total = total + size
			free = free + (numFree or 0)
		end
	end

	self.Text:SetText(total > 0 and (free .. '/' .. total) or '')
end