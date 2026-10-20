"""Complete mixed exports preserve sealed bids and scenario partitions."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as directory:
    for variant in ("goofspiel-4", "oshi-zumo-2"):
        output = Path(directory) / variant
        subprocess.run(
            [str(EXPORTER), str(output), "10", "1", variant, "mixed", "0"],
            cwd=ROOT,
            check=True,
        )
        manifest = json.loads((output / "manifest.json").read_text())
        families, counts = {}, {}
        for split in ("train", "validation"):
            rows = [
                json.loads(line)
                for line in (output / (split + ".jsonl")).read_text().splitlines()
            ]
            assert len(rows) == manifest[split + "_examples"]
            families[split] = {row["seed"] for row in rows}
            if split == "train":
                assert {row["prompt_template"]["variant"] for row in rows} == {
                    "canonical",
                    "plain",
                    "numbered",
                    "questions",
                    "reordered",
                }
            for row in rows:
                counts[row["episode_id"]] = counts.get(row["episode_id"], 0) + 1
                assert row["prompt_template"]["bank"] == "gozu-rules-v2"
                for message in row["prompt"]:
                    assert (
                        row["prompt_template"][message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                action = json.loads(row["completion"][0]["content"])
                assert isinstance(action["bid"], int) and set(action) == {
                    "bid",
                    "say",
                    "notes",
                }
        assert families["train"].isdisjoint(families["validation"])
        assert all(
            counts[f"gozu-{variant}-{run['seed']}-{run['prompt_selection']['variant']}"]
            == run["decisions"]
            > 0
            for run in manifest["runs"]
        )
        if variant == "oshi-zumo-2":
            assert len(families["train"]) == 1 and not families["validation"]
        else:
            assert len(families["train"]) == 8 and len(families["validation"]) == 2
        print(variant, "10 complete mixed exports PASS", flush=True)
