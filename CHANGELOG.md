# Changelog

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
