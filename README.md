# 🛡️ MedaAuras

**Modular aura and indicator toolkit for World of Warcraft.** Lightweight mini-addons in one package.

![WoW](https://img.shields.io/badge/WoW-12.0%2B-orange) ![License](https://img.shields.io/badge/license-MIT-blue)

---

## ✨ Features

- 🧩 **Modular architecture** — each feature is an independent mini-addon with its own settings
- 🔇 **Error isolation** — one module crashing won't break the rest
- 🎨 **MedaUI integration** — consistent, clean settings interface
- ⚙️ **Per-module config** — sidebar navigation with enable/disable checkboxes

### Focus Interrupt Helper

- 🟢 **Color-coded interrupt status** — green (in range + ready), red (out of range), orange (on cooldown)
- 🎯 **Focus priority** — checks focus target first, falls back to current target (or focus-only mode)
- 🔄 **Three display modes:**
  - **Standalone Icon** — draggable icon with cooldown timer
  - **Action Bar Overlay** — color wash on your existing bar button
  - **Auto-Detect (CD Hook)** — hooks button updates for reliable detection (ElvUI compatible)
- 📊 **CDM overlay** — also colors your interrupt in Blizzard's CooldownViewer
- ⏱️ **Self-tracking cooldown** — bypasses Blizzard's "secret values" restriction with its own timer
- 🐾 **Warlock pet support** — detects Spell Lock, Axe Toss, and Grimoire: Fel Ravager including button morphing
- 🎨 **Fully customizable** colors, icon size, overlay opacity & cosmetic icon override

### Mana Tracker

- 🔵 **Always-visible mana display** — shows your current mana regardless of combat state or druid form
- 🛡️ **Secret value safe** — handles WoW 12.0+ secret numbers without crashing
- 📊 **Bar or Orb** — two display styles, fully customizable colors, textures, and sizing

### Group Mana Tracker

- 💧 **Healer mana at a glance** — shows mana for every healer in your party or raid
- 🧊 **Druid form aware** — remembers last known mana when druids shapeshift instead of showing zero
- 🍺 **Drinking alert** — configurable banner with countdown bar when a healer starts drinking, with optional sound
- 🔒 **Taint safe** — displays secret mana values directly without breaking in M+ or restricted contexts

### Gone Fishin'

- 🎣 **Three-panel HUD** — left (zone & session stats), right (zone fish checklist), and bottom (favorites, best spot, lure tips) panels appear while fishing; each panel can be dragged independently and remembers its position
- 🔒 **Lock / unlock** — panels are locked by default to prevent accidental moves; unlock from settings to reposition, then re-lock
- 🐟 **Zone fish checklist** — live checklist of every fish available in the current zone with quality-colored names and lifetime counts; scrolls via mouse wheel when more than 6 are caught
- 📂 **Collapsible junk & missing** — `[+] Junk` and `[+] Missing` sections sit below the fish list and expand on click to show junk items caught in the zone or fish you haven't caught yet (dimmed/desaturated)
- ⭐ **Favorite spots** — mark any fishing location as a favorite with world map pins and distance indicator on the HUD
- 🏆 **Best spot tracking** — automatically surfaces the zone with the most fishing pool catches
- 🧪 **Lure hints** — HUD suggests lures for uncaught fish in your current zone
- 📊 **Stats window** — draggable panel with three tabs:
  - **Overview** — total caught, casts, catch rate, time fished, fish/hour, longest streak, rarest catch, unique count
  - **Collection** — Midnight Pokedex with per-category progress bars (Fish, Lures, Treasures, Lines, Rods, Recipes) plus dynamic "Other Catches" section; sort, search, and rich hover tooltips with zone/pool/rarity data
  - **Zones** — expandable zone rows with subzone breakdowns and favorite buttons
- 🗺️ **Map pins** — favorite fishing spots appear on the world map
- 📤 **Export** — dump discovery data for crowd-sourcing static datasets
- 🔄 **Versioned migrations** — SavedVariables safely upgraded across addon updates, never losing data

---

## 🚀 Quick Start

```
/mwa          → Open settings panel
/mauras       → Open settings panel (alias)
```

---

## 📦 Install

Download from [CurseForge](https://legacy.curseforge.com/wow/addons/medaauras) • [Wago](https://addons.wago.io/addons/medaauras) • [GitHub Releases](https://github.com/Medalink/MedaAuras/releases)

Extract to `World of Warcraft/_retail_/Interface/AddOns/` → `/reload`

**Requires:** [MedaUI](https://github.com/Medalink/MedaUI) (included automatically in packaged releases)

---

Made by **Medalink** 🎮
