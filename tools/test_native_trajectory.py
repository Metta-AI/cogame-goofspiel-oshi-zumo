"""Qualify native request/response, retry, fallback, privacy, and replay joins."""
import json
import re
import sys
from pathlib import Path

binary, output, revision, sdk = sys.argv[1:]
sys.path.insert(0, str(Path(sdk) / "tools"))
from native_fixture import qualify

def action(user):
    return {"bid": int(re.search(r"YOUR LEGAL BIDS: ([0-9]+)", user)[1])}

qualify(binary, {'seed': 17, 'sampled': True, 'turnDelayMs': 0, 'player_connect_timeout_seconds': 3, 'episodeTimeoutSeconds': 120, 'maxOutputTokens': 900, 'llmTimeoutSeconds': 5, 'tokens': ['0', '1', '2', '3'], 'players': [{'name': 'fixture-0'}, {'name': 'fixture-1'}, {'name': 'fixture-2'}, {'name': 'fixture-3'}], 'mode': 'goofspiel', 'cards': 4, 'maxRounds': 2, 'batchSpacingSeconds': 1}, action, output, revision)
