--[[
	Shared helpers for decoding cached item slot data.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local C = LibStub('C_Everywhere').Item

function Addon:ParseSlotItem(data)
	local prefix = data:sub(1,9)
	if prefix == 'battlepet' then
		local id, quality = data:match(':(%d+):%d+:(%d+)')
		local id, quality = tonumber(id), tonumber(quality) or 1
		local name, icon = C_PetJournal.GetPetInfoBySpeciesID(id)

		return { itemID = id, iconFileID = icon, quality = quality,
		         hyperlink = format('%s|H%sx0|h[%s]|h|r', ITEM_QUALITY_COLORS[quality].hex, data, name) }
	elseif prefix == 'keystone:' then
		local id = tonumber(data:match(':(%d+)'))
		local _, _, _, _, icon = C.GetItemInfoInstant(id)
		local _, link, quality = C.GetItemInfo(id)

		return { itemID = id, iconFileID = icon, quality = quality,
		         hyperlink = link:gsub('item[:%d]+', data, 1) }
	else
		local values, count = strsplit(';', data)
		local link = 'item:' .. values
		local id, _, _, _, icon = C.GetItemInfoInstant(link)
		local _, link, quality = C.GetItemInfo(link)

		return { itemID = id, iconFileID = icon, quality = quality, hyperlink = link,
		         stackCount = tonumber(count) or 1 }
	end
end
