"""Published game configurations with real player processes and failed inference."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    for name in ("game", "player", "verifier", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    variants = {
        entry["id"]: entry["game_config"]
        for entry in json.loads((root / "coworld_manifest_template.json").read_text())[
            "variants"
        ]
    }
    cases = [(name, "canonical") for name in variants]
    if not args.smoke:
        cases += [
            ("goofspiel-4", wording)
            for wording in (
                "plain",
                "numbered",
                "questions",
                "reordered",
                "heldout-briefing",
                "heldout-reference",
                "mixed",
            )
        ]
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        episode_id = work.name
        config.update(
            seed=17,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(seats)],
            players=[{"name": f"policy-{seat}"} for seat in range(seats)],
        )
        (work / "config.json").write_text(json.dumps(config))
        endpoint = socket.socket()
        endpoint.bind(("127.0.0.1", 0))
        port = free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COGAME_SAVE_TRAJECTORY_URI=(work / "trajectory.jsonl").as_uri(),
            COWORLD_EPISODE_ID=episode_id,
            COWORLD_GAME_VERSION="prompt-validation",
            COWORLD_SOURCE_REVISION="uncommitted-gozu-validation",
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{endpoint.getsockname()[1]}",
        )
        processes = []
        logs = []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(args.game)],
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("host did not start")
            for seat in range(seats):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Bid only from your legal set.",
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(args.player)],
                        cwd=root,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            assert game.wait(timeout=1250) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            report = json.loads(
                subprocess.check_output(
                    [
                        str(args.verifier),
                        str(work / "episode.replay"),
                        str(work / "trajectory.jsonl"),
                        episode_id,
                    ],
                    cwd=root,
                    text=True,
                )
            )
            assert report["full_schedule"]
            records = [
                json.loads(line)
                for line in (work / "trajectory.jsonl").read_text().splitlines()
            ]
            assert records[-1]["status"] == "completed"
            for row in records[:-1]:
                seat = int(row["seat"])
                view = row["observation"]
                metadata = view["prompt_template"]
                assert metadata["variant"] == (
                    "reordered" if wording == "mixed" else wording
                )
                for role in ("system", "user"):
                    assert (
                        metadata[role + "_sha256"].lower()
                        == hashlib.sha256(view[role].encode()).hexdigest()
                    )
                assert f"PRIVATE-STRATEGY-{seat}" in view["user"]
                assert all(
                    f"PRIVATE-STRATEGY-{other}" not in view["user"]
                    for other in range(seats)
                    if other != seat
                )
                assert (
                    row["action_status"] == "fallback"
                    and row["selected_attempt_id"] is None
                )
                assert len(row["attempts"]) == 2
                assert all(
                    a["origin"] == "model"
                    and not a["accepted"]
                    and a["platform_call_id"] is None
                    for a in row["attempts"]
                )
            public = (work / "episode.replay").read_text()
            assert "PRIVATE-STRATEGY-" not in public and "prompt_template" not in public
            assert (work / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            print(
                work.name,
                report["decisions"],
                "executed decisions;",
                2 * report["decisions"],
                "failed requests; source replay verification PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
            endpoint.close()


if __name__ == "__main__":
    main()
