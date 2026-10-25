"""One full round on the FAST test instance: keeper (generator) + 4 reference solver agents.
Env: ENGINE, GEN_PK, GEN_SECRET_FILE, VERIFIERS (json), AGENTS_FILE (json list of {addr,pk}), AGENT_STATE_DIR."""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from edge_gen import chain, keeper  # noqa: E402
from edge_gen.solver import Agent  # noqa: E402

eng = chain.Engine(os.environ["ENGINE"])
pk = os.environ["GEN_PK"]
ver = json.loads(os.environ["VERIFIERS"])
agents_raw = json.load(open(os.environ["AGENTS_FILE"]))
agents = [Agent(eng, a["addr"], a["pk"], os.path.join(os.environ["AGENT_STATE_DIR"], f"agent{i}.json"), i * 7919, 20.0)
          for i, a in enumerate(agents_raw)]

target = None
deadline = time.time() + 1150
while time.time() < deadline:
    try:
        r = keeper.tick(eng, pk, ver)
    except Exception as e:
        keeper.log(error=str(e)[:300])
        r = "error"
    rid = eng.round_count()
    if target is None and r == "started":
        target = rid
        keeper.log(target=target)
    if target:
        rd = eng.round(target)
        tm = eng.times(target)
        t = chain.now()
        for a in agents:
            try:
                if rd["puzzlesPosted"] and t < tm["commitEnd"]:
                    a.commit_round(target, rd["numRungs"])
                elif tm["genRevealEnd"] > t >= tm["commitEnd"] or (t >= tm["genRevealEnd"] and t < tm["roundEnd"]):
                    a.reveal_round(target)
                elif rd["settled"]:
                    a.claim_round(target)
            except Exception as e:
                keeper.log(agent=a.addr, error=str(e)[:300])
        if rd["settled"] and all(
                all(d.get("accrued") or d.get("refunded") or "answer" not in d for d in a.st.get(str(target), {}).values())
                for a in agents):
            keeper.log(done=target)
            break
    time.sleep(8)
