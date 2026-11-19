# xpeta

XP progress tracker for WoW Forever (`## Interface: 16001`, client 1.60.1).

```
xpeta (17.66%)
Last kill: 102  |  to level: 55
Last 5 kills: 96  |  to level: 59
XP/h: 4,200  |  ETA 1h 20m
```

## Math

- **Progress** = `UnitXP / UnitXPMax × 100`; **remaining** = `UnitXPMax − UnitXP`
- **Last kill** = XP of the latest kill (including rested/group bonus);
  to level = `⌈remaining / last kill⌉`
- **Last 5 kills** = average of the last ≤ 5 kills; to level = `⌈remaining / average⌉`
- **XP gain** (every source: kills, quests, exploration) = `XP − previous XP`;
  on level-up = `(previous max − previous XP) + XP`
- **XP/h** = `Σ gains in span × 3600 / span`, where span = time since the first
  gain, capped at the rolling window (default 15 min), minimum 60 s.
  Idle longer than the window restarts the span at the next gain.
- **ETA** = `remaining / XP/h`, rounded up to the minute

## Interface

- Events: `PLAYER_XP_UPDATE` (all XP gains), `CHAT_MSG_COMBAT_XP_GAIN` (kill XP,
  parsed via `COMBATLOG_XPGAIN_FIRSTPERSON`), `PLAYER_ENTERING_WORLD`, `ADDON_LOADED`
- API: `UnitXP`, `UnitXPMax`, `UnitLevel`
- Saved: `XpetaDB` (settings), `XpetaCharDB` (last 5 kills, per character)

## Install

Copy this folder to `World of Warcraft/_forever_/Interface/AddOns/xpeta/`.

`/xpeta lock | unlock | window <min> | alpha <0-1> | scale <0.5-3> | reset | resetpos | show | hide`

## License

MIT
