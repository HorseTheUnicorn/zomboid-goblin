package com.horsetheunicorn.goblinsurvivor;

import zombie.characters.IsoLivingCharacter;
import zombie.characters.SurvivorDesc;
import zombie.characters.BodyDamage.BodyDamage;
import zombie.core.skinnedmodel.visual.BaseVisual;
import zombie.core.skinnedmodel.visual.HumanVisual;
import zombie.core.skinnedmodel.visual.IHumanVisual;
import zombie.core.skinnedmodel.visual.ItemVisuals;
import zombie.iso.IsoCell;
import zombie.core.skinnedmodel.advancedanimation.AnimationSet;
import zombie.inventory.InventoryItem;
import zombie.inventory.InventoryItemFactory;
import zombie.inventory.types.HandWeapon;
import zombie.inventory.types.WeaponType;
import zombie.characters.IsoZombie;
import zombie.core.skinnedmodel.ModelManager;
import zombie.network.GameServer;
import java.util.Collections;

/** Human NPC body; deliberately neither a network player nor a zombie. */
public final class HumanSurvivor extends IsoLivingCharacter implements IHumanVisual {
    // B42's AssaultRifle2 is the .308 M14-style rifle. It is a real
    // two-handed firearm with a 20-round magazine and a 40-tile range.
    // The same verified weapon contract is used by Goblin and every managed
    // survivor so no companion silently becomes an unarmed bystander.
    private static final String SURVIVOR_FIREARM = "Base.AssaultRifle2";
    private static final String SURVIVOR_MAGAZINE = "Base.M14Clip";
    private static final String SURVIVOR_AMMO = "Base.308Bullets";
    private static final String SURVIVOR_MELEE_WEAPON = "Base.BaseballBat";
    private static final int SURVIVOR_MAGAZINE_CAPACITY = 20;
    private static final float SURVIVOR_MAX_HEALTH = 100.0f;

    private HumanVisual humanVisual;
    private HandWeapon firearm;
    private HandWeapon meleeWeapon;
    private long visualTicks;
    private long renderCalls;
    private long shotsFired;
    private long meleeAttacks;
    private boolean walking;
    private boolean running;
    private boolean movementIntentMoving;
    private boolean movementIntentRunning;
    private String advancedAnimationState = "";
    private String lastAnimationError = "";
    private boolean meleeAttackPose;
    private boolean firearmAimingPose;
    private boolean firearmAttackPose;
    private boolean unlimitedAmmoPolicy;
    private boolean godMode = true;
    private boolean survivorDead;
    /**
     * Compatibility-only body damage object for engine states that require
     * BodyDamage (notably B42's fence-vault state).  Survivor health remains
     * authoritative in this class and never uses vanilla injury simulation.
     */
    private BodyDamage compatibilityBodyDamage;
    private String deathReason = "";
    private String lastFireError = "";
    private String lastMeleeError = "";
    private float observedX;
    private float observedY;

    @Override
    public BodyDamage getBodyDamage() {
        if (bodyDamage != null) return bodyDamage;
        if (compatibilityBodyDamage == null) {
            compatibilityBodyDamage = new BodyDamage(this);
        }
        return compatibilityBodyDamage;
    }

    public HumanSurvivor(SurvivorDesc descriptor, IsoCell cell, int x, int y, int z) {
        super(cell, x, y, z);
        // Snapshot-driven bodies must not run the incomplete vanilla NPC update.
        cell.getObjectList().remove(this);
        cell.getAddList().remove(this);
        initWornItems("Human");
        initAttachedItems("Human");
        setDescriptor(descriptor);
        setFemale(descriptor.isFemale());
        getHumanVisual().copyFrom(descriptor.getHumanVisual());
        InitSpriteParts(descriptor);
        Dressup(descriptor);
        wear("Base.Tshirt_DefaultTEXTURE");
        wear("Base.Trousers_JeanBaggy");
        wear("Base.Shoes_BlueTrainers");
        health = SURVIVOR_MAX_HEALTH;
        dead = false;
        survivorDead = false;
        ensureGodMode();
        observedX = x;
        observedY = y;
        if (!zombie.network.GameServer.server) {
            var animations = AnimationSet.GetAnimationSet("player", false);
            getAdvancedAnimator().setAnimSet(animations);
            getAdvancedAnimator().setState(animations.GetState("idle"), Collections.emptyList());
            advancedAnimationState = "idle";
        }
        setDoRender(true);
        setAlphaAndTarget(1.0f);
    }

    private void wear(String type) {
        zombie.inventory.InventoryItem item = zombie.inventory.InventoryItemFactory.CreateItem(type);
        if (item == null || item.getBodyLocation() == null) {
            throw new IllegalArgumentException("Invalid survivor clothing: " + type);
        }
        getInventory().AddItem(item);
        getWornItems().setItem(item.getBodyLocation(), item);
    }

    /**
     * Equip a primary item without firing the global OnEquipPrimary Lua event.
     *
     * B42's public setPrimaryHandItem method is written for IsoPlayer and
     * invokes vanilla equip listeners.  One of those listeners assumes an
     * IsoPlayer fishing component and throws when a custom IsoLivingCharacter
     * equips a rifle.  The protected hand fields are the engine's actual
     * storage, so update them directly while retaining the model/bookkeeping
     * work that is safe for this non-player body.
     */
    private void equipPrimarySilently(InventoryItem item) {
        if (item == null) return;
        if (leftHandItem != item) {
            setEquipParent(leftHandItem, item, false);
            leftHandItem = item;
            handItemShouldSendToClients = true;
            resetEquippedHandsModels();
        }
        if (item instanceof HandWeapon weapon) {
            setUseHandWeapon(weapon);
            try {
                setVariable("Weapon", WeaponType.getWeaponType(this).getType());
            } catch (Throwable ignored) { }
        } else {
            setUseHandWeapon(null);
        }
    }

    private int wearOutfitItem(String type) {
        if (type == null || type.isBlank()) return 0;
        try {
            InventoryItem item = InventoryItemFactory.CreateItem(type);
            if (item == null || item.getBodyLocation() == null) return 0;
            getInventory().AddItem(item);
            // The false flag avoids player-only inventory/drop bookkeeping;
            // this body is a local visual actor, not a network IsoPlayer.
            setWornItem(item.getBodyLocation(), item, false);
            return 1;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    /**
     * Apply a deterministic, server-supplied outfit to the local human body.
     * Each roster member receives a different catalog combination; the
     * profile is carried in the snapshot so every client renders the same
     * clothing.  Invalid optional items are skipped without losing the body.
     */
    public int applyOutfit(String top, String outer, String pants,
            String shoes, String head, String back) {
        clearWornItems();
        int worn = 0;
        worn += wearOutfitItem(top);
        worn += wearOutfitItem(outer);
        worn += wearOutfitItem(pants);
        worn += wearOutfitItem(shoes);
        worn += wearOutfitItem(head);
        worn += wearOutfitItem(back);
        try { resetModel(); } catch (Throwable ignored) { }
        return worn;
    }

    @Override public HumanVisual getHumanVisual() {
        // Lazy initialization also supports virtual calls from base constructors.
        if (humanVisual == null) humanVisual = new HumanVisual(this);
        return humanVisual;
    }

    @Override public BaseVisual getVisual() { return getHumanVisual(); }
    @Override public ItemVisuals getItemVisuals() {
        ItemVisuals result = new ItemVisuals();
        getItemVisuals(result);
        return result;
    }
    @Override public boolean isZombie() { return false; }
    @Override public boolean isSkeleton() { return false; }
    @Override public String getObjectName() { return "GoblinHumanSurvivor"; }

    /**
     * IsoGameCharacter defaults to the generic "Base" animation set.  Real
     * players override this to "player"; without the same override the model
     * manager reloads this custom human with an empty set when its animation
     * player is created, leaving a visible body whose legs remain at idle.
     */
    @Override public String GetAnimSetName() { return "player"; }

    /**
     * Equip a real B42 firearm and replenish its loaded magazine and reserve.
     * The body is deliberately outside the vanilla update loop, so the
     * unlimited-ammo policy is enforced here rather than relying on a reload
     * action that would require an IsoPlayer action state.
     */
    public boolean ensureFirearm() {
        if (survivorDead) return false;

        InventoryItem held = getPrimaryHandItem();
        if (held instanceof HandWeapon weapon && SURVIVOR_FIREARM.equals(held.getFullType())) {
            firearm = weapon;
        }
        if (firearm == null) {
            InventoryItem existing = getInventory().getItemFromType(SURVIVOR_FIREARM);
            if (existing instanceof HandWeapon weapon) firearm = weapon;
        }
        if (firearm == null) {
            InventoryItem created = InventoryItemFactory.CreateItem(SURVIVOR_FIREARM);
            if (!(created instanceof HandWeapon weapon)) {
                lastFireError = "InventoryItemFactory did not return " + SURVIVOR_FIREARM;
                return false;
            }
            firearm = weapon;
            getInventory().AddItem(firearm);
        }

        firearm.setRanged(true);
        firearm.setContainsClip(true);
        firearm.setRoundChambered(true);
        firearm.setSpentRoundChambered(false);
        firearm.setJammed(false);
        firearm.setAmmoPerShoot(1);
        firearm.setMaxAmmo(SURVIVOR_MAGAZINE_CAPACITY);
        firearm.setCurrentAmmoCount(SURVIVOR_MAGAZINE_CAPACITY);
        try { firearm.setFireMode("Single"); } catch (Throwable ignored) { }
        equipPrimarySilently(firearm);
        setUnlimitedAmmo(true);
        // B42 stores the engine unlimited-ammo flag on IsoPlayer; this body
        // is deliberately not an IsoPlayer. Keep the policy on the custom
        // human and replenish the magazine after every authoritative shot.
        unlimitedAmmoPolicy = true;

        InventoryItem magazine = getInventory().getItemFromType(SURVIVOR_MAGAZINE);
        if (magazine == null) {
            magazine = InventoryItemFactory.CreateItem(SURVIVOR_MAGAZINE);
            if (magazine != null) getInventory().AddItem(magazine);
        }
        if (magazine != null) {
            if (magazine.getMaxAmmo() < SURVIVOR_MAGAZINE_CAPACITY) {
                magazine.setMaxAmmo(SURVIVOR_MAGAZINE_CAPACITY);
            }
            magazine.setCurrentAmmoCount(magazine.getMaxAmmo());
        }

        InventoryItem reserve = getInventory().getItemFromType(SURVIVOR_AMMO);
        if (reserve == null) {
            reserve = InventoryItemFactory.CreateItem(SURVIVOR_AMMO);
            if (reserve != null) getInventory().AddItem(reserve);
        }
        if (reserve != null && reserve.getCount() < 999) reserve.setCount(999);
        boolean ready = hasReadyFirearm();
        lastFireError = ready ? "" : "firearm_not_ready: " + firearmDiagnostics();
        return ready;
    }

    public boolean hasReadyFirearm() {
        return firearm != null
                && SURVIVOR_FIREARM.equals(firearm.getFullType())
                && getPrimaryHandItem() == firearm
                && firearm.isRanged()
                && firearm.isContainsClip()
                && !firearm.isJammed()
                && firearm.isRoundChambered()
                && unlimitedAmmoPolicy;
    }

    public String getFirearmType() {
        return firearm == null ? "" : firearm.getFullType();
    }

    public HandWeapon getFirearm() { return firearm; }
    public long getShotsFired() { return shotsFired; }
    public String getLastFireError() { return lastFireError; }
    public boolean isGodMode() { return godMode; }

    /** Equip the deterministic melee weapon used by an explicit melee order. */
    public boolean ensureMeleeWeapon() {
        if (survivorDead) return false;

        InventoryItem held = getPrimaryHandItem();
        if (held instanceof HandWeapon weapon
                && SURVIVOR_MELEE_WEAPON.equals(held.getFullType())) {
            meleeWeapon = weapon;
        }
        if (meleeWeapon == null) {
            InventoryItem existing = getInventory().getItemFromType(SURVIVOR_MELEE_WEAPON);
            if (existing instanceof HandWeapon weapon) meleeWeapon = weapon;
        }
        if (meleeWeapon == null) {
            InventoryItem created = InventoryItemFactory.CreateItem(SURVIVOR_MELEE_WEAPON);
            if (!(created instanceof HandWeapon weapon)) {
                lastMeleeError = "InventoryItemFactory did not return " + SURVIVOR_MELEE_WEAPON;
                return false;
            }
            meleeWeapon = weapon;
            getInventory().AddItem(meleeWeapon);
        }

        // The item script supplies damage and range. Reassert only the
        // category boundary that matters to this custom body so a malformed
        // or stale item cannot be used as a ranged weapon here.
        meleeWeapon.setRanged(false);
        equipPrimarySilently(meleeWeapon);
        boolean ready = hasReadyMeleeWeapon();
        lastMeleeError = ready ? "" : "melee_weapon_not_ready";
        return ready;
    }

    public boolean hasReadyMeleeWeapon() {
        return meleeWeapon != null
                && SURVIVOR_MELEE_WEAPON.equals(meleeWeapon.getFullType())
                && getPrimaryHandItem() == meleeWeapon
                && !meleeWeapon.isRanged()
                && meleeWeapon.isMelee();
    }

    public HandWeapon getMeleeWeapon() { return meleeWeapon; }
    public long getMeleeAttacks() { return meleeAttacks; }
    public String getLastMeleeError() { return lastMeleeError; }

    /** Reassert both the custom and vanilla cheat flags on the server thread. */
    public void ensureGodMode() {
        if (survivorDead) return;
        godMode = true;
        try { setGodMod(true); } catch (Throwable ignored) { }
        try { setInvulnerable(true); } catch (Throwable ignored) { }
        health = SURVIVOR_MAX_HEALTH;
        dead = false;
    }

    public String firearmDiagnostics() {
        if (firearm == null) return "firearm=null";
        InventoryItem held = getPrimaryHandItem();
        return "type=" + firearm.getFullType()
                + " held=" + (held == firearm)
                + " heldType=" + (held == null ? "" : held.getFullType())
                + " ranged=" + firearm.isRanged()
                + " clip=" + firearm.isContainsClip()
                + " chambered=" + firearm.isRoundChambered()
                + " jammed=" + firearm.isJammed()
                + " engineUnlimited=" + isUnlimitedAmmo()
                + " policyUnlimited=" + unlimitedAmmoPolicy
                + " magazineType=" + firearm.getMagazineType()
                + " clipSize=" + firearm.getClipSize()
                + " maxAmmo=" + firearm.getMaxAmmo()
                + " currentAmmo=" + firearm.getCurrentAmmoCount();
    }

    /** Fire one authoritative shot at a normal IsoZombie. */
    public boolean fireAt(IsoZombie target) {
        if (target == null || target.isDead() || !ensureFirearm()) return false;
        float dx = target.getX() - getX();
        float dy = target.getY() - getY();
        float distance = (float)Math.sqrt(dx * dx + dy * dy);
        if (distance > 0.001f) setForwardDirection(dx / distance, dy / distance);
        setIsAiming(true);
        setVariable("isAiming", true);
        setVariable("isAttacking", true);
        setVariable("AttackAnim", true);
        setVariable("initiateAttack", true);
        setVariable("rangedWeapon", true);
        setVariable("Weapon", "firearm");
        setVariable("RangedWeaponEmpty", false);
        setPerformingAttackAnimation(true);
        try {
            // The fourth Hit argument suppresses damage when true.  A real
            // server-authoritative firearm hit must use the normal damage
            // path so the zombie's health/death state can replicate.
            target.Hit(firearm, this, 1.0f, false, 1.0f, false);
            shotsFired++;
            return true;
        } catch (Throwable error) {
            lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
            return false;
        } finally {
            setPerformingAttackAnimation(false);
            setIsAiming(false);
            setVariable("isAttacking", false);
            setVariable("AttackAnim", false);
            setVariable("initiateAttack", false);
            // A shot may have consumed the clip in the underlying item code.
            // Re-equipping here makes the next server tick deterministic.
            ensureFirearm();
        }
    }

    /** Perform one bounded authoritative melee strike against a live zombie. */
    public boolean meleeAt(IsoZombie target) {
        if (target == null || target.isDead() || !ensureMeleeWeapon()) return false;
        float dx = target.getX() - getX();
        float dy = target.getY() - getY();
        float distance = (float)Math.sqrt(dx * dx + dy * dy);
        if (distance > 2.25f) {
            lastMeleeError = "target_out_of_melee_range";
            return false;
        }
        if (distance > 0.001f) setForwardDirection(dx / distance, dy / distance);
        setVariable("isAiming", false);
        setVariable("isAttacking", true);
        setVariable("isMelee", true);
        try {
            setPerformingAttackAnimation(true);
            target.Hit(meleeWeapon, this, 1.0f, false, 1.0f, false);
            meleeAttacks++;
            lastMeleeError = "";
            return true;
        } catch (Throwable error) {
            lastMeleeError = error.getClass().getSimpleName() + ": " + error.getMessage();
            return false;
        } finally {
            setPerformingAttackAnimation(false);
            setVariable("isAttacking", false);
            setVariable("isMelee", false);
        }
    }

    /** Apply the short client-side attack pose without entering vanilla AI. */
    public void setMeleeAttackPose(boolean active) {
        meleeAttackPose = active;
        setVariable("isAiming", false);
        setVariable("isAttacking", active);
        setVariable("isMelee", active);
        try { setPerformingAttackAnimation(active); } catch (Throwable ignored) { }
    }

    /**
     * Select the native B42 movement graph for the item that is actually in
     * the survivor's hands.  The generic walk/run nodes use the unarmed/bat
     * graph and their weapon condition does not match a firearm, which leaves
     * a custom human sliding, stuttering, or apparently idle while its
     * server-authoritative position changes.
     */
    private String movementAnimationState(boolean moving, boolean run) {
        // B42's AnimationSet stores the folders as root states.  The rifle,
        // melee, walk, and run variants are child nodes selected by Weapon,
        // isMoving, and the other animation variables inside those roots.
        if (!moving) return "idle";
        return run ? "run" : "movement";
    }

    private String movementAnimationFallback(boolean moving, boolean run) {
        if (!moving) return null;
        return run ? "movement" : "idle";
    }

    /**
     * Transition only when the requested root state changes.  B42's
     * AdvancedAnimator owns the blend-in/out timing in the XML state graph;
     * repeatedly calling setState every frame would restart that blend and
     * make network interpolation look like a broken walk cycle.
     */
    private boolean setAdvancedAnimationState(String preferred, String fallback) {
        if (GameServer.server || preferred == null) return false;
        try {
            var animator = getAdvancedAnimator();
            String next = preferred;
            boolean preferredAvailable = animator.containsState(next);
            boolean fallbackAvailable = fallback != null && animator.containsState(fallback);
            if (!preferredAvailable && fallbackAvailable) {
                next = fallback;
            }
            if (!preferredAvailable && !fallbackAvailable) {
                lastAnimationError = "missing:" + preferred + "/" + fallback;
                return false;
            }
            String current = animator.getCurrentStateName();
            if (next.equalsIgnoreCase(advancedAnimationState)
                    && current != null && next.equalsIgnoreCase(current)) {
                return true;
            }
            animator.setState(next);
            advancedAnimationState = next;
            lastAnimationError = "";
            return true;
        } catch (Throwable error) {
            // Keep the human body visible if an animation node changes between
            // B42 point releases.
            lastAnimationError = error.getClass().getSimpleName() + ": " + error.getMessage();
            return false;
        }
    }

    private void applyMovementAnimationState(boolean moving, boolean run) {
        String preferred = movementAnimationState(moving, run);
        String fallback = movementAnimationFallback(moving, run);
        setAdvancedAnimationState(preferred, fallback);
    }

    /**
     * Drive the B42 ranged action state for this client-side visual actor.
     *
     * A custom IsoLivingCharacter does not receive IsoPlayer's vanilla input
     * action chain, so merely setting isAiming leaves the model in idle and
     * produces no rifle animation.  Keep the state edge-triggered: snapshots
     * arrive more often than a single-shot animation and must not restart the
     * animation on every update.
     */
    public void setFirearmPose(boolean aiming, boolean firing) {
        if (survivorDead) return;
        boolean changed = firearmAimingPose != aiming || firearmAttackPose != firing;
        firearmAimingPose = aiming;
        firearmAttackPose = firing;

        setIsAiming(aiming);
        setPerformingAttackAnimation(firing);
        setVariable("isAiming", aiming);
        setVariable("isAttacking", firing);
        setVariable("AttackAnim", firing);
        setVariable("initiateAttack", firing);
        setVariable("rangedWeapon", true);
        setVariable("Weapon", "firearm");
        setVariable("RangedWeaponEmpty", false);

        if (!GameServer.server && changed) {
            // Ranged aim/fire is an action layer.  Keep the movement root
            // selected so its child graph can continue animating the legs;
            // the flags above provide the firearm overlay variables.
            applyMovementAnimationState(walking, running);
        }
    }

    /** Apply the small custom health model used because bodyDamage is absent. */
    public boolean receiveZombieDamage(float amount, String reason) {
        if (survivorDead || godMode || isInvulnerable()
                || !Float.isFinite(amount) || amount <= 0.0f) return survivorDead;
        health = Math.max(0.0f, health - amount);
        if (health <= 0.0f) {
            survivorDead = true;
            dead = true;
            deathReason = reason == null || reason.isBlank() ? "zombie_attack" : reason;
            setDoRender(false);
            return true;
        }
        return false;
    }

    /** Restore custom-human health without entering IsoPlayer body damage. */
    public boolean restoreHealth(float amount) {
        if (survivorDead || !Float.isFinite(amount) || amount <= 0.0f) return false;
        float before = health;
        health = Math.min(SURVIVOR_MAX_HEALTH, health + amount);
        if (health > before) {
            dead = false;
            return true;
        }
        return false;
    }

    public boolean markSurvivorDead(String reason) {
        if (survivorDead) return false;
        health = 0.0f;
        dead = true;
        survivorDead = true;
        deathReason = reason == null || reason.isBlank() ? "unknown" : reason;
        setDoRender(false);
        return true;
    }

    public String getDeathReason() { return deathReason; }

    @Override public boolean isDead() { return survivorDead || super.isDead(); }
    @Override public boolean isAlive() { return !isDead(); }

    /** Keep the named Goblin's identity stable across recreation. */
    public void forceGoblinAppearance() { getHumanVisual().setHairModel("Spike"); }

    /**
     * Apply the server-authoritative movement pose to this real human body.
     * Build 42 exposes run/walk as separate player animation states; setting
     * only isMoving leaves a custom IsoLivingCharacter in an unstable idle/
     * movement blend. Sprinting stays disabled because it is a player
     * stamina/action system, while running is a bounded navigation pose.
     */
    public void setMovementMode(boolean moving, boolean run) {
        boolean nextRunning = moving && run;
        movementIntentMoving = moving;
        movementIntentRunning = nextRunning;
        walking = moving;
        running = nextRunning;
        try { setRunning(nextRunning); } catch (Throwable ignored) { }
        try { setSprinting(false); } catch (Throwable ignored) { }
        setVariable("isMoving", moving);
        setVariable("isRunning", nextRunning);
        setVariable("Run", nextRunning);
        // defaultWalk/defaultRun use WalkSpeed as a 0..1 blend coordinate:
        // zero is the walk sample and one is the run sample.  Values above
        // one extrapolate the blend and are the source of the old leg jitter.
        setVariable("WalkSpeed", nextRunning ? 1.0f : 0.0f);
        setVariable("WalkInjury", 0.0f);
        if (!GameServer.server && !firearmAimingPose && !firearmAttackPose) {
            // Run this even when the boolean intent did not change: equipping
            // the rifle changes the correct native graph from Idle to
            // IdleRifle without restarting a stable movement cycle.
            applyMovementAnimationState(moving, nextRunning);
        }
    }

    public boolean isRunningPose() { return running; }

    /** Replicate the short B42 hop pose for snapshot-rendered clients. */
    public void setTraversalPose(boolean active, boolean run) {
        if (survivorDead) return;
        if (active) {
            setVariable("ClimbingFence", true);
            setVariable("ClimbFenceStarted", true);
            setVariable("ClimbFenceFinished", false);
            setVariable("ClimbFenceOutcome", "success");
            setVariable("VaultOverRun", run);
            setVariable("VaultOverSprint", false);
            setMovementMode(false, false);
        } else {
            clearVariable("ClimbingFence");
            clearVariable("ClimbFenceStarted");
            clearVariable("ClimbFenceFinished");
            clearVariable("ClimbFenceOutcome");
            clearVariable("VaultOverRun");
            clearVariable("VaultOverSprint");
            setMovementMode(movementIntentMoving, movementIntentRunning);
        }
    }

    /** Advance only the pose/model/light path, never vanilla needs or NPC AI. */
    public void tickVisual() {
        visualTicks++;
        float dx = getX() - observedX;
        float dy = getY() - observedY;
        float distance = (float) Math.sqrt(dx * dx + dy * dy);
        if (distance > 0.002f && distance < 3.0f) {
            setForwardDirection(dx / distance, dy / distance);
        }
        observedX = getX();
        observedY = getY();
        // Never infer the authoritative movement state from a single render
        // frame.  Network interpolation can legitimately pause between
        // snapshots; using that pause to enter Idle was the main source of
        // the broken walk/run transitions.
        setMovementMode(movementIntentMoving, movementIntentRunning);
        ensureVisualRegistration();
        if (getCurrentSquare() != null && getModelInstance() != null) {
            enableVisualBoneUpdates();
            updateForServerGui();
        }
    }

    @Override public void render(float x, float y, float z,
            zombie.core.textures.ColorInfo color, boolean a, boolean b,
            zombie.core.opengl.Shader shader) {
        renderCalls++;
        super.render(x, y, z, color, a, b, shader);
    }

    public String visualDiagnostics() {
        return "ticks=" + visualTicks + " renderCalls=" + renderCalls
                + " inObjectList=" + (getCell() != null && getCell().getObjectList().contains(this))
                + " pendingRemoval=" + (getCell() != null && getCell().getRemoveList().contains(this))
                + " animPlayer=" + hasAnimationPlayer()
                 + " animState=" + getAnimationStateName()
                 + " advancedState=" + advancedAnimationStateName()
                 + " requestedAdvancedState=" + advancedAnimationState
                 + " animationRuntime=" + animationRuntimeDiagnostics()
                 + " walking=" + walking + " running=" + running
                + " intent=" + movementIntentMoving + "/" + movementIntentRunning
                + " worn=" + getWornItems().size()
                + " hair=" + getHumanVisual().getHairModel()
                + " firearm=" + getFirearmType()
                + " weaponReady=" + hasReadyFirearm()
                + " meleeWeapon=" + (meleeWeapon == null ? "" : meleeWeapon.getFullType())
                + " meleeReady=" + hasReadyMeleeWeapon()
                + " meleeAttacks=" + meleeAttacks
                + " meleePose=" + meleeAttackPose
                + " aiming=" + isAiming()
                + " attackAnim=" + isPerformingAttackAnimation()
                + " firearmPose=" + firearmAimingPose + "/" + firearmAttackPose
                + " firearmState=" + firearmDiagnostics()
                + " sceneCulled=" + isSceneCulled();
    }

    private String advancedAnimationStateName() {
        try {
            String state = getAdvancedAnimator().getCurrentStateName();
            return state == null ? "" : state;
        } catch (Throwable ignored) {
            return "";
        }
    }

    private String animationRuntimeDiagnostics() {
        try {
            var animator = getAdvancedAnimator();
            var player = getAnimationPlayer();
            var root = animator.getRootLayer();
            var multiTrack = player == null ? null : player.getMultiTrack();
            int tracks = multiTrack == null ? -1 : multiTrack.getTrackCount();
            boolean ready = player != null && player.isReady();
            float boneDelta = player == null ? 0.0f : player.getBoneTransformsTimeDelta();
            var syncNode = root == null ? null : root.getCurrentSyncNode();
            var syncTrack = root == null ? null : root.getCurrentSyncTrack();
            var clip = syncTrack == null ? null : syncTrack.getClip();
            var variables = getGameVariablesInternal();
            return "root=" + (root == null ? "" : root.getCurrentStateName())
                    + " movement=" + animator.containsState("movement")
                    + " run=" + animator.containsState("run")
                    + " idle=" + animator.containsState("idle")
                    + " playerReady=" + ready
                    + " updateBones=" + (player != null && player.updateBones)
                    + " tracks=" + tracks
                    + " node=" + (syncNode == null ? "" : syncNode.getName())
                    + " clip=" + (clip == null ? "" : clip.name)
                    + " trackTime=" + (syncTrack == null ? 0.0f : syncTrack.getCurrentTrackTime())
                    + " animationTime=" + (syncTrack == null ? 0.0f : syncTrack.getCurrentAnimationTime())
                    + " clipDuration=" + (clip == null ? 0.0f : clip.getDuration())
                    + " weapon=" + (variables == null ? "" : variables.getVariableString("Weapon"))
                    + " movingVar=" + (variables != null && variables.getVariableBoolean("isMoving"))
                    + " runVar=" + (variables != null && variables.getVariableBoolean("Run"))
                    + " walkSpeed=" + (variables == null ? 0.0f : variables.getVariableFloat("WalkSpeed", 0.0f))
                    + " dt=" + getAnimationTimeDelta()
                    + " boneDt=" + boneDelta
                    + " animationError=" + lastAnimationError;
        } catch (Throwable error) {
            return "animationDiagError=" + error.getClass().getSimpleName();
        }
    }

    /**
     * Register this local human with B42's real model manager. Kahlua cannot
     * reliably read the manager's static singleton field, so keep this engine
     * call on the Java side where the singleton and overload are unambiguous.
     * The dedicated server never needs an OpenGL model registration.
     */
    public boolean ensureVisualModel() {
        if (GameServer.server) return getModelInstance() != null;
        try {
            ModelManager manager = ModelManager.instance;
            if (!manager.ContainsChar(this)) manager.Add(this);
            enableVisualBoneUpdates();
            setSceneCulled(false);
            setDoRender(true);
            return getModelInstance() != null && manager.ContainsChar(this);
        } catch (Throwable ignored) {
            return false;
        }
    }

    public boolean visualModelManaged() {
        if (GameServer.server) return false;
        try { return ModelManager.instance.ContainsChar(this); }
        catch (Throwable ignored) { return false; }
    }

    /**
     * ModelManager can create an AnimationPlayer for a custom body before it
     * knows that the body is part of the visible scene.  In that case B42
     * advances track time but intentionally skips the skin/bone transform
     * pass, which looks exactly like a survivor sliding with locked legs.
     * Visible client actors must opt into the bone pass explicitly.
     */
    private void enableVisualBoneUpdates() {
        if (GameServer.server) return;
        try {
            var player = getAnimationPlayer();
            if (player != null) player.updateBones = true;
        } catch (Throwable ignored) { }
    }

    // No vanilla living-character update until the dedicated NPC lifecycle owns it.
    @Override public void preupdate() { }
    @Override public void update() { }
    @Override public void postupdate() { }

    public boolean ensureVisualRegistration() {
        IsoCell cell = getCell();
        if (cell == null) return false;
        try {
            var objects = cell.getObjectList();
            // The original one-shot registration was getCell().getObjectList().add(this);
            // keep the operation idempotent because B42 may prune a visual object.
            if (!objects.contains(this)) objects.add(this);
            cell.getAddList().remove(this);
            cell.getRemoveList().remove(this);
            return objects.contains(this);
        } catch (Throwable ignored) {
            return false;
        }
    }

    public void registerVisualObject() {
        ensureVisualRegistration();
    }

    public void unregisterVisualObject() {
        try { removeFromSquare(); } catch (Throwable ignored) { }
        IsoCell cell = getCell();
        if (cell != null) {
            cell.getObjectList().remove(this);
            cell.getAddList().remove(this);
            cell.getRemoveList().remove(this);
        }
        setDoRender(false);
    }
}
