"""Captured-registry identifiers + real Lua resolver; not native execution."""
import json
from pathlib import Path
import unittest

from tests import test_goblin_jobs as job_fixtures

ROOT = Path(__file__).resolve().parents[1]


class RuntimeIdentifierTests(unittest.TestCase):
    def setUp(self):
        fixture = job_fixtures.ExtendedJobTests()
        fixture.setUp()
        self.lua = fixture.lua
        self.items = json.loads((ROOT / 'reference/pz-items.json').read_text())
        self.recipes = json.loads((ROOT / 'reference/pz-recipes.json').read_text())

    def test_every_enabled_toolkit_id_resolves_in_captured_runtime(self):
        index = {r['full_type']: r for r in self.items['records']}
        kinds = list(self.lua.globals().Tools.types.values())
        self.assertTrue(kinds)
        self.assertEqual(len(kinds), len(set(kinds)))
        for kind in kinds:
            with self.subTest(item=kind):
                record = index[kind]
                self.assertTrue(record['lookup_by_id'])
                self.assertIs(record['enabled'], True)
                self.assertIs(record['obsolete'], False)

    def test_all_captured_recipe_ids_reach_exact_resolver_lookup(self):
        # Capture uses real ScriptManager lookup. These lightweight objects only
        # verify Lua routing of those IDs, not recipe execution or NPC support.
        self.lua.execute('''
            registry={}
            ScriptManager.instance.getCraftRecipe=function(self,id) return registry[id] end
            function installRecipe(id,name)
                registry[id]={id=id,getName=function() return name end,
                    getTranslationName=function() return name end}
            end
        ''')
        for record in self.recipes['records']:
            self.lua.globals().installRecipe(record['recipe_id'], record['name'])
        for record in self.recipes['records']:
            with self.subTest(recipe=record['recipe_id']):
                self.assertTrue(record['lookup_by_id'])
                result = self.lua.globals().Craft.resolve(record['recipe_id'])
                self.assertIsNotNone(result)
                self.assertEqual(result['id'], record['recipe_id'])

    def test_ambiguous_display_names_and_nonexistent_ids_are_rejected(self):
        self.lua.execute('''
            local function r(name)
                return {getName=function() return name end,
                    getTranslationName=function() return 'Shared display name' end}
            end
            ScriptManager.instance.getCraftRecipe=function() return nil end
            ScriptManager.instance.getAllCraftRecipes=function()
                return list({r('First'),r('Second')}) end
            assert(Craft.resolve('Shared display name')==nil)
            assert(Craft.resolve('Base.DoesNotExist')==nil)
            assert(Craft.resolve('')==nil and Craft.resolve(string.rep('a',97))==nil)
            assert(Craft.resolve('bad'..string.char(10)..'name')==nil)
        ''')

    def test_unknown_tool_id_never_calls_inventory_creation(self):
        self.lua.execute('''
            local creates=0
            a.inv.AddItem=function() creates=creates+1;error('must not create') end
            for n=1,100 do assert(Tools.ensure(a,'Base.DoesNotExist')==nil) end
            assert(creates==0)
        ''')


if __name__ == '__main__':
    unittest.main()
