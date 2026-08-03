-- Daseeki-Bags 1.x SavedVariables — SYNTHETIC FULL fixture for the CUTOVER
-- one-shot orchestration suite (harness/run-selftests.lua, suite
-- "cutover-orchestration").
--
-- bags1x-sample.lua is a reduced copy of the real 1.x DATA globals; it exercises the
-- owner pass and the lock pass but its DaseekiBagsSets holds a single key, so it says
-- nothing about the SETTINGS pass or about the ORDER the passes run in.
--
-- This file is the other half: a structurally faithful 1.x file with ALL THREE globals
-- populated the way a long-lived install populates them, chosen so that the ordering of
-- the migration chain is OBSERVABLE in the result rather than merely asserted:
--
--   * global.inventory.columns = 12 and .spacing = 4  — EXACTLY the pre-parity 2.0
--     default pair that Frame.MigrateDensity flips to 11/2. The settings pass claims
--     db.densityUserChose when it writes a grid from 1.x, and MigrateDensity honours
--     that marker. So the final db holds 12/4 if and only if the settings pass ran
--     BEFORE the density heal. If the order ever inverts, the owner's 1.x grid is
--     silently re-defaulted on the very login that imported it, and this fixture is
--     what turns that red.
--
--   * customRules holds one convertible SEARCH rule and one MACRO rule, so the
--     rules -> categories conversion reports one imported and one skipped, and
--     db.categoriesUserChose is claimed before Rules.MigrateDefaultFlip can see it.
--
--   * display.* carries explicit OFFs, which are the only display values worth
--     carrying (both sides default to ON).
--
--   * `locked` tables in both real-world variants (populated / present-but-empty),
--     across two characters, so the lock pass reports a multi-character import.
--
--   * DaseekiBagsMesh names one character that is ALSO full (must not downgrade) and
--     two that are summary-only.
--
-- Values are invented. This is not owner data.

DaseekiBagsAccount = {
["Whitemane"] = {
["Puuchoco"] = {
[0] = {
["items"] = {
"6948",
[12] = "22261;10",
},
["size"] = 20,
["locked"] = {
[3] = true,
},
},
{
["items"] = {
"22157",
"22157",
[13] = "22261;2",
},
["size"] = 14,
["link"] = "14046",
["locked"] = {
[13] = true,
[14] = true,
},
},
[4] = {
},
[-1] = {
["items"] = {
[3] = "4306;20",
},
["size"] = 24,
},
[-2] = {
["items"] = {
[1] = "5175",
},
["size"] = 32,
},
["equip"] = {
[7] = "139",
[18] = "3111;100",
},
["money"] = 39000,
["class"] = "WARRIOR",
["race"] = "Troll",
["sex"] = 2,
["faction"] = "Horde",
["level"] = 60,
["mesh"] = {
["itemCounts"] = {
[22157] = 2,
[22261] = 12,
},
["rev"] = 32,
},
},
["Itchey"] = {
[0] = {
["items"] = {
"6948",
[12] = "2905",
},
["size"] = 20,
["locked"] = {
},
},
[1] = {
["items"] = {
[2] = "858;5",
},
["size"] = 10,
["locked"] = {
[2] = true,
[9] = true,
},
},
["money"] = 63,
["class"] = "ROGUE",
["race"] = "Gnome",
["sex"] = 1,
["faction"] = "Alliance",
["level"] = 12,
["mesh"] = {
["itemCounts"] = {
[6948] = 1,
[2905] = 1,
},
["rev"] = 4,
},
},
},
}

DaseekiBagsMesh = {
["Whitemane"] = {
["Puuchoco"] = {
["ts"] = 1785208100,
["rev"] = 32,
["money"] = 39000,
["class"] = "WARRIOR",
["race"] = "Troll",
["faction"] = "Horde",
["level"] = 60,
["itemCounts"] = {
[22157] = 2,
},
},
["Shalk"] = {
["ts"] = 1785208149,
["rev"] = 179,
["money"] = 1022693,
["class"] = "SHAMAN",
["race"] = "Orc",
["faction"] = "Horde",
["level"] = 60,
["itemCounts"] = {
[13724] = 52,
[6948] = 1,
},
},
["Yffre"] = {
["ts"] = 1783373387,
["rev"] = 1,
["money"] = 500,
["class"] = "DRUID",
["race"] = "NightElf",
["faction"] = "Alliance",
["level"] = 1,
["itemCounts"] = {
[159] = 2,
},
},
},
}

DaseekiBagsSets = {
["global"] = {
["inventory"] = {
["columns"] = 12,
["itemScale"] = 1,
["spacing"] = 4,
["bagBreak"] = 2,
["money"] = false,
["enabled"] = true,
["alpha"] = 1,
["scale"] = 1,
["strata"] = "HIGH",
["x"] = -50,
["y"] = 100,
["point"] = "BOTTOMRIGHT",
},
["bank"] = {
["columns"] = 14,
["itemScale"] = 1,
["spacing"] = 4,
},
},
["profiles"] = {
},
["customRules"] = {
{
["title"] = "Herbs",
["search"] = "t:trade & q:common",
["icon"] = 134194,
},
{
["title"] = "Scripted",
["macro"] = "return item.id == 6948",
},
},
["countItems"] = false,
["countCurrency"] = true,
["moneyTooltipFaction"] = true,
["moneyTooltipMinGold"] = 25,
["glowQuality"] = false,
["glowNew"] = true,
["glowPoor"] = true,
["glowAlpha"] = 0.77,
["glowSets"] = true,
["colorSlots"] = true,
["slotAlpha"] = 0.41,
["slotBorderColor"] = {
0.207843154668808,
0,
0.02352941408753395,
0.5899999737739563,
},
["display"] = {
["banker"] = true,
["merchant"] = false,
["mailInfo"] = false,
["auctioneer"] = true,
["tradePartner"] = true,
["crafting"] = true,
},
}
