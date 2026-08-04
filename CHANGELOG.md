# Changelog

## Unreleased — 2.0.2

**Characters that only exist in Daseeki Nexus now show up in the character menu with a
readable summary instead of being invisible, sorting keeps a private log of every run so
it can be tuned against real data, and the character menu no longer floats on screen after
you close the bags.**

### Characters synced from Daseeki Nexus

If another one of your accounts syncs a character through Daseeki Nexus but that character
has never been played on this one, Bags knew about its gold — the money tooltip counted it —
but the character menu did not list it at all. It does now, with the same class colour, the
same **Summary** tag and the same "3d" age stamp as any other row.

Picking one opens a **summary view**: that character's gold, and a list of everything it is
carrying — icon, name and count — sorted by name, with a line at the top saying where the
data came from and how old it is. That replaces the blank grid the row would have shown.

Two things about those rows are deliberate.

- **There is no remove ✕ on them.** The record lives in Nexus, not in Bags, so deleting it
  here would not stick — the character would simply reappear the next time the two stores
  are merged. A control that does nothing is worse than no control.
- **The favourite star still works.** Favourites are Bags' own preference, stored under the
  character's name, so starring a synced character sticks and lifts it to the top of the
  menu exactly like any other.

Right-clicking a synced character's name still opens the bank preview, and it shows that
same summary. It says so plainly, too: what Nexus sends is one combined tally of everything
a character holds — bags, bank, equipped and mail together — so there is no bags-versus-bank
split to show. Bags says that rather than showing you an empty bank window, which would have
read as "this character's bank is empty".

With Daseeki Nexus not installed, or its Inventory module switched off, none of the above
appears and the character menu is exactly what it was.

### Sorting

- **Sorting is faster on a slow connection.** A sort issues its moves in rounds, and each
  round used to wait out a fixed 1/20th-second tick before looking again — even when the
  server had already confirmed the move the next one was waiting on. Confirmations now wake
  the sort immediately when they unblock something. Measured across the simulated bag and
  bank fixtures at 50ms–500ms latency: **15% less time overall**, up to 39% on a full
  120-slot bank, with no increase in the number of moves made and several runs that used to
  give up now finishing. The old tick remains as the safety cadence, so nothing depends on
  the confirmations arriving.
- **Sorting keeps a log.** Every run now records one compact line — how big the bag was, how
  full, how many moves were planned versus made, how many rounds, how long it took, the
  measured server round-trip, and why it stopped if it did. The last 50 runs are kept.
  `/bags sortlog` prints them newest first; `/bags sortlog clear` empties the list. Nothing
  about the sort itself is slower for it, and the single chat line at the end is unchanged.
  This exists so the next round of tuning is done against your bags rather than a guess.
- **Long sorts get more patience on a slow link.** The guards that stop a sort which has
  genuinely stalled are now measured in seconds rather than in ticks, and they stretch to
  fit the round-trip the log has actually measured. They can only ever get more patient,
  never less.

### Fixed

- **The character menu no longer outlives the window.** Opening the character dropdown and
  then closing the bags — with Escape, or the X — left the menu floating on screen with
  nothing behind it. It now closes with the window it belongs to, on both the bag and bank
  windows.


## 2.0.1 — 2026-08-04

**Sorting is faster and always finishes, the Blizzard bank window no longer turns up
alongside ours, new items are marked on the border instead of with a corner dot, and a
click that could leave your bags unresponsive is fixed.**

### Sorting

Sorting a full bank could crawl and then give up part-way, printing *"sort stopped: time
budget exceeded"* and leaving a bag half arranged with no word about what it had skipped.
Three separate things were wrong.

- **It was waiting on itself.** While a sort is running, some slots are always mid-flight —
  the server has been told to move them but has not answered yet. The sort was planning its
  next batch of moves *including* those slots, and then throwing almost all of that batch
  away because the game will not touch a slot twice at once. On a full bank it was managing
  fewer than two moves per round when a dozen were available. It now plans around the slots
  it is waiting on, so each round issues moves it can actually make. Measured on a full
  120-slot bank, the same sort finished in **3.9 seconds instead of 7.4**.
- **A sort no longer gives up because it is taking a while.** The old ten-second ceiling is
  gone. A sort now stops only if it genuinely stops making progress, so a big bank on a slow
  connection runs to completion instead of being abandoned. If a sort ever does have to
  stop, it now tells you how much was left undone so you can just run it again.
- **Specialised bags are filled first again.** Herb bags, enchanting bags, soul bags and
  quivers are homes, not overflow — Bags 1 filled them first and put the leftovers in your
  general bags, and 2.0 had it backwards, spilling herbs into your backpack while the herb
  bag sat half empty. That is restored, along with Bags 1's rule that a swap is only made
  when *both* items can legally live where they are going.

### New items

Newly-looted items used to be marked with a small crimson dot in the corner of the slot.
They now **glow crimson and pulse gently on the border** instead, the way the rest of the
item cues work — quest gold, unusable red and equipment-set teal are all border colours, and
newness is now one too. The pulse stops as soon as you interact with the item.

The new glow sits below the quest, unusable and equipment-set colours, so it never hides one
of those; it does sit above the plain rarity colour while an item is new. You can turn it off
under *Item borders → Glow newly-acquired items*.

### The bank

**Blizzard's bank window no longer appears when you visit a banker.** It was showing up
next to (or on top of) the Daseeki bank window. If you would rather have the default one,
there is a new option — *Auto-display → Use the Daseeki bank window* — and turning it off
brings Blizzard's bank straight back, with no reload.

### Right-clicking a character's name

Right-clicking the character name at the top of the bag window now **opens that character's
bank**. Because the bank window can show characters you are not logged into, this works as a
bank preview for your alts: pick an alt from the name dropdown, right-click the name, and
look through their bank. Right-click again to put it away.

Toggling between the combined and split bag layouts has not moved — it is still a
right-click on the title bar itself, anywhere outside the character name.

### A click that could leave your bags unresponsive

**Fixes a bug where your bags could stop responding to clicks — most visibly, items would
not go into a trade window.**

#### What was happening

The sort glyph does two things: left-click sorts your bags, right-click opens *sort lock
configuration mode*, where clicking a slot marks it so a sort never moves it. That mode
deliberately takes over every click on every item, because in it a click means "lock this
slot", not "use this item".

If you right-clicked the sort glyph meaning "sort", you were in that mode without
realising it. On a grid with nothing locked yet, nothing on the item cells looked any
different, and the only sign was a small notice card floating above the bag window — which
was easy to miss, and could sit off the top of the screen entirely if you keep your bags
up high. From then on, every click on an item toggled a lock instead of doing what you
expected: no picking items up, no selling at a vendor, no depositing at the bank, and — the
way this was found — no right-clicking an item into an open trade. The mode was only ever
held in memory, which is why logging out and back in appeared to "fix" it.

#### What changed

- **Opening a trade, a merchant, the bank, the mailbox, the auction house or a tradeskill
  window now ends the mode automatically**, and says so in chat. Those are windows you
  click items *into*; suspending item clicks there is never what you wanted. Your locked
  slots are saved and keep applying to sorts — only the editing mode closes. This happens
  whether or not you have the matching "open my bags automatically" option switched on.
- **The mode is now impossible to miss.** While it is open every item cell wears a red
  wash, so the grid itself tells you clicks are suspended instead of leaving it to a
  floating card.
- **The notice card can no longer land off-screen.** If there is no room above the bag
  window it appears below it instead.
- **A stuck cell heals itself.** If anything ever leaves a cell suspended after the mode
  has closed, the next click or hover on it releases it, and any repaint of the window
  clears it — so the worst case is one lost click, not bags that quietly stop working.

Nothing about how locking works has changed: right-click the sort glyph to open the mode,
click slots to lock and unlock them, and right-click again (or press Escape, click the
notice, close the window, or start a sort) to leave.

## 2.0.0

**Daseeki Bags has been rebuilt from scratch — and everything you had comes with you.**
This is the same addon, in the same folder, with the same name: you install it over 1.x
the way you install any other update. There is nothing to export, nothing to re-enter,
and nothing to set up again. The first time you log in, Bags 2 reads your old saved data
and brings it across, once, automatically.

**Requirements: Daseeki Core 2.2.0 or later is now required.** 1.x listed Core as optional,
but Bags 2 draws its whole window with Core's shared look — without it there is no window at
all. Core is therefore a proper dependency from this release: the game will not load Bags
until Core is installed and enabled, and CurseForge will offer Core alongside it. (If Bags
is forced to load with Core missing, it now leaves your normal Blizzard bags working and
tells you why in chat, instead of leaving you with no bags at all.) Daseeki Nexus stays
entirely optional.

### What carries over

- **Every character's bags, bank, keyring and gold** — including alts you have not logged
  in on for months, and characters on your *other* accounts that reached you through 1.x's
  cross-account sync. They are in the character list on the first login, with the same
  contents and the same gold totals.
- **Your settings.** Column count, slot size, spacing, whether your bags draw as one grid
  or split per bag, the money bar, cross-character tooltip counts, quality colouring, the
  money-tooltip options, your empty-slot artwork and opacity, your slot edge, and every
  auto-open interaction you had switched *off* (banker, merchant, mail, auction house,
  trade, crafting) stay switched off.
- **Your keybindings.** The keys you bound to *Toggle Bags* and *Toggle Bank* in 1.x keep
  working, untouched. You do not need to re-bind anything. (Bags 2 also adds a third
  action, *Find item across characters*, which starts unbound.)
- **Your sort locks.** The slots you right-click-locked in 1.x so sorting would never move
  them are read out of the old data and re-applied, per character, exactly where they were.
- **Your chat commands.** `/dbg` and `/Daseeki-Bags` still work and still open the bags, so
  any macro you built on them keeps working. `/bags` (short `/dbags`) is the new spelling,
  and `/bags help` lists everything. `/dbg mesh` now tells you where cross-account sync
  went: it is Daseeki Nexus's Inventory module, and your 1.x mesh characters were imported.
- **Your custom rules**, as far as they can be expressed. A 2.0 category is a saved search,
  so 1.x rules that were searches become categories automatically; rules that ran custom
  Lua cannot become a search and are reported rather than silently dropped — your 1.x copy
  of them is never touched either way.

### What does *not* carry over

- **Skins.** 1.x could be re-skinned by other addons; 2.0 draws itself in the shared Daseeki
  look. There is no setting to carry.
- **A handful of 1.x appearance knobs with no 2.0 equivalent** (frame strata/alpha, per-frame
  named profiles, the individual glow switches). Where 2.0 expresses the same idea a
  different way, it keeps its own control rather than guessing at a conversion.
- **The launcher button on Titan Panel / Bazooka bars is gone.** 1.x registered a data-broker
  plugin you could click to open your bags from a bar addon; open them with your bag key,
  the bag icons, or `/bags` instead.
- **The tracked-currency row along the bottom of the bag window is gone**, and so are the
  currency counts 1.x added to currency tooltips (the *count currency* setting) — Classic
  Era has almost nothing to track, and Bags 2 counts tokens the same way it counts any
  other item.
- **The equipment-set glow is deliberately left off**, even if 1.x had it on. On Classic Era
  1.x could only ever draw that cue with ItemRack installed, so a stored "on" recorded a
  switch you never touched, not a look you chose. Turn it on under Item borders if you want it.

### If anything looks wrong

- **The import runs once and knows it.** If it ever finds itself marked done while your
  character list is empty, it repairs itself on the next login and tells you so in chat.
- **Your 1.x data is not deleted, moved, or rewritten.** Bags 2 only *reads* it. It stays in
  your saved variables file exactly as 1.x left it.
- **You can go back.** Reinstalling Daseeki Bags 1.1.5 over 2.0 finds its own saved data
  right where it left it and starts up as if nothing happened — you would lose only what
  you changed inside 2.0. This is supported **for at least two releases** (through 2.2.0);
  after that the 1.x data may be retired and downgrading becomes a fresh start.
- **One-time housekeeping:** if you had installed the *Daseeki Bags 2 (BETA)* folder
  alongside 1.x during testing, delete it. Everything moved into the normal Daseeki Bags
  folder, and leaving the beta folder in place will make the game complain about duplicate
  keybindings.

### The window itself

- **Switch characters from the header now: click the name at the top of the window.**
  The character name in the title bar has a small **dropdown arrow** after it, and clicking
  the name *or* the arrow opens the same character list you already had. The list drops
  **downward** from the title, over the window. The **button in the bottom-left corner is
  gone** — that was the previous round's placement and you reversed it. This is the better
  home for it: the list changes which character the title is naming, so it belongs on the
  title rather than in a corner two bands away.
  - **The bank window works exactly the same way.** Its title already read
    *"<Character> · Bank"*, so the arrow simply joins the name there, and its bottom-left
    button is gone too.
  - **Dragging the window by its name still works.** Grab the character name and pull and
    the window moves as it always did; only a click that *never became a drag* opens the
    list.
  - **Right-clicking the title still flips combined/split.** That gesture is older than the
    dropdown and it survived intact — left-click picks a character, right-click flips the
    layout. Hovering the name spells both out in a tooltip.
  - The footer keeps everything else you asked to keep: the **Raid Prep flask**, the
    **free/total slot count** and the **money**.

- **The character list reads "5d", not "Updated 5d ago".** Just the age, as you asked —
  `5d`, `1h`, `4m`, `27d`. The column shrank from 104 pixels to 44 and the whole menu got
  narrower with it. Two entries keep their words because they are not ages: the character
  you are logged in on still reads **Online**, and one that has never been captured still
  reads **No data**. Anything under a minute reads **now** rather than "0m".
  - The bank window's *"Updated …"* stamp under the title is untouched — that one is a
    standing caption on an offline view, where the sentence is the point.

- **The favourite star is a real star now, in both states.** The unfavourited state used to
  draw as a meaningless hollow box. That was not a size or colour problem: the ★ and ☆
  characters **do not exist** in the font the suite ships (nor in any of the built-in WoW
  faces the font picker offers), so the game was drawing its "missing character" box. The
  star is now **drawn artwork**, like every other glyph in the window — a filled gold star
  when a character is favourited, and a clearly readable **star outline** when it is not.
  It also lights up gold when you hover it, so you can see it is clickable.
  - Everything else about the list is unchanged: the columns, the scrolling, the class
    colours, the FULL/SUMMARY tags, the ✕ delete with its confirmation, and favourites
    still lifting to the top.

- **The bag window opens a little bigger by default.** You asked to bring the default
  scale up just a bit, so it moved from **89% to 92%** — about three percent, which is
  roughly a pixel and a half on each slot. Only the *size* changed: the slot shape, the
  spacing between slots and the glow proportions are all exactly what they were, so the
  window is the same window, just slightly larger. The bank window follows it, as always.
  - **It applies to you even though your setting already said 89%.** The 89% had been
    written into your saved settings the first time you logged in with the scale option,
    so simply changing the default would have done nothing. Bags 2 therefore does a
    one-time check on the next login: if your window scale is *still sitting at the old
    89% default* and you have never moved the slider, it becomes 92%. It happens once,
    ever, and it is remembered so it can never happen twice.
  - **If you ever moved the Window scale slider, nothing happens.** Any value other than
    exactly the old default is treated as your choice and is left completely alone — and
    from now on the slider records that you set it, so even deliberately choosing 89%
    survives. Future default changes will never take back a number you picked.
  - **You can still change it whenever you like**: Options → Grid → *Window scale*.
  - This is the one place Bags 2 knowingly departs from matching Bags 1's size exactly.
    That was a deliberate call from you, and the size-parity tests record it as such
    rather than quietly loosening — they still prove Bags 2 reproduces Bags 1's window
    pixel-for-pixel at the old value, and separately that the shipped default now sits a
    few percent above it on purpose.

- **Right-click the sort button to lock bag slots, exactly like Bags 1.** This is the
  feature that had not been carried over yet. Right-clicking the sort glyph puts the
  window into a **lock configuration mode**: a notice appears above the window explaining
  it, and while you are in it every slot click *locks or unlocks that slot* instead of
  picking the item up. A locked slot wears a red prohibition sign, and the sort will never
  move anything into it or out of it. Right-click the sort glyph again, press **Escape**,
  click the notice, or just close the window to finish — normal clicking comes straight
  back. The notice keeps a running count of how many slots you have locked.
  - **It works at the bank too.** Right-clicking the bank window's Sort button opens the
    same mode, and bank slots, bag slots and keyring slots are all lockable.
  - **The locks you already have came with you.** Your Bags 1 locks were read out of the
    old saved data and carried over automatically the first time this version loads —
    Poonyx's four locked slots and Shalk's nine are already there. Nothing was taken from
    the old file; it is only read.
  - **Locks are per character**, exactly as they were in Bags 1, and they are remembered
    between sessions. No new setting appeared in the options, and no other setting changed.
  - **Sorting in combat behaves exactly as it did before.** Locking is a configuration
    mode, not a sort, so none of the combat rules around sorting changed.

- **The quality glow fades inward over the icon again, instead of reading as a hard
  border.** Side by side against Bags 1 the shape was right but the balance was not: a
  glowing slot in Bags 2 was mostly a crisp coloured rim, where Bags 1 washes colour over
  the edge of the icon and lets it fall away inward. The cause was one number. Bags 1 puts
  the strength of that wash on a slider, and yours has been at **0.77** for years — Bags 2
  had been shipping the slider's untouched factory value of 0.5. At 0.5 the soft wash is
  faint enough that the crisp ring hugging the icon out-shouts it, which is exactly the
  "just a hard border" you were seeing. Bags 2 now ships **your** value, so the wash is the
  loud half of the cue and the ring is the quiet half, in the proportion you have been
  looking at all along.
  - **The ring itself was not touched, deliberately.** Bags 1 draws the same ring, at full
    strength — it only ever applies the slider to the wash, never to the ring. The ring is
    what pins the soft halo to its own slot; without it the colour reads as an unanchored
    bloom drifting into the gaps. It stays exactly as it was.
  - Nothing here is a new setting, and nothing you had configured changed.

- **The bottom of the bag window is a proper footer now.** It used to be a money strip
  with a slot count floating near it; it is now one row with three zones — controls on
  the left, the free/total count in the middle, your gold on the right — and everything
  in it sits on the same line. The band grew by two pixels so a button fits in it
  properly, which is the entire change to the window's size.
  - **The character selector moved to the bottom-left corner.** It was the odd one out in
    the top-right cluster: sort, search, settings and close all do something *to* this
    window, while the selector changes *whose* window you are looking at. Down in the
    footer it sits with the other per-character readouts — that character's slot count,
    that character's gold. It behaves exactly as before, with the same menu; the menu now
    opens upward, since the button is at the bottom. The search box also gets the extra
    width the selector used to occupy.
  - **The Raid Prep button is back**, next to the character selector, where Bags 1 put it.
    It toggles the raid consumables checklist, opens it beside the bags, and honours the
    "open with bags" and "city only" options you set in Raid Prep itself. If you do not
    have Daseeki Raid Prep installed you will never see the button.
  - **Your gold no longer touches the window's right edge.** The coin icons are drawn a
    couple of pixels wider than the game reports them to be, so the last coin was
    overhanging the border. The whole strip is inset a little further in, and it now stays
    inside the frame at any amount of gold.
- **The bank window got the same footer**, corner for corner: its character selector moved
  down to the bottom-left in the same compact form, its gold sits inside the border, and
  the decorative backpack icon that used to occupy that corner is gone. The bank's title
  already names the character, so the selector no longer says it twice.
- Nothing you had configured changed, and no new settings were added.

- **The teal rings are gone.** After the last round almost every piece of gear in the bag
  was wearing a teal ring instead of its rarity colour. The cue itself was working
  correctly — those really were items in your Armory gear sets — but on a geared character
  that is roughly a third of the bag, and because set teal outranks rarity, all of those
  slots lost their green/blue/purple. It also was not what Bags 1 does: on Classic Era,
  Bags 1 can only draw that cue when ItemRack is loaded, and it isn't, so Bags 1 draws no
  teal at all. **The equipment-set glow is now off by default** and lives on the options
  page under Item borders if you want it. Searching with `set:` works either way.
  The membership test itself was also tightened while it was open: it now only counts an
  item that a set actually names in a slot that set has not disabled, only for equippable
  gear, and it stays completely silent when Armory is missing or has no sets.
- **The slot background from Bags 1 is back — your Bags 1 look, not Bags 1's defaults.**
  The last round read the shipped defaults out of the Bags 1 source and gave every empty
  slot the bevelled backpack artwork at full opacity, which is a much louder grid than the
  one you actually run. Your real Bags 1 profile draws a faction crest at 29% opacity in
  empty slots, and frames *every* slot — full or empty — with a quiet dark 2px edge. That
  is what 2.0 draws now, and those are its new defaults. Three new controls under
  **Slot appearance**: empty slot art (None / Classic / Lion / Alliance / Horde), empty
  slot opacity, and slot edge opacity. If you had those settings in Bags 1, they now
  migrate across too.

- **The bag cell is now Bags 1's bag cell, element for element.** Two earlier rounds fixed
  the glow and then the panel underneath it, and the grid still read busier than Bags 1
  side by side. The cause was never one detail — it was that a 2.0 cell simply had more
  things drawn on it. A cell now draws exactly what Bags 1 draws:
  - **The grey panel behind every slot is gone**, not dimmed. Bags 1 paints no panel at
    all — an item's own icon is the slot, and an empty slot is the familiar bag-slot art.
    2.0 now does the same, so the grid is icons on the window background instead of a
    lattice of hard-edged squares with a gutter between them.
  - **Empty slots use the classic empty-bag-slot art** instead of a flat dark rectangle.
  - **Grey (junk) items are no longer greyed out.** Bags 1 keeps them in full colour and
    puts the small vendor coin on the slot; that is what you get now. A third of a Classic
    bag being rendered in greyscale was most of "hard to view".
  - **Coloured items get their crisp ring back under the glow.** Bags 1 draws both — a thin
    quality-coloured frame hugging the icon, with the soft halo washing over it. Without
    the frame the halo was an unanchored colour spill; with it, the glow belongs to its own
    slot again.
  - **The stack-count numeral is the game's own again**, in its own place, exactly as in
    Bags 1 — no custom font, no shifted corner.
  - **Equipment-set items glow teal instead of carrying a bronze corner dot.** Bags 1 has
    always expressed gear-set membership as a glow colour, in the order quest gold, then
    can't-use red, then set teal, then rarity. One cue per slot, not two.
- **The glow itself is re-derived from Bags 1 rather than from a reference spec**: very
  slightly smaller, a touch brighter, sitting dead-centre instead of one pixel high, and
  layered under the slot's own numerals and icons rather than over them. Everything still
  scales with the density slider, so any cell size reads like a scaled Bags 1.
- Search dimming now fades to the same depth Bags 1 uses.
- The only thing 2.0 still draws that Bags 1 does not is the crimson new-item dot, which is
  a deliberate 2.0 feature; a test now pins that it is the *only* extra.
- No new settings, nothing you had configured changed, and the equipment-set toggle still
  works — it now switches the teal glow instead of the corner dot.

- **The quality glow is now exact.** The soft colored halo around each item was close
  but not right: it was drawn very slightly too small, a touch too bright, and sat one
  pixel low. It is now the reference treatment parameter for parameter — the halo is a
  little wider relative to the cell, the intensity is slightly softer, and it is nudged
  up one pixel so it sits centered on the icon rather than under it. All three scale with
  the density slider, so the halo looks identical at every cell size.
- Poor-quality items now carry the reference's near-black tint instead of Blizzard's grey.
  You will not see this in bags — poor and common items are still deliberately unglowed
  there — but the color table now matches the character window, which *does* glow every
  quality.
- **A glowing item's cell now belongs to the glow.** Every cell sits on a quiet grey
  panel. On a glowing item that panel's hard square edge was still showing at full
  strength through the soft halo, so the cell read as "grey box with a glow behind it"
  instead of the clean lit slot you get in Bags 1. The panel now steps aside for exactly
  as long as that item glows — any glow: rarity, quest gold, or the can't-use red — and
  comes straight back when it stops (item moved out, replaced by something below your
  minimum-quality setting, or the item borders turned off). Empty slots and ordinary
  white/grey items keep their panel exactly as before.
- No new settings, and nothing you had configured changed: the on/off toggle, the
  minimum-quality floor, and the quest-gold-over-red-over-rarity order are all as they were.
  Search dimming is unchanged too — a dimmed glowing slot still recedes as one piece.
- Changed: Daseeki Bags is now licensed **All Rights Reserved** rather than MIT, matching the rest of the suite; 2.0 is an independent rewrite that vendors no third-party code, and the 1.x vendored-library attribution stays with tag `v1.1.5`, the last release that shipped it.

## 1.1.5
- Maintenance release; no user-facing changes. (This entry was missing: the tag shipped without one.)

## 1.1.4
- Fixed item/keyring changes not propagating when both accounts were already online when a session started — API-poll discovery now also sends the item manifest, not just gold.
- Fixed rev divergence sticking forever: OnManifest now re-syncs on any rev mismatch (not just when behind), so a phantom stale rev heals on next contact.
- Closed login race: after the initial recompute finalises our rev, manifests are re-advertised to all known peers so they don't hold a one-step-behind snapshot.

## 1.1.3
- Keyring now caches live during play (and reliably on login) instead of only at an unreliable login snapshot, so keys stay current and sync across accounts. Existing characters need to be logged in once to refresh their keyring.
- Hardened cross-account item counts: zero/stale entries are dropped on receive and any legacy zero counts are scrubbed on load.
- Added `/dbg mesh item <id>` to list which characters (local and other-account) hold a given item.

## 1.1.2
- Fixed a Lua error in the cross-account sync roster poll when the server hadn't yet delivered the channel member list (`'for' limit must be a number`).

## 1.1.1
- Renamed the short chat command from `/bgn` to `/dbg` to avoid colliding with Bagnon. The full `/Daseeki-Bags` command is unchanged.

## 1.1.0
- Added **Cross-Account Sync**: share data live between your own accounts while both are logged in, no guild/party/raid required.
  - Gold, per-character item counts, and tracked currencies now appear in their tooltips for characters on your other accounts, grouped under an "Other Accounts" section beneath your current account's characters.
  - Synced characters show their real class color and race icon.
  - Uses a shared token + channel (set in the options panel under "Cross-Account Sync"). Optionally reuses an existing addon channel to save a channel slot.
  - Efficient by design: a lightweight manifest is exchanged on login, full data is sent only for characters that actually changed, and live edits (loot/sell/craft) push just the changed items — staying well under WoW's addon-message limits.
  - Last-known data for other accounts persists between sessions, so it still shows after those accounts log off.
  - New chat commands: `/bgn mesh` (status), `/bgn mesh send` (force a push), `/bgn mesh clear` (wipe received data).
- Money tooltip now lists your top characters per account with the rest summed into an "Others" line.

## 1.0.0
- Initial CurseForge release.
