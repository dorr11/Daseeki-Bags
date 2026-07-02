# Changelog

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
