--[[
	Searches every stored character and guild bank for matching items.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local L = LibStub('AceLocale-3.0'):GetLocale(ADDON)
local Search = LibStub('ItemSearch-1.3')
local Finder = Addon:NewModule('ItemFinder')

function Finder:Find(query)
	if not query or query == '' then
		return {}
	end

	local totals = {}

	local function scan(owner, location, items)
		for slot, data in pairs(items or Addon.None) do
			local ok, info = pcall(Addon.ParseSlotItem, Addon, data)
			if ok and info.hyperlink and Search:Matches(info.hyperlink, query) then
				local key = tostring(info.itemID) .. '\0' .. tostring(owner) .. '\0' .. location
				if totals[key] then
					totals[key].count = totals[key].count + (info.stackCount or 1)
				else
					totals[key] = {
						owner = owner,
						location = location,
						itemID = info.itemID,
						hyperlink = info.hyperlink,
						icon = info.iconFileID,
						quality = info.quality,
						count = info.stackCount or 1,
					}
				end
			end
		end
	end

	for _, owner in Addon.Owners:Iterate() do
		for _, bag in ipairs(Addon.InventoryBags) do
			local data = owner[bag]
			scan(owner, L.Bags, data and data.items)
		end

		for _, bag in ipairs(Addon.BankBags) do
			local data = owner[bag]
			scan(owner, L.Bank, data and data.items)
		end

		scan(owner, L.Mail, owner.mail)
		scan(owner, L.Equipped, owner.equip)
		scan(owner, L.VoidStorage, owner.vault and owner.vault.items)
	end

	local results = {}
	for _, entry in pairs(totals) do
		tinsert(results, entry)
	end
	return results
end
