# Pandemic Highlighter

Managed Plater hook payload for highlighting your own player or pet DoTs on enemy nameplates when they enter the pandemic window.

## Behavior

- Tracks a shipped editable DoT table grouped by class.
- Only considers debuffs cast by you or your pet.
- Uses live nameplate aura timing for the real check: `remaining <= duration * 0.30`.
- Can alert on the debuff icon, the nameplate, or both.
- Supports `glow`, `pixel glow`, `enlarge`, and `dim others`.
- Can queue a global sound when a debuff first enters the pandemic window.
- Buffers sound bursts so many simultaneous DoT windows do not all fire on the same frame.

## Files

- Source hook: `docs/plater/pandemic-debuff-highlighter.lua`
- Generator: `docs/plater/generate-pandemic-debuff-highlighter-import.lua`
- Generated import: `docs/plater/pandemic-debuff-highlighter-import.txt`

## Notes

- This is implemented as a Plater hook mod instead of a per-aura Plater script because the requested feature set needs shared state across multiple nameplates for dimming and sound queueing.
- The runtime path is optimized to avoid full plate recounts on every nameplate update. Global dim sweeps only happen when the overall pandemic-active state flips.
- The reference durations in the spell table are seeded from the local wow-tools DB2 export, but runtime pandemic math always uses the live aura duration currently shown by Plater.
- The shipped spell table is intentionally readable and editable in the hook source.
