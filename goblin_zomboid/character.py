"""Vanilla-only character creation and persistent appearance ownership."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import json
import re
import time
from collections.abc import Callable, Mapping
from copy import deepcopy
from typing import Any

MAX_CHARACTER_BYTES = 16 * 1024
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,63}$")
CATEGORY_RE = re.compile(r"^[a-z][a-z0-9_:-]{0,63}$")
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
FIXED_CATEGORIES = {
    "gender",
    "skin_tone",
    "hair_style",
    "hair_color",
    "beard_style",
    "beard_color",
    "profession",
    "trait",
    "body_type",
}
PROPOSAL_KEYS = {
    "name",
    "gender",
    "skin_tone",
    "hair_style",
    "hair_color",
    "beard_style",
    "beard_color",
    "profession",
    "traits",
    "clothing",
    "accessories",
    "body_type",
    "cosmetics",
}
REQUIRED_KEYS = {
    "name",
    "gender",
    "skin_tone",
    "hair_style",
    "hair_color",
    "profession",
    "traits",
    "clothing",
    "accessories",
}


class CharacterError(ValueError):
    """Raised when a character proposal or catalog is unsafe."""


class CharacterLifecycle(str, Enum):
    FRESH = "fresh"
    CREATION_PENDING = "creation_pending"
    ACTIVE = "active"
    DEAD = "dead"
    RECREATE_REQUIRED = "recreate_required"


@dataclass(frozen=True)
class VanillaOption:
    category: str
    option_id: str
    label: str
    source: str = "vanilla"

    @classmethod
    def from_mapping(cls, category: str, raw: Mapping[str, Any]) -> "VanillaOption":
        if not isinstance(category, str) or not CATEGORY_RE.fullmatch(category):
            raise CharacterError("invalid option category")
        if not isinstance(raw, Mapping):
            raise CharacterError("vanilla option must be an object")
        if not all(isinstance(key, str) for key in raw):
            raise CharacterError("vanilla option keys must be strings")
        if set(raw) != {"id", "label", "source"}:
            raise CharacterError("vanilla option has an invalid schema")
        option_id = raw["id"]
        label = raw["label"]
        source = raw["source"]
        if not isinstance(option_id, str) or not ID_RE.fullmatch(option_id):
            raise CharacterError("invalid vanilla option id")
        if (
            not isinstance(label, str)
            or not label.strip()
            or len(label) > 96
            or CONTROL_RE.search(label)
        ):
            raise CharacterError("invalid vanilla option label")
        if source != "vanilla":
            raise CharacterError("non-vanilla option rejected")
        return cls(category, option_id, label.strip(), source)


@dataclass(frozen=True)
class VanillaCatalog:
    version: str
    options: dict[str, tuple[VanillaOption, ...]]

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "VanillaCatalog":
        if not isinstance(raw, Mapping) or set(raw) != {"version", "options"}:
            raise CharacterError("invalid vanilla catalog schema")
        version = raw["version"]
        option_map = raw["options"]
        if (
            not isinstance(version, str)
            or not ID_RE.fullmatch(version)
            or len(version) > 64
        ):
            raise CharacterError("invalid vanilla catalog version")
        if not isinstance(option_map, Mapping) or not option_map:
            raise CharacterError("vanilla catalog has no options")
        parsed: dict[str, tuple[VanillaOption, ...]] = {}
        for category, values in option_map.items():
            if not isinstance(category, str) or not CATEGORY_RE.fullmatch(category):
                raise CharacterError("invalid catalog category")
            if category not in FIXED_CATEGORIES and not (
                category.startswith("clothing_")
                or category.startswith("accessory")
                or category.startswith("cosmetic_")
            ):
                raise CharacterError("catalog category is outside the vanilla schema")
            if not isinstance(values, list) or not values or len(values) > 512:
                raise CharacterError("invalid option list")
            seen: set[str] = set()
            entries: list[VanillaOption] = []
            for value in values:
                option = VanillaOption.from_mapping(category, value)
                if option.option_id in seen:
                    raise CharacterError("duplicate option id")
                seen.add(option.option_id)
                entries.append(option)
            parsed[category] = tuple(entries)
        return cls(version, parsed)

    def has(self, category: str, option_id: str) -> bool:
        return any(
            option.option_id == option_id
            for option in self.options.get(category, ())
        )

    def require(self, category: str, option_id: str) -> str:
        if not isinstance(option_id, str) or not self.has(category, option_id):
            raise CharacterError(
                f"option is not in the vanilla catalog: {category}/{option_id}"
            )
        return option_id

    def as_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "options": {
                category: [
                    {
                        "id": option.option_id,
                        "label": option.label,
                        "source": option.source,
                    }
                    for option in values
                ]
                for category, values in self.options.items()
            },
        }


@dataclass(frozen=True)
class CharacterProposal:
    name: str
    gender: str
    skin_tone: str
    hair_style: str
    hair_color: str
    profession: str
    traits: tuple[str, ...]
    clothing: dict[str, str]
    accessories: tuple[str, ...]
    beard_style: str | None = None
    beard_color: str | None = None
    body_type: str | None = None
    cosmetics: dict[str, str] | None = None

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "name": self.name,
            "gender": self.gender,
            "skin_tone": self.skin_tone,
            "hair_style": self.hair_style,
            "hair_color": self.hair_color,
            "profession": self.profession,
            "traits": list(self.traits),
            "clothing": dict(self.clothing),
            "accessories": list(self.accessories),
        }
        if self.beard_style is not None:
            result["beard_style"] = self.beard_style
        if self.beard_color is not None:
            result["beard_color"] = self.beard_color
        if self.body_type is not None:
            result["body_type"] = self.body_type
        if self.cosmetics:
            result["cosmetics"] = dict(self.cosmetics)
        return result


class CharacterProposalValidator:
    def __init__(self, *, max_bytes: int = MAX_CHARACTER_BYTES) -> None:
        self.max_bytes = max_bytes

    def validate_json(
        self,
        raw_json: str | bytes,
        catalog: VanillaCatalog,
    ) -> CharacterProposal:
        encoded = (
            raw_json.encode("utf-8")
            if isinstance(raw_json, str)
            else raw_json
            if isinstance(raw_json, bytes)
            else None
        )
        if encoded is None or len(encoded) > self.max_bytes:
            raise CharacterError("character proposal exceeds the size limit")

        def reject_constant(value: str) -> None:
            raise CharacterError(f"non-finite JSON value: {value}")

        try:
            raw = json.loads(
                encoded.decode("utf-8"),
                parse_constant=reject_constant,
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise CharacterError("invalid character proposal JSON") from exc
        return self.validate(raw, catalog)

    def validate(
        self,
        raw: Mapping[str, Any],
        catalog: VanillaCatalog,
    ) -> CharacterProposal:
        if not isinstance(raw, Mapping):
            raise CharacterError("character proposal must be an object")
        if not all(isinstance(key, str) for key in raw):
            raise CharacterError("character proposal keys must be strings")
        if not isinstance(catalog, VanillaCatalog):
            raise CharacterError("vanilla catalog is invalid")
        unknown = set(raw).difference(PROPOSAL_KEYS)
        missing = REQUIRED_KEYS.difference(raw)
        if unknown:
            raise CharacterError(f"unknown character field: {sorted(unknown)[0]}")
        if missing:
            raise CharacterError(f"missing character field: {sorted(missing)[0]}")

        name = self._text(raw["name"], "name", 32)
        if name != "Goblin":
            raise CharacterError("character name must remain Goblin")

        gender = self._option(raw["gender"], "gender", catalog)
        skin_tone = self._option(raw["skin_tone"], "skin_tone", catalog)
        hair_style = self._option(raw["hair_style"], "hair_style", catalog)
        hair_color = self._option(raw["hair_color"], "hair_color", catalog)
        profession = self._option(raw["profession"], "profession", catalog)

        traits = raw["traits"]
        if not isinstance(traits, list) or not 1 <= len(traits) <= 5:
            raise CharacterError("traits must contain between one and five options")
        trait_values = tuple(
            self._option(item, "trait", catalog) for item in traits
        )
        if len(set(trait_values)) != len(trait_values):
            raise CharacterError("traits must be unique")

        clothing = self._selection_map(raw["clothing"], catalog, "clothing_")
        accessories = raw["accessories"]
        if not isinstance(accessories, list) or len(accessories) > 8:
            raise CharacterError("accessories must be a short list")
        accessory_values = tuple(
            self._accessory_option(item, catalog) for item in accessories
        )
        if len(set(accessory_values)) != len(accessory_values):
            raise CharacterError("accessories must be unique")

        optional: dict[str, str | None] = {}
        for key, category in (
            ("beard_style", "beard_style"),
            ("beard_color", "beard_color"),
            ("body_type", "body_type"),
        ):
            if key in raw and raw[key] is not None:
                optional[key] = self._option(raw[key], category, catalog)
            else:
                optional[key] = None

        cosmetics: dict[str, str] = {}
        if "cosmetics" in raw:
            value = raw["cosmetics"]
            if not isinstance(value, Mapping) or len(value) > 16:
                raise CharacterError("cosmetics must be a short object")
            for category, option_id in value.items():
                if (
                    not isinstance(category, str)
                    or not category.startswith("cosmetic_")
                ):
                    raise CharacterError("cosmetic category is not allowed")
                cosmetics[category] = self._option(option_id, category, catalog)

        return CharacterProposal(
            name=name,
            gender=gender,
            skin_tone=skin_tone,
            hair_style=hair_style,
            hair_color=hair_color,
            profession=profession,
            traits=trait_values,
            clothing=clothing,
            accessories=accessory_values,
            beard_style=optional["beard_style"],
            beard_color=optional["beard_color"],
            body_type=optional["body_type"],
            cosmetics=cosmetics or None,
        )

    @staticmethod
    def _text(value: Any, field: str, maximum: int) -> str:
        if (
            not isinstance(value, str)
            or not value.strip()
            or len(value) > maximum
            or CONTROL_RE.search(value)
        ):
            raise CharacterError(f"invalid character {field}")
        return value.strip()

    @staticmethod
    def _option(
        value: Any,
        category: str,
        catalog: VanillaCatalog,
    ) -> str:
        if not isinstance(value, str) or not ID_RE.fullmatch(value):
            raise CharacterError(f"invalid option id for {category}")
        return catalog.require(category, value)

    @staticmethod
    def _selection_map(
        value: Any,
        catalog: VanillaCatalog,
        prefix: str,
    ) -> dict[str, str]:
        if not isinstance(value, Mapping) or not value or len(value) > 8:
            raise CharacterError("clothing must be a short non-empty object")
        result: dict[str, str] = {}
        for category, option_id in value.items():
            if (
                not isinstance(category, str)
                or not category.startswith(prefix)
            ):
                raise CharacterError("clothing category is not allowed")
            result[category] = CharacterProposalValidator._option(
                option_id, category, catalog
            )
        return result

    @staticmethod
    def _accessory_option(value: Any, catalog: VanillaCatalog) -> str:
        if not isinstance(value, str) or not ID_RE.fullmatch(value):
            raise CharacterError("invalid accessory option id")
        for category in catalog.options:
            if category.startswith("accessory") and catalog.has(category, value):
                return value
        raise CharacterError("accessory is not in the vanilla catalog")


@dataclass(frozen=True)
class CharacterCreateAction:
    generation: int
    catalog_version: str
    proposal: CharacterProposal

    def as_dict(self) -> dict[str, Any]:
        return {
            "action": "CREATE_CHARACTER",
            "generation": self.generation,
            "catalog_version": self.catalog_version,
            "proposal": self.proposal.as_dict(),
        }


@dataclass(frozen=True)
class CharacterResult:
    accepted: bool
    status: str
    reason: str
    action: CharacterCreateAction | None = None


class CharacterCreationController:
    """Owns the one-time appearance manifest and its recreation boundary."""

    def __init__(
        self,
        *,
        lifecycle: CharacterLifecycle = CharacterLifecycle.FRESH,
        manifest: Mapping[str, Any] | None = None,
        persist: Callable[[CharacterLifecycle, dict[str, Any] | None], None] | None = None,
    ) -> None:
        self.lifecycle = CharacterLifecycle(lifecycle)
        if manifest is not None and not isinstance(manifest, Mapping):
            raise CharacterError("character manifest must be an object")
        self.manifest = deepcopy(dict(manifest)) if manifest is not None else None
        self.persist = persist

    def create(
        self,
        proposal: CharacterProposal | Mapping[str, Any],
        catalog: VanillaCatalog,
        *,
        now: int | None = None,
    ) -> CharacterResult:
        if self.lifecycle not in {
            CharacterLifecycle.FRESH,
            CharacterLifecycle.RECREATE_REQUIRED,
        }:
            return CharacterResult(False, "already_created", "appearance is already owned")
        validator = CharacterProposalValidator()
        try:
            clean = (
                proposal
                if isinstance(proposal, CharacterProposal)
                else validator.validate(proposal, catalog)
            )
            if isinstance(clean, CharacterProposal):
                checked = validator.validate(clean.as_dict(), catalog)
            else:
                checked = clean
        except CharacterError as exc:
            return CharacterResult(False, "rejected", str(exc))
        generation = self.next_generation()
        manifest = {
            "generation": generation,
            "created_at": int(now if now is not None else time.time()),
            "catalog_version": catalog.version,
            "creation_status": CharacterLifecycle.CREATION_PENDING.value,
            "appearance": checked.as_dict(),
        }
        action = CharacterCreateAction(generation, catalog.version, checked)
        self.lifecycle = CharacterLifecycle.CREATION_PENDING
        self.manifest = manifest
        self._persist()
        return CharacterResult(
            True,
            "pending",
            "deterministic character creation command is ready",
            action,
        )

    def next_generation(self) -> int:
        """Return the only generation that may follow the durable manifest."""

        previous_generation = 0
        if self.manifest:
            raw_generation = self.manifest.get("generation", 0)
            if (
                isinstance(raw_generation, int)
                and not isinstance(raw_generation, bool)
                and raw_generation >= 0
            ):
                previous_generation = raw_generation
        return previous_generation + 1

    def complete_native_recreation(
        self,
        generation: int,
        *,
        now: int | None = None,
    ) -> bool:
        """Record a vanilla client-created replacement with no model manifest.

        This is the recovery path used when the PZ character-creation screen
        is already open and cannot return a complete option catalog. The
        native client still owns all character fields; the agent only records
        the generation boundary and never invents appearance data.
        """

        if self.lifecycle != CharacterLifecycle.RECREATE_REQUIRED:
            return False
        if (
            not isinstance(generation, int)
            or isinstance(generation, bool)
            or generation != self.next_generation()
        ):
            return False
        self.lifecycle = CharacterLifecycle.ACTIVE
        self.manifest = {
            "generation": generation,
            "created_at": int(now if now is not None else time.time()),
            "catalog_version": "native_default",
            "creation_status": CharacterLifecycle.ACTIVE.value,
            "creation_mode": "vanilla_default",
        }
        self._persist()
        return True

    def confirm_creation(self, generation: int) -> bool:
        """Mark the manifest active only after PZ reports the character exists."""
        if self.lifecycle != CharacterLifecycle.CREATION_PENDING:
            return False
        if (
            not isinstance(generation, int)
            or isinstance(generation, bool)
            or not self.manifest
            or self.manifest.get("generation") != generation
        ):
            return False
        self.manifest["creation_status"] = CharacterLifecycle.ACTIVE.value
        self.lifecycle = CharacterLifecycle.ACTIVE
        self._persist()
        return True

    def adopt_existing(self, *, now: int | None = None) -> bool:
        """Adopt an already-created PZ body without changing its appearance."""

        if self.lifecycle != CharacterLifecycle.FRESH or self.manifest is not None:
            return False
        self.lifecycle = CharacterLifecycle.ACTIVE
        self.manifest = {
            "generation": 0,
            "created_at": int(now if now is not None else time.time()),
            "catalog_version": "adopted_existing",
            "creation_status": "adopted_existing",
            "adopted": True,
        }
        self._persist()
        return True

    def pending_action(self, catalog: VanillaCatalog) -> CharacterCreateAction | None:
        """Reconstruct a persisted creation command for a safe retry."""

        if self.lifecycle != CharacterLifecycle.CREATION_PENDING or not self.manifest:
            return None
        generation = self.manifest.get("generation")
        catalog_version = self.manifest.get("catalog_version")
        raw_appearance = self.manifest.get("appearance")
        if (
            not isinstance(generation, int)
            or isinstance(generation, bool)
            or generation < 1
            or not isinstance(catalog_version, str)
            or not isinstance(raw_appearance, Mapping)
            or catalog.version != catalog_version
        ):
            return None
        try:
            proposal = CharacterProposalValidator().validate(raw_appearance, catalog)
        except CharacterError:
            return None
        return CharacterCreateAction(generation, catalog_version, proposal)

    def on_death(self, *, character_deleted: bool = False) -> CharacterLifecycle:
        if character_deleted and self.lifecycle in {
            CharacterLifecycle.CREATION_PENDING,
            CharacterLifecycle.ACTIVE,
            CharacterLifecycle.DEAD,
        }:
            self.lifecycle = CharacterLifecycle.RECREATE_REQUIRED
            self._persist()
        elif self.lifecycle == CharacterLifecycle.ACTIVE:
            self.lifecycle = CharacterLifecycle.DEAD
            self._persist()
        return self.lifecycle

    def on_respawn(self) -> CharacterLifecycle:
        if self.lifecycle == CharacterLifecycle.DEAD:
            self.lifecycle = CharacterLifecycle.ACTIVE
            self._persist()
        return self.lifecycle

    def mark_character_deleted(self) -> CharacterLifecycle:
        return self.on_death(character_deleted=True)

    def equipment_selection(
        self,
        found_items: list[Mapping[str, Any]],
        chosen_ids: list[str],
    ) -> dict[str, Any]:
        """Accept only vanilla items present in the current found-item set."""
        if self.lifecycle != CharacterLifecycle.ACTIVE:
            raise CharacterError("equipment requires an active character")
        if not isinstance(found_items, list) or not isinstance(chosen_ids, list):
            raise CharacterError("equipment selection is invalid")
        if any(
            not isinstance(item_id, str) or not ID_RE.fullmatch(item_id)
            for item_id in chosen_ids
        ):
            raise CharacterError("equipment selection contains an invalid item id")
        if len(chosen_ids) > 16 or len(set(chosen_ids)) != len(chosen_ids):
            raise CharacterError("equipment selection is invalid")
        found: dict[str, Mapping[str, Any]] = {}
        for item in found_items:
            if not isinstance(item, Mapping):
                raise CharacterError("found item is invalid")
            if set(item).difference({"id", "category", "source", "found"}):
                raise CharacterError("found item has an unknown field")
            item_id = item.get("id")
            if (
                not isinstance(item_id, str)
                or not ID_RE.fullmatch(item_id)
                or item.get("source") != "vanilla"
                or item.get("found") is not True
            ):
                continue
            found[item_id] = item
        for chosen in chosen_ids:
            if chosen not in found:
                raise CharacterError("equipment must be a found vanilla item")
        return {
            "action": "EQUIP_FOUND_VANILLA",
            "generation": (
                int(self.manifest.get("generation", 0))
                if self.manifest
                else 0
            ),
            "items": list(chosen_ids),
        }

    def snapshot(self) -> dict[str, Any]:
        return {
            "lifecycle": self.lifecycle.value,
            "manifest": deepcopy(self.manifest) if self.manifest else None,
        }

    def _persist(self) -> None:
        if self.persist is not None:
            self.persist(self.lifecycle, dict(self.manifest) if self.manifest else None)
