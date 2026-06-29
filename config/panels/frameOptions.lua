--[[
	Frame-specific settings menu.
	All Rights Reserved
--]]


local C = LibStub('C_Everywhere').AddOns
local L, ADDON, Addon, Config = select(2, ...).Addon()

function Addon.PopulateComponentToggles(self)
	local savedSets = self.sets
	self.sets = (Addon.player and Addon.player.profile[self.frame]) or Addon.Settings.ProfileDefaults[self.frame] or Addon.sets

	self:AddRow(Config.componentMenuHeight, function()
		self:AddCheck('sidebar')

		if Config.tabs then
			self:AddCheck('tabs')
		end

		if Config.components then
			if self.frame == 'inventory' or self.frame == 'bank' then
				self:AddCheck('bagToggle')

				if DepositIntoBank or DepositReagentBank and self.frame == 'bank' then
					self:AddCheck('deposit')
				end
			end

			self:AddCheck('sort')
			self:AddCheck('search')
			self:AddCheck('options')

			if self.frame ~= 'vault' then
				self:AddCheck('money')
			end
		end

		if Addon.IsModern and self.frame ~= 'guild' then
			self:AddCheck('currency')
		end

		self:AddCheck('broker')
	end)

	self.sets = savedSets
end

function Addon.PopulateFrameOptions(self)
	local enabled = Addon.Frames:IsEnabled(self.frame)

	-- Selection
	self.sets = (Addon.player and Addon.player.profile[self.frame]) or Addon.Settings.ProfileDefaults[self.frame] or Addon.sets
	self:AddFrameChoice()
	self:AddCheck('enabled')
		:SetValue(enabled)
		:SetCall('OnInput', function()
			local addon = Addon.Frames:Get(self.frame).addon
			if addon then
				if enabled then
					C.DisableAddOn(addon)
				else
					C.EnableAddOn(addon)
				end
			end
		end)

	if enabled then
		-- Appearance
		self:AddSectionHeader(L.Appearance)

		local skins = {arg = 'skin'}
		for i, skin in Addon.Skins:Iterate() do
			skins[i] = {key = skin.id, text = skin.title, tip = skin.tooltip}
		end
		local current = Addon.Skins:Get(self.sets.skin)
		local colW = math.floor((self:GetWidth() or 610) / 3)
		local frameSets = self.sets

		local function add3Col(height, f1, f2, f3)
			self:AddRow(height, function()
				local row = self.row
				for _, fn in ipairs{f1, f2, f3} do
					local col = row:Add('Group')
					col:SetWidth(colW)
					col:SetHeight(height)
					col:SetChildren(function()
						self.row = col
						fn()
						self.row = row
					end)
				end
			end)
		end

		-- Row 1: Skin | Layer | Scale
		add3Col(60,
			function()
				self:AddChoice(skins)
			end,
			function()
				self:AddChoice{arg = 'strata',
					{key = 'LOW', text = LOW},
					{key = 'MEDIUM', text = AUCTION_TIME_LEFT2},
					{key = 'HIGH', text = HIGH}}
			end,
			function()
				self:AddPercentage('scale', 20, 300)
			end
		)

		-- Row 2: Opacity | Spacing | Columns
		add3Col(60,
			function()
				self:AddPercentage('alpha')
			end,
			function()
				self:AddSlider('spacing', -15, 15)
			end,
			function()
				if Config.columns then
					self:AddSlider('columns', 1, 50)
				end
			end
		)

		self:AddColumnHeaders('Background', 'Items', 'Bags')

		-- 3-col content area
		add3Col(220,
			function()
				-- Background: skin-dependent color pickers
				if current then
					if current.centerColor then
						self:AddColor('color'):SetKeys{left = 25, top = -5}
						local sets = frameSets
						local opSlider = self:AddLabeled('Slider', 'colorAlpha')
						opSlider:SetCall('OnValue', function(_, v)
							if sets.color then
								sets.color[4] = v / 100
								Addon.Frames:Update()
							end
						end)
						opSlider:SetRange(0, 100)
						opSlider:SetValue((sets.color and sets.color[4] or 0.85) * 100)
						opSlider:SetPattern('%s%')
					end
					if current.borderColor then
						self:AddColor('borderColor'):SetKeys{left = 25, top = -5}
					end
				end
			end,
			function()
				-- Items: item scale, artwork, border color
				self.sets = frameSets
				self:AddPercentage('itemScale', 20, 200)
				self.sets = Addon.sets
				self:AddChoice{arg = 'slotBackground',
					LAYOUT_STYLE_MODERN and {key = 3, text = LAYOUT_STYLE_MODERN} or false,
					{key = 2, text = EXPANSION_NAME0},
					{key = 1, text = NONE},
					{key = 4, text = 'Lion'},
					{key = 5, text = FACTION_ALLIANCE},
					{key = 6, text = FACTION_HORDE},
				}
				if (Addon.sets.slotBackground or 0) > 1 then
					self:AddPercentage('slotAlpha', 0, 100)
				end
				local bc = Addon.sets.slotBorderColor or {1, 1, 1, 0}
				self:AddLabeled('ColorPicker', 'slotBorderColor')
					:SetValue(CreateColor(bc[1], bc[2], bc[3], bc[4] or 0))
					:SetCall('OnColor', function(_, v)
						local sbc = Addon.sets.slotBorderColor
						sbc[1], sbc[2], sbc[3], sbc[4] = v:GetRGBA()
						Addon.Frames:Update()
					end)
				self.sets = frameSets
			end,
			function()
				-- Bags: break, spacing, scale
				self.sets = frameSets
				self:AddChoice{arg = 'bagBreak',
					{key = 0, text = NEVER},
					{key = 1, text = L.ByType},
					{key = 2, text = ALWAYS}}
				if (self.sets.bagBreak or 0) > 0 then
					self:AddPercentage('breakSpace', 100, 200):SetSmall(true)
				end
				self:AddPercentage('bagScale', 20, 200)
			end
		)
	end
end
