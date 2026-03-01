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
