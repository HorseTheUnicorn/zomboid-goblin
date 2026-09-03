# Build 42 server-body feasibility probe

This disposable mod is an evidence harness, not part of the live Goblin loadout.
It runs on an isolated native Linux dedicated server and records whether Build 42
can construct a server-side survivor/player object, attach it to the world, and
expose it through the server player collections. It never enables Goblin on the
live server and it does not accept model text or arbitrary code.

The probe must be removed from the disposable server after the run. A successful
object-construction result is not sufficient for Architecture A: a real client
must still observe movement, damage, inventory, appearance, persistence, and
death/respawn behavior before the body driver can be enabled.
