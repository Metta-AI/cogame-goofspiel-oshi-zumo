"""Complete candidate export, engine replay verification, and canonical comparisons."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER, VERIFIER = map(lambda value: Path(value).resolve(), sys.argv[1:3])
ORIGINAL = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else None
work = Path(tempfile.mkdtemp(prefix="gozu-source-candidates-"))
for variant in ("goofspiel-4", "oshi-zumo-2"):
    output = work / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant], cwd=ROOT, check=True
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["review_required"] and len(manifest["runs"]) == 10
    assert (
        not (output / "train.jsonl").exists()
        and not (output / "validation.jsonl").exists()
    )
    original = {}
    if ORIGINAL is not None:
        source = work / (variant + "-original")
        subprocess.run(
            [str(ORIGINAL), str(source), "10", "1", variant], cwd=ROOT, check=True
        )
        for split in ("train", "validation"):
            for line in (source / (split + ".jsonl")).read_text().splitlines():
                row = json.loads(line)
                original.setdefault(row["episode_id"], []).append(row)
    for run in manifest["runs"]:
        trajectory = output / run["trajectory"]
        replay = output / run["replay"]
        assert (
            trajectory.stat().st_mode & 0o777 == replay.stat().st_mode & 0o777 == 0o600
        )
        report = json.loads(
            subprocess.check_output(
                [str(VERIFIER), str(replay), str(trajectory), run["episode_id"]],
                cwd=ROOT,
                text=True,
            )
        )
        assert report["full_schedule"] and report["decisions"] == run["decisions"]
        records = [json.loads(line) for line in trajectory.read_text().splitlines()]
        assert records[-1]["seed_family"] == str(run["seed"])
        assert records[-1]["source_revision"] == manifest["source_revision"]
        for index, decision in enumerate(records[:-1]):
            (attempt,) = decision["attempts"]
            assert attempt["origin"] == "teacher" and attempt["accepted"]
            assert attempt["parsed_action"] == decision["executed_action"]
            if ORIGINAL is not None:
                before = original[f"gozu-{variant}-{run['seed']}"][index]
                assert before["prompt"] == attempt["prompt"]
                assert (
                    json.loads(before["completion"][0]["content"])
                    == decision["executed_action"]
                )
    print(
        variant,
        "ten full candidates, private artifacts, source engine verifier and canonical parity PASS",
        flush=True,
    )
print(work, flush=True)
