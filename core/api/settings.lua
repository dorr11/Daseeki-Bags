--[[
	Initializes the settings, checks for version updates and provides the necessary API for profile management.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local VAR = 'DaseekiBagsSets'
local L = LibStub('AceLocale-3.0'):GetLocale(ADDON)
local Settings = Addon:NewModule('Settings')


--[[ Startup ]]--

function Settings:OnLoad()
	DaseekiBagsAccount = self:SetDefaults(DaseekiBagsAccount or {}, {account = {}})
	Addon.sets = self:SetDefaults(_G[VAR] or {}, Mixin({
		global = self:SetDefaults({}, self.ProfileDefaults),
		profiles = {}, customRules = {},
		namedProfiles = {}, characterActiveProfile = {},

		resetPlayer = true, flashFind = true,
		countItems = true, countCurrency = true,
		moneyTooltipFaction = false, moneyTooltipMinGold = 0,
		depositAccount = true, depositReagents = true,
		display = {
			banker = true, accountBanker = true, characterBanker = true, voidStorageBanker = true,
			auctioneer = true, blackMarketAuctioneer = true, mailInfo = true, merchant = true, vendor = true,
			transmogrifier = true, socketing = true, itemUpgrade = true,
			crafting = true, tradePartner = true,
			scrappingMachine = true, soulbind = true, itemInteraction = true,
		},

		glowAlpha = 0.5,
		glowQuality = true, glowNew = true, glowQuest = true, glowSets = true, glowUnusable = true, glowPoor = true,

		colorSlots = true,
		color = {
			normal = {1, 1, 1},
			account = {0.86, 1, .98},
			key = {1, .9, .19},
			quiver = {1, .87, .68},
			soul = {0.64, 0.39, 1},
			reagent = {1, .87, .68},
			leather = {1, .6, .45},
			enchant = {0.64, 0.83, 1},
			inscribe = {.64, 1, .82},
			engineer = {0.36, 0.68, 0.52},
			tackle = {0.42, 0.59, 1},
			fridge = {1, .5, .5},
			gem = {1, .65, .98},
			mine = {0.65, 0.53, 0.25},
			herb = {.5, 1, .5},
		}
	}, self.GlobalDefaults))

	for realm, owners in pairs(Addon.sets.profiles) do
		for id, profile in pairs(owners) do
			self:SetDefaults(profile, self.ProfileDefaults)
		end
	end
	
	_G[VAR] = Addon.sets
	self:Upgrade()

	-- Bootstrap named profiles: seed Default from current global on first run
	if not next(Addon.sets.namedProfiles) then
		Addon.sets.namedProfiles['Default'] = self:SnapshotProfile()
	end
	if not Addon.sets.namedProfiles[self:GetActiveProfile()] then
		self:SetActiveProfile('Default')
	end

	-- Apply this character's chosen profile so appearance reflects their selection
	self:ApplyNamedProfile(self:GetActiveProfile())

	-- Save current state back to the active profile snapshot on logout
	local logout = CreateFrame('Frame')
	logout:RegisterEvent('PLAYER_LOGOUT')
	logout:SetScript('OnEvent', function()
		Addon.Settings:SaveCurrentToProfile(Addon.Settings:GetActiveProfile())
	end)
end

function Settings:Upgrade() -- all code temporary, will be removed eventually
	xpcall(function()
		local OLD_KEYSTONE_FORMAT = '^' .. strrep('%d+:', 6) .. '%d+$'
		local OLD_PET_FORMAT = '^' .. strrep('%d+:', 7) .. '%d+$'

		local function upgradeItemFormat(data)
			for key, value in pairs(data) do
				local kind = type(value)
				if kind == 'table' then
					if (value.size or value.name or key == 'vault') and not value.items then
						local items = {}

						for k,v in pairs(value) do
							if type(k) ~= 'string' then
								items[k] = v
								value[k] = nil
							end
						end

						if next(items) then
							value.items = items
						end
					else
						value.tabNameEditBoxHeader, value.tabCleanupConfirmation = nil
						upgradeItemFormat(value)
					end
				elseif kind == 'string' then
					if value:find(OLD_KEYSTONE_FORMAT) then
						data[key] = 'keystone:' .. value
					elseif value:find(OLD_PET_FORMAT) then
						data[key] = 'battlepet:' .. value
					end
				end
			end
		end

		upgradeItemFormat(DaseekiBagsAccount)

		for _,realm in ipairs(GetKeysArray(DaseekiBagsAccount)) do
			local owners = DaseekiBagsAccount[realm]
			if type(owners) ~= 'table' then
				DaseekiBagsAccount[realm] = nil
			elseif realm ~= 'account' then
				for _,id in ipairs(GetKeysArray(owners)) do
					if type(id) ~= 'string' then
						owners[id] = nil
					end
				end
			end
		end
	end, function(...)
		print('|cff33ff99' .. ADDON .. '|r ' .. L.UpgradeError)
		geterrorhandler()(...)
	end)
end


--[[ Named Profile API ]]--

-- Keys stored directly on Addon.sets (from GlobalDefaults) that are per-profile appearance settings
local SHARED_PROFILE_KEYS = {'slotBackground', 'slotAlpha', 'slotBorderColor'}

local function playerKey()
	local name, realm = UnitFullName('player')
	name = name or UnitName('player') or '?'
	-- own-realm characters return a nil/empty realm here, and GetNormalizedRealmName()
	-- can itself be nil very early in login or during logout — fall back safely.
	if not realm or realm == '' then
		realm = (GetNormalizedRealmName and GetNormalizedRealmName())
		     or (GetRealmName and GetRealmName() and GetRealmName():gsub('%s+', ''))
		     or ''
	end
	return name .. '-' .. realm
end

function Settings:GetActiveProfile()
	local name = Addon.sets.characterActiveProfile[playerKey()]
	if name and Addon.sets.namedProfiles[name] then return name end
	return 'Default'
end

function Settings:SetActiveProfile(name)
	Addon.sets.characterActiveProfile[playerKey()] = name
end

local function serializeValue(val)
	local t = type(val)
	if t == 'number' then return tostring(val)
	elseif t == 'boolean' then return tostring(val)
	elseif t == 'string' then return string.format('%q', val)
	elseif t == 'table' then
		local parts = {}
		for k, v in pairs(val) do
			local sv = serializeValue(v)
			if sv then
				local sk = type(k) == 'number' and ('[' .. k .. ']') or ('[' .. string.format('%q', k) .. ']')
				tinsert(parts, sk .. '=' .. sv)
			end
		end
		return '{' .. table.concat(parts, ',') .. '}'
	end
end

function Settings:SnapshotProfile()
	local snapshot = {global = CopyTable(Addon.sets.global)}
	for _, key in ipairs(SHARED_PROFILE_KEYS) do
		local v = Addon.sets[key]
		snapshot[key] = type(v) == 'table' and CopyTable(v) or v
	end
	return snapshot
end

function Settings:ApplyNamedProfile(name)
	local saved = Addon.sets.namedProfiles[name]
	if not saved then return end

	-- Support old format (flat CopyTable of global, no .global wrapper key)
	local savedGlobal = saved.global or saved

	-- Repopulate each per-frame table in-place (preserving existing references)
	for frame, frameDefaults in pairs(self.ProfileDefaults) do
		local target = Addon.sets.global[frame]
		if target then
			wipe(target)
			local src = savedGlobal[frame]
			if src then
				for k, v in pairs(src) do
					target[k] = type(v) == 'table' and CopyTable(v) or v
				end
			end
			self:SetDefaults(target, frameDefaults)
		end
	end

	-- Restore shared appearance keys (new format only; old format didn't capture these)
	if saved.global then
		for _, key in ipairs(SHARED_PROFILE_KEYS) do
			if saved[key] ~= nil then
				local v = saved[key]
				Addon.sets[key] = type(v) == 'table' and CopyTable(v) or v
			end
		end
	end

	self:SetActiveProfile(name)
	if Addon.Frames then
		Addon.Frames:Update()
	end
end

function Settings:SaveCurrentToProfile(name)
	Addon.sets.namedProfiles[name] = self:SnapshotProfile()
end

function Settings:DeleteProfile(name)
	if name == 'Default' then return end
	Addon.sets.namedProfiles[name] = nil
	if self:GetActiveProfile() == name then
		self:ApplyNamedProfile('Default')
	end
end

function Settings:ExportProfile(name)
	self:SaveCurrentToProfile(name)
	local snapshot = Addon.sets.namedProfiles[name]
	if not snapshot then return nil end
	return serializeValue({name = name, data = snapshot})
end

function Settings:ImportProfile(encoded)
	local fn, err = loadstring('return ' .. encoded)
	if not fn then return nil, err end
	local ok, result = pcall(fn)
	if not ok or type(result) ~= 'table' then return nil, 'Invalid data.' end
	local name = result.name
	local data = result.data
	if type(name) ~= 'string' or name == '' or type(data) ~= 'table' then
		return nil, 'Missing name or data.'
	end
	-- Ensure new snapshot format
	if not data.global then
		data = {global = data}
	end
	Addon.sets.namedProfiles[name] = data
	return name
end


--[[ Character Profile API ]]--

function Settings:SetProfile(realm, id, profile)
	realm = GetOrCreateTableEntry(Addon.sets.profiles, realm)
	realm[id] = profile and self:SetDefaults(profile, self.ProfileDefaults)
end

function Settings:GetProfile(realm, id)
	realm = Addon.sets.profiles[realm]
	return realm and realm[id] or Addon.sets.global
end