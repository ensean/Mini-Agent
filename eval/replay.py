"""Replay eval/ground_truth.json against the running demo to produce evaluable sessions.

    .venv/bin/python eval/replay.py                          # local demo on 127.0.0.1:8080
    .venv/bin/python eval/replay.py --base-url https://dxxxx.cloudfront.net

Each scenario becomes ONE session (all its turns share a session_id, which the demo puts on
every span as `session.id`). Writes eval/out/<run_id>.json for batch_eval.py.
"""
import argparse
import json
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).parent


def ask(base_url: str, question: str, session_id: str) -> dict:
    req = urllib.request.Request(
        base_url.rstrip("/") + "/api/ask",
        data=json.dumps({"question": question, "session_id": session_id}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)


def run_scenario(base_url: str, run_id: str, sc: dict) -> dict:
    sid = f"{run_id}-{sc['id']}"
    turns = []
    for t in sc["turns"]:
        try:
            r = ask(base_url, t["question"], sid)
            turns.append({"question": t["question"], "answer": r["answer"], "sql": r["sql"],
                          "tool_calls": r["tool_calls"], "elapsed_s": r["elapsed_s"]})
        except Exception as e:  # keep going; a failed turn is itself an eval signal
            turns.append({"question": t["question"], "error": str(e)})
    print(f"  {sc['id']:<22} {sid}  " + "  ".join(
        f"{t.get('elapsed_s', 'ERR')}s/{t.get('tool_calls', '-')}calls" for t in turns))
    return {"scenario_id": sc["id"], "session_id": sid, "turns": turns}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8080")
    ap.add_argument("--only", nargs="*", help="scenario ids to run (default: all)")
    ap.add_argument("--parallel", type=int, default=4)
    args = ap.parse_args()

    scenarios = json.loads((HERE / "ground_truth.json").read_text())
    if args.only:
        scenarios = [s for s in scenarios if s["id"] in args.only]
    run_id = time.strftime("r%m%d%H%M") + uuid.uuid4().hex[:4]
    started = time.time()
    print(f"run {run_id}: {len(scenarios)} scenarios -> {args.base_url}")
    with ThreadPoolExecutor(args.parallel) as pool:
        sessions = list(pool.map(lambda s: run_scenario(args.base_url, run_id, s), scenarios))
    out = HERE / "out" / f"{run_id}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"run_id": run_id, "started_at": started, "ended_at": time.time(),
                               "base_url": args.base_url, "sessions": sessions},
                              ensure_ascii=False, indent=2))
    print(f"wrote {out}\nnext: wait ~2-3 min for CloudWatch ingestion, then "
          f".venv/bin/python eval/batch_eval.py {out}")


if __name__ == "__main__":
    main()
