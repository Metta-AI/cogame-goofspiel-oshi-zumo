"""Exercise both certified games through Metta's numeric decision protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

for variant, players, slots in (("goofspiel-4", 4, 14), ("oshi-zumo-2", 2, 21)):
    for seed in ("test-1", "test-2"):
        with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
            observation = bridge.reset(seed, players)
            dimensions = None
            decisions = 0
            while not isinstance(observation, Terminal):
                encoding = DecisionEncoding.model_validate_json(
                    bridge.request({"kind": "encode"})
                )
                assert len(encoding.actions) == slots
                dimensions = dimensions or len(encoding.values)
                assert len(encoding.values) == dimensions
                action = json.loads(bridge.teacher())
                assert encoding.action_for(encoding.indices_for(action)) == action
                previous_round = observation.turn
                observation = bridge.step(
                    observation.decision_id, json.dumps(action)
                ).observation
                decisions += 1
                if not isinstance(observation, Terminal) and decisions % players:
                    assert observation.turn == previous_round
            assert decisions >= players * 2
            assert abs(sum(observation.scores.values())) < 1e-6
            print(variant, seed, decisions, dimensions, observation.scores)
