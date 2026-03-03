local _, ns = ...
local D = ns.RemindersData
D.contexts = D.contexts or {}
D.contexts.dungeons = D.contexts.dungeons or {}
D.contexts.delves = D.contexts.delves or {}
D.contexts.instanceTypes = D.contexts.instanceTypes or {}
D.contexts.affixes = D.contexts.affixes or {}

D.contexts.instanceTypes.party = { label = "Dungeon" }
D.contexts.instanceTypes.raid = { label = "Raid" }
D.contexts.instanceTypes.scenario = { label = "Scenario" }
D.contexts.instanceTypes.delve = { label = "Delve" }

D.contexts.dungeons[658] = {
    name          = "Pit of Saron",
    season1MPlus  = true,
    header        = "Pit of Saron -- Scourge disease and frost/shadow (Wrath of the Lich King)",
    notes         = {
        "Scourge enemies apply disease effects throughout.",
        "Frost and Shadow magic debuffs from death knight-type mobs.",
        "Poison effects from plague creatures.",
    },
    talentNotes   = "Disease dispel is critical for Scourge effects. Magic dispel important for frost/shadow. Poison dispel useful.",
    dispelPriority = { "dispel_disease", "dispel_magic", "dispel_poison" },
    interruptPriority = {
        { spell = "Shadow Bolt", mob = "Deathwhisper Necrolyte", danger = "high" },
        { spell = "Plague Blast", mob = "Plagueborn Horror", danger = "high" },
        { spell = "Frost Nova", mob = "Wrathbone Coldwraith", danger = "medium" },
    },
}

D.contexts.dungeons[1209] = {
    name          = "Skyreach",
    season1MPlus  = true,
    header        = "Skyreach -- wind and arcane magic (Warlords of Draenor)",
    notes         = {
        "Wind and arcane magic debuffs from Arakkoa casters.",
        "Curse effects from solar priests.",
        "Positioning important for wind knockback mechanics.",
    },
    talentNotes   = "Magic dispel important. Curse dispel helpful. Knockback-resistant positioning talents useful.",
    dispelPriority = { "dispel_magic", "dispel_curse" },
    interruptPriority = {
        { spell = "Solar Heal", mob = "Solar Familiar", danger = "high" },
        { spell = "Flash Bang", mob = "Arakkoa Sun-Talon", danger = "medium" },
        { spell = "Arcane Bolt", mob = "Skyreach Arcanist", danger = "medium" },
    },
}

D.contexts.dungeons[1753] = {
    name          = "Seat of the Triumvirate",
    season1MPlus  = true,
    header        = "Seat of the Triumvirate -- Void/Shadow magic on Argus (Legion)",
    notes         = {
        "Void-infused enemies apply heavy Shadow magic debuffs.",
        "Some encounters have purgeable Void shields.",
    },
    talentNotes   = "Magic dispel critical for Void debuffs. Offensive dispel useful for Void shields.",
    dispelPriority = { "dispel_magic", "offensive_dispel" },
    interruptPriority = {
        { spell = "Void Bolt", mob = "Shadowguard Subjugator", danger = "high" },
        { spell = "Suppression Field", mob = "Void Warden", danger = "high" },
    },
}

D.contexts.dungeons[2526] = {
    name          = "Algeth'ar Academy",
    season1MPlus  = true,
    header        = "Algeth'ar Academy -- arcane curses and magic-heavy (Dragonflight)",
    notes         = {
        "Arcane curse effects on several encounters.",
        "Magic debuffs from draconic casters.",
        "Moderate interrupt requirements.",
    },
    talentNotes   = "Curse dispel is most valuable. Magic dispel helpful. Standard dungeon utility.",
    dispelPriority = { "dispel_curse", "dispel_magic" },
    interruptPriority = {
        { spell = "Arcane Missiles", mob = "Arcane Ravager", danger = "high" },
        { spell = "Mystic Blast", mob = "Unruly Textbook", danger = "medium" },
    },
}

D.contexts.dungeons[2801] = {
    name          = "Windrunner Spire",
    season1MPlus  = true,
    header        = "Windrunner Spire -- poison, curses, and magic in the Windrunner ruins",
    notes         = {
        "Poison Spray from Creeping Spindleweb and Poison Blade from Ardent Cutthroat.",
        "Curse of Darkness (Derelict Duo) spawns a Dark Entity if not dispelled.",
        "Arcane Salvo and Shadow Bolt casters -- interrupt-heavy.",
        "Spellguard's Protection sphere on mobs -- purge or move mobs out.",
    },
    talentNotes   = "Curse dispel is critical (Curse of Darkness). Poison dispel valuable. Offensive dispel (Purge) helps with Spellguard shields.",
    dispelPriority = { "dispel_curse", "dispel_poison", "offensive_dispel", "dispel_magic" },
    interruptPriority = {
        { spell = "Arcane Salvo", mob = "Spellbound Sentry", danger = "high" },
        { spell = "Shadow Bolt", mob = "Derelict Channeler", danger = "high" },
        { spell = "Poison Spray", mob = "Creeping Spindleweb", danger = "medium" },
    },
}

D.contexts.dungeons[2802] = {
    name          = "Murder Row",
    season1MPlus  = false,
    header        = "Murder Row -- Fel magic and poison in Silvermoon's underbelly",
    notes         = {
        "Forbidden Fel practitioners apply heavy magic debuffs.",
        "Fel corruption causes poison-like DoTs.",
        "Enemy Fel shields must be purged for efficient damage.",
    },
    talentNotes   = "Magic dispel important for Fel debuffs. Offensive dispel (Purge/Spellsteal) helps strip Fel shields. Poison dispel useful.",
    dispelPriority = { "dispel_magic", "offensive_dispel", "dispel_poison" },
    interruptPriority = {
        { spell = "Fel Bolt", mob = "Fel Practitioner", danger = "high" },
        { spell = "Shadow Mend", mob = "Fel Acolyte", danger = "high" },
    },
}

D.contexts.dungeons[2803] = {
    name          = "Magister's Terrace",
    season1MPlus  = true,
    header        = "Magister's Terrace -- reimagined; heavy magic and purgeable shields",
    notes         = {
        "Blood elf casters apply stacking magic debuffs.",
        "Magical shields on enemies are frequent -- offensive dispel essential.",
        "Curse effects from fel-touched magisters.",
    },
    talentNotes   = "Offensive dispel (Purge/Spellsteal) is essential for shield mechanics. Magic dispel critical. Curse dispel helpful.",
    dispelPriority = { "offensive_dispel", "dispel_magic", "dispel_curse" },
    interruptPriority = {
        { spell = "Arcane Nova", mob = "Sunblade Magister", danger = "high" },
        { spell = "Mana Detonation", mob = "Sunblade Warlock", danger = "high" },
        { spell = "Fel Crystal Strike", mob = "Fel Crystal Channeler", danger = "medium" },
    },
}

D.contexts.dungeons[2804] = {
    name          = "The Blinding Vale",
    season1MPlus  = false,
    header        = "The Blinding Vale -- unbalanced Light effects and purgeable buffs",
    notes         = {
        "Overwhelming Light debuffs (magic) on several encounters.",
        "Light-empowered enemies gain purgeable buff shields.",
        "High group-wide damage during Light surges.",
    },
    talentNotes   = "Magic dispel critical for Light debuffs. Offensive dispel (Purge) important for Light shields. Defensive cooldowns for surges.",
    dispelPriority = { "dispel_magic", "offensive_dispel" },
    interruptPriority = {
        { spell = "Radiant Bolt", mob = "Light Zealot", danger = "high" },
        { spell = "Blinding Surge", mob = "Blinding Channeler", danger = "high" },
    },
}

D.contexts.dungeons[2805] = {
    name          = "Den of Nalorakk",
    season1MPlus  = false,
    header        = "Den of Nalorakk -- Amani trials with curses, poisons, and disease",
    notes         = {
        "Amani troll casters apply curses during trials of the Loa of War.",
        "Poison effects from jungle creatures and troll alchemists.",
        "Disease mechanics from blood rituals.",
    },
    talentNotes   = "Curse dispel is most important. Poison and disease dispels both valuable. Self-sustain talents helpful for trial encounters.",
    dispelPriority = { "dispel_curse", "dispel_poison", "dispel_disease" },
    interruptPriority = {
        { spell = "Hex of Nalorakk", mob = "Amani Hex Priest", danger = "high" },
        { spell = "Poison Volley", mob = "Jungle Alchemist", danger = "medium" },
        { spell = "Blood Ritual", mob = "Amani Blood Guard", danger = "medium" },
    },
}

D.contexts.dungeons[2806] = {
    name          = "Maisara Caverns",
    season1MPlus  = true,
    header        = "Maisara Caverns -- necromantic Amani caves; interrupt-heavy and disease-laden",
    notes         = {
        "Necromantic casters apply disease and magic debuffs -- extremely interrupt-heavy.",
        "Curse effects from Amani shamans.",
        "Considered one of the hardest Season 1 dungeons due to mechanics density.",
    },
    talentNotes   = "Disease dispel essential for necromantic effects. Curse dispel important. Interrupt-focused talents and short-CD kicks are critical.",
    dispelPriority = { "dispel_disease", "dispel_curse", "dispel_magic" },
    interruptPriority = {
        { spell = "Necrotic Bolt", mob = "Necromantic Channeler", danger = "high" },
        { spell = "Death Curse", mob = "Amani Shaman", danger = "high" },
        { spell = "Shadow Volley", mob = "Cave Shadowcaster", danger = "high" },
        { spell = "Plague Spit", mob = "Blighted Crawler", danger = "medium" },
    },
}

D.contexts.dungeons[2807] = {
    name          = "Nexus-Point Xenas",
    season1MPlus  = true,
    header        = "Nexus-Point Xenas -- Void and Shadowguard magic",
    notes         = {
        "Heavy Shadow/Void magic debuffs from Shadowguard enemies.",
        "Void corruption causes curse-like effects.",
        "Loyalties mechanic requires awareness of enemy buffs -- purge helpful.",
    },
    talentNotes   = "Magic dispel critical for Void debuffs. Curse dispel valuable. Offensive dispel useful for Shadowguard buffs.",
    dispelPriority = { "dispel_magic", "dispel_curse", "offensive_dispel" },
    interruptPriority = {
        { spell = "Void Bolt", mob = "Shadowguard Caster", danger = "high" },
        { spell = "Shadow Mending", mob = "Void Mender", danger = "high" },
        { spell = "Curse of the Void", mob = "Nexus Corruptor", danger = "medium" },
    },
}

D.contexts.dungeons[2808] = {
    name          = "Voidscar Arena",
    season1MPlus  = false,
    header        = "Voidscar Arena -- cosmic combat with heavy magic damage",
    notes         = {
        "Void and cosmic combatants deal heavy magic (Shadow) damage.",
        "Arena mechanics require burst movement and defensives.",
    },
    talentNotes   = "Magic dispel important. Defensive cooldowns and mobility talents valuable for arena mechanics.",
    dispelPriority = { "dispel_magic" },
    interruptPriority = {
        { spell = "Cosmic Bolt", mob = "Void Champion", danger = "high" },
        { spell = "Shadow Nova", mob = "Arena Invoker", danger = "medium" },
    },
}

D.contexts.delves = {
    { name = "The Shadow Enclave", notes = "Shadow and stealth mechanics in an enclosed space." },
    { name = "Collegiate Calamity", notes = "Arcane experiments gone wrong -- magic debuffs and volatile hazards." },
    { name = "Parhelion Plaza", notes = "Light-themed outdoor delve. Available March 31." },
    { name = "The Darkway", notes = "Dark corridors with Void and shadow hazards. Available March 24." },
    { name = "Twilight Crypts", notes = "Undead and shadow casters with disease and magic effects." },
    { name = "Atal'Aman", notes = "Amani troll ruins with curse and poison effects." },
    { name = "The Grudge Pit", notes = "Close-quarters combat with bleeds and physical damage spikes." },
    { name = "The Gulf of Memory", notes = "Void-infused memories with magic debuffs and disorientation." },
    { name = "Sunkiller Sanctum", notes = "Light-corrupted enemies with magic and holy damage." },
    { name = "Shadowguard Point", notes = "Shadowguard military outpost -- magic and shadow debuffs." },
    { name = "Torment's Rise", notes = "Nemesis delve -- high-difficulty boss encounter. Bring defensive cooldowns." },
}

D.contexts.affixes[9] = { name = "Tyrannical", tip = "Boss damage +30%. Prioritize single-target builds and defensive cooldowns for boss encounters." }
D.contexts.affixes[10] = { name = "Fortified", tip = "Trash damage +20%. Prioritize AoE builds and crowd-control utility." }
D.contexts.affixes[152] = { name = "Challenger's Peril", tip = "Dying subtracts 15 seconds from the timer. Play safe and bring defensive talents." }
D.contexts.affixes[158] = { name = "Xal'atath's Bargain: Ascendant", tip = "Periodically spawns Void zones. Stay mobile and avoid lingering in them." }
D.contexts.affixes[159] = { name = "Xal'atath's Bargain: Frenzied", tip = "Non-boss enemies enrage at 30% HP. Soothe or burst them down quickly." }
D.contexts.affixes[160] = { name = "Xal'atath's Bargain: Voidbound", tip = "Void orbs spawn periodically. Collecting them triggers an explosion -- coordinate pickup." }

