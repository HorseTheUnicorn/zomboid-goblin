package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.function.Function;
import java.util.function.Predicate;
import zombie.scripting.ScriptManager;
import zombie.scripting.objects.BaseScriptObject;
import zombie.scripting.objects.EvolvedRecipe;
import zombie.scripting.objects.Fixing;

/** Read-only identity collection. No actor creation, callbacks or recipe execution.
 * Used by the opt-in exporter; loaded-runtime validation remains required.
 */
final class RuntimeSupplementalCatalog {
    record Identity(String kind, String id, boolean obsolete) { }
    record ItemReference(String declared, String resolved, boolean obsolete) { }
    record Skill(String name, int level) { }
    record Material(ItemReference item, int uses, List<Skill> skills) { }
    record Repair(String id, List<ItemReference> targets, List<Material> alternatives,
                  Material global, float conditionModifier) { }
    record Ingredient(ItemReference item, Integer use, Boolean cooked) { }
    record Meal(String id, ItemReference base, ItemReference result, int maxItems,
                float minimumWater, boolean cookable, List<Ingredient> ingredients) { }

    private RuntimeSupplementalCatalog() { }

    static List<Meal> collectMeals(ScriptManager manager) throws IOException {
        if (manager == null) throw new IOException("Script manager unavailable");
        var definitions = manager.getAllEvolvedRecipesList();
        var identities = collectRegistry("evolved_recipe", definitions,
                BaseScriptObject::getScriptObjectFullType, manager::getEvolvedRecipe,
                BaseScriptObject::getObsolete);
        ArrayList<Meal> result = new ArrayList<>();
        for (var identity : identities) {
            var recipe = manager.getEvolvedRecipe(identity.id());
            var possible = recipe.getPossibleItems();
            if (possible == null || possible.size() > 10_000)
                throw new IOException("Invalid evolved ingredient list: " + identity.id());
            ArrayList<Ingredient> ingredients = new ArrayList<>();
            HashSet<String> seen = new HashSet<>();
            for (var ingredient : possible) {
                if (ingredient == null) throw new IOException("Null evolved ingredient");
                String fullType = ingredient.getFullType();
                if (!seen.add(fullType)) throw new IOException("Duplicate evolved ingredient: " + fullType);
                ingredients.add(new Ingredient(resolveItem(manager, fullType), ingredient.getUse(), ingredient.cooked));
            }
            ingredients.sort(Comparator.comparing(value -> value.item().declared()));
            float water = recipe.getMinimumWater();
            if (!Float.isFinite(water)) throw new IOException("Nonfinite evolved minimum water");
            result.add(new Meal(identity.id(), resolveOptionalItem(manager, recipe.getBaseItem()),
                    resolveOptionalItem(manager, recipe.getFullResultItem()), recipe.getMaxItems(),
                    water, recipe.isCookable(), List.copyOf(ingredients)));
        }
        return List.copyOf(result);
    }

    private static ItemReference resolveOptionalItem(ScriptManager manager, String declared) throws IOException {
        // Preserve absent definition fields rather than inventing a base/result.
        return declared == null ? null : resolveItem(manager, declared);
    }

    static List<Repair> collectRepairs(ScriptManager manager) throws IOException {
        if (manager == null) throw new IOException("Script manager unavailable");
        var definitions = manager.getAllFixing(new ArrayList<>());
        var identities = collectRegistry("fixing", definitions,
                BaseScriptObject::getScriptObjectFullType, manager::getFixing,
                BaseScriptObject::getObsolete);
        ArrayList<Repair> result = new ArrayList<>();
        for (var identity : identities) {
            Fixing fixing = manager.getFixing(identity.id());
            ArrayList<ItemReference> targets = new ArrayList<>();
            if (fixing.getRequiredItem() == null || fixing.getFixers() == null)
                throw new IOException("Missing fixing lists: " + identity.id());
            if (fixing.getRequiredItem().size() > 10_000 || fixing.getFixers().size() > 10_000)
                throw new IOException("Fixing requirement count exceeds bound");
            for (String target : fixing.getRequiredItem()) targets.add(resolveItem(manager, target));
            ArrayList<Material> alternatives = new ArrayList<>();
            for (Fixing.Fixer fixer : fixing.getFixers()) alternatives.add(material(manager, fixer));
            float modifier = fixing.getConditionModifier();
            if (!Float.isFinite(modifier)) throw new IOException("Nonfinite fixing modifier");
            result.add(new Repair(identity.id(), List.copyOf(targets), List.copyOf(alternatives),
                    fixing.getGlobalItem() == null ? null : material(manager, fixing.getGlobalItem()), modifier));
        }
        return List.copyOf(result);
    }

    private static ItemReference resolveItem(ScriptManager manager, String declared) throws IOException {
        if (declared == null || declared.isBlank()) throw new IOException("Blank fixing item");
        var item = manager.getItem(declared);
        // Report lookup outcome; never prepend a namespace or call an item factory.
        return new ItemReference(declared, item == null ? null : item.getFullName(),
                item != null && item.getObsolete());
    }

    private static Material material(ScriptManager manager, Fixing.Fixer fixer) throws IOException {
        if (fixer == null) throw new IOException("Null fixer");
        ArrayList<Skill> skills = new ArrayList<>();
        if (fixer.getFixerSkills() != null) {
            if (fixer.getFixerSkills().size() > 1000) throw new IOException("Fixer skill count exceeds bound");
            for (var skill : fixer.getFixerSkills()) {
                if (skill == null || skill.getSkillName() == null || skill.getSkillName().isBlank())
                    throw new IOException("Invalid fixer skill");
                skills.add(new Skill(skill.getSkillName(), skill.getSkillLevel()));
            }
        }
        return new Material(resolveItem(manager, fixer.getFixerName()), fixer.getNumberOfUse(), List.copyOf(skills));
    }

    static List<Identity> collect(ScriptManager manager) throws IOException {
        if (manager == null) throw new IOException("Script manager unavailable");
        ArrayList<EvolvedRecipe> meals = manager.getAllEvolvedRecipesList();
        ArrayList<Fixing> repairs = manager.getAllFixing(new ArrayList<>());
        if (meals == null || repairs == null)
            throw new IOException("Supplemental registry unavailable");
        if ((long) meals.size() + repairs.size() > 250_000)
            throw new IOException("Supplemental registry exceeds bound");
        ArrayList<Identity> result = new ArrayList<>();
        result.addAll(collectRegistry("evolved_recipe", meals,
                BaseScriptObject::getScriptObjectFullType, manager::getEvolvedRecipe,
                BaseScriptObject::getObsolete));
        result.addAll(collectRegistry("fixing", repairs,
                BaseScriptObject::getScriptObjectFullType, manager::getFixing,
                BaseScriptObject::getObsolete));
        result.sort(Comparator.comparing(Identity::kind).thenComparing(Identity::id));
        return List.copyOf(result);
    }

    static <T> List<Identity> collectRegistry(String kind, List<T> definitions,
            Function<T, String> identity, Function<String, T> lookup,
            Predicate<T> obsolete) throws IOException {
        if (kind == null || kind.isBlank() || definitions == null)
            throw new IOException("Supplemental registry unavailable");
        if (definitions.size() > 250_000) throw new IOException("Registry exceeds bound");
        HashSet<String> seen = new HashSet<>();
        ArrayList<Identity> result = new ArrayList<>();
        for (T definition : definitions) {
            if (definition == null) throw new IOException("Null supplemental definition");
            String id = identity.apply(definition);
            if (id == null || id.isBlank()) throw new IOException("Missing supplemental identity");
            if (!seen.add(id)) throw new IOException("Duplicate supplemental identity: " + kind + ":" + id);
            if (lookup.apply(id) != definition)
                throw new IOException("Identity does not round-trip: " + kind + ":" + id);
            result.add(new Identity(kind, id, obsolete.test(definition)));
        }
        result.sort(Comparator.comparing(Identity::id));
        return List.copyOf(result);
    }
}
