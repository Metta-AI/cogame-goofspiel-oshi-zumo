"""Complete simultaneous-bid games with matched wording and numeric observations."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(
    binary, variant, players, seed, wording="canonical", prompt_seed=0, text_mode=False
):
    with subprocess.Popen(
        [str(binary), str(ROOT / "coworld_manifest_template.json"), variant]
        + (["text"] if text_mode else []),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": players,
                "seed": str(seed),
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace = []
        systems = set()
        while observation["kind"] == "decision":
            view = observation["semantic_view"].copy()
            if binary == BRIDGE:
                metadata = view.pop("prompt_template")
                assert (
                    metadata["bank"],
                    metadata["variant"],
                    metadata["selection"],
                    metadata["seed"],
                ) == (
                    "gozu-rules-v2",
                    WORDINGS[prompt_seed % 5] if wording == "mixed" else wording,
                    wording,
                    prompt_seed,
                )
                for message in observation["messages"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            encoding = request({"kind": "encode"})
            teacher = json.loads(request({"kind": "teacher"})["response"])
            assert {"bid": teacher["bid"]} in encoding["actions"]
            if text_mode:
                seat = observation["seat"]
                expected = f"PRIVATE-NOTE-{seat}" if observation["turn"] else ""
                assert view["notes"] == expected
                assert all(
                    f"PRIVATE-NOTE-{other}" not in observation["messages"][1]["content"]
                    for other in range(players)
                    if other != seat
                )
                teacher.update(say=f"hello-{seat}", notes=f"PRIVATE-NOTE-{seat}")
            old = observation
            reply = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(teacher),
                }
            )
            assert reply["kind"] == "accepted"
            trace.append((view, old["messages"][1], encoding, teacher, reply["action"]))
            systems.add(old["messages"][0]["content"])
            observation = reply["observation"]
            if observation["kind"] == "decision" and len(trace) % players:
                assert observation["turn"] == old["turn"]
                assert observation["semantic_view"]["history"] == view["history"]
        assert abs(sum(observation["scores"].values())) < 1e-6
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        return trace, observation, systems


for variant, players in (("goofspiel-4", 4), ("oshi-zumo-2", 2)):
    canonical = play(BRIDGE, variant, players, 17)
    wordings = []
    for wording in WORDINGS:
        run = play(BRIDGE, variant, players, 17, wording)
        assert run[:2] == canonical[:2]
        wordings.append(run[2])
    assert len({tuple(sorted(values)) for values in wordings}) == 7
    assert play(BRIDGE, variant, players, 17, "mixed", 4) == play(
        BRIDGE, variant, players, 17, "reordered"
    )
    text_canonical = play(BRIDGE, variant, players, 17, text_mode=True)
    assert (
        play(BRIDGE, variant, players, 17, "plain", text_mode=True)[:2]
        == text_canonical[:2]
    )
    print(variant, "12 complete matched/numeric/text games PASS", flush=True)
for wording, split in ((wording, split) for wording in WORDINGS[-2:]
                       for split in (None, "train", "typo")):
    rejected = subprocess.run(
        [
            str(BRIDGE),
            str(ROOT / "coworld_manifest_template.json"),
            "goofspiel-4",
            "text",
        ],
        input=json.dumps(
            {
                "kind": "reset",
                "players": 4,
                "seed": "17",
                "promptVariant": wording,
                **({"split": split} if split is not None else {}),
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert rejected.returncode != 0 and "held-out" in rejected.stderr
