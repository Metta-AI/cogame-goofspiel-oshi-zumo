"""Exercise sealed external bids with a mock System One sidecar in Docker."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class SystemOne(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        assert self.path == "/v1/systemone"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        choices = list(body["questions"]["decision"]["criteria"])
        selected = choices[-1]
        self.calls.append((dict(self.headers), selected, body["model"]))
        payload = json.dumps(
            {
                "model": body["model"],
                "answers": {
                    "decision": {
                        "type": "choice",
                        "confidence": 1.0,
                        "probabilities": {
                            choice: float(choice == selected) for choice in choices
                        },
                    }
                },
                "usage": {"input_tokens": 100, "output_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True, timeout=90
    ).stdout.strip()


def run_mode(image: str, root: Path, mode: str, model_port: int):
    seats = 4 if mode == "goofspiel" else 2
    work = root / mode
    work.mkdir()
    os.chmod(work, 0o777)
    (work / "config.json").write_text(
        json.dumps(
            {
                "mode": mode,
                "seed": 7,
                "cards": 4,
                "coins": 8,
                "size": 2,
                "minBid": 1,
                "maxRounds": 4,
                "turnDelayMs": 0,
                "playerConnectTimeoutSeconds": 10,
                "llmTimeoutSeconds": 5,
                "episodeTimeoutSeconds": 120,
                "tokens": [f"token-{slot}" for slot in range(seats)],
                "players": [{"name": f"player-{slot}"} for slot in range(seats)],
            }
        )
    )
    name = f"gozu-jev-{os.getpid()}-{mode}"
    network = f"{name}-net"
    containers = [f"{name}-game", *(f"{name}-p{slot}" for slot in range(seats))]
    docker("network", "create", network)
    passed = False
    try:
        docker(
            "run", "-d", "--name", containers[0], "--network", network,
            "--network-alias", "gozu-game", "-e", "COGAME_HOST=0.0.0.0",
            "-e", "COGAME_PORT=8080",
            "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
            "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
            "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
            "-v", f"{work}:/coworld:rw", image, "/bin/goofspiel-oshi-zumo",
        )
        time.sleep(1)
        for slot in range(seats):
            args = [
                "run", "-d", "--name", containers[slot + 1], "--network", network,
                "--add-host", "host.docker.internal:host-gateway",
                "-e",
                f"COWORLD_PLAYER_WS_URL=ws://gozu-game:8080/player?slot={slot}"
                f"&token=token-{slot}",
            ]
            if slot == 0:
                args += [
                    "-e", "PLAYER_JEV=1", "-e",
                    f"AWS_ENDPOINT_URL_BEDROCK_RUNTIME=http://host.docker.internal:{model_port}",
                ]
            else:
                args += ["-e", "PLAYER_SCRIPTED=match"]
            docker(*args, image, "/bin/goofspiel-oshi-zumo-player")
        assert docker("wait", containers[0]) == "0"
        for container in containers[1:]:
            assert docker("wait", container) == "0"
        results = json.loads((work / "results.json").read_text())
        replay = json.loads((work / "replay.json").read_text())
        reveals = [event for event in replay["events"] if event["kind"] == "reveal"]
        assert results["reason"] == "complete"
        assert results["fallbacks"] == [0] * seats
        assert len(reveals) == 4
        assert len(SystemOne.calls) == 4
        for reveal, (headers, selected, model) in zip(reveals, SystemOne.calls):
            assert headers["x-coworld-player-slot"] == "0"
            assert "authorization" not in headers
            assert model == "typesafe/jev-1.13"
            assert reveal["bids"][0] == int(selected.removeprefix("bid_"))
            assert reveal["scripted"] == [False] + [True] * (seats - 1)
            assert reveal["fellBack"] == [False] * seats
        print(f"{mode}: {len(reveals)} accepted Jev bids, {seats} players, zero fallback")
        passed = True
    finally:
        if not passed:
            for container in containers:
                logs = subprocess.run(
                    ["docker", "logs", container], capture_output=True, text=True
                )
                print(logs.stdout, logs.stderr, file=sys.stderr)
        for container in containers:
            subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        subprocess.run(["docker", "network", "rm", network], capture_output=True)


if __name__ == "__main__":
    image = sys.argv[1]
    server = http.server.HTTPServer(("0.0.0.0", 0), SystemOne)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="gozu-jev-smoke-") as directory:
            for mode in ("goofspiel", "oshizumo"):
                SystemOne.calls.clear()
                run_mode(image, Path(directory), mode, server.server_port)
    finally:
        server.shutdown()
        thread.join()
