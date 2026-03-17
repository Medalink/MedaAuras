from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEED = REPO_ROOT / "scripts" / "interrupt_seed.json"
DEFAULT_OUTPUT = REPO_ROOT / "Data" / "Interrupts.lua"
DEFAULT_DB2_ROOT = Path("F:/Dev/wow-tools/data/db2")

LUA_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Data/Interrupts.lua from wow-tools DB2 spell data plus a curated seed."
    )
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--db2-root", type=Path, default=DEFAULT_DB2_ROOT)
    parser.add_argument("--build", type=str, default=None, help="Specific DB2 build directory name")
    return parser.parse_args()


def to_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def lua_str(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def lua_scalar(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return lua_str(value)
    if isinstance(value, (int, float)):
        return str(value)
    return None


def lua_key(key):
    if isinstance(key, int):
        return f"[{key}]"
    if isinstance(key, str) and LUA_IDENT_RE.match(key):
        return key
    return f"[{lua_str(str(key))}]"


def render_lua(value, indent: int = 0) -> list[str]:
    pad = "    " * indent
    scalar = lua_scalar(value)
    if scalar is not None:
        return [f"{pad}{scalar}"]

    if isinstance(value, list):
        if not value:
            return [f"{pad}{{}}"]
        lines = [f"{pad}{{"]
        for item in value:
            item_lines = render_lua(item, indent + 1)
            item_lines[-1] = item_lines[-1] + ","
            lines.extend(item_lines)
        lines.append(f"{pad}}}")
        return lines

    if isinstance(value, dict):
        if not value:
            return [f"{pad}{{}}"]
        lines = [f"{pad}{{"]
        for key, item in value.items():
            item_scalar = lua_scalar(item)
            prefix = f"{'    ' * (indent + 1)}{lua_key(key)} = "
            if item_scalar is not None:
                lines.append(prefix + item_scalar + ",")
                continue
            item_lines = render_lua(item, indent + 1)
            first = item_lines[0].lstrip()
            lines.append(prefix + first)
            lines.extend(item_lines[1:])
            lines[-1] = lines[-1] + ","
        lines.append(f"{pad}}}")
        return lines

    raise TypeError(f"Unsupported Lua value: {type(value)!r}")


def assign_block(name: str, value) -> str:
    lines = render_lua(value)
    lines[0] = f"{name} = {lines[0].lstrip()}"
    return "\n".join(lines)


def resolve_build_root(db2_root: Path, build_name: str | None) -> Path:
    if build_name:
        build_root = db2_root / build_name
        if not build_root.is_dir():
            raise FileNotFoundError(f"DB2 build not found: {build_root}")
        return build_root

    builds = sorted([path for path in db2_root.iterdir() if path.is_dir()], key=lambda path: path.name, reverse=True)
    if not builds:
        raise FileNotFoundError(f"No DB2 builds found under {db2_root}")
    return builds[0]


def load_spell_metadata(build_root: Path) -> dict[int, dict[str, int | str]]:
    csv_root = build_root / "csv"
    spell_name_path = csv_root / "SpellName.csv"
    spell_misc_path = csv_root / "SpellMisc.csv"
    spell_cooldowns_path = csv_root / "SpellCooldowns.csv"

    if not spell_name_path.exists():
        raise FileNotFoundError(f"Missing DB2 export: {spell_name_path}")
    if not spell_misc_path.exists():
        raise FileNotFoundError(f"Missing DB2 export: {spell_misc_path}")
    if not spell_cooldowns_path.exists():
        raise FileNotFoundError(f"Missing DB2 export: {spell_cooldowns_path}")

    names: dict[int, str] = {}
    icons: dict[int, int] = {}
    cooldowns: dict[int, int] = {}

    with spell_name_path.open("r", encoding="utf-8", errors="ignore", newline="") as handle:
        for row in csv.DictReader(handle):
            spell_id = to_int(row.get("ID"))
            if not spell_id:
                continue
            name = (row.get("Name_lang") or "").strip()
            if name:
                names[spell_id] = name

    with spell_misc_path.open("r", encoding="utf-8", errors="ignore", newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("DifficultyID") != "0":
                continue
            spell_id = to_int(row.get("SpellID"))
            icon_id = to_int(row.get("SpellIconFileDataID"))
            if spell_id and icon_id and spell_id not in icons:
                icons[spell_id] = icon_id

    with spell_cooldowns_path.open("r", encoding="utf-8", errors="ignore", newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("DifficultyID") != "0":
                continue
            spell_id = to_int(row.get("SpellID"))
            if not spell_id:
                continue
            recovery = to_int(row.get("RecoveryTime")) or 0
            category = to_int(row.get("CategoryRecoveryTime")) or 0
            start = to_int(row.get("StartRecoveryTime")) or 0
            cooldown_ms = max(recovery, category, start)
            if cooldown_ms > 0:
                cooldowns[spell_id] = cooldown_ms // 1000

    spell_meta: dict[int, dict[str, int | str]] = {}
    for spell_id, name in names.items():
        spell_meta[spell_id] = {"name": name}
        if spell_id in icons:
            spell_meta[spell_id]["icon"] = icons[spell_id]
        if spell_id in cooldowns:
            spell_meta[spell_id]["baseCD"] = cooldowns[spell_id]

    return spell_meta


def load_seed(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_interrupt_entry(entry: dict, spell_meta: dict[int, dict[str, int | str]]) -> dict:
    spell_id = int(entry["spellID"])
    meta = spell_meta.get(spell_id)
    if not meta:
        raise KeyError(f"Missing DB2 spell metadata for spell {spell_id}")

    name = entry.get("name") or meta.get("name")
    icon = entry.get("icon", meta.get("icon"))
    base_cd = entry.get("baseCD", meta.get("baseCD"))

    if not name:
        raise KeyError(f"Missing spell name for spell {spell_id}")
    if icon is None:
        raise KeyError(f"Missing icon for spell {spell_id}")
    if base_cd is None:
        raise KeyError(f"Missing cooldown for spell {spell_id}")

    normalized = {
        "id": spell_id,
        "spellID": spell_id,
        "name": name,
        "class": entry["class"],
        "baseCD": int(base_cd),
        "icon": icon,
    }
    if entry.get("pet") is not None:
        normalized["pet"] = bool(entry["pet"])
    if entry.get("altIDs"):
        normalized["altIDs"] = [int(value) for value in entry["altIDs"]]
    if entry.get("petSpellID"):
        normalized["petSpellID"] = int(entry["petSpellID"])
    if entry.get("focusScan"):
        normalized["focusScan"] = True
    return normalized


def normalize_capability(value: dict, all_interrupts_by_id: dict[int, dict]) -> dict:
    if value.get("hasInterrupt") is False:
        return {"hasInterrupt": False}

    spell_id = int(value["spellID"])
    source = all_interrupts_by_id.get(spell_id)
    if not source:
        raise KeyError(f"Capability references unknown interrupt spell {spell_id}")

    normalized = {"spellID": spell_id}
    if value.get("baseCD") is not None:
        normalized["baseCD"] = int(value["baseCD"])
    if value.get("name") is not None:
        normalized["name"] = value["name"]
    if value.get("icon") is not None:
        normalized["icon"] = value["icon"]
    if value.get("pet") is not None:
        normalized["pet"] = bool(value["pet"])
    if value.get("petSpellID") is not None:
        normalized["petSpellID"] = int(value["petSpellID"])
    if value.get("talentCheck") is not None:
        normalized["talentCheck"] = int(value["talentCheck"])

    if "baseCD" not in normalized and source.get("baseCD") is not None:
        normalized["baseCD"] = int(source["baseCD"])
    if "pet" not in normalized and source.get("pet") is not None:
        normalized["pet"] = bool(source["pet"])
    if "name" not in normalized and source.get("name") is not None:
        normalized["name"] = source["name"]

    return normalized


def normalize_spec_capabilities(seed_caps: dict, all_interrupts_by_id: dict[int, dict]) -> dict[int, dict]:
    result: dict[int, dict] = {}
    for spec_id_raw, value in seed_caps.items():
        spec_id = int(spec_id_raw)
        normalized = {
            "class": value["class"],
            "role": value["role"],
        }
        if value.get("hasInterrupt") is False:
            normalized["hasInterrupt"] = False
            result[spec_id] = normalized
            continue

        if "primary" in value:
            normalized["primary"] = normalize_capability(value["primary"], all_interrupts_by_id)
        if value.get("alternates"):
            normalized["alternates"] = [
                normalize_capability(item, all_interrupts_by_id) for item in value["alternates"]
            ]
        if value.get("extras"):
            normalized["extras"] = [
                normalize_capability(item, all_interrupts_by_id) for item in value["extras"]
            ]
        result[spec_id] = normalized
    return result


def normalize_role_fallbacks(seed_role_fallbacks: dict, all_interrupts_by_id: dict[int, dict]) -> dict:
    result = {}
    for class_token, role_map in seed_role_fallbacks.items():
        normalized_roles = {}
        for role, value in role_map.items():
            normalized_roles[role] = normalize_capability(value, all_interrupts_by_id)
        result[class_token] = normalized_roles
    return result


def normalize_class_fallbacks(seed_class_fallbacks: dict, all_interrupts_by_id: dict[int, dict]) -> dict:
    result = {}
    for class_token, value in seed_class_fallbacks.items():
        result[class_token] = normalize_capability(value, all_interrupts_by_id)
    return result


def build_all_interrupts_table(all_interrupt_entries: list[dict]) -> dict[int, dict]:
    result = {}
    for entry in all_interrupt_entries:
        result[entry["spellID"]] = {
            "name": entry["name"],
            "cd": entry["baseCD"],
            "icon": entry["icon"],
        }
    return result


def build_interrupts_list(all_interrupt_entries: list[dict]) -> list[dict]:
    result = []
    for entry in all_interrupt_entries:
        if not entry.get("focusScan"):
            continue
        item = {
            "id": entry["spellID"],
            "name": entry["name"],
            "class": entry["class"],
            "baseCD": entry["baseCD"],
        }
        if entry.get("pet") is not None:
            item["pet"] = bool(entry["pet"])
        if entry.get("altIDs"):
            item["altIDs"] = list(entry["altIDs"])
        if entry.get("petSpellID") is not None:
            item["petSpellID"] = entry["petSpellID"]
        result.append(item)
    return result


def build_lookup_only_interrupts(all_interrupt_entries: list[dict]) -> list[dict]:
    result = []
    for entry in all_interrupt_entries:
        if entry.get("focusScan"):
            continue
        item = {
            "id": entry["spellID"],
            "name": entry["name"],
            "class": entry["class"],
            "baseCD": entry["baseCD"],
        }
        if entry.get("pet") is not None:
            item["pet"] = bool(entry["pet"])
        if entry.get("altIDs"):
            item["altIDs"] = list(entry["altIDs"])
        if entry.get("petSpellID") is not None:
            item["petSpellID"] = entry["petSpellID"]
        result.append(item)
    return result


def build_class_defaults(class_interrupt_order: dict, all_interrupts_by_id: dict[int, dict]) -> dict:
    result = {}
    for class_token, spell_ids in class_interrupt_order.items():
        if not spell_ids:
            continue
        source = all_interrupts_by_id[int(spell_ids[0])]
        result[class_token] = {
            "id": source["spellID"],
            "cd": source["baseCD"],
            "name": source["name"],
        }
    return result


def build_spec_overrides(spec_capabilities: dict[int, dict], class_defaults: dict[str, dict]) -> dict[int, dict]:
    result = {}
    for spec_id, value in spec_capabilities.items():
        primary = value.get("primary")
        if not primary:
            continue
        class_default = class_defaults.get(value["class"])
        if not class_default:
            continue

        primary_spell = primary["spellID"]
        primary_cd = primary.get("baseCD")
        if (
            primary_spell == class_default["id"]
            and primary_cd == class_default["cd"]
            and not primary.get("pet")
            and not primary.get("petSpellID")
        ):
            continue

        override = {
            "id": primary_spell,
            "cd": primary_cd,
            "name": primary["name"],
        }
        if primary.get("pet"):
            override["isPet"] = True
        if primary.get("petSpellID"):
            override["petSpellID"] = primary["petSpellID"]
        result[spec_id] = override
    return result


def build_spec_no_interrupt(spec_capabilities: dict[int, dict]) -> dict[int, bool]:
    return {spec_id: True for spec_id, value in spec_capabilities.items() if value.get("hasInterrupt") is False}


def build_healer_keeps_kick(role_fallbacks: dict) -> dict[str, bool]:
    result = {}
    for class_token, roles in role_fallbacks.items():
        healer = roles.get("HEALER")
        if healer and healer.get("hasInterrupt") is not False:
            result[class_token] = True
    return result


def build_spec_extra_kicks(spec_capabilities: dict[int, dict], all_interrupts_by_id: dict[int, dict]) -> dict[int, list[dict]]:
    result = {}
    for spec_id, value in spec_capabilities.items():
        extras = value.get("extras") or []
        if not extras:
            continue
        rows = []
        for extra in extras:
            source = all_interrupts_by_id[extra["spellID"]]
            row = {
                "id": extra["spellID"],
                "cd": extra.get("baseCD", source["baseCD"]),
                "name": extra.get("name", source["name"]),
                "icon": extra.get("icon", source["icon"]),
            }
            if extra.get("talentCheck") is not None:
                row["talentCheck"] = extra["talentCheck"]
            rows.append(row)
        result[spec_id] = rows
    return result


def build_data_model(seed: dict, spell_meta: dict[int, dict[str, int | str]], build_name: str) -> dict:
    all_interrupt_entries = [normalize_interrupt_entry(entry, spell_meta) for entry in seed["allInterrupts"]]
    all_interrupts_by_id = {entry["spellID"]: entry for entry in all_interrupt_entries}

    class_interrupt_order = {
        class_token: [int(value) for value in spell_ids]
        for class_token, spell_ids in seed["classInterruptOrder"].items()
    }
    spec_capabilities = normalize_spec_capabilities(seed["specCapabilities"], all_interrupts_by_id)
    role_fallbacks = normalize_role_fallbacks(seed["roleFallbacks"], all_interrupts_by_id)
    class_fallbacks = normalize_class_fallbacks(seed["classFallbacks"], all_interrupts_by_id)
    class_defaults = build_class_defaults(class_interrupt_order, all_interrupts_by_id)

    return {
        "buildName": build_name,
        "allInterrupts": build_all_interrupts_table(all_interrupt_entries),
        "interrupts": build_interrupts_list(all_interrupt_entries),
        "lookupOnlyInterrupts": build_lookup_only_interrupts(all_interrupt_entries),
        "classDefaults": class_defaults,
        "classInterruptList": class_interrupt_order,
        "specOverrides": build_spec_overrides(spec_capabilities, class_defaults),
        "specNoInterrupt": build_spec_no_interrupt(spec_capabilities),
        "healerKeepsKick": build_healer_keeps_kick(role_fallbacks),
        "specCapabilities": spec_capabilities,
        "roleFallbacks": role_fallbacks,
        "classFallbacks": class_fallbacks,
        "cdReductionTalents": {int(k): v for k, v in seed["cdReductionTalents"].items()},
        "cdOnKickTalents": {int(k): v for k, v in seed["cdOnKickTalents"].items()},
        "specExtraKicks": build_spec_extra_kicks(spec_capabilities, all_interrupts_by_id),
        "spellAliases": {int(k): int(v) for k, v in seed["spellAliases"].items()},
        "classColors": seed["classColors"],
    }


def render_file(data: dict) -> str:
    sections: list[str] = [
        "-- Auto-generated by scripts/generate_interrupt_data.py",
        f"-- Source: scripts/interrupt_seed.json + wow-tools DB2 build {data['buildName']}",
        "-- Do not edit this file by hand.",
        "",
        "local ADDON_NAME, ns = ...",
        "",
        "local InterruptData = {}",
        "ns.InterruptData = InterruptData",
        "",
        "if MedaAuras and MedaAuras.Log then",
        '    MedaAuras.Log("[InterruptData] Loaded OK")',
        "end",
        "",
        "-- ============================================================================",
        "-- All interrupt spells keyed by spellID (fast lookup for laundering checks)",
        "-- ============================================================================",
        "",
        assign_block("InterruptData.ALL_INTERRUPTS", data["allInterrupts"]),
        "",
        "-- ============================================================================",
        "-- Full array with class/pet metadata (for FocusInterruptHelper-style iteration)",
        "-- ============================================================================",
        "",
        assign_block("InterruptData.INTERRUPTS", data["interrupts"]),
        "",
        "InterruptData.INTERRUPT_BY_SPELL = {}",
        "for _, info in ipairs(InterruptData.INTERRUPTS) do",
        "    InterruptData.INTERRUPT_BY_SPELL[info.id] = info",
        "end",
    ]

    for entry in data["lookupOnlyInterrupts"]:
        sections.append(assign_block(f"InterruptData.INTERRUPT_BY_SPELL[{entry['id']}]", entry))

    sections.extend(
        [
            "",
            "-- ============================================================================",
            "-- Default (primary) interrupt per class for auto-registration",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.CLASS_DEFAULTS", data["classDefaults"]),
            "",
            "-- ============================================================================",
            "-- Ordered spell IDs to check per class (first known spell wins as primary)",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.CLASS_INTERRUPT_LIST", data["classInterruptList"]),
            "",
            "-- ============================================================================",
            "-- Legacy spec override and no-interrupt tables",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.SPEC_OVERRIDES", data["specOverrides"]),
            "",
            assign_block("InterruptData.SPEC_NO_INTERRUPT", data["specNoInterrupt"]),
            "",
            assign_block("InterruptData.HEALER_KEEPS_KICK", data["healerKeepsKick"]),
            "",
            "-- ============================================================================",
            "-- Spec and role capability metadata",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.SPEC_CAPABILITIES", data["specCapabilities"]),
            "",
            assign_block("InterruptData.ROLE_FALLBACKS", data["roleFallbacks"]),
            "",
            assign_block("InterruptData.CLASS_FALLBACKS", data["classFallbacks"]),
            "",
            "-- ============================================================================",
            "-- Passive CD reduction talents (applied to baseCd on inspect)",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.CD_REDUCTION_TALENTS", data["cdReductionTalents"]),
            "",
            "-- ============================================================================",
            "-- CD reduction on successful interrupt (applied when mob cast is interrupted)",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.CD_ON_KICK_TALENTS", data["cdOnKickTalents"]),
            "",
            "-- ============================================================================",
            "-- Extra kicks granted by spec (second interrupt ability)",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.SPEC_EXTRA_KICKS", data["specExtraKicks"]),
            "",
            "-- ============================================================================",
            "-- Spell aliases: some spells fire different IDs on party vs own client",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.SPELL_ALIASES", data["spellAliases"]),
            "",
            "-- ============================================================================",
            "-- Class colors for the tracker UI",
            "-- ============================================================================",
            "",
            assign_block("InterruptData.CLASS_COLORS", data["classColors"]),
            "",
            "for specID, specData in pairs(InterruptData.SPEC_CAPABILITIES) do",
            "    if specData.hasInterrupt == false then",
            "        InterruptData.SPEC_NO_INTERRUPT[specID] = true",
            "    end",
            "end",
            "",
            "local function NormalizeCapability(classToken, def)",
            "    if not def or def.hasInterrupt == false then return nil end",
            "",
            "    local spellID = def.spellID or def.id",
            "    local entry = InterruptData.INTERRUPT_BY_SPELL[spellID]",
            "    local spellMeta = InterruptData.ALL_INTERRUPTS[spellID]",
            "    if not spellID or not spellMeta then return nil end",
            "",
            "    local normalized = {",
            "        spellID = spellID,",
            "        id = spellID,",
            "        class = classToken or def.class or (entry and entry.class),",
            "        name = def.name or (entry and entry.name) or spellMeta.name,",
            "        baseCD = def.baseCD or def.cd or (entry and entry.baseCD) or spellMeta.cd,",
            "        cd = def.baseCD or def.cd or (entry and entry.baseCD) or spellMeta.cd,",
            "        icon = def.icon or spellMeta.icon,",
            "        pet = def.pet ~= nil and def.pet or (entry and entry.pet) or false,",
            "        altIDs = def.altIDs or (entry and entry.altIDs),",
            "        petSpellID = def.petSpellID,",
            "        talentCheck = def.talentCheck,",
            "    }",
            "",
            "    return normalized",
            "end",
            "",
            "local function BuildCapabilityList(classToken, specData)",
            "    local results = {}",
            "    if not specData or specData.hasInterrupt == false then return results end",
            "",
            "    if specData.primary then",
            "        local primary = NormalizeCapability(classToken, specData.primary)",
            "        if primary then results[#results + 1] = primary end",
            "    end",
            "",
            "    for _, def in ipairs(specData.alternates or {}) do",
            "        local alt = NormalizeCapability(classToken, def)",
            "        if alt then results[#results + 1] = alt end",
            "    end",
            "",
            "    for _, def in ipairs(specData.extras or {}) do",
            "        local extra = NormalizeCapability(classToken, def)",
            "        if extra then results[#results + 1] = extra end",
            "    end",
            "",
            "    return results",
            "end",
            "",
            "function InterruptData:GetSpecData(specID)",
            "    return specID and self.SPEC_CAPABILITIES[specID] or nil",
            "end",
            "",
            "function InterruptData:SpecHasInterrupt(specID)",
            "    local data = self:GetSpecData(specID)",
            "    return data and data.hasInterrupt ~= false or false",
            "end",
            "",
            "function InterruptData:GetSpecInterruptCandidates(specID)",
            "    local data = self:GetSpecData(specID)",
            "    if not data then return {} end",
            "    return BuildCapabilityList(data.class, data)",
            "end",
            "",
            "function InterruptData:GetPrimaryInterruptForSpec(specID)",
            "    local candidates = self:GetSpecInterruptCandidates(specID)",
            "    return candidates[1]",
            "end",
            "",
            "function InterruptData:GetRoleFallbackRecord(classToken, role)",
            "    local classRoles = classToken and self.ROLE_FALLBACKS[classToken]",
            "    return classRoles and role and classRoles[role] or nil",
            "end",
            "",
            "function InterruptData:GetRoleFallbackInterrupt(classToken, role)",
            "    return NormalizeCapability(classToken, self:GetRoleFallbackRecord(classToken, role))",
            "end",
            "",
            "function InterruptData:GetClassFallbackInterrupt(classToken)",
            "    return NormalizeCapability(classToken, classToken and self.CLASS_FALLBACKS[classToken] or nil)",
            "end",
            "",
            "function InterruptData:GetPlayerClassInterruptCandidates(classToken)",
            "    local list = {}",
            "    for _, spellID in ipairs(self.CLASS_INTERRUPT_LIST[classToken] or {}) do",
            "        local normalized = NormalizeCapability(classToken, { spellID = spellID })",
            "        if normalized then",
            "            list[#list + 1] = normalized",
            "        end",
            "    end",
            "    return list",
            "end",
            "",
        ]
    )

    return "\n".join(sections)


def main() -> None:
    args = parse_args()
    build_root = resolve_build_root(args.db2_root, args.build)
    spell_meta = load_spell_metadata(build_root)
    seed = load_seed(args.seed)
    data = build_data_model(seed, spell_meta, build_root.name)
    output = render_file(data)
    args.output.write_text(output, encoding="utf-8", newline="\n")
    print(f"Wrote {args.output} using DB2 build {build_root.name}")


if __name__ == "__main__":
    main()
