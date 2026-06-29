--[[
	optionsPanel.lua
		Options menu class with API shared among all panels
--]]

local L, ADDON, Addon = select(2, ...).Addon()
local Panel = Addon:NewModule('OptionsPanel', LibStub('Sushi-3.2').OptionsGroup:NewClass())

local SectionFont = CreateFont('DaseekiBagsSectionFont')
SectionFont:SetFont(GameFontNormal:GetFont(), 14, '')
SectionFont:SetTextColor(1, 1, 1)

local SubSectionFont = CreateFont('DaseekiBagsSubSectionFont')
SubSectionFont:SetFont(GameFontNormal:GetFont(), 11, '')
SubSectionFont:SetTextColor(0.85, 0.85, 0.85)


--[[ Groups ]]--

function Panel:New(id, icons)
	local parent = self ~= Panel and self
	local f = Addon:NewModule(id, Panel:Super(Panel):New(parent or 'Daseeki Bags', parent and L[id]))
f:SetSubtitle(L[id .. 'Description']:format(ADDON))

	-- wrap the content frame in a scroll frame so it can grow taller than the canvas
	local dock = f:GetParent()
	local scroll = CreateFrame('ScrollFrame', nil, dock, 'UIPanelScrollFrameTemplate')
	scroll:SetPoint('TOPLEFT', 4, -11)
	scroll:SetPoint('BOTTOMRIGHT', -24, 5)

	f:ClearAllPoints()
	f:SetParent(scroll)
	f:SetPoint('TOPLEFT')
	f:SetWidth(scroll:GetWidth())
	scroll:SetScrollChild(f)

	scroll:SetScript('OnSizeChanged', function(_, width)
		f:SetWidth(width)
		f:Layout(true)
	end)

	f:SetChildren(function() f:Populate() end)
	f.sets, f.frame = Addon.sets, 'inventory'
	return f
end

function Panel:AddSectionHeader(text)
	local h = self:Add('Header', text, SectionFont, true)
	h.top = 20
	return h
end

function Panel:AddColumnHeaders(...)
	local titles = {...}
	local n = #titles
	self:AddRow(22, function()
		local colWidth = math.floor((self:GetWidth() or 610) / n) - 24
		for _, title in ipairs(titles) do
			local h = self.row:Add('Header', title, SubSectionFont, true)
			h:SetJustifyH('CENTER')
			h:SetWidth(colWidth)
			h.top, h.bottom = 2, 2
		end
	end)
end

function Panel:AddRow(height, children)
	local group = self:Add('Group')
	group:SetHeight(height)
	group:SetResizing('HORIZONTAL')
	group:SetChildren(function(row) self.row = row; children(row); self.row = nil end)
	return group
end


--[[ Singletons ]]--

function Panel:AddCheck(arg,...)
	local args = {arg, ...}
	local sets = self.sets
	local b = self:AddLabeled('Check', arg)
	b:SetCall('OnClick', function(_,_, v)
		for _, arg in ipairs(args) do
			sets[arg] = v
		end
	end)
	b:SetValue(sets[arg])
	return b
end

function Panel:AddColor(arg)
	local sets = self.sets
	local b = self:AddLabeled('ColorPicker', arg)
	b:SetCall('OnColor', function(_, v) sets[arg] = {v:GetRGBA()} end)
	local c = sets[arg] or {}
	b:SetValue(CreateColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1))
	b:SetSmall(true)
	return b
end

function Panel:AddSlider(arg, min,max)
	local sets = self.sets
	local s = self:AddLabeled('Slider', arg)
	s:SetCall('OnValue', function(_, v) sets[arg] = v end)
	s:SetRange(min, max)
	s:SetValue(sets[arg] or min or 0)
	return s
end

function Panel:AddPercentage(arg, min,max)
	local sets = self.sets
	local s = self:AddLabeled('Slider', arg)
	s:SetCall('OnValue', function(_, v) sets[arg] = v/100 end)
	s:SetRange(min or 1, max or 100)
	s:SetValue((sets[arg] or 1) * 100)
	s:SetPattern('%s%')
	return s
end

function Panel:AddChoice(data)
	local sets = self.sets
	local choice = self:AddLabeled('DropChoice', data.arg)
	choice:SetCall('OnValue', function(_, v) sets[data.arg] = v end)
	choice:SetValue(sets[data.arg])
	choice:AddChoices(data)
	return choice
end

function Panel:AddLabeled(class, id)
	local label = id:gsub('^.', strupper)
	local tip = rawget(L, label .. 'Tip')

	local f = (self.row or self):Add(class, L[label])
	f:SetCall('OnInput', function() Addon.Frames:Update() end)
	f:SetTip(tip and f:GetLabel(), tip)
	return f
end

function Panel:AddBreak()
	return self:GetSuper().AddBreak(self.row or self)
end


--[[ Specific ]]--

function Panel:AddFrameChoice()
	local choice = self:Add('DropChoice', L.Frame, self.frame)
	choice:SetCall('OnInput', function(_, id) self.frame = id end)

	for i, frame in Addon.Frames:Iterate() do
		if frame.addon ~= false then
			choice:AddChoices(frame.id, frame.name)
		end
	end
	return choice
end
