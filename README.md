# 🛡️ MedaAuras

**Modular aura and indicator toolkit for World of Warcraft.** Lightweight mini-addons in one package.

![WoW](https://img.shields.io/badge/WoW-12.0%2B-orange) ![License](https://img.shields.io/badge/license-MIT-blue)

---

## ✨ Features

- 🧩 **Modular architecture** — each feature is an independent mini-addon with its own settings
- 🔇 **Error isolation** — one module crashing won't break the rest
- 🎨 **MedaUI integration** — consistent, clean settings interface
- ⚙️ **Per-module config** — shared sidebar navigation with enable/disable toggles and module settings pages
- 📦 **Custom module import** — validate and install standalone MedaAuras module packages directly from the built-in Import page or `/mwa import`

### Focus Interrupt Helper

- 🎯 **Smarter interrupt glow** — highlights your kick based on whether your focus or target is in range and whether the spell is ready
- 🪟 **Multiple display styles** — use a movable standalone icon or color your existing action bar button instead
- 🐾 **Class support** — works with normal interrupts and warlock pet kicks, with simple color and icon customization

### Interrupted

- 🚫 **Party interrupt tracker** — shows your kick and your party's kicks in one list so you can see who is ready
- ⏱️ **Clear cooldown bars** — each player gets a class-colored timer with an optional `READY` state when their interrupt comes back
- 🪟 **Easy to place** — move, resize, and show it only where you want, including dungeons, raids, arena, or open world

### Gone Fishin'

- 🎣 **Fishing HUD** — shows zone info, session totals, fish checklist, favorite spot info, and lure tips while you fish
- ⭐ **Collection tools** — save favorite fishing spots, track your best zones, and see them on the world map
- 📊 **Full fishing journal** — browse overview, collection, and zone stats in a separate window, with export support for your data

### Group Mana Tracker

- 💧 **Healer mana list** — keeps healer mana visible in party and raid so you can check recovery at a glance
- 🍺 **Drinking alerts** — pops a clear warning when a healer starts drinking, with optional sound and countdown bar
- 🎨 **Readable layout** — move the frame, resize it, and tune icons, text, colors, and spacing to fit your UI

### Lazy Cast

- 🎯 **Role-based casting** — cast on tank, healer, DPS, pet, or self without changing your main target
- ✨ **Great for support spells** — ideal for spells like `Power Infusion` or `Misdirection` when you want them to snap to the right target fast
- 🔢 **Two quick slots** — set up two spell slots and place their generated macros straight onto your action bars
- ⭐ **Preferred targets** — save favorite players for each slot and optionally fall back to self when no match is available

### Mana Tracker

- 🔵 **Always-on mana display** — keeps your mana visible even when the default UI would normally hide it
- 📊 **Bar or orb mode** — choose the style that fits your UI, then adjust size, orientation, textures, and text
- 🪟 **Simple positioning** — move it, lock it, and customize colors, borders, and labels without extra setup

### Reminders

- 📊 **All-in-one prep panel** — a four-tab window for personal reminders, group coverage, talent suggestions, and pre-key prep
- ⚔️ **Group coverage checks** — highlights missing dispels, utility, and important interrupts for your current party
- 🗺️ **Dungeon and delve help** — auto-shows in instances and lets you preview other dungeons, delves, classes, roles, and specs from the toolbar

### Shut It

- 🔇 **Silence annoying NPCs** — target an NPC and mute their chat, talking heads, and voice lines with one click
- 📋 **NPC Explorer** — manage your muted list in a dedicated panel and add NPCs by name or ID when needed
- 📤 **Share and fine-tune** — export or import mute lists and add manual sound IDs for anything the automatic mute misses
---

## 🚀 Quick Start

```
/mwa          → Open settings panel
/mauras       → Open settings panel (alias)
/mwa import   → Open custom module import dialog
/mwa lock     → Lock movable addon frames
/mwa unlock   → Unlock movable addon frames
/mr           → Open the Reminders panel
```

---

## 📦 Install

Download from [CurseForge](https://legacy.curseforge.com/wow/addons/medaauras) • [Wago](https://addons.wago.io/addons/medaauras) • [GitHub Releases](https://github.com/Medalink/MedaAuras/releases)

Extract to `World of Warcraft/_retail_/Interface/AddOns/` → `/reload`

**Requires:** [MedaUI](https://github.com/Medalink/MedaUI) (included automatically in packaged releases)

---

Made by **Medalink** 🎮
