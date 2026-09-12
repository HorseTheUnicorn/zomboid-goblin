"""Read-only live model checks: two concurrent game chats and a tool-call response.

Run from the repository with: python tools/check_qwen_runtime.py --url http://127.0.0.1:18000
No game commands or Discord messages are sent and no returned tools are executed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import time
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from goblin_zomboid.qwen import QwenClient


def check_chat(url, alias, owner, name):
    qwen = QwenClient(base_url=url, model=alias, timeout_seconds=30)
    start = time.perf_counter()
    intent, speech = qwen.propose_chat({
        "mode": "PARTY", "controlled_npc_id": "goblin.primary." + owner,
        "controlled_owner": owner, "companion": {"name": name, "task": "FOLLOW"},
        "event": {"speaker": owner, "text": "Goblin, tell me your name and what you do while I stand still."},
    })
    assert intent.intent == "SAY" and name in speech, speech
    return {"owner": owner, "alias": alias, "seconds": round(time.perf_counter()-start, 2), "speech": speech}


def check_tool(url):
    request = Request(url + "/v1/chat/completions", headers={"Content-Type": "application/json"}, data=json.dumps({
        "model": "goblin-smart", "max_tokens": 96, "temperature": 0,
        "messages": [{"role": "user", "content": "Call get_companion_status for horse. Do not guess the status."}],
        "tools": [{"type": "function", "function": {"name": "get_companion_status", "description": "Read companion status.",
            "parameters": {"type": "object", "properties": {"owner": {"type": "string"}}, "required": ["owner"]}}}],
        "tool_choice": "auto", "chat_template_kwargs": {"enable_thinking": False},
    }).encode())
    start = time.perf_counter()
    with urlopen(request, timeout=30) as response:
        data = json.load(response)
    call = data["choices"][0]["message"]["tool_calls"][0]["function"]
    assert call["name"] == "get_companion_status" and json.loads(call["arguments"]) == {"owner": "horse"}, call
    return {"tool_call": call, "seconds": round(time.perf_counter()-start, 2), "executed": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:18000")
    args = parser.parse_args()
    QwenClient(base_url=args.url)  # Enforce loopback before using either endpoint.
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(check_chat, args.url, alias, owner, name) for alias, owner, name in (
            ("goblin-fast", "horse", "Ratspit Ashlicker"), ("goblin-smart", "unicorn", "Sootfang Tinchewer"))]
        results = [future.result() for future in futures]
    results.append(check_tool(args.url))
    print(json.dumps(results, indent=2))
