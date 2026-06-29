# MutexDelay-1.0 :watch:
[![Patreon](http://img.shields.io/badge/news%20&%20rewards-patreon-ff4d42)](https://www.patreon.com/jaliborc)
[![Paypal](http://img.shields.io/badge/donate-paypal-1d3fe5)](https://www.paypal.me/jaliborc)
[![Discord](http://img.shields.io/badge/discuss-discord-5865F2)](https://bit.ly/discord-jaliborc)

Straightforward library that allows to easily delay a method call, and to avoid multiple sources making unnecessary multiple calls to the same function for efficiency. Hence, behaves like a mutex over delayed code.

### API Overview
|Name|Description|
|:--|:--|
| :Embed(object) | Adds the library methods to your object. |
| :Delay(time, method [,args]) | Calls the given `method` after a certain `time` with the given `args`. Locks the `method` from further calls until complete.  |
| :Delaying(method) | Whether the `method` is currently locked from further calls. |

### :warning: Reminder!
If you use this library, please list it as one of your dependencies in the CurseForge admin system. It's a big help! :+1: