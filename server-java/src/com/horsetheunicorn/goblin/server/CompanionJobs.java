package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.util.StormEnv;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.List;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;
import zombie.core.random.Rand;
import zombie.entity.components.crafting.recipe.CraftRecipeData;
import zombie.entity.components.crafting.recipe.HandcraftLogic;
import zombie.inventory.FixingManager;
import zombie.inventory.InventoryItem;
import zombie.inventory.types.DrainableComboItem;
import zombie.network.GameServer;
import zombie.scripting.objects.Fixing;

/** Native 42.20 crafting/repair operations without IsoPlayer-only XP/history.
 * No player proxies, global recipe mutations, transformers, or client hooks.
 */
public final class CompanionJobs {
    private CompanionJobs() { }

    private static boolean companion(IsoGameCharacter body) {
        return body instanceof IsoZombie && StormEnv.isStormServer() && GameServer.server
            && Boolean.TRUE.equals(body.getModData().rawget("GoblinNPC"));
    }

    // The public perform() consumes/creates items, then unconditionally casts
    // to IsoPlayer. Invoke only its native consumption/output phases instead.
    // Resolve both signatures before allowing any inventory mutation.
    private static final class CraftMethods {
        static final Method CONSUME = method("consumeInputsInternal", IsoGameCharacter.class,
                boolean.class, List.class, List.class);
        static final Method OUTPUT = method("createOutputsInternal", boolean.class,
                List.class, IsoGameCharacter.class);
        private static Method method(String name, Class<?>... args) {
            try {
                Method result = CraftRecipeData.class.getDeclaredMethod(name, args);
                result.setAccessible(true);
                return result;
            } catch (ReflectiveOperationException ex) {
                throw new IllegalStateException("Unsupported PZ crafting API: " + name, ex);
            }
        }
    }

    public static boolean craft(IsoGameCharacter body, HandcraftLogic logic) {
        if (!companion(body) || logic == null || logic.getPlayer() != body) return false;
        Method consume = CraftMethods.CONSUME;
        Method output = CraftMethods.OUTPUT;
        if (!logic.canPerformCurrentRecipe()) return false;
        CraftRecipeData data = logic.getRecipeData();
        if (data.getRecipe().isBuildableRecipe() || data.getRecipe().requiresSpecificWorkstation()) return false;
        for (InventoryItem item : data.getAllNotKeepInputItems()) {
            if (Boolean.TRUE.equals(item.getModData().rawget("GoblinToolKit"))
                    || !body.getInventory().getItems().contains(item)) return false;
        }
        try {
            if (!Boolean.TRUE.equals(consume.invoke(data, body, false,
                    logic.getSourceResources(), logic.getAllItems()))) return false;
            data.luaCallOnStart(body);
            if (!Boolean.TRUE.equals(output.invoke(data, false, null, body)))
                throw new IllegalStateException("Recipe consumed materials but could not produce its result");
            return true;
        } catch (ReflectiveOperationException ex) {
            Throwable cause = ex instanceof InvocationTargetException invocation ? invocation.getCause() : ex;
            // A thrown error is terminal. Lua must not replay a partial batch.
            throw new IllegalStateException("Companion crafting stopped; inspect materials before retrying", cause);
        }
    }

    public static boolean repair(IsoGameCharacter body, InventoryItem item, Fixing fixing, Fixing.Fixer fixer) {
        if (!companion(body) || item == null || fixing == null || fixer == null
                || !FixingManager.getFixes(item).contains(fixing) || !fixing.getFixers().contains(fixer)) return false;
        if (fixing.countUses(body, fixer, item) < fixer.getNumberOfUse()) return false;
        Fixing.Fixer global = fixing.getGlobalItem();
        if (global != null && fixing.countUses(body, global, item) < global.getNumberOfUse()) return false;
        if (global != null && global.getFixerName().equals(fixer.getFixerName())
                && fixing.countUses(body, fixer, item) < fixer.getNumberOfUse()+global.getNumberOfUse()) return false;
        var required=fixing.getRequiredItems(body, fixer, item);
        if (required == null) return false;
        for (InventoryItem supply : required) {
            if (Boolean.TRUE.equals(supply.getModData().rawget("GoblinToolKit"))
                    && !(supply instanceof DrainableComboItem)) return false;
        }
        boolean success = Rand.Next(100) >= FixingManager.getChanceOfFail(item, body, fixing, fixer);
        int gain = Math.max(1, (int)Math.round((item.getConditionMax()-item.getCondition())
                * FixingManager.getCondRepaired(item, body, fixing, fixer)/100.0));
        // These are the same native fixers (including drainable fuel), not
        // invented replacements. Skip only the incompatible player XP award.
        FixingManager.useFixer(body, fixer, item);
        if (global != null) FixingManager.useFixer(body, global, item);
        if (success) {
            item.setConditionNoSound(Math.min(item.getConditionMax(), item.getCondition()+gain));
            item.setHaveBeenRepaired(item.getHaveBeenRepaired()+1);
        } else if (item.getCondition()>0) {
            item.setCondition(item.getCondition()-1);
            body.getEmitter().playSound("FixingItemFailed");
        }
        item.syncItemFields();
        return true; // An attempted native repair can legitimately fail its roll.
    }
}
