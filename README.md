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
- 🎨 **Fully customizable** colors, icon size, overlay opacity & cosmetic icon override

### Mana Tracker

- 🔵 **Always-visible mana display** — shows your current mana regardless of combat state or druid form
- 🛡️ **Secret value safe** — handles WoW 12.0+ secret numbers without crashing; StatusBar fill, color curves, and text rendering all protected via `pcall` fallbacks
- 📊 **Two display styles:**
  - **Bar** — configurable width, height, orientation (horizontal/vertical), and fill texture
  - **Orb** — circular sphere that fills and drains via MaskTexture clipping; adjustable radius, orb shape (solid, glow, glass), and fill texture
- 🎨 **Full customization** — mana color, background color, border color, opacity, text size, text anchor, show/hide text, percentage or raw value display
- 🖼️ **Texture browser** — browse built-in, custom, and LibSharedMedia textures with inline previews; bar textures render full-width fills, orb shapes show a side preview panel
- 👁️ **Live preview** — real-time preview panel in settings shows exactly how the display looks as you tweak options
- 🔀 **Live mode switching** — swap between bar and orb at any time; settings panel shows only the controls relevant to the active mode
- 📝 **Diagnostic logging** — throttled snapshots to MedaDebug showing secret value status, curve results, and display mode

---

## 🚀 Quick Start

```
/mauras       → Open settings panel
```

---

## 📦 Install

Download from [CurseForge](https://legacy.curseforge.com/wow/addons/medaauras) • [Wago](https://addons.wago.io/addons/medaauras) • [GitHub Releases](https://github.com/Medalink/MedaAuras/releases)

Extract to `World of Warcraft/_retail_/Interface/AddOns/` → `/reload`

**Requires:** [MedaUI](https://github.com/Medalink/MedaUI) (included automatically in packaged releases)

---

Made by **Medalink** 🎮
