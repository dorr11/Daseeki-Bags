--[[
	Automatic display settings menu.
	All Rights Reserved
--]]

local L, ADDON, Addon = select(2, ...).Addon()

local function AddOption(self, ...)
	return self:AddCheck(...):SetWidth(250)
end

function Addon.PopulateDisplayOptions(self)
	self.sets = Addon.sets.display
	self:AddSectionHeader(L.DisplayInventory)
	self:AddRow(35*6, function()
		AddOption(self,'banker', 'accountBanker', 'characterBanker')
		AddOption(self,'voidStorageBanker')

		AddOption(self,'auctioneer', 'blackMarketAuctioneer')
		AddOption(self,'merchant', 'vendor')
		AddOption(self,'mailInfo')

		AddOption(self,'tradePartner')
		AddOption(self,'crafting')
		AddOption(self,'transmogrifier', 'socketing', 'itemUpgrade', 'itemInteraction')
		AddOption(self,'character')
	end)

	self:AddSectionHeader(L.CloseInventory)
	self:AddRow(35*3, function()
		for i, event in ipairs {'mapFrame', 'combat', 'vehicle'} do
			AddOption(self,event)
		end
	end)

	self:AddSectionHeader(OTHER)
	Addon.PopulateColorSlots(self)
end