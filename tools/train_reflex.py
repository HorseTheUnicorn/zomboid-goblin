"""Train the Reflex Brain classifier (pure Python, CPU, deterministic).

    python -m tools.generate_reflex_dataset
    python -m tools.train_reflex

Writes goblin_zomboid/reflex_model.json with the dataset digest and holdout
metrics. Training fails (non-zero exit) if the holdout shows any order or
non-social line being answered socially by the full router, or if social
accuracy drops below the configured floor.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import random

from goblin_zomboid.reflex import (NaiveBayes, ReflexRouter, SOCIAL_CATEGORIES, dataset_digest)


def load(path: Path) -> list[dict[str, str]]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    for row in rows:
        if set(row) != {"text", "label"}:
            raise ValueError("dataset rows must contain only text and label")
    return rows


def split(rows: list[dict[str, str]], seed: int, holdout: float):
    rng = random.Random(seed)
    by_label: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        by_label.setdefault(row["label"], []).append(row)
    train, test = [], []
    for label in sorted(by_label):
        group = list(by_label[label])
        rng.shuffle(group)
        cut = max(1, int(len(group) * holdout))
        test.extend(group[:cut])
        train.extend(group[cut:])
    return train, test


def evaluate(model: NaiveBayes, rows: list[dict[str, str]], threshold: float) -> dict[str, object]:
    router = ReflexRouter(model, threshold=threshold, seed=0)
    social_total = social_correct = leaks = answered = 0
    confusion: dict[str, dict[str, int]] = {}
    for row in rows:
        decision = router.route(row["text"], owner="tester")
        predicted = decision.category if decision.route == "SOCIAL" else decision.route
        confusion.setdefault(row["label"], {}).setdefault(predicted, 0)
        confusion[row["label"]][predicted] += 1
        if row["label"] in SOCIAL_CATEGORIES:
            social_total += 1
            if decision.route == "SOCIAL":
                answered += 1
                if decision.category == row["label"]:
                    social_correct += 1
        elif decision.route == "SOCIAL":
            leaks += 1
    return {
        "holdout_rows": len(rows),
        "social_rows": social_total,
        "social_answered": answered,
        "social_correct": social_correct,
        "social_precision": round(social_correct / answered, 4) if answered else 0.0,
        "social_recall": round(social_correct / social_total, 4) if social_total else 0.0,
        "non_social_leaks": leaks,
        "confusion": confusion,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=Path("reference/reflex-dataset.jsonl"))
    parser.add_argument("--out", type=Path, default=Path("goblin_zomboid/reflex_model.json"))
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--holdout", type=float, default=0.2)
    parser.add_argument("--threshold", type=float, default=0.85)
    parser.add_argument("--min-precision", type=float, default=0.9)
    args = parser.parse_args()
    rows = load(args.dataset)
    train, test = split(rows, args.seed, args.holdout)
    model = NaiveBayes.train([(r["text"], r["label"]) for r in train])
    metrics = evaluate(model, test, args.threshold)
    final = NaiveBayes.train([(r["text"], r["label"]) for r in rows])
    final.metadata.update({"dataset_sha256": dataset_digest(rows), "dataset_rows": len(rows),
                           "holdout": metrics, "threshold": args.threshold, "seed": args.seed})
    args.out.write_text(json.dumps(final.to_json(), sort_keys=True, separators=(",", ":")), encoding="utf-8")
    print(json.dumps({k: v for k, v in metrics.items() if k != "confusion"}, sort_keys=True))
    if metrics["non_social_leaks"] or metrics["social_precision"] < args.min_precision:
        print("REFLEX_TRAINING_REJECTED")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
