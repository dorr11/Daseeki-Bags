--[[
	Defines keybindings and a slash command menu.
	All Rights Reserved
--]]


local ADDON, Addon = ...
local Slash = Addon:NewModule('Commands')
local L = LibStub('AceLocale-3.0'):GetLocale(ADDON)


--[[ Keybindings ]]--

do
	local ADDON_UPPER = ADDON:upper():gsub('-', '')
	_G['BINDING_HEADER_' .. ADDON_UPPER] = ADDON
	_G['BINDING_NAME_' .. ADDON_UPPER .. '_TOGGLE'] = L.OpenBags
	_G['BINDING_NAME_' .. ADDON_UPPER .. '_BANK_TOGGLE'] = L.OpenBank
	_G['BINDING_NAME_' .. ADDON_UPPER .. '_VAULT_TOGGLE'] = L.OpenVault
end


--[[ Slash Commands ]]--

function Slash:OnLoad()
	SlashCmdList[ADDON] = self.OnSlashCommand
	_G['SLASH_'..ADDON..'1'] = '/' .. ADDON
	_G['SLASH_'..ADDON..'2'] = '/dbg'
end

function Slash.OnSlashCommand(cmd)
	local cmd = cmd and cmd:lower()
	if cmd == 'bags' or cmd == 'inventory' then
		Addon.Frames:Toggle('inventory')
	elseif cmd == 'bank' then
		Addon.Frames:Toggle('bank')
	elseif cmd == 'vault' then
		Addon.Frames:Toggle('vault')
	elseif cmd == 'version' then
		print('|cff33ff99' .. ADDON .. '|r version ' .. LibStub('C_Everywhere').AddOns.GetAddOnMetadata(ADDON, 'version'))
	elseif cmd == 'mesh' then
		Slash:PrintMeshStatus()
	elseif cmd == 'mesh send' then
		Slash:MeshTestSend()
	elseif cmd == 'mesh clear' then
		Slash:MeshClear()
	elseif cmd:match('^mesh item %d+$') then
		Slash:MeshItem(tonumber(cmd:match('(%d+)$')))
	elseif cmd == 'config' or cmd == 'options' then
		Addon:ShowOptions()
	elseif cmd == 'reset' then
		Slash:ResetSettings()
	else
		Slash:PrintHelp()
	end
end

function Slash:ResetSettings()
	LibStub('Sushi-3.2').Popup {
		icon = 'Interface/Addons/Daseeki-Bags/Art/' .. ADDON .. '-big',
		text = format(L.ResetConfirm, ADDON), button1 = OKAY, button2 = CANCEL,
		whileDead = 1, exclusive = 1, hideOnEscape = 1,
		OnAccept = function()
			wipe(DaseekiBagsAccount)
			wipe(Addon.sets)
			ReloadUI()
		end
	}
end

function Slash:MeshTestSend()
	local tag = '|cff33ff99' .. ADDON .. '|r'
	print(tag .. ' Mesh: forcing gold push now...')
	if Addon.MeshSync then
		Addon.MeshSync:PushAll()
		print(tag .. ' Mesh: full account snapshot sent (if channel was joined). Watch for "Remote owners" appearing on the other account via /dbg mesh.')
	else
		print(tag .. ' Mesh: MeshSync module not found.')
	end
end

function Slash:PrintMeshStatus()
	local tag = '|cff33ff99' .. ADDON .. '|r'
	local token = Addon.sets and Addon.sets.meshToken
	print(tag .. ' Cross-Account Sync status:')
	print('  Token: ' .. (token and token ~= '' and ('|cff00ff00' .. token .. '|r') or '|cffff0000not set|r'))
	local ch = Addon.sets and Addon.sets.meshChannel
	local chanName = token and token ~= '' and ((ch and ch ~= '') and ch or ('DBagSync' .. token)) or nil
	local chanNum = chanName and GetChannelName(chanName) or nil
	if chanName then
		local label = (ch and ch ~= '') and '' or ' (auto)'
		if chanNum and chanNum > 0 then
			local members = GetNumChannelMembers(chanNum) or 0
			print('  Channel: ' .. chanName .. label .. ' — |cff00ff00joined (#' .. chanNum .. ', ' .. members .. ' API members)|r')
		else
			print('  Channel: ' .. chanName .. label .. ' — |cffff0000not in channel|r')
		end
	else
		print('  Channel: |cffff0000set a token first|r')
	end
	local rosterCount = 0
	if Addon.MeshSync and Addon.MeshSync._GetRoster then
		for name in pairs(Addon.MeshSync._GetRoster()) do
			rosterCount = rosterCount + 1
			print('  Live roster: |cff00ff00' .. name .. '|r')
		end
	end
	if rosterCount == 0 then print('  Live roster: |cffff8800empty (waiting for JOIN events or API poll)|r') end
	local invOk = Addon.MeshTransport and Addon.MeshTransport:IsAvailable()
	print('  Item/Currency sync: ' .. (invOk and '|cff00ff00enabled|r' or '|cffff0000disabled (LibSerialize/LibDeflate missing)|r'))
	local remotes = 0
	for _, owner in Addon.Owners:Iterate() do
		if owner.meshRemote then
			remotes = remotes + 1
			local c = owner.cache or {}
			local copper = c.money
			local items = 0
			if c.itemCounts then for _ in pairs(c.itemCounts) do items = items + 1 end end
			print(format('  Remote: %s-%s = %s | %d items | rev %s',
				owner.name, owner.realm,
				copper and GetMoneyString(copper) or 'no gold',
				items, tostring(c.rev or '-')))
		end
	end
	if remotes == 0 then print('  Remote owners: none received yet') end
	print('  (use /dbg mesh send to push gold, /dbg mesh clear to wipe remote data)')
end

-- Debug: dump what every owner reports for a given itemID (in-memory truth).
function Slash:MeshItem(id)
	local tag = '|cff33ff99' .. ADDON .. '|r'
	print(format('%s Owners holding item %d:', tag, id))
	local any = false
	for _, owner in Addon.Owners:Iterate() do
		local kind, count
		if owner.meshRemote then
			kind = 'REMOTE'
			count = owner.itemCounts and owner.itemCounts[id]
		elseif owner.isguild then
			kind = 'guild'
		else
			kind = owner.offline and 'local-offline' or 'local-online'
		end
		if count and count > 0 then
			any = true
			local fac = owner.faction or '?'
			print(format('  %s-%s [%s, %s] = %d', owner.name, owner.realm or '?', kind, fac, count))
		end
	end
	if not any then print('  (no REMOTE owner reports this item in itemCounts)') end
	print(format('  faction filter is %s; your faction = %s',
		Addon.sets.moneyTooltipFaction and '|cffff8800ON|r' or 'off', Addon.player.faction or '?'))
end

function Slash:MeshClear()
	local tag = '|cff33ff99' .. ADDON .. '|r'
	LibStub('Sushi-3.2').Popup {
		text = 'Wipe all cross-account (mesh) data received from other accounts? Your own characters are unaffected.',
		button1 = OKAY, button2 = CANCEL, whileDead = 1, hideOnEscape = 1,
		OnAccept = function()
			wipe(DaseekiBagsMesh)
			print(tag .. ' Mesh: remote data cleared. Reload to fully reset in-memory owners.')
		end,
	}
end

function Slash:PrintHelp()
	print('|cff33ff99' .. ADDON .. '|r ' .. L.Commands)
	self:Print('bags', L.CmdShowInventory)
	self:Print('bank', L.CmdShowBank)
	self:Print('vault', L.CmdShowVault, Addon.LoadVault)
	self:Print('config/options', L.CmdShowOptions)
	self:Print('reset', L.CmdReset)
	self:Print('version', L.CmdShowVersion)
end

function Slash:Print(cmd, desc, requirement)
	if requirement ~= false then
		print(format(' - |cFF33FF99%s|r: %s', cmd, desc))
	end
end
