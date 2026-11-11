"""Run each turn's reference_sql against the demo ClickHouse and write eval/ground_truth.json.

    .venv/bin/python eval/build_ground_truth.py      # needs demo/clickhouse.sh running

The synthetic data in demo/seed.sql is deterministic (cityHash64-based), so the committed
ground_truth.json stays valid for any fresh deployment; re-run this after changing seed.sql.
"""
import json
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
CH_URL = "http://127.0.0.1:8123/"


def query(sql: str) -> str:
    url = CH_URL + "?" + urllib.parse.urlencode(
        {"user": "demo", "password": "demo", "default_format": "TSVWithNames"})
    with urllib.request.urlopen(urllib.request.Request(url, data=sql.encode())) as r:
        return r.read().decode().strip()


def main():
    scenarios = json.loads((HERE / "dataset.json").read_text())
    for sc in scenarios:
        for turn in sc["turns"]:
            if "reference_sql" in turn:
                turn["expected_response"] = (
                    "参考结果（由参考 SQL 在同一份数据上计算，回答中的关键数字应与之一致，"
                    "允许四舍五入差异）：\n" + query(turn["reference_sql"]))
    (HERE / "ground_truth.json").write_text(json.dumps(scenarios, ensure_ascii=False, indent=2) + "\n")
    for sc in scenarios:
        print(sc["id"], "|", " / ".join(t["expected_response"].split("\n", 1)[-1].replace("\n", " ; ")[:90]
                                        for t in sc["turns"]))


if __name__ == "__main__":
    main()
