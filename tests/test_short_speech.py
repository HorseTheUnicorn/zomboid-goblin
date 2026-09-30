"""One-bubble speech limits at the model and native display boundaries."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from goblin_zomboid.qwen import QwenClient
from goblin_zomboid.social import SPEECH_LIMIT, compact_speech, sanitize_speech

ROOT = Path(__file__).resolve().parents[1]


class ShortSpeechTests(unittest.TestCase):
    def test_long_speech_keeps_complete_sentence(self):
        self.assertEqual(sanitize_speech("The reserve is ready. " + "Comrade, more glorious words. " * 6),
                         "The reserve is ready. Comrade, more glorious words. Comrade, more glorious words. "
                         "Comrade, more glorious words.")

    def test_long_unpunctuated_line_ends_at_word_boundary(self):
        text = compact_speech("Comrade " * 40)
        self.assertLessEqual(len(text), SPEECH_LIMIT)
        self.assertTrue(text.endswith("Comrade..."))

    def test_compacting_does_not_bypass_safety_validation(self):
        with self.assertRaises(ValueError):
            sanitize_speech("Fine. " + "safe " * 30 + " exec: something")
        with self.assertRaises(ValueError):
            sanitize_speech("x" * 241)

    def test_unicode_speech_also_fits_the_lua_byte_limit(self):
        text = sanitize_speech("Товарищ " * 25)
        self.assertLessEqual(len(text.encode("utf-8")), SPEECH_LIMIT)
        self.assertTrue(text.endswith("Товарищ..."))

    def test_qwen_schemas_and_prompts_agree(self):
        schema = QwenClient._chat_schema({"mode": "ROAM"})
        self.assertTrue(all(branch["properties"]["text"]["maxLength"] == 140
                            for branch in schema["oneOf"]))
        self.assertEqual(QwenClient._reflect_schema()["properties"]["say"]["maxLength"], 140)
        self.assertIn("140 characters", QwenClient._chat_prompt())

    def test_lua_display_boundary_handles_long_built_in_and_utf8_lines(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        base = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"
        lua.globals().paths = ";".join((base / side / "?.lua").as_posix()
                                      for side in ("shared", "server"))
        lua.execute('''
            package.path=paths..';'..package.path
            package.loaded['GoblinSurvivor/GoblinAppearance']={}
            Body=require('GoblinSurvivor/GoblinBody')
            Body.isGoblin=function() return true end
            data={};Body.data=function() return data end
            isServer=function() return true end
            sendServerCommand=function(_,_,args) speech=args.text end
        ''')
        long = "Comrade, food stored. " + "More words for the revolution " * 20
        lua.globals().long_line = long
        lua.execute("assert(Body.say({},long_line));assert(#speech<=140);assert(speech:find('food stored%.'))")
        lua.globals().long_line = "Товарищ " * 40
        lua.execute("assert(Body.say({},long_line));assert(#speech<=140)")
        # Lupa decodes as UTF-8, so a split multi-byte character would fail here.
        self.assertTrue(lua.globals().speech.endswith("..."))


if __name__ == "__main__":
    unittest.main()
