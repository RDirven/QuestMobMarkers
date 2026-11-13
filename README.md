# Quest Mob Markers

Shows a yellow **!** on the nameplate of every mob you still need for a quest in WoW Forever, so you can see your quest mobs without hovering over them one by one.

## Features

- A yellow ! next to the health bar of mobs that count for one of your quests
- The mark disappears as soon as your objective for that mob is done
- No quest database: it reads what the game itself says in the mob's tooltip
- In a group: your own progress, plus what your group members still need in a second colour (optional)
- Shows your progress next to the mark (3/8), or how many you still need; a mob that counts for several quests shows all of them (3/8 0/4)
- Settings window with live preview: position, size, text size and colour, opacity, hide in combat

Nameplates have to be on (default key: V).

## Usage

| Command | Effect |
| --- | --- |
| `/qmm` | Open the settings window |
| `/qmm on` / `/qmm off` | Turn the marks on or off |
| `/qmm size <8-64>` | Size of the mark |
| `/qmm pos <x> <y>` | Move the mark (default `0 0`) |
| `/qmm debug` | Print what the addon sees for your target (for bug reports) |

## License

MIT
