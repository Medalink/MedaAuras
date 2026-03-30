# Priority Kick Dimmer

This is a Plater hook mod that dims every enemy nameplate except mobs currently casting a tracked spell.

On Midnight clients, interruptibility can be hidden or tainted. The current mod therefore supports three trigger modes:

- focus target casts
- priority list only
- all interruptible casts
- any enemy cast fallback

Plater passes a persistent `modTable` to hook mods. Older drafts of this example called it `scriptTable`; the name itself is not semantically important in Lua, but the current file uses `modTable` to match Plater's docs and avoid confusion.

Files:

- [`priority-kick-dimmer.lua`](/F:/Dev/MedaAuras/docs/plater/priority-kick-dimmer.lua)
- [`priority-kick-dimmer-import.txt`](/F:/Dev/MedaAuras/docs/plater/priority-kick-dimmer-import.txt)
- [`generate-priority-kick-dimmer-import.lua`](/F:/Dev/MedaAuras/docs/plater/generate-priority-kick-dimmer-import.lua)

## What it does

- Keeps tracked casters at full alpha.
- Dims all other visible enemy nameplates to a configurable opacity.
- Stops dimming as soon as the cast ends, is interrupted, or finishes.
- Can optionally require that the player actually has an interrupt.
- Can optionally require that the player's interrupt is ready, not just known.
- Lets you use your priority list as the authoritative trigger path, without depending on Midnight interrupt-state reads.
- Includes an `any cast` fallback toggle when you want guaranteed behavior even on clients that hide interruptibility.
- Includes a focus-target trigger toggle so your focused mob can force the dimmer when it starts casting.

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

The import already includes the real Plater options for opacity, trigger mode, and interrupt gating.

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

- `Number`: `Cast Dim Opacity`, key `dimOpacityPercent`, min `0`, max `100`, fraction `false`, default `25`
  Meaning: `0` = invisible while dimmed, `100` = no dim effect.
- `Toggle`: `Trigger On Focus Target Casts`, key `matchFocusTargetCasts`, default `false`
  Meaning: if your current focus target has a visible enemy NPC nameplate and starts casting or channeling, the dimmer triggers even outside the normal priority list.
- `Toggle`: `Match Any Enemy Cast (Fallback)`, key `matchAnyEnemyCasts`, default `false`
  Meaning: any visible enemy NPC cast or channel triggers the dimmer, including non-interruptible casts. This is the reliable fallback mode on Midnight.
- `Toggle`: `Match All Interruptible Casts`, key `matchAllInterruptibleCasts`, default `false`
  Meaning: any interruptible enemy NPC cast triggers the dimmer instead of only your priority list. On Midnight this is best-effort because Blizzard can hide interrupt state.
- `Toggle`: `Require Known Interrupt`, key `requireKnownInterrupt`, default `false`
  Perf note: cheap after init, because the mod caches whether your character has a supported interrupt until talents/spec change.
- `Toggle`: `Require Ready Interrupt`, key `requireReadyInterrupt`, default `false`
  Perf note: slightly more work than known-only, because the mod checks cooldown readiness during cast evaluation with a short cache.
- `Toggle`: `Debug Output`, key `debugEnabled`, default `false`
- `Toggle`: `Debug Successes`, key `debugSuccesses`, default `false`

## Tuning

If you do not add real Plater options, these fallback defaults in `Initialization` still apply:

- `config.dimOpacityPercent = 25`
- `config.matchFocusTargetCasts = false`
- `config.matchAnyEnemyCasts = false`
- `config.requireKnownInterrupt = false`
- `config.requireReadyInterrupt = false`
- `config.matchAllInterruptibleCasts = false`
- `config.debugEnabled = false`
- `config.debugSuccesses = false`

Meaning:

- `dimOpacityPercent = 25` means non-priority plates stay at 25% opacity during a tracked cast.
- `matchFocusTargetCasts = true` means your current focus target can trigger the dimmer with any cast or channel as long as its enemy NPC nameplate is visible.
- `matchAnyEnemyCasts = true` means any visible enemy NPC cast or channel triggers the dimmer, including non-interruptible casts.
- `requireKnownInterrupt = true` means the dimmer only engages if your character has an interrupt at all.
- `requireReadyInterrupt = true` means the dimmer only engages if your interrupt is currently usable off cooldown.
- `matchAllInterruptibleCasts = true` means any interruptible cast triggers the dimmer, not just spells from your priority lists. On Midnight this is best-effort.
- `debugEnabled = true` prints failure reasons to chat, including which gate failed.
- `debugSuccesses = true` also prints successful matches, which is noisier but useful while diagnosing.

Mode precedence:

- `matchFocusTargetCasts = true` wins first for the focused unit
- else `matchAnyEnemyCasts = true`
- else `matchAllInterruptibleCasts = true`
- else the mod uses your priority list only

Performance note:

- `requireKnownInterrupt` is effectively free in combat after the initial resolve, because the answer is cached.
- `requireReadyInterrupt` is still lightweight, but it is the more expensive option because it has to watch interrupt cooldown state. The mod now throttles that with a short cache.
- Leave both debug options off outside troubleshooting, because chat logging is intentionally more verbose than the normal runtime path.

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
