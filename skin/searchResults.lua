--[[
	The cross-character item search results window.
	All Rights Reserved
--]]

local ADDON, Addon = ...
local L = LibStub('AceLocale-3.0'):GetLocale(ADDON)
local Results = Addon.Base:NewClass('SearchResults', 'Frame', 'BackdropTemplate', true)

Results.NumRows = 12
Results.RowHeight = 20


--[[ Construct ]]--

function Results:Construct()
	local f = self:Super(Results):Construct()
	f:SetSize(420, 360)
	f:SetFrameStrata('DIALOG')
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag('LeftButton')
	f:SetScript('OnDragStart', f.StartMoving)
	f:SetScript('OnDragStop', f.StopMovingOrSizing)
	f:SetScript('OnShow', function()
		f:ApplySkin()
		f:RegisterSignal('SKINS_LOADED', 'ApplySkin')
		f:RegisterSignal('UPDATE_ALL',   'ApplySkin')
	end)
	f:SetScript('OnHide', function() f:UnregisterAll() end)

	tinsert(UISpecialFrames, f:GetName())

	f.Title = f:CreateFontString(nil, 'ARTWORK', 'GameFontNormal')
	f.Title:SetPoint('TOP', 0, -10)
	f.Title:SetText(L.FindItem)

	f.CloseButton = CreateFrame('Button', nil, f, 'UIPanelCloseButton')
	f.CloseButton:SetPoint('TOPRIGHT', -2, -2)
	f.CloseButton:SetScript('OnClick', function() f:Hide() end)

	f.SearchBox = CreateFrame('EditBox', nil, f, 'SearchBoxTemplate')
	f.SearchBox:SetPoint('TOPLEFT', 16, -32)
	f.SearchBox:SetPoint('TOPRIGHT', -16, -32)
	f.SearchBox:SetHeight(20)
	f.SearchBox:SetScript('OnTextChanged', function(box)
		SearchBoxTemplate_OnTextChanged(box)
		f:Search(box:GetText())
	end)
	f.SearchBox:SetScript('OnShow', function(box)
		box:SetFocus()
	end)

	f.Scroll = CreateFrame('ScrollFrame', '$parentScroll', f, 'FauxScrollFrameTemplate')
	f.Scroll:SetPoint('TOPLEFT', 16, -58)
	f.Scroll:SetPoint('BOTTOMRIGHT', -32, 16)
	f.Scroll:SetScript('OnVerticalScroll', function(scroll, delta)
		FauxScrollFrame_OnVerticalScroll(scroll, delta, f.RowHeight, function() f:UpdateRows() end)
	end)

	f.Rows = {}
	for i = 1, f.NumRows do
		local row = CreateFrame('Button', nil, f)
		row:SetHeight(f.RowHeight)
		row:SetPoint('TOPLEFT', f.Scroll, 'TOPLEFT', 0, -(i-1) * f.RowHeight)
		row:SetPoint('RIGHT', f.Scroll, 'RIGHT')

		row.Icon = row:CreateTexture(nil, 'ARTWORK')
		row.Icon:SetSize(16, 16)
		row.Icon:SetPoint('LEFT')

		row.Text = row:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
		row.Text:SetPoint('LEFT', row.Icon, 'RIGHT', 4, 0)
		row.Text:SetPoint('RIGHT')
		row.Text:SetJustifyH('LEFT')

		row:SetScript('OnEnter', function(self)
			local result = self.result
			if result and result.hyperlink then
				GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
				GameTooltip:SetHyperlink(result.hyperlink)
				GameTooltip:Show()
			end
		end)
		row:SetScript('OnLeave', function()
			GameTooltip:Hide()
		end)

		f.Rows[i] = row
	end

	f.Empty = f:CreateFontString(nil, 'ARTWORK', 'GameFontDisableSmall')
	f.Empty:SetPoint('CENTER', f.Scroll, 'CENTER')

	f.results = {}
	return f
end


--[[ Skinning ]]--

function Results:ApplySkin()
	local profile = Addon.player and Addon.player.profile and Addon.player.profile['inventory']
	if not profile then return end

	if self.bgSkin then
		self.bgSkin:Release()
	end
	self.bgSkin = Addon.Skins:Acquire(profile.skin, self)
	local border = profile.borderColor or {0.3, 0.3, 0.3, 1}
	local center = profile.color or {0, 0, 0, 0.85}
	self.bgSkin('load')
	self.bgSkin('borderColor', border[1], border[2], border[3], border[4])
	self.bgSkin('centerColor', center[1], center[2], center[3], center[4])
end


--[[ API ]]--

function Results:New(parent)
	local f = self:Super(Results):New(UIParent)
	f:SetPoint('CENTER')
	f:ApplySkin()
	f:Show()
	f.SearchBox:SetFocus()
	f:Search(f.SearchBox:GetText())
	return f
end

function Results:Search(query)
	self.results = Addon.ItemFinder:Find(query)
	self.Scroll:SetVerticalScroll(0)
	FauxScrollFrame_SetOffset(self.Scroll, 0)
	self:UpdateRows()
end

function Results:UpdateRows()
	local results = self.results
	local offset = FauxScrollFrame_GetOffset(self.Scroll)

	for i = 1, self.NumRows do
		local row = self.Rows[i]
		local result = results[i + offset]
		row.result = result

		if result then
			row.Icon:SetTexture(result.icon or 134400)

			local itemName = result.hyperlink and result.hyperlink:match('%[(.-)%]') or UNKNOWN
			local quality = ITEM_QUALITY_COLORS[result.quality or 1] or ITEM_QUALITY_COLORS[1]
			local countTag = result.count and result.count > 1 and ('  x' .. result.count) or ''

			row.Text:SetText(format('%s%s|r  -  %s  (%s)%s',
				quality.hex, itemName, result.owner:GetDisplayName(12), result.location, countTag))
			row:Show()
		else
			row:Hide()
		end
	end

	self.Empty:SetShown(#results == 0 and self.SearchBox:GetText() ~= '')
	self.Empty:SetText(L.NoItemsFound)

	FauxScrollFrame_Update(self.Scroll, #results, self.NumRows, self.RowHeight)
end
