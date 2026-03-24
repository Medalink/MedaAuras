# Priority Kick Dimmer

This is a Plater hook mod that dims every enemy nameplate except mobs currently casting an interruptible, high-priority spell.

Plater passes a persistent `modTable` to hook mods. Older drafts of this example called it `scriptTable`; the name itself is not semantically important in Lua, but the current file uses `modTable` to match Plater's docs and avoid confusion.

Files:

- [`priority-kick-dimmer.lua`](/F:/Dev/MedaAuras/docs/plater/priority-kick-dimmer.lua)
- [`priority-kick-dimmer-import.txt`](/F:/Dev/MedaAuras/docs/plater/priority-kick-dimmer-import.txt)
- [`generate-priority-kick-dimmer-import.lua`](/F:/Dev/MedaAuras/docs/plater/generate-priority-kick-dimmer-import.lua)

## What it does

- Keeps priority casters at full alpha.
- Dims all other visible enemy nameplates to a configurable opacity.
- Stops dimming as soon as the cast ends, is interrupted, or finishes.
- Can optionally require that the player actually has an interrupt.
- Can optionally require that the player's interrupt is ready, not just known.

## Why this is combat-safe

- It only reads cast state from Plater and Blizzard spell APIs.
- It only changes frame alpha on existing nameplate frames.
- It does not touch protected actions, secure buttons, targeting, or CVars.
- It restores normal plate alpha by asking Plater to re-run its normal plate update path.

That makes it the same class of work Plater already does during combat for range alpha, target alpha, and similar visual updates.

## Import

1. Open `Plater -> Modding -> Hooking`.
2. Click `Import`.
3. Paste the contents of [`priority-kick-dimmer-import.txt`](/F:/Dev/MedaAuras/docs/plater/priority-kick-dimmer-import.txt).
4. Import the mod.

The import already includes the real Plater options for opacity and interrupt gating.

## Manual setup

1. Open `Plater -> Modding -> Hooking`.
2. Create a new mod.
3. Add these hooks:

- `Initialization`
- `Nameplate Added`
- `Nameplate Removed`
- `Nameplate Updated`
- `Cast Start`
- `Cast Update`
- `Cast Stop`
- `Player Talent Update`
- `Mod Option Changed`

4. Paste the matching function from [`priority-kick-dimmer.lua`](/F:/Dev/MedaAuras/docs/plater/priority-kick-dimmer.lua) into each hook.
5. Open the mod admin `Options` panel and add these real Plater options:

- `Number`: `Dim Opacity`, key `dimOpacityPercent`, min `0`, max `100`, fraction `false`, default `25`
- `Toggle`: `Match All Interruptible Casts`, key `matchAllInterruptibleCasts`, default `false`
- `Toggle`: `Require Known Interrupt`, key `requireKnownInterrupt`, default `false`
  Perf note: cheap after init, because the mod caches whether your character has a supported interrupt until talents/spec change.
- `Toggle`: `Require Ready Interrupt`, key `requireReadyInterrupt`, default `false`
  Perf note: slightly more work than known-only, because the mod checks cooldown readiness during cast evaluation with a short cache.

## Tuning

If you do not add real Plater options, these fallback defaults in `Initialization` still apply:

- `config.dimOpacityPercent = 25`
- `config.requireKnownInterrupt = false`
- `config.requireReadyInterrupt = false`
- `config.matchAllInterruptibleCasts = false`

Meaning:

- `dimOpacityPercent = 25` means non-priority plates stay at 25% opacity.
- `requireKnownInterrupt = true` means the dimmer only engages if your character has an interrupt at all.
- `requireReadyInterrupt = true` means the dimmer only engages if your interrupt is currently usable off cooldown.
- `matchAllInterruptibleCasts = true` means any interruptible cast triggers the dimmer, not just spells from your priority lists.

Performance note:

- `requireKnownInterrupt` is effectively free in combat after the initial resolve, because the answer is cached.
- `requireReadyInterrupt` is still lightweight, but it is the more expensive option because it has to watch interrupt cooldown state. The mod now throttles that with a short cache.

The current code also hard-filters itself to enemy NPC plates, so the import is safe even if you do not add an extra Plater scope filter.

## Priority list strategy

Best:

- Fill `config.priorityNpcSpellIDs` with exact `npcID + spellID` pairs.

Good:

- Fill `config.prioritySpellIDs` with spell IDs.

Fallback:

- Use `priorityNpcSpellNames` or `prioritySpellNames`.

The file now ships with hardcoded `config.prioritySpellIDs` chosen from the local wow-tools client spell exports:

- `22667` `Shadow Command`
- `152893` `Solar Heal`
- `313977` `Curse of the Void`
- `349141` `Radiant Bolt`
- `396812` `Mystic Blast`
- `441747` `Dark Mending`
- `1261326` `Necrotic Bolt`
- `343154` `Holy Wrath`
- `323252` `Raise Dead`

It also ships with a larger `priorityNpcSpellNames` map generated from this repo's reminders data, covering `42` mob/spell priority pairs from [Dungeons.lua](/F:/Dev/MedaAuras/Data/Dungeons.lua). That keeps generic spell names like `Shadow Bolt` and `Void Bolt` scoped to the mobs your reminders data actually marks as important.

`Death Curse` is still left as a fallback name match because that exact spell name did not appear in the current `SpellName` export, so there was no client-backed spell ID to hardcode from the local data set.

If you want maximum precision, replace or extend these with exact `npcID + spellID` entries once you have the authoritative NPC names or IDs for your final pull list.
