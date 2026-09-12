import json
import unittest
from unittest.mock import patch

from goblin_zomboid.lenin import REFERENCE_CARDS, SOURCE_URL, reference_prompt
from goblin_zomboid.qwen import QwenClient, QwenError
from goblin_zomboid.social import sanitize_speech


class LeninDialogueTests(unittest.TestCase):
    def test_local_references_are_explicitly_paraphrases_and_original_fiction(self):
        self.assertEqual(SOURCE_URL, "https://www.marxists.org/archive/lenin/quotes.htm")
        self.assertGreaterEqual(len(REFERENCE_CARDS), 6)
        for card in REFERENCE_CARDS:
            text = reference_prompt(card)
            self.assertIn("paraphrased", text)
            self.assertIn("NOT a historical quote", text)
            self.assertEqual(sanitize_speech(card[2]), card[2])

    def test_ambient_uses_one_local_reference_and_one_bounded_model_request(self):
        line = "Lenin's committee can wait; this fucking roof cannot, comrade."
        with patch("goblin_zomboid.qwen.random.choice", return_value=REFERENCE_CARDS[1]), \
                patch.object(QwenClient, "_request_json", return_value=json.dumps({"text": line})) as request:
            self.assertEqual(QwenClient().propose_ambient({}), line)
        request.assert_called_once()
        prompt = request.call_args.args[0]
        self.assertIn(REFERENCE_CARDS[1][1], prompt)
        self.assertIn("not an answer or a command", prompt)
        self.assertIn("fuck, shit, damn", prompt)
        self.assertEqual(request.call_args.kwargs["max_tokens"], 96)
        self.assertFalse(request.call_args.kwargs["schema"]["additionalProperties"])

    def test_profane_ambient_cannot_smuggle_an_action(self):
        with patch.object(QwenClient, "_request_json", return_value=json.dumps(
                {"text": "Close the fucking curtains, comrade.", "intent": "CLOSE_CURTAINS"})):
            with self.assertRaises(QwenError): QwenClient().propose_ambient({})

    def test_curtain_chat_uses_single_validated_action_and_retains_profane_speech(self):
        response = {"intent": "CLOSE_CURTAINS", "mode": "PARTY", "text": "I'll shut those damn curtains, comrade."}
        with patch.object(QwenClient, "_request_json", return_value=json.dumps(response)):
            intent, speech = QwenClient().propose_chat({"mode": "PARTY", "controlled_owner": "horse"})
        self.assertEqual(intent.intent, "CLOSE_CURTAINS")
        self.assertEqual(speech, response["text"])
