# Daseeki Bags

A standalone bag interface for WoW Classic Era — combines all your bags into a single sortable, searchable view, with cross-character item counts and account-wide gold tracking.

## Features

- Single combined bag window (or split per bag) with sorting, search and custom categories.
- Offline browsing of every character's bags, bank and keyring, plus cross-account summaries.
- Cross-character item counts in tooltips, and a Find window that searches all characters at once.
- Sort locks: right-click the sort glyph to mark slots sorting must never touch.
- Draws in the shared Daseeki look, so it matches the rest of the suite.

## Requires

- Optional: [Daseeki Core](../Daseeki-Core) — adds the bag's options panel to the shared Daseeki options hub. Daseeki Bags works standalone without it.
- Optional: [Daseeki Nexus](../Daseeki-Nexus) — when its Inventory module is present, Bags sources its cross-account character summaries from the Nexus graph. Fully optional; Bags falls back to its own store without it.

## Upgrading from 1.x

Install over the top — same folder, same saved variables. Your bags, gold, settings,
keybindings and sort locks are imported automatically on the first login. See `CHANGELOG.md`
(2.0.0) for exactly what carries over and what does not. The 1.x source tree was removed at
the 2.0 cutover; tag `v1.1.5` is the last release that shipped it.

## Credits

1.x was built on top of vendored libraries originally from Jaliborc (João Cardoso) and Tuller's bag addons — see `LICENSE`. 2.0 is an independent rewrite and vendors no third-party code.

## Development

- `harness/run-selftests.cmd` — headless self-test suite under real Lua 5.1 (toc parse, bindings and identity gates, then every registered suite). Exit 0 = all pass.
- `harness/validate-real.lua` — read-only migration validator; point it at *copies* of real 1.x SavedVariables files.
