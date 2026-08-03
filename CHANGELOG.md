# Changelog

## Unreleased

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
