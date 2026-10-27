"""Exercise both complete native games and preserve every artifact under OUTPUT."""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def run(game, player, verifier, output, variant, seed):
    root = output / f"{variant['id']}-seed{seed}"
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = config["num_agents"]
    config.update(
        seed=seed,
        turnDelayMs=0,
        batchSpacingSeconds=1,
        player_connect_timeout_seconds=5,
        episodeTimeoutSeconds=120,
        shutdownGraceSeconds=1,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"native-identity-fixture-{variant['id']}-{seed}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, "game exited before readiness; see retained game.log"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, PLAYER_SCRIPTED="match", COWORLD_TIMEOUT_SECONDS="120")
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))
        assert server.wait(timeout=120) == 0
        for child in children[1:]:
            assert child.wait(timeout=5) == 0
        summary = json.loads((root / "trajectory.jsonl").read_text().splitlines()[-1])
        assert summary["status"] == "completed"
        assert summary["game"] == "goofspiel-oshi-zumo"
        assert (root / "trajectory.jsonl").stat().st_mode & 0o077 == 0
        report = subprocess.check_output(
            [
                str(verifier),
                str(root / "replay.json"),
                str(root / "trajectory.jsonl"),
                episode,
            ],
            timeout=30,
        )
        (root / "verification.json").write_bytes(report)
        # This new synthetic fixture checks the archived-format reader without
        # altering any historical trace or granting it current source admission.
        legacy = []
        for line in (root / "trajectory.jsonl").read_text().splitlines():
            row = json.loads(line)
            row["game"] = "gozu"
            if row["event_type"] == "episode":
                row["seed_family"] = str(seed)
            legacy.append(json.dumps(row))
        (root / "legacy-fixture.jsonl").write_text("\n".join(legacy) + "\n")
        subprocess.check_call(
            [
                str(verifier),
                str(root / "replay.json"),
                str(root / "legacy-fixture.jsonl"),
                episode,
            ],
            timeout=30,
            stdout=subprocess.DEVNULL,
        )
        return summary["seed_family"]
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, verifier, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    families = {}
    for variant in manifest["variants"]:
        families[variant["id"]] = [run(game, player, verifier, destination, variant, seed) for seed in (17, 18)]
    assert families["goofspiel-4"][0] != families["goofspiel-4"][1]
    assert families["oshi-zumo-2"][0] == families["oshi-zumo-2"][1]
    (destination / "families.json").write_text(json.dumps(families, indent=2) + "\n")
    print("four complete native games: catalog identity, physical families, replay joins and legacy reader passed")


if __name__ == "__main__":
    main()
