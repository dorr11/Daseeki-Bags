![](http://jaliborc.com/media/addons/large/stalecheck.webp)
[![Patreon](http://img.shields.io/badge/news%20&%20rewards-patreon-ff4d42)](https://www.patreon.com/jaliborc)
[![Paypal](http://img.shields.io/badge/donate-paypal-1d3fe5)](https://www.paypal.me/jaliborc)
[![Discord](http://img.shields.io/badge/discuss-discord-5865F2)](https://bit.ly/discord-jaliborc)

# StaleCheck-1.0 :date:
A library that helps users keep your addons up to date. It handles both detecting when a new version of your addon is available and letting users know of it in an unobtrusive way.

### Usage
You can simply call the library to check for updates (after saved variables have been loaded):

```lua
Lib:CheckForUpdates("MyAddon", My_Saved_Vars)
```

The library will store all the information it needs under `My_Saved_Vars.latest`. You can also embed the library or specify an icon to be shown in dialog popups.

```lua
MyAddon:Embed(Lib)
MyAddon:CheckForUpdates("MyAddon", My_Saved_Vars, "Interface/Addons/MyAddon/myIcon")
```

### Notes
- Version numbers must be in `x[.x][.x]` format.  For example: `'5'`, `'5.0'` and `'5.0.0'` are all valid version numbers.
- Add `'b'` or `'a'` somewhere to version number to mark it as beta/alpha version (example: `'5.0b'` and `'5.0 beta'` will both be interpreted as beta builds).
- Creating popups through the blizzard API causes taint. Thus, the library will only show a popup message if `Sushi-3.1` is loaded. Otherwise, a chat message will be printed instead.

### Reminder!
If you use this library, please list it as one of your dependencies in the CurseForge admin system. It's a big help! :+1:
