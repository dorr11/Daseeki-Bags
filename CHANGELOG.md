# Changelog

## Unreleased

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
