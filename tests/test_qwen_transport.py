import json
import threading
import unittest
from unittest.mock import patch

from goblin_zomboid.qwen import QwenClient, QwenError


class QwenTransportTests(unittest.TestCase):
    def test_chat_grammar_keeps_owner_mode_and_required_targets_without_unsafe_fields(self):
        schema=QwenClient._chat_schema({'controlled_owner':'Alice','mode':'PARTY'})
        branches={s['properties']['intent']['const']:s for s in schema['oneOf']}
        self.assertFalse(branches['SAY']['additionalProperties'])
        self.assertNotIn('target',branches['SAY']['properties'])
        self.assertEqual(branches['FOLLOW']['properties']['target']['properties']['label'],{'const':'Alice'})
        for branch in branches.values():
            self.assertEqual(branch['properties']['mode'],{'const':'PARTY'})
            self.assertIn('text',branch['required'])
            self.assertNotIn('npc_id',branch['properties'])
        safe=QwenClient._chat_schema({'mode':'SAFE'})
        self.assertNotIn('FOLLOW',[s['properties']['intent']['const'] for s in safe['oneOf']])

    def test_one_chat_request_produces_validated_speech_and_action(self):
        qwen=QwenClient()
        raw=json.dumps({'intent':'FOLLOW','mode':'PARTY','text':'On your heels, comrade.',
                        'target':{'kind':'player','player':'horse'}})
        with patch.object(qwen,'_request_json',return_value=raw) as request:
            intent,speech=qwen.propose_chat({'controlled_owner':'horse'})
        self.assertEqual(intent.intent,'FOLLOW')
        self.assertEqual(speech,'On your heels, comrade.')
        request.assert_called_once()

    def test_combined_chat_still_rejects_unsafe_or_incomplete_responses(self):
        qwen=QwenClient()
        for raw in ({'intent':'SAY','mode':'PARTY'},
                    {'intent':'SAY','mode':'PARTY','text':'ok','lua':'execute'},
                    {'intent':'SAY','mode':'PARTY','text':'x'*241}):
            with self.subTest(raw=raw), patch.object(qwen,'_request_json',return_value=json.dumps(raw)):
                with self.assertRaises(QwenError): qwen.propose_chat({})

    def test_pending_http_pumps_callbacks_on_callers_thread(self):
        caller=threading.get_ident()
        pumped=threading.Event()
        callbacks=[]
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self):
                self_test.assertNotEqual(threading.get_ident(),caller)
                self_test.assertTrue(pumped.wait(3), 'IPC was blocked by HTTP')
                return json.dumps({'choices':[{'message':{'content':'{"text":"Here, comrade."}'}}]}).encode()
        self_test=self
        qwen=QwenClient()
        def callback():
            callbacks.append(threading.get_ident())
            pumped.set()
        qwen.set_wait_callback(callback)
        with patch('goblin_zomboid.qwen.urlopen',return_value=Response()):
            self.assertEqual(qwen.propose_speech({}),'Here, comrade.')
        self.assertEqual(callbacks,[caller])

    def test_transport_timeout_is_not_mistaken_for_a_pending_future(self):
        with patch('goblin_zomboid.qwen.urlopen',side_effect=TimeoutError('timeout')):
            with self.assertRaises(QwenError):
                QwenClient().propose_speech({})
