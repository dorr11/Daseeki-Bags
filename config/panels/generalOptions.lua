--[[
	General settings menu.
	All Rights Reserved
--]]

local L, ADDON, Addon, Config = select(2, ...).Addon()
local General = Addon.OptionsPanel('GeneralOptions', '|TInterface/Addons/Daseeki-Bags/Art/'..ADDON..'-Small:16:16|t')

function General:Populate()
	self.sets = Addon.sets

	local colW2 = math.floor((self:GetWidth() or 610) / 2)
	local function add2Col(height, f1, f2)
		self:AddRow(height, function()
			local row = self.row
			for _, fn in ipairs{f1, f2} do
				local col = row:Add('Group')
				col:SetWidth(colW2)
				col:SetHeight(height)
				col:SetChildren(function()
					self.row = col
					fn()
					self.row = row
				end)
			end
		end)
	end

	add2Col(35,
		function() self:AddCheck('locked') end,
		function()
			self:AddLabeled('Check', 'characterSpecific')
				:SetCall('OnInput', function() self:ToggleGlobals() end)
				:SetChecked(Addon.player.profile ~= Addon.sets.global)
		end
	)

	self:AddSectionHeader(GENERAL)
	Addon.PopulateComponentToggles(self)

	self:AddSectionHeader(L.Tooltips)
	add2Col(90,
		function()
			self:AddCheck('countItems')
			self:AddCheck('countCurrency')
		end,
		function()
			self:AddCheck('moneyTooltipFaction')
			self:AddSlider('moneyTooltipMinGold', 0, 1000)
		end
	)

	self:AddSectionHeader(L.FrameOptions)
	Addon.PopulateFrameOptions(self)
	Addon.PopulateBackground(self)

	self:AddSectionHeader(L.SlotOptions)
	Addon.PopulateSlotOptions(self)
	Addon.PopulateDisplayOptions(self)

	self:AddSectionHeader(L.Database)

	add2Col(200,
		function()
			-- Column 1: Named profiles
			local profilePicker = self.row:Add('DropChoice', L.ActiveProfile)
			local function refreshProfiles()
				profilePicker.choices = {}
				local names = {}
				for name in pairs(Addon.sets.namedProfiles) do tinsert(names, name) end
				sort(names)
				for _, name in ipairs(names) do
					profilePicker:AddChoices(name, name)
				end
				profilePicker:SetValue(Addon.Settings:GetActiveProfile())
			end
			refreshProfiles()
			profilePicker:SetCall('OnValue', function(_, name)
				if name and name ~= Addon.Settings:GetActiveProfile() then
					Addon.Settings:SaveCurrentToProfile(Addon.Settings:GetActiveProfile())
					Addon.Settings:ApplyNamedProfile(name)
					self:Update()
				end
			end)

			self.row:Add('GrayButton', L.NewProfile):SetCall('OnClick', function()
				StaticPopupDialogs['DASEEKI_BAGS_NEW_PROFILE'] = {
					text = L.NewProfilePrompt, button1 = OKAY, button2 = CANCEL,
					hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
					OnAccept = function(dialog)
						local name = strtrim(dialog.EditBox:GetText())
						if name ~= '' and not Addon.sets.namedProfiles[name] then
							Addon.Settings:SaveCurrentToProfile(name)
							Addon.Settings:SetActiveProfile(name)
							refreshProfiles()
						end
					end,
				}
				StaticPopup_Show('DASEEKI_BAGS_NEW_PROFILE')
			end)

			self.row:Add('GrayButton', L.CopyProfile):SetCall('OnClick', function()
				StaticPopupDialogs['DASEEKI_BAGS_COPY_PROFILE'] = {
					text = L.CopyProfilePrompt:format(Addon.Settings:GetActiveProfile()),
					button1 = OKAY, button2 = CANCEL,
					hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
					OnAccept = function(dialog)
						local name = strtrim(dialog.EditBox:GetText())
						if name ~= '' and not Addon.sets.namedProfiles[name] then
							Addon.Settings:SaveCurrentToProfile(name)
							refreshProfiles()
						end
					end,
				}
				StaticPopup_Show('DASEEKI_BAGS_COPY_PROFILE')
			end)

			self.row:Add('RedButton', L.DeleteProfile):SetCall('OnClick', function()
				local name = Addon.Settings:GetActiveProfile()
				if name == 'Default' then return end
				LibStub('Sushi-3.2').Popup {
					text = L.ConfirmDeleteProfile:format(name),
					button1 = OKAY, button2 = CANCEL,
					OnAccept = function()
						Addon.Settings:DeleteProfile(name)
						self:Update()
					end
				}
			end)

			self.row:Add('GrayButton', L.ExportProfile):SetCall('OnClick', function()
				local encoded = Addon.Settings:ExportProfile(Addon.Settings:GetActiveProfile())
				if encoded then
					LibStub('Sushi-3.2').Popup:New {
						id = ADDON .. 'ExportProfile',
						text = L.ExportProfilePopup,
						button1 = OKAY,
						editBox = encoded,
					}
				end
			end)

			self.row:Add('GrayButton', L.ImportProfile):SetCall('OnClick', function()
				LibStub('Sushi-3.2').Popup:New {
					id = ADDON .. 'ImportProfile',
					text = L.ImportProfilePopup,
					button1 = OKAY, button2 = CANCEL,
					editBox = '',
					OnAccept = function(_, encoded)
						local name, err = Addon.Settings:ImportProfile(encoded)
						if name then
							Addon.Settings:ApplyNamedProfile(name)
							self:Update()
						else
							print('|cff33ff99' .. ADDON .. '|r ' .. (L.ImportProfileError or 'Import failed') .. (err and (': ' .. err) or ''))
						end
					end,
				}
			end)
		end,
		function()
			-- Column 2: Character data
			local picker = self.row:Add('DropChoice', L.CharacterData)
			local owners = {}
			local function refreshChoices()
				picker.choices = {}
				wipe(owners)
				for i, owner in Addon.Owners:Iterate() do
					if owner ~= Addon.player then
						owners[i] = owner
						picker:AddChoices(i, owner:GetDisplayName())
					end
				end
				self.targetOwner = nil
				picker:SetValue(nil)
			end
			refreshChoices()
			picker:SetCall('OnValue', function(_, key) self.targetOwner = owners[key] end)

			self.row:Add('RedButton', L.DeleteCharacterData):SetCall('OnClick', function()
				if self.targetOwner then
					local owner = self.targetOwner
					LibStub('Sushi-3.2').Popup {
						text = L.ConfirmDeleteCharacter:format(owner.name),
						button1 = OKAY, button2 = CANCEL,
						OnAccept = function()
							owner:Delete()
							refreshChoices()
						end
					}
				end
			end)

			self.row:Add('RedButton', L.ResetDatabase):SetCall('OnClick', function()
				LibStub('Sushi-3.2').Popup {
					text = L.ConfirmResetDatabase,
					button1 = OKAY, button2 = CANCEL,
					OnAccept = function()
						wipe(DaseekiBagsAccount)
						ReloadUI()
					end
				}
			end)
		end
	)

	self:AddSectionHeader(L.MeshSync)
	add2Col(80, function()
		local tokenStatus = (Addon.sets.meshToken ~= '') and L.MeshTokenActive:format(Addon.sets.meshToken) or L.MeshTokenNone
		self.row:Add('Header', tokenStatus, 'GameFontDisable', true)
		self.row:Add('GrayButton', L.MeshTokenSet):SetCall('OnClick', function()
			StaticPopupDialogs['DASEEKI_BAGS_MESH_TOKEN'] = {
				text = L.MeshTokenPrompt, button1 = OKAY, button2 = CANCEL,
				hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
				OnAccept = function(dialog)
					Addon.sets.meshToken = strtrim(dialog.EditBox:GetText())
					self:Update()
				end,
			}
			StaticPopup_Show('DASEEKI_BAGS_MESH_TOKEN')
		end)
		local chanStatus = (Addon.sets.meshChannel ~= '') and L.MeshChannelActive:format(Addon.sets.meshChannel) or L.MeshChannelNone
		self.row:Add('Header', chanStatus, 'GameFontDisable', true)
		self.row:Add('GrayButton', L.MeshChannelSet):SetCall('OnClick', function()
			StaticPopupDialogs['DASEEKI_BAGS_MESH_CHANNEL'] = {
				text = L.MeshChannelPrompt, button1 = OKAY, button2 = CANCEL,
				hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
				OnAccept = function(dialog)
					Addon.sets.meshChannel = strtrim(dialog.EditBox:GetText())
					self:Update()
				end,
			}
			StaticPopup_Show('DASEEKI_BAGS_MESH_CHANNEL')
		end)
	end, function()
		self.row:Add('Header', L.MeshTokenTip, 'GameFontDisable', true)
	end)

	self.sets = Addon.sets
end

function General:ToggleGlobals()
	if Addon.player.profile == Addon.sets.global then
		self:SetProfile(CopyTable(Addon.sets.global))
	else
		LibStub('Sushi-3.2').Popup {
			text = L.ConfirmGlobals, showAlertGear = true, button1 = YES, button2 = NO,
			OnAccept = function()
				self:SetProfile(nil)
				self:Update()
			end
		}
	end
end

function General:SetProfile(profile)
	Addon.player:SetProfile(profile)
	Addon.Frames:Update()
end
