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

### Reminders

- 🛡️ **Group coverage panel** — live dispel and utility audit for your dungeon party, auto-triggered on instance entry
- 💊 **Dispel tracking** — shows which debuff types your group can remove (curse, poison, disease, magic) with severity-coded rows
- ⚔️ **Utility tracking** — monitors Bloodlust, Battle Res, Purge/Spellsteal, Enrage removal (Soothe), and Group Stealth (Shroud)
- 🏰 **Midnight dungeons** — full data for all 8 new Midnight dungeons + 4 returning Season 1 M+ dungeons, with per-dungeon hazard notes and dispel priorities
- 🔮 **Dungeon-specific rules** — smart severity escalation (e.g., missing Curse dispel is critical in Windrunner Spire, missing Purge is critical in Magister's Terrace)
- 🔍 **Name-based fallback** — gracefully handles provisional instance IDs via `GetInstanceInfo()` name matching; use `/reminders instanceinfo` to verify IDs in-game
- 🕳️ **Delve support** — auto-detects delves with context-aware recommendations via `C_PartyInfo.IsDelveInProgress()`
- 📊 **Tabbed interface** — Group Comp tab for live audit, Talents tab for context-aware build recommendations
- 🎯 **Talent recommendations** — surfaces top M+ talent and hero talent builds with export strings, popularity, key level, and DPS
- 📋 **Copy-to-clipboard** — one-click copy for talent export strings
- 🔀 **Source-agnostic filtering** — data sources (Archon, Wowhead, Icy Veins, and any future providers) are defined in the data layer; the addon discovers them automatically. Enable/disable individually in settings
- 🎯 **Personal talent reminders** — spec-specific suggestions when you're missing key talents for your content
- 🔔 **Notification banners** — configurable severity-gated alerts with adjustable duration when entering dungeons with coverage gaps
- 🗺️ **Context override** — test your group composition against any dungeon or delve from the dropdown without zoning in
- 📌 **Minimap button** — one-click toggle for the coverage panel
- 🎨 **Theme controls** — panel width, background toggle, and opacity slider

### Shut It

- 🔇 **One-click NPC silencing** — target an NPC and click the minimap button to instantly mute their chat messages and talking head dialog; no confirmation step, takes effect immediately
- 🎯 **Live capture** — runs in the background during delves, dungeons, and open world; logs every message the NPC tries to say while suppressing it in real-time
- 📋 **NPC Explorer** — browse and manage all silenced NPCs in a list/detail panel; search by name or NPC ID to add entries manually without needing to target the NPC in-game
- 🔊 **Automatic voice-over muting** — embeds a database of creature voice-over FileDataIDs built from the community listfile; when you silence an NPC, matching voice files are looked up and muted instantly via `MuteSoundFile` with no manual ID entry needed
- 🔍 **Manual sound ID support** — add individual Sound FileIDs or SoundKit IDs per NPC for anything the auto-lookup misses, with per-entry play and remove buttons; wago.tools URL auto-generated for manual lookup
- 🗣️ **Talking head suppression** — automatically hides the talking head frame and kills the voice-over audio for silenced NPCs
- 📤 **Export / Import** — share your silenced NPC list with friends via a copyable string; per-NPC or export-all, with a paste-to-import popup
- ⌨️ **Slash commands** — `/mwa shutit` (open explorer), `scan` (silence target), `stop` (stop capture), `list` (print all), `export`, `import`

### Lazy Cast

- 🎯 **Role-based auto-targeting** — cast spells on tank, healer, DPS, pet, or self without changing your current target
- 🔢 **Two configurable slots** — each slot pairs a spell with a target role; auto-creates a macro you drag to your action bar
- 🐾 **Pet support** — targets your own pet first, then scans group/raid for other players' pets (hunters, warlocks, etc.)
- 🛡️ **Dead-target fallback** — automatically skips dead group members and picks the next alive player in that role
- 💚 **Self-cast fallback** — optional per-slot toggle for healers who want the spell to land on themselves when no role target is available (off by default to prevent accidental self-casts)

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
