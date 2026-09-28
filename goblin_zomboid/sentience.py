"""Goblin Sentience V1: a persistent self between perception and action.

The old free-will loop picked one action every ~40 s and forgot why. Each
Goblin now carries a continuous self (mood, desires, a current goal with a
plan, private thoughts, expectations) that survives every Qwen call and
restarts. Cognition is woken by significant events, not just a timer, and it
runs while Goblin follows; only physical actions still wait for the owner to
stop. Qwen decides *why* and *what next*; the validator, Lua capabilities and
server authority still decide *how* and *whether*.

Nothing here talks to the game or to Qwen. ``GoblinService`` feeds it
situation reports and Qwen output; this module turns them into state.
"""
from __future__ import annotations

import copy
import time
from collections.abc import Mapping
from typing import Any

# Job-level intents a plan step may name (Lua still validates everything).
PLAN_INTENTS = (
    "SECURE_BASE", "INSPECT_BASE", "MAINTAIN_BASE", "REPAIR_STRUCTURE", "CLOSE_CURTAINS",
    "SORT_STORAGE", "STOCKPILE", "FETCH_ITEM", "DELIVER", "DISMANTLE", "LOOT_AREA", "RETURN_TO_BASE",
    "TREAT_PLAYER", "CHOP_WOOD", "FORAGE", "CHECK_TRAPS", "COOK", "FARM", "CRAFT",
    "VEHICLE_INSPECT", "VEHICLE_SERVICE", "REFUEL_VEHICLE", "REPAIR_VEHICLE", "CHANGE_TIRE",
    "FOLLOW", "SAY",
)
DECISIONS = ("continue", "new", "interrupt", "complete", "abandon")

# kind -> (importance 0..1, emotional valence -1..1)
EVENT_WEIGHTS: dict[str, tuple[float, float]] = {
    "owner_bitten": (1.0, -1.0),
    "owner_hurt": (0.85, -0.7),
    "horde": (0.85, -0.6),
    "base_attacked": (0.8, -0.6),
    "threat_rising": (0.6, -0.3),
    "job_failed": (0.55, -0.3),
    "owner_insulted": (0.55, -0.5),
    "owner_praised": (0.5, 0.6),
    "goblin_met": (0.5, 0.2),
    "night_approaching": (0.55, -0.1),
    "owner_left_base": (0.5, 0.0),
    "food_low": (0.55, -0.3),
    "vehicle_low": (0.4, -0.1),
    "new_place": (0.35, 0.1),
    "job": (0.3, 0.2),
    "job_complete": (0.3, 0.3),
    "kills": (0.35, 0.3),
    "chat": (0.3, 0.0),
    "thought": (0.25, 0.0),
    "choice": (0.2, 0.0),
    "met": (0.5, 0.2),
}
WAKE_IMPORTANCE = 0.5          # this important or more wakes cognition now
BACKGROUND_REFLECT_S = 240.0   # slow thought when nothing happens
MIN_REFLECT_GAP_S = 20.0       # never think about the same Goblin faster than this
MAX_THOUGHTS = 8

DEFAULT_DESIRES = (
    {"goal": "keep my comrade alive", "priority": 100},
    {"goal": "make the base defensible", "priority": 70},
    {"goal": "keep the car usable", "priority": 40},
    {"goal": "keep us fed and stocked", "priority": 45},
    {"goal": "find something interesting", "priority": 20},
)


def event_weight(kind: str, text: str = "") -> tuple[float, float]:
    kind = str(kind)
    if kind == "job":
        upper = str(text).upper()
        if "COMPLETE" in upper:
            return EVENT_WEIGHTS["job_complete"]
        return EVENT_WEIGHTS["job_failed"]
    return EVENT_WEIGHTS.get(kind, (0.3, 0.0))


def new_self(npc_id: str, name: str | None = None, owner: str | None = None) -> dict[str, Any]:
    return {
        "identity": npc_id, "name": name, "owner": owner,
        "mood": "restless", "desires": [dict(d) for d in DEFAULT_DESIRES],
        "current_goal": None, "suspended_goal": None, "plan": [], "current_step": 0,
        "thoughts": [], "expectations": {}, "last_reflect_at": 0.0, "reflections": 0,
    }


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] if value else None


class Sentience:
    """Per-Goblin cognitive state and the rules that move it."""

    def __init__(self, mind, *, clock=time.time) -> None:
        self.mind = mind
        self.clock = clock
        self.selves: dict[str, dict[str, Any]] = {}
        self.inbox: dict[str, list[dict[str, Any]]] = {}
        self.last_seen: dict[str, dict[str, Any]] = {}

    # ------------------------------------------------------------- state
    def get(self, npc_id: str, name: str | None = None, owner: str | None = None) -> dict[str, Any]:
        state = self.selves.get(npc_id)
        if state is None:
            state = self.mind.load_self(npc_id) or new_self(npc_id, name, owner)
            base = new_self(npc_id, name, owner)
            for key, value in base.items():
                state.setdefault(key, value)
            self.selves[npc_id] = state
        if name:
            state["name"] = name
        if owner:
            state["owner"] = owner
        return state

    def save(self, npc_id: str) -> None:
        if npc_id in self.selves:
            self.mind.save_self(npc_id, self.selves[npc_id])

    def view(self, npc_id: str) -> dict[str, Any]:
        """What Qwen sees of Goblin's own mind (compact, no bookkeeping)."""
        state = self.get(npc_id)
        plan = state.get("plan") or []
        step = int(state.get("current_step") or 0)
        return {
            "mood": state.get("mood"),
            "desires": state.get("desires"),
            "current_goal": state.get("current_goal"),
            "suspended_goal": state.get("suspended_goal"),
            "plan": plan,
            "current_step": plan[step] if 0 <= step < len(plan) else None,
            "step_number": step + 1 if plan else None,
            "private_thoughts": list(state.get("thoughts") or [])[-5:],
            "expectations": state.get("expectations") or {},
        }

    def current_step(self, npc_id: str) -> dict[str, Any] | None:
        state = self.get(npc_id)
        plan = state.get("plan") or []
        step = int(state.get("current_step") or 0)
        return plan[step] if 0 <= step < len(plan) else None

    # -------------------------------------------------------- perception
    def perceive(self, companion: Mapping[str, Any], raw_events: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
        """Turn the game's event log and situation changes into weighted
        events. Returns the new events (already stored in memory and inbox)."""
        npc_id = companion.get("npc_id")
        situation = companion.get("situation")
        if not isinstance(npc_id, str) or not isinstance(situation, Mapping):
            return []
        events: list[dict[str, Any]] = []
        for raw in raw_events:
            kind, text = str(raw.get("kind", "event")), str(raw.get("text", ""))
            if kind == "job":
                kind = "job_complete" if "COMPLETE" in text.upper() else "job_failed"
            events.append({"kind": kind, "text": text})
        previous = self.last_seen.get(npc_id)
        current = self._snapshot(situation)
        if previous is not None:
            events.extend(self._changes(previous, current, situation))
        self.last_seen[npc_id] = current
        place = current.get("room")
        owner = companion.get("owner")
        day = current.get("day")
        stored = []
        for event in events:
            importance, valence = EVENT_WEIGHTS.get(event["kind"], (0.3, 0.0))
            event["importance"], event["valence"] = importance, valence
            # Game-log events are already stored by GoblinMind.observe;
            # derived changes are new memories.
            if event.get("derived"):
                self.mind.record(npc_id, event["kind"], event["text"], day, importance=importance,
                                 valence=valence, place=place,
                                 entities=[owner] if isinstance(owner, str) else None)
            stored.append(event)
            self._opinion_from_event(npc_id, owner, event)
        if stored:
            inbox = self.inbox.setdefault(npc_id, [])
            inbox.extend(stored)
            del inbox[:-12]
        return stored

    @staticmethod
    def _snapshot(situation: Mapping[str, Any]) -> dict[str, Any]:
        def sub(key):
            value = situation.get(key)
            return value if isinstance(value, Mapping) else {}
        time_info, place, threats, base = sub("time"), sub("place"), sub("threats"), sub("base")
        owner, vehicle = sub("owner"), sub("vehicle")
        nearby = situation.get("nearby_goblins") if isinstance(situation.get("nearby_goblins"), list) else []
        shortages = base.get("stock_shortages") if isinstance(base.get("stock_shortages"), list) else []
        return {
            "day": time_info.get("day") if isinstance(time_info.get("day"), int) else None,
            "period": time_info.get("period"),
            "room": place.get("room") if isinstance(place.get("room"), str) else None,
            "threat": threats.get("level"),
            "base_distance": base.get("distance"),
            "owner_bitten": owner.get("bitten_parts") if isinstance(owner.get("bitten_parts"), int) else 0,
            "goblins": sorted(str(g.get("name") or g.get("npc_id")) for g in nearby if isinstance(g, Mapping)),
            "food_short": any("food" in str(s).lower() or "tinned" in str(s).lower() for s in shortages),
            "vehicle": str(vehicle.get("summary") or ""),
        }

    @staticmethod
    def _changes(before: Mapping[str, Any], now: Mapping[str, Any], situation) -> list[dict[str, Any]]:
        events = []
        def add(kind, text):
            events.append({"kind": kind, "text": text, "derived": True})
        if (now.get("owner_bitten") or 0) > (before.get("owner_bitten") or 0):
            add("owner_bitten", "my comrade got bitten")
        order = ("clear", "distant", "a few", "several", "horde")
        if now.get("threat") in order and before.get("threat") in order \
                and order.index(now["threat"]) >= 3 > order.index(before["threat"]) and now["threat"] != "horde":
            add("threat_rising", f"zombies gathering ({now['threat']})")
        if now.get("period") == "evening" and before.get("period") in ("afternoon", "morning"):
            add("night_approaching", "the light is going; night is coming")
        if before.get("base_distance") == "at base" and now.get("base_distance") not in (None, "at base"):
            add("owner_left_base", "we left the base")
        if now.get("room") and now.get("room") != before.get("room"):
            add("new_place", f"we went into the {now['room']}")
        for name in set(now.get("goblins") or []) - set(before.get("goblins") or []):
            add("goblin_met", f"ran into {name}")
        if now.get("food_short") and not before.get("food_short"):
            add("food_low", "the base is running short of food")
        vehicle = now.get("vehicle") or ""
        if vehicle and vehicle != before.get("vehicle") and ("fuel 0" in vehicle or "fuel 1" in vehicle
                                                             or "low tire" in vehicle):
            add("vehicle_low", f"the car looks rough: {vehicle[:80]}")
        return events

    def _opinion_from_event(self, npc_id: str, owner: Any, event: Mapping[str, Any]) -> None:
        if not isinstance(owner, str):
            return
        kind = event.get("kind")
        subject = owner.lower()
        if kind in ("owner_hurt", "owner_bitten", "horde"):
            self.mind.nudge_opinion(npc_id, subject, "reckless", 0.04)
        elif kind == "owner_praised":
            self.mind.nudge_opinion(npc_id, subject, "generous", 0.05)
        elif kind == "owner_insulted":
            self.mind.nudge_opinion(npc_id, subject, "respect", -0.05)
        elif kind == "job_complete":
            text = str(event.get("text", "")).split(" ")[0].lower()
            if text:
                self.mind.nudge_opinion(npc_id, "activity:" + text, "preference", 0.02)
        elif kind == "job_failed":
            text = str(event.get("text", "")).split(" ")[0].lower()
            if text:
                self.mind.nudge_opinion(npc_id, "activity:" + text, "preference", -0.03)

    def social(self, npc_id: str, owner: str | None, category: str | None, text: str) -> None:
        """A chat line from the owner: praise and insults are events too."""
        kind = {"praise": "owner_praised", "thanks": "owner_praised", "insult": "owner_insulted"}.get(
            str(category or "").lower())
        if kind is None:
            return
        importance, valence = EVENT_WEIGHTS[kind]
        event = {"kind": kind, "text": f"{owner or 'my comrade'} said: {text[:80]}",
                 "importance": importance, "valence": valence}
        self.inbox.setdefault(npc_id, []).append(event)
        self._opinion_from_event(npc_id, owner, event)

    # ---------------------------------------------------------- scheduling
    def wants_reflection(self, npc_id: str, now: float | None = None) -> tuple[bool, float]:
        """(should think now, priority). Important news wakes him at once;
        otherwise he reflects slowly in the background."""
        now = self.clock() if now is None else now
        state = self.get(npc_id)
        since = now - float(state.get("last_reflect_at") or 0)
        if since < MIN_REFLECT_GAP_S:
            return False, 0.0
        top = max((float(e.get("importance", 0)) for e in self.inbox.get(npc_id, [])), default=0.0)
        if top >= WAKE_IMPORTANCE:
            return True, top
        if not state.get("current_goal") and since >= 60:
            # No purpose yet: form one before acting.
            return True, WAKE_IMPORTANCE
        if since >= BACKGROUND_REFLECT_S:
            return True, 0.2
        return False, 0.0

    def reflection_context(self, npc_id: str) -> dict[str, Any]:
        state = self.get(npc_id)
        return {"self": self.view(npc_id),
                "what_just_happened": [
                    {k: e[k] for k in ("kind", "text", "importance") if k in e}
                    for e in self.inbox.get(npc_id, [])][-8:],
                "reflections_so_far": state.get("reflections", 0)}

    # -------------------------------------------------------- reflection
    def apply_reflection(self, npc_id: str, output: Mapping[str, Any]) -> dict[str, Any]:
        """Fold Qwen's reflection into the self. Invalid parts are ignored,
        never trusted: plan steps must name known intents."""
        state = self.get(npc_id)
        now = self.clock()
        state["last_reflect_at"] = now
        state["reflections"] = int(state.get("reflections") or 0) + 1
        top = max((float(e.get("importance", 0)) for e in self.inbox.get(npc_id, [])), default=0.0)
        self.inbox[npc_id] = []
        mood = _text(output.get("mood"), 60)
        if mood:
            state["mood"] = mood
        thought = _text(output.get("thought"), 200)
        if thought:
            thoughts = list(state.get("thoughts") or [])
            thoughts.append(thought)
            state["thoughts"] = thoughts[-MAX_THOUGHTS:]
        expectation = output.get("expectation")
        if isinstance(expectation, Mapping):
            about, expect = _text(expectation.get("about"), 40), _text(expectation.get("expect"), 120)
            if about and expect:
                expectations = dict(state.get("expectations") or {})
                expectations[about] = expect
                state["expectations"] = dict(list(expectations.items())[-6:])
        for entry in (output.get("opinions") or [])[:3]:
            if not isinstance(entry, Mapping):
                continue
            subject, trait = _text(entry.get("subject"), 40), _text(entry.get("trait"), 24)
            value = entry.get("value")
            if subject and trait and isinstance(value, (int, float)):
                # Drift toward the new view instead of overwriting it.
                old = self.mind.opinion(npc_id, subject, trait)
                self.mind.set_opinion(npc_id, subject, trait, old + (float(value) - old) * 0.35,
                                      _text(entry.get("note"), 120))
        decision = output.get("decision") if output.get("decision") in DECISIONS else "continue"
        plan = self._clean_plan(output.get("plan"))
        goal = _text(output.get("goal"), 100)
        reason = _text(output.get("reason"), 160)
        previous = state.get("current_goal")
        if decision in ("new", "interrupt") and goal and plan:
            if decision == "interrupt" and previous and not state.get("suspended_goal"):
                state["suspended_goal"] = {"goal": previous, "plan": state.get("plan") or [],
                                           "current_step": int(state.get("current_step") or 0)}
            state["current_goal"] = {"goal": goal, "reason": reason, "started": now}
            state["plan"], state["current_step"] = plan, 0
        elif decision in ("complete", "abandon"):
            self._finish_goal(npc_id, state, decision)
        elif decision == "continue" and plan and not previous and goal:
            state["current_goal"] = {"goal": goal, "reason": reason, "started": now}
            state["plan"], state["current_step"] = plan, 0
        memory = thought or (f"I decided: {goal}" if goal else None)
        if memory:
            self.mind.record(npc_id, "thought", memory, self._day(npc_id),
                             importance=max(0.25, min(0.8, top * 0.8)),
                             valence=0.0, place=self.last_seen.get(npc_id, {}).get("room"))
        self.save(npc_id)
        return {"decision": decision, "importance": top, "say": _text(output.get("say"), 200)}

    @staticmethod
    def _clean_plan(raw: Any) -> list[dict[str, Any]]:
        plan = []
        for step in raw if isinstance(raw, list) else []:
            if not isinstance(step, Mapping) or step.get("intent") not in PLAN_INTENTS:
                continue
            clean = {"intent": step["intent"], "note": _text(step.get("note"), 80) or ""}
            if isinstance(step.get("job"), str):
                clean["job"] = step["job"][:24]
            plan.append(clean)
            if len(plan) >= 6:
                break
        return plan

    def _finish_goal(self, npc_id: str, state: dict[str, Any], how: str) -> None:
        goal = state.get("current_goal")
        if goal:
            self.mind.record(npc_id, "goal", f"{'finished' if how == 'complete' else 'gave up on'}: "
                             f"{goal.get('goal')}", self._day(npc_id),
                             importance=0.45, valence=0.4 if how == "complete" else -0.2)
        suspended = state.get("suspended_goal")
        if suspended:
            # Back to what he was doing before something more urgent came up.
            state["current_goal"] = suspended.get("goal")
            state["plan"] = suspended.get("plan") or []
            state["current_step"] = int(suspended.get("current_step") or 0)
            state["suspended_goal"] = None
        else:
            state["current_goal"], state["plan"], state["current_step"] = None, [], 0

    def step_result(self, npc_id: str, intent: str, success: bool) -> None:
        """A physical job finished: advance the plan (or wake a rethink)."""
        state = self.get(npc_id)
        step = self.current_step(npc_id)
        if step is None:
            return
        if step.get("intent") != intent:
            return  # an owner order or another job; the plan waits
        if not success:
            # Never hammer the same failing step: after two failures skip it.
            step["failures"] = int(step.get("failures") or 0) + 1
            if step["failures"] >= 2:
                success = True
                self.mind.record(npc_id, "gave_up", f"gave up on {intent} for now", self._day(npc_id),
                                 importance=0.35, valence=-0.3)
        if success:
            state["current_step"] = int(state.get("current_step") or 0) + 1
            if state["current_step"] >= len(state.get("plan") or []):
                self._finish_goal(npc_id, state, "complete")
        if not success or step.get("failures"):
            importance, valence = EVENT_WEIGHTS["job_failed"]
            self.inbox.setdefault(npc_id, []).append(
                {"kind": "job_failed", "text": f"{intent} did not work out", "importance": importance,
                 "valence": valence})
        self.save(npc_id)

    def _day(self, npc_id: str) -> int | None:
        return self.last_seen.get(npc_id, {}).get("day")

    def snapshot(self) -> dict[str, Any]:
        return {npc_id: {k: copy.deepcopy(v) for k, v in self.view(npc_id).items() if k != "desires"}
                for npc_id in list(self.selves)}
