from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from goblin_zomboid.config import AgentConfig
from goblin_zomboid.protocol import make_message
from goblin_zomboid.service import GoblinService
from goblin_zomboid.validator import IntentValidator


class FakeQwen:
    def __init__(self, intent: str = "FOLLOW") -> None:
        self.intent = intent
        self.intent_contexts: list[object] = []
        self.speech_contexts: list[object] = []

    def propose_speech(self, context: object) -> str:
        self.speech_contexts.append(context)
        return "Comrade, I have heard you. The canned beans shall be organized."

    def propose_intent(self, context: object):
        self.intent_contexts.append(context)
        if self.intent == "SET_BASE":
            payload = {"intent": "SET_BASE", "mode": "SAFE"}
        elif self.intent == "LOOT_AREA":
            payload = {
                "intent": "LOOT_AREA",
                "mode": "ROAM",
                "target": {"kind": "current_position", "name": "current area"},
                "loot_focus": "surprise",
            }
        else:
            payload = {
                "intent": "FOLLOW",
                "mode": "PARTY",
                "target": {"kind": "player", "player": "speaker"},
            }
        return IntentValidator().validate(payload)


class BrokenQwen:
    def propose_speech(self, _context: object) -> str:
        from goblin_zomboid.qwen import QwenError
        raise QwenError("speech outage")

    def propose_intent(self, _context: object):
        from goblin_zomboid.qwen import QwenError
        raise QwenError("intent outage")


class NpcServiceTests(unittest.TestCase):
    def _ambient_state(self,service,**overrides):
        self._publish_state(service)
        fields=service._read_state().fields
        fields['companions'][0].update(owner_online=True,owner_idle_seconds=45,task='FOLLOW',combat_state='NONE')
        fields['companions'][0].update(overrides)
        service.store.publish_runtime('zomboid-state',make_message('runtime.state',timestamp_ms=2000000,**fields))
        service.next_ambient['goblin.primary.alice']=0

    def test_ambient_lenin_remark_is_only_speech_for_correct_owner_with_cooldown(self):
        class Ambient(FakeQwen):
            def propose_ambient(self,context):
                self.context=context
                return 'Lenin had a revolution; I have a committee of stolen beans, comrade.'
        qwen=Ambient();service=self._service(qwen)
        try:
            self._ambient_state(service)
            service.run_once();service.ambient_future.result(timeout=2)
            self.assertEqual(service.run_once().status,'ambient_spoken')
            commands=self._commands(service)
            self.assertEqual([(c.fields['owner'],c.fields['action']) for c in commands],[('Alice','SAY')])
            self.assertIn('Lenin',qwen.context['ambient_topic'])
            self.assertNotIn('x',qwen.context['companion'])
            self.assertGreaterEqual(service.next_ambient['goblin.primary.alice'],2120)
            service.run_once();self.assertIsNone(service.ambient_future)
        finally:
            service.close()

    def test_pending_ambient_inference_never_blocks_addressed_chat(self):
        import threading
        release=threading.Event()
        class Ambient(FakeQwen):
            def propose_ambient(self,context):
                release.wait(3)
                return 'Lenin would demand a better can opener.'
        service=self._service(Ambient())
        try:
            self._ambient_state(service)
            service.run_once();future=service.ambient_future
            self._publish_chat(service,'Bob','Goblin come here','urgent-bob')
            self.assertEqual(service.run_once().status,'npc_command_published')
            self.assertFalse(future.done())
            release.set();future.result(timeout=2)
            service.run_once()
            self.assertFalse(any(c.fields['owner']=='Alice' for c in self._commands(service)))
        finally:
            release.set();service.close()

    def test_stale_ambient_is_discarded_after_logout_combat_or_explicit_job(self):
        class Ambient(FakeQwen):
            def propose_ambient(self,context): return 'Lenin would organize these beans.'
        for changes in ({'owner_online':False},{'task':'BUILD'},{'combat_state':'READY'},{'owner_idle_seconds':0},{'riding':True}):
            with self.subTest(changes=changes):
                service=self._service(Ambient())
                try:
                    self._ambient_state(service)
                    service.run_once();service.ambient_future.result(timeout=2)
                    self._ambient_state(service,**changes)
                    service.run_once()
                    self.assertFalse(self._commands(service))
                finally:
                    service.close()

    def test_attack_chat_is_published_and_next_players_chat_still_runs(self):
        class AttackQwen(FakeQwen):
            def propose_intent(self, context):
                return IntentValidator().validate({'intent':'ATTACK','mode':'PARTY'})
        service=self._service(AttackQwen())
        try:
            self._publish_state(service)
            self._publish_chat(service,'Alice','Goblin kill that zombie','attack-a')
            self._publish_chat(service,'Bob','Goblin kill that zombie','attack-b')
            self.assertEqual(service.run_once().status,'npc_command_published')
            self.assertEqual(service.run_once().status,'npc_command_published')
            attacks=[c for c in self._commands(service) if c.fields['action']=='ATTACK']
            self.assertEqual({c.fields['owner'] for c in attacks},{'Alice','Bob'})
        finally:
            service.close()

    def test_failed_chat_is_not_replayed_and_does_not_stop_next_player(self):
        service=self._service(FakeQwen())
        try:
            self._publish_state(service)
            self._publish_chat(service,'Alice','Goblin come here','failure-a')
            service._poll_events()
            original=service._handle_chat
            def broken(chat,companion):
                raise RuntimeError('isolated test failure')
            service._handle_chat=broken
            with self.assertLogs('goblin_zomboid.service',level='ERROR'):
                self.assertEqual(service.run_once().status,'chat_failed')
            self.assertFalse(service.pending_chats)
            service._handle_chat=original
            self._publish_chat(service,'Bob','Goblin come here','success-b')
            self.assertEqual(service.run_once().status,'npc_command_published')
            self.assertTrue(any(c.fields['owner']=='Bob' for c in self._commands(service)))
        finally:
            service.close()

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="goblin-service-npc-"))
        self.bridge = self.directory / "bridge"
        self.bridge.mkdir()
        self.config = AgentConfig(
            bridge_root=self.bridge,
            enabled=True,
            heartbeat_seconds=1,
            pz_timeout_seconds=30,
            start_paused=False,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def _service(self, qwen: object) -> GoblinService:
        return GoblinService(
            self.config,
            memory_path=self.directory / "memory.sqlite3",
            qwen=qwen,
            clock=lambda: 2_000.0,
        )

    def _publish_state(self, service: GoblinService) -> None:
        service.store.publish_runtime(
            "zomboid-heartbeat",
            make_message(
                "runtime.heartbeat",
                timestamp_ms=2_000_000,
                body_mode="npc",
                companion_count=2,
            ),
        )
        service.store.publish_runtime(
            "zomboid-state",
            make_message(
                "runtime.state",
                timestamp_ms=2_000_000,
                companions=[
                    {
                        "npc_id": "goblin.primary.alice",
                        "owner": "Alice",
                        "alive": True,
                        "body_present": True,
                        "body_mode": "npc",
                        "control_ready": True,
                        "npc_engine_ready": True,
                        "mode": "PARTY",
                        "weapon_ready": True,
                        "x": 100,
                        "y": 200,
                    },
                    {
                        "npc_id": "goblin.primary.bob",
                        "owner": "Bob",
                        "alive": True,
                        "body_present": True,
                        "body_mode": "npc",
                        "control_ready": True,
                        "npc_engine_ready": True,
                        "mode": "PARTY",
                        "weapon_ready": True,
                    },
                ],
                nearby_players=[{"id": "Alice"}, {"id": "Bob"}],
            ),
        )

    def _publish_chat(self, service: GoblinService, speaker: str, text: str, stem: str) -> None:
        service.store.publish(
            "events",
            make_message(
                "event.chat",
                timestamp_ms=2_000_000,
                speaker=speaker,
                text=text,
                authorized=False,
            ),
            stem=stem,
        )

    def _commands(self, service: GoblinService):
        commands = []
        for item in service.store.iter_ready("commands"):
            commands.append(service.store.read_ready(item))
        return commands

    def _offline_state(self, service, **overrides):
        self._publish_state(service)
        fields=dict(service._read_state().fields)
        offline=fields['companions'][0]
        offline.update(owner_online=False, task='FOLLOW', autonomous=False,
                       name='Ratspit Ashlicker', persisted=True, authority_token='offline-test-grant')
        offline.update(overrides)
        service.store.publish_runtime('zomboid-state',make_message('runtime.state',timestamp_ms=2_000_000,**fields))

    def test_offline_qwen_uses_one_scoped_grant_and_does_not_poll_every_heartbeat(self):
        qwen=FakeQwen('LOOT_AREA');service=self._service(qwen)
        try:
            self._offline_state(service)
            self.assertEqual(service.run_once().status,'offline_command_published')
            command=self._commands(service)[0]
            self.assertTrue(command.fields['autonomous'])
            self.assertEqual(command.fields['authority_token'],'offline-test-grant')
            self.assertEqual(command.fields['owner'],'Alice')
            self.assertNotIn('authority_token',qwen.intent_contexts[0])
            self.assertEqual(qwen.intent_contexts[0]['event']['type'],'offline_decision')
            self.assertEqual(qwen.intent_contexts[0]['persistent_goblins'][0]['name'],'Ratspit Ashlicker')
            service.run_once()
            self.assertEqual(len(qwen.intent_contexts),1)
        finally:
            service.close()

    def test_offline_explicit_order_or_unloaded_body_is_not_sent_to_qwen_for_control(self):
        for overrides in ({'task':'WAIT'}, {'body_present':False}):
            qwen=FakeQwen('LOOT_AREA');service=self._service(qwen)
            try:
                self._offline_state(service,**overrides)
                service.run_once()
                self.assertEqual(qwen.intent_contexts,[])
                self.assertEqual(len(service.last_state['companions']),2)
            finally:
                service.close()

    def test_offline_decision_is_cancelled_if_owner_returns_during_inference(self):
        qwen=FakeQwen('LOOT_AREA');service=self._service(qwen)
        propose=qwen.propose_intent
        def returning_owner(context):
            result=propose(context)
            self._offline_state(service,owner_online=True)
            return result
        qwen.propose_intent=returning_owner
        try:
            self._offline_state(service)
            self.assertEqual(service.run_once().status,'offline_cancelled')
            self.assertEqual(self._commands(service),[])
        finally:
            service.close()

    def test_unknown_chat_owner_cannot_fall_back_to_someone_elses_goblin(self):
        service=self._service(FakeQwen())
        try:
            self._publish_state(service)
            self._publish_chat(service,'Eve','Goblin, follow me','unknown-owner')
            self.assertEqual(service.run_once().status,'waiting_for_goblin')
            self.assertEqual(self._commands(service),[])
        finally:
            service.close()

    def test_chat_speech_knows_the_persistent_roster_including_offline_goblins(self):
        qwen=FakeQwen();service=self._service(qwen)
        try:
            self._offline_state(service,body_present=False)
            self._publish_chat(service,'Bob','Goblin, who is Ratspit?','roster-question')
            service.run_once()
            roster=qwen.speech_contexts[0]['persistent_goblins']
            self.assertFalse(roster[0]['body_present'])
            self.assertEqual(roster[0]['name'],'Ratspit Ashlicker')
            self.assertNotIn('authority_token',roster[0])
        finally:
            service.close()

    def test_server_applied_chat_generates_reply_without_restarting_task(self) -> None:
        qwen=FakeQwen()
        service=self._service(qwen)
        try:
            self._publish_state(service)
            service.store.publish('events',make_message('event.chat',timestamp_ms=2_000_000,
                speaker='Alice',text='Goblin, board up the windows',authorized=False,
                direct_action='FORTIFY',direct_applied=True,addressed=True),stem='already-applied')
            result=service.run_once()
            self.assertEqual(result.status,'npc_spoke')
            self.assertEqual(qwen.intent_contexts,[])
            self.assertEqual([c.fields['action'] for c in self._commands(service)],['SAY'])
        finally:
            service.close()

    def test_rejected_direct_order_reports_failure_without_substitute_or_qwen(self) -> None:
        qwen=FakeQwen()
        service=self._service(qwen)
        try:
            self._publish_state(service)
            service.store.publish('events',make_message('event.chat',timestamp_ms=2_000_000,
                speaker='Alice',text='Goblin, open the door',authorized=False,addressed=True,
                direct_action='OPEN_DOOR',direct_applied=False,direct_detail='door is locked'),stem='refused-door')
            service.run_once()
            self.assertEqual(qwen.intent_contexts,[])
            self.assertEqual(qwen.speech_contexts,[])
            commands=self._commands(service)
            self.assertEqual([c.fields['action'] for c in commands],['SAY'])
            self.assertIn('locked',commands[0].fields['text'])
        finally:
            service.close()

    def test_already_reported_order_does_not_duplicate_chat_or_consume_qwen(self) -> None:
        qwen=FakeQwen()
        service=self._service(qwen)
        try:
            self._publish_state(service)
            service.store.publish('events',make_message('event.chat',timestamp_ms=2_000_000,
                speaker='Bob',text='Goblin, sow cabbage',authorized=False,addressed=True,
                direct_action='FARM',direct_applied=True,direct_reported=True,
                direct_detail='farm job queued: sow'),stem='reported-farm')
            result=service.run_once()
            self.assertEqual(result.status,'npc_command_handled')
            self.assertEqual(qwen.intent_contexts,[])
            self.assertEqual(qwen.speech_contexts,[])
            self.assertEqual(self._commands(service),[])
        finally:
            service.close()

    def test_feral_name_address_routes_to_the_speakers_companion(self) -> None:
        service=self._service(FakeQwen())
        try:
            self._publish_state(service)
            service.store.publish('events',make_message('event.chat',timestamp_ms=2_000_000,
                speaker='Bob',text='Ratspit, follow me',authorized=False,addressed=True,
                direct_action='FOLLOW',direct_applied=True),stem='feral-name')
            service.run_once()
            commands=self._commands(service)
            self.assertEqual(len(commands),1)
            self.assertEqual(commands[0].fields['npc_id'],'goblin.primary.bob')
        finally:
            service.close()

    def test_addressed_chat_routes_reply_and_action_to_speakers_goblin(self) -> None:
        qwen = FakeQwen("FOLLOW")
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, follow me.", "alice-chat")
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            commands = self._commands(service)
            self.assertEqual({cmd.fields["action"] for cmd in commands}, {"SAY", "FOLLOW"})
            self.assertTrue(all(cmd.fields["npc_id"] == "goblin.primary.alice" for cmd in commands))
            self.assertTrue(all(cmd.fields["owner"] == "Alice" for cmd in commands))
            self.assertEqual(qwen.intent_contexts[0]["controlled_npc_id"], "goblin.primary.alice")
            self.assertNotIn("x", qwen.intent_contexts[0])
            self.assertNotIn("y", qwen.intent_contexts[0])
        finally:
            service.close()

    def test_combined_chat_has_one_model_call_and_routes_both_outputs_to_owner(self):
        class CombinedQwen:
            def __init__(self): self.contexts=[]
            def propose_chat(self,context):
                self.contexts.append(context)
                return IntentValidator().validate({'intent':'FOLLOW','mode':'PARTY',
                    'target':{'kind':'player','player':'speaker'}}),'At your heels, comrade.'
            def propose_speech(self,_): raise AssertionError('second model call')
            def propose_intent(self,_): raise AssertionError('second model call')
        qwen=CombinedQwen();service=self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service,'Bob','Goblin, come along.','combined')
            self.assertEqual(service.run_once().status,'npc_command_published')
            self.assertEqual(len(qwen.contexts),1)
            self.assertEqual(qwen.contexts[0]['controlled_npc_id'],'goblin.primary.bob')
            self.assertEqual(len(qwen.contexts[0]['persistent_goblins']),2)
            self.assertNotIn('x',qwen.contexts[0]['companion'])
            commands=self._commands(service)
            self.assertEqual({c.fields['action'] for c in commands},{'SAY','FOLLOW'})
            self.assertTrue(all(c.fields['owner']=='Bob' for c in commands))
        finally: service.close()

    def test_second_player_gets_a_different_goblin_id(self) -> None:
        qwen = FakeQwen("LOOT_AREA")
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Bob", "Goblin, loot this place and bring it home.", "bob-chat")
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            commands = self._commands(service)
            self.assertTrue(all(cmd.fields["npc_id"] == "goblin.primary.bob" for cmd in commands))
            self.assertIn("LOOT_AREA", {cmd.fields["action"] for cmd in commands})
        finally:
            service.close()

    def test_set_base_is_a_normal_per_player_intent(self) -> None:
        qwen = FakeQwen("SET_BASE")
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, this is our base. Remember it.", "base-chat")
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            actions = {cmd.fields["action"] for cmd in self._commands(service)}
            self.assertIn("SET_BASE", actions)
        finally:
            service.close()

    def test_ordinary_heartbeat_does_not_spend_qwen_tokens(self) -> None:
        qwen = FakeQwen()
        service = self._service(qwen)
        try:
            self._publish_state(service)
            first = service.run_once()
            second = service.run_once()
            self.assertEqual(first.status, "npc_steady")
            self.assertEqual(second.status, "npc_steady")
            self.assertEqual(qwen.intent_contexts, [])
            self.assertEqual(qwen.speech_contexts, [])
        finally:
            service.close()

    def test_chat_loop_polls_quickly_and_drains_two_players_without_heartbeat_sleeps(self):
        service=self._service(FakeQwen())
        try:
            waits=[];handled=[];polls=[]
            class Stop:
                def is_set(self): return len(handled)>=3
                def wait(self,seconds): waits.append(seconds)
            def once():
                handled.append(service.pending_chats.pop(0) if service.pending_chats else 'heartbeat')
            def poll():
                if not polls:
                    polls.append(True);service.pending_chats.extend(['Alice','Bob'])
            service.run_once=once
            service._poll_events=poll
            service._poll_responses=lambda:None
            service.run_forever(Stop())
            self.assertEqual(handled,['heartbeat','Alice','Bob'])
            self.assertLessEqual(max(waits),0.25)
            self.assertIn(0,waits)
        finally:
            service.close()

    def test_second_players_chat_is_collected_while_first_model_request_is_slow(self):
        clock=[2000.0]
        test=self
        class PumpingQwen(FakeQwen):
            def set_wait_callback(self, callback):
                self.wait=callback
            def propose_speech(self, context):
                if context['controlled_owner']=='Alice':
                    clock[0]=2010.0
                    test._publish_chat(service,'Bob','Goblin, hello','bob-during-inference')
                    self.wait()
                    # Longer than the event acceptance TTL; Bob must already be
                    # queued, and Alice's selected driver must remain Alice's.
                    clock[0]=2040.0
                    fields=service.store.read_runtime('zomboid-state').fields
                    service.store.publish_runtime('zomboid-state',make_message(
                        'runtime.state',timestamp_ms=2040000,**fields))
                    self.wait()
                return super().propose_speech(context)
        qwen=PumpingQwen()
        service=GoblinService(self.config,memory_path=self.directory/'memory.sqlite3',
            qwen=qwen,clock=lambda:clock[0])
        try:
            self._publish_state(service)
            self._publish_chat(service,'Alice','Goblin, hello','alice-first')
            service.run_once()
            self.assertEqual(len(service.pending_chats),1)
            self.assertTrue(all(c.fields['owner']=='Alice' for c in self._commands(service)))
            service.run_once()
            self.assertEqual([c['controlled_owner'] for c in qwen.speech_contexts],['Alice','Bob'])
            self.assertEqual({c.fields['owner'] for c in self._commands(service)},{'Alice','Bob'})
        finally:
            service.close()

    def test_coordinates_are_removed_before_qwen_sees_companion_state(self) -> None:
        qwen = FakeQwen()
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, come here.", "safe-chat")
            service.run_once()
            context = qwen.intent_contexts[0]
            self.assertNotIn("x", context)
            self.assertNotIn("y", context)
        finally:
            service.close()

    def test_qwen_outage_does_not_break_server_owned_companion(self) -> None:
        service = self._service(BrokenQwen())
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, follow me.", "outage-chat")
            result = service.run_once()
            self.assertEqual(result.status, "qwen_failed")
            self.assertIn("intent failed", result.detail)
        finally:
            service.close()


if __name__ == "__main__":
    unittest.main()
