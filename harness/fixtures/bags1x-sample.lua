-- Daseeki-Bags 1.x SavedVariables — REDUCED, structure-preserving fixture.
--
-- Trimmed copy of the real 1.x SV shape (2 full characters, 3 mesh summaries;
-- item lists cut to a few entries each). Faithful to the real serializer's
-- shape: unindented, char tables keyed [realm][char], containers under NUMERIC
-- keys (0=backpack, 1..N=bags, -1=bank, -2=keyring), slot values "id"/"id;count".
-- This drives the harness fixture-migration suite. Not owner data of record —
-- values are truncated on purpose so the repo can be published for packaging.
--
-- SORT LOCKS: 1.x stores them as `locked = { [slot] = true }` INSIDE the per-bag
-- record, beside items/size/link (core/classes/item.lua PostClick ->
-- GetBagInfo(bag).locked). Both real-world variants are represented here so the
-- lock-migration pass is exercised end to end by the fixture suite:
--   Puuchoco bag 1 — a real, populated lock table (2 slots)
--   Itchey   bag 0 — a lock table with nothing set, which the owner's own file
--                    actually contains; it must import NOTHING and create no root.

DaseekiBagsAccount = {
["Whitemane"] = {
["Puuchoco"] = {
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
[0] = {
["items"] = {
"6948",
[12] = "22261;10",
},
["size"] = 20,
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
[16] = "37",
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
[17058] = 78,
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
[6948] = 1,
[159] = 2,
},
},
},
}

DaseekiBagsSets = {
["slotBorderColor"] = {
0.207843154668808,
0,
0.02352941408753395,
0.5899999737739563,
},
}
