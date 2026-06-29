--[[
	Color settings menu.
	All Rights Reserved
--]]

local L, ADDON, Addon = select(2, ...).Addon()

local function SlotTypes()
	local types = {}
	local ignore = {'normal'}

	if Addon.IsClassic then
		tAppendAll(ignore, {'inscribe', 'tackle', 'fridge', 'gem'})
	end

	if Addon.IsModern then
		tAppendAll(ignore, {'key', 'soul', 'quiver'})
	end

	if not Addon.IsRetail then
		tAppendAll(ignore, {'account', 'reagent'})
	end

	for name in pairs(Addon.sets.color) do
		if not tContains(ignore, name) then
			tinsert(types, name)
		end
	end

	sort(types)
	tinsert(types, 1, 'normal')
	return types
end

function Addon.PopulateColorSlots(self)
	local savedSets = self.sets
	self.sets = Addon.sets

	self:AddCheck('colorSlots').bottom = 11

	if Addon.sets.colorSlots then
		self:AddRow(35 * ceil(#SlotTypes() / 3), function()
			for i, name in ipairs(SlotTypes()) do
				local c = self.sets.color[name] or {1, 1, 1, 1}  -- guard: some slot types (e.g. 'normal') may be unset
				self:AddLabeled('ColorPicker', name .. 'Color')
					:SetValue(CreateColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1))
					:SetCall('OnColor', function(_, v) self.sets.color[name] = {v:GetRGBA()} end)
					:SetSmall(true)
			end
		end).left = 20
	end

	self.sets = savedSets
end

function Addon.PopulateBackground(self)
end

function Addon.PopulateSlotOptions(self)
	self.sets = Addon.sets

	self:AddRow(35*2, function()
		self:AddCheck('glowQuality')
		self:AddCheck('glowQuest')
		self:AddCheck('glowSets')
		self:AddCheck('glowUnusable')
		self:AddCheck('glowNew')
		self:AddCheck('glowPoor')
	end)
	self:AddPercentage('glowAlpha'):SetWidth(585)
end
