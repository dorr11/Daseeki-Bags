--[[
	Daseeki-Bags default settings.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local function AsArray(table)
	return setmetatable(table, {__metatable = false})
end

local FrameDefaults = {
	enabled = true,
	bagToggle = true, sort = true, serverSort = true, search = true, options = true, money = true, broker = true,
	
	strata = 'HIGH', alpha = 1, scale = 1,
	color = {0, 0, 0, 0.85},
	borderColor = {0.3, 0.3, 0.3, 1},
	x = 0, y = 0,

	itemScale = 1, bagScale = 1, spacing = 2,
	bagBreak = 1, breakSpace = 1.3,

	rules = {sidebar = AsArray({'all', 'tradegoods', 'consumable', 'armor', 'questitem', 'miscellaneous'})},
	activeRules = {}, brokerObject = ADDON .. 'Launcher',
    skin = Addon.Skins.Default,
}

Addon.Settings.ProfileDefaults = {
	inventory = Addon:SetDefaults({
		rules = {sidebar = AsArray({'all', 'normal', 'trade'})},
		currency = true,
		point = 'BOTTOMRIGHT',
		x = -50, y = 100,
		columns = 10,
	}, FrameDefaults),

	bank = Addon:SetDefaults({
		rules = Addon.IsRetail and {sidebar = AsArray({'all', 'player', 'account'})},
		columns = Addon.IsRetail and 22 or 14,
		sidebar = Addon.IsRetail,
		deposit = true, currency = true,
		point = 'LEFT',
		x = 95
	}, FrameDefaults),

	vault = Addon:SetDefaults({
		point = 'LEFT',
		columns = 16,
		x = 95
	}, FrameDefaults),

	guild = Addon:SetDefaults({
		point = 'CENTER',
		columns = 7,
	}, FrameDefaults)
}

Addon.Settings.GlobalDefaults = {
	slotBackground = 2,
	slotAlpha = 1,
	slotBorderColor = {1, 1, 1, 0},
}