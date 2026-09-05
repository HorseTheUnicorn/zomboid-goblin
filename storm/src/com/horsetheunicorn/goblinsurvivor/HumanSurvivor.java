package com.horsetheunicorn.goblinsurvivor;

import zombie.characters.IsoLivingCharacter;
import zombie.characters.SurvivorDesc;
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
    private static final int SURVIVOR_MAGAZINE_CAPACITY = 20;
    private static final float SURVIVOR_MAX_HEALTH = 100.0f;

    private HumanVisual humanVisual;
    private HandWeapon firearm;
    private long visualTicks;
    private long renderCalls;
    private long shotsFired;
    private long movingUntil;
    private boolean walking;
    private boolean unlimitedAmmoPolicy;
    private boolean godMode = true;
    private boolean survivorDead;
    private String deathReason = "";
    private String lastFireError = "";
    private float observedX;
    private float observedY;

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
        setVariable("isAiming", true);
        setVariable("isAttacking", true);
        try {
            target.Hit(firearm, this, 1.0f, true, 1.0f, false);
            shotsFired++;
            return true;
        } catch (Throwable error) {
            lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
            return false;
        } finally {
            setVariable("isAttacking", false);
            // A shot may have consumed the clip in the underlying item code.
            // Re-equipping here makes the next server tick deterministic.
            ensureFirearm();
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

    /** Advance only the pose/model/light path, never vanilla needs or NPC AI. */
    public void tickVisual() {
        visualTicks++;
        float dx = getX() - observedX;
        float dy = getY() - observedY;
        float distance = (float) Math.sqrt(dx * dx + dy * dy);
        long now = System.nanoTime();
        if (distance > 0.002f && distance < 3.0f) {
            setForwardDirection(dx / distance, dy / distance);
            movingUntil = now + 650_000_000L;
        }
        observedX = getX();
        observedY = getY();
        boolean moving = now < movingUntil;
        if (walking != moving) {
            walking = moving;
            setVariable("isMoving", moving);
            setVariable("WalkSpeed", 1.0f);
            setVariable("WalkInjury", 0.0f);
            var animations = AnimationSet.GetAnimationSet("player", false);
            getAdvancedAnimator().setState(animations.GetState(moving ? "movement" : "idle"),
                    Collections.emptyList());
        }
        if (getCurrentSquare() != null && getModelInstance() != null) updateForServerGui();
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
                + " walking=" + walking + " worn=" + getWornItems().size()
                + " hair=" + getHumanVisual().getHairModel()
                + " firearm=" + getFirearmType()
                + " weaponReady=" + hasReadyFirearm()
                + " firearmState=" + firearmDiagnostics()
                + " sceneCulled=" + isSceneCulled();
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

    // No vanilla living-character update until the dedicated NPC lifecycle owns it.
    @Override public void preupdate() { }
    @Override public void update() { }
    @Override public void postupdate() { }

    public void registerVisualObject() {
        getCell().getObjectList().add(this);
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
