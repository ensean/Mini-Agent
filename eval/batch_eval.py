"""Score a replay run with AgentCore batch evaluation, using the dataset's ground truth.

    .venv/bin/python eval/batch_eval.py eval/out/<run_id>.json

For an agent hosted outside AgentCore Runtime, batch evaluation is the simplest path:
point it at the agent's log group + OTel service.name, list the session ids, and attach
per-session ground truth (expected responses per turn, assertions, expected tool
trajectory). No need to download spans yourself.
"""
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from common import AGENT_NAME, CUSTOM_EVALUATOR_NAME, LOG_GROUP, find_evaluator_id, session

HERE = Path(__file__).parent
BUILTIN = [
    "Builtin.Correctness",            # TRACE   - vs expected_response
    "Builtin.Helpfulness",            # TRACE
    "Builtin.InstructionFollowing",   # TRACE   - vs system prompt rules (LIMIT, SQL block, ...)
    "Builtin.GoalSuccessRate",        # SESSION - vs assertions
    "Builtin.TrajectoryInOrderMatch", # SESSION - vs expected_trajectory
    "Builtin.ToolSelectionAccuracy",  # TOOL_CALL
    "Builtin.ToolParameterAccuracy",  # TOOL_CALL
]


def ground_truth(sc: dict) -> dict:
    gt = {"turns": [{"input": {"prompt": t["question"]},
                     "expectedResponse": {"text": t["expected_response"]}} for t in sc["turns"]],
          "assertions": [{"text": a} for a in sc["assertions"]],
          "expectedTrajectory": {"toolNames": sc["expected_trajectory"]}}
    return {"inline": gt}


def main(run_file: str):
    run = json.loads(Path(run_file).read_text())
    scenarios = {s["id"]: s for s in json.loads((HERE / "ground_truth.json").read_text())}
    custom = find_evaluator_id(CUSTOM_EVALUATOR_NAME)
    evaluators = BUILTIN + ([custom] if custom else [])
    sessions = run["sessions"]

    ac = session().client("bedrock-agentcore")
    t0 = datetime.fromtimestamp(run["started_at"], timezone.utc) - timedelta(minutes=5)
    t1 = datetime.fromtimestamp(run["ended_at"], timezone.utc) + timedelta(minutes=10)
    r = ac.start_batch_evaluation(
        batchEvaluationName=f"t2s_{run['run_id']}",
        evaluators=[{"evaluatorId": e} for e in evaluators],
        dataSourceConfig={"cloudWatchLogs": {
            "logGroupNames": [LOG_GROUP], "serviceNames": [AGENT_NAME],
            "filterConfig": {"sessionIds": [s["session_id"] for s in sessions],
                             "timeRange": {"startTime": t0, "endTime": t1}}}},
        evaluationMetadata={"sessionMetadata": [
            {"sessionId": s["session_id"], "testScenarioId": s["scenario_id"],
             "groundTruth": ground_truth(scenarios[s["scenario_id"]])} for s in sessions]},
    )
    bid = r["batchEvaluationId"]
    print(f"batch evaluation {bid} started ({len(sessions)} sessions x {len(evaluators)} evaluators)")
    while True:
        g = ac.get_batch_evaluation(batchEvaluationId=bid)
        res = g.get("evaluationResults", {})
        print(f"  {g['status']:<22} done={res.get('numberOfSessionsCompleted', 0)}"
              f" running={res.get('numberOfSessionsInProgress', 0)} failed={res.get('numberOfSessionsFailed', 0)}"
              f" ignored={res.get('numberOfSessionsIgnored', 0)}/{res.get('totalNumberOfSessions', '?')}")
        if g["status"] not in ("PENDING", "IN_PROGRESS"):
            break
        time.sleep(30)

    out = HERE / "out" / f"{run['run_id']}.batch.json"
    out.write_text(json.dumps(g, ensure_ascii=False, indent=2, default=str))
    print(f"\n{'evaluator':<48}{'avg':>7}{'n':>5}{'fail':>6}")
    for s in res.get("evaluatorSummaries", []):
        st = s.get("statistics", {})
        avg = st.get("averageScore")
        print(f"{s['evaluatorId']:<48}{avg if avg is None else round(avg, 3)!s:>7}"
              f"{s.get('totalEvaluated', 0):>5}{s.get('totalFailed', 0):>6}")
    oc = g.get("outputConfig", {}).get("cloudWatchConfig")
    if oc:
        print(f"\nper-session results: log group {oc['logGroupName']} / stream {oc['logStreamName']}")
        print(f"  .venv/bin/python eval/show_results.py {out}")
    print(f"saved {out}")


if __name__ == "__main__":
    main(sys.argv[1])
