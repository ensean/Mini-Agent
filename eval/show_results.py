"""Per-session view of a batch evaluation: score matrix + explanations for anything < 1.

    .venv/bin/python eval/show_results.py eval/out/<run_id>.batch.json [--md report.md]

Reads the gen_ai.evaluation.result records the service writes to the batch's output log
stream. TRACE / TOOL_CALL level evaluators are averaged per session.
"""
import argparse
import json
from collections import defaultdict

from common import session


def short(evaluator_id: str) -> str:
    return evaluator_id.replace("Builtin.", "").split("-")[0]


def fetch(log_group: str, stream: str) -> list[dict]:
    logs = session().client("logs")
    out, kw = [], {"logGroupName": log_group, "logStreamNames": [stream]}
    while True:
        r = logs.filter_log_events(**kw)
        out += [json.loads(e["message"])["attributes"] for e in r["events"]]
        if "nextToken" not in r:
            return out
        kw["nextToken"] = r["nextToken"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("batch_file")
    ap.add_argument("--md", help="also write a markdown report here")
    args = ap.parse_args()
    batch = json.load(open(args.batch_file))
    oc = batch["outputConfig"]["cloudWatchConfig"]
    recs = fetch(oc["logGroupName"], oc["logStreamName"])

    scores = defaultdict(lambda: defaultdict(list))   # session -> evaluator -> [score]
    issues = []
    for a in recs:
        sid, ev = a["session.id"], short(a.get("gen_ai.evaluation.name", "?"))
        if "error.message" in a:
            issues.append((sid, ev, "ERROR", a["error.message"]))
            continue
        v = a["gen_ai.evaluation.score.value"]
        scores[sid][ev].append(v)
        if v < 1:
            issues.append((sid, ev, f"{v:g} {a.get('gen_ai.evaluation.score.label', '')}",
                           a.get("gen_ai.evaluation.explanation", "")))

    evs = sorted({e for s in scores.values() for e in s})
    rows = [["session"] + evs]
    for sid in sorted(scores):
        rows.append([sid.split("-", 1)[-1]] + [
            f"{sum(v) / len(v):.2f}" if (v := scores[sid].get(e)) else "-" for e in evs])
    rows.append(["**mean**"] + [
        f"{sum(x) / len(x):.2f}" if (x := [y for s in scores.values() for y in s.get(e, [])]) else "-"
        for e in evs])
    md = ["| " + " | ".join(r) + " |" for r in rows]
    md.insert(1, "|" + "---|" * len(evs + [0]))
    md += ["", f"### Below 1.0 or errored ({len(issues)})", ""]
    md += [f"- **{sid.split('-', 1)[-1]} / {ev}** = {val}: {exp[:400]}" for sid, ev, val, exp in sorted(issues)]
    text = "\n".join(md)
    print(text)
    if args.md:
        open(args.md, "w").write(f"# Batch evaluation {batch['batchEvaluationId']}\n\n{text}\n")


if __name__ == "__main__":
    main()
