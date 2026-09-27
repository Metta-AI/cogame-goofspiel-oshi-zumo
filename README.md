# Goofspiel / Oshi-Zumo

Two **simultaneous-move, zero-sum budget-pacing** games from
[OpenSpiel](https://github.com/google-deepmind/open_spiel), ported as one
coworld for the Softmax Coworld platform on the
[cogame-babel](https://github.com/Metta-AI/cogame-babel) technology stack
(parley → cosino → focus → babel). One sim, one image, one protocol, two
manifest variants.

**Goofspiel** (the Game of Pure Strategy) — four cogs each hold the cards
**1–13**. Every round one prize card is turned face up and all four secretly
bid one card; the highest bid takes the prize and scores its rank, ties
**split** it, and every bid card is **spent whether it won or not**, so all
hands empty together after thirteen rounds. Total pool: 91.

**Oshi-Zumo** — two cogs with **20 coins** each repeatedly bid to shove a sumo
token one cell toward the opponent's edge of a seven-cell dohyō. **Both bids
are always paid**, and **equal bids do not move the token**. Pushing it off the
far edge wins outright; if the coins or the round cap run out first, whoever's
half the token is *not* in wins, and the centre cell is a draw.

Both games are perfect-information **about the past**: every bid anyone has
ever made is public the instant a round resolves. The only unknowns are what
the rivals are bidding *this* round and, in goofspiel, the order of the prizes
still to come. The whole skill is budget pacing and opponent modelling.

Prompt players send their strategy to the game. The server asks Claude for
their bids in one parallel batch each round. External players receive a
seat observation and return a sealed legal bid through the same player socket.
Two built-in **scripted baselines** play any seat that registers as scripted. They also
cover prompt seats when no game LLM credentials are available:

- **`match`** — bid the card of the same rank as the prize, else the cheapest
  card above it, else your highest. In oshi-zumo, spend the even rate that
  would carry the token off the edge with the purse you have.
- **`hoard`** — dump your lowest card on the small prizes and swing your
  highest at the big ones. In oshi-zumo, minimum-bid until one loss would end
  it, then spend half the purse.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy display
names never reach an agent's prompt, so nobody can meta-game "that seat is the
champion", and no seat can identify a confederate. The spectator and replay
viewers map the aliases back to policy names; results are reported under policy
names. Bids are **sealed server-side** — no socket sees any bid of round *r*
before every bid of round *r* is in.

**Scoring.** One `scores` array, same meaning in both modes, higher is better,
and the array sums to 0. Goofspiel: `score_i = (N·share_i − 1)/(N − 1)` where
`share_i` is the seat's share of the prize value awarded — at four seats that
is `(points − 22.75)/68.25`, so the equal share scores 0 and taking everything
scores +1. Oshi-Zumo: +1 / −1, and 0/0 on a draw. `results.reason` is
`complete` or `deadline`; the finer ending rides in `results.ending`
(`prizes-exhausted`, `pushout`, `coins-exhausted`, `round-cap`, `wall-clock`).
A `deadline` episode is a real result — the game is fully scored at the stop.

**The gasp.** One predicate in both modes: `overbid` when `margin >= 6`, the
top bid over the best bid strictly below it. It gets its own event, its own
feed line, its own scrub beat and a full-width banner.

## Layout

- `src/gozu.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/gozu/sim.nim` — pure rules: the seeded prize deck, hands and purses,
  bid resolution, the overbid predicate, the endings, scoring, the replay
  bytes and the replay re-derivation; shared by server, tests and the wasm
  viewer
- `src/gozu/llm.nim` — Claude client (one parallel batch per round) + the
  `match` and `hoard` scripted baselines
- `src/gozu/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/gozu_player.nim` — prompt and scripted player
- `client/chrome_common.js` — the cogame-babel chrome, copied region by region
  (see the header; `tools/ci/chrome_scope_check.mjs` enforces it)
- `client/renderer.js` — the game block: the bid table, the dohyō track, the
  scorebug, the feed lines and the drivers
- `client/{global,player,replay_broadcast}.html` — the three served pages
- `replay-viewer/` — static wasm replay viewer (`index.html?replay=<url>`)
- `tools/build_replay_viewer.sh` — the `coworld build` replay-viewer hook
- `scripts/art/` — the nano-banana source sheet and the split script that
  produce `data/sumo_token.png` and `data/card_back.png`
- `data/` — the board art; the cog sprites, floor and font come from
  [cogame-babel](https://github.com/Metta-AI/cogame-babel) /
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the paths
# are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim                 # the rules
nim r --path:src tests/test_bot.nim                 # the scripted baselines
nim r --path:src tests/test_replay.nim              # record -> re-derive
nim r --path:src tests/test_manifest.nim            # packaging invariants
nim c -d:release -o:bin/goofspiel-oshi-zumo src/gozu.nim
nim c -d:release -o:bin/goofspiel-oshi-zumo-player src/gozu_player.nim
nim c --hints:off -d:emscripten replay-viewer/gozu_replay.nim   # wasm viewer
```

Every test also runs under `-d:release` in CI. The containerised end-to-end
episode is `tools/ci/docker_smoke.sh <image>`; it drives the certification
fixture with one game container and four player containers, validates
`results.json` against the manifest's own `results_schema`, and keeps the
replay for the viewer smoke.

Coworld packaging is done by `.github/workflows/coworld-release.yml`
(build → certify → upload-policy → upload-coworld → secret put, in that
order — it is load-bearing).

## Fielding a policy

```bash
uv run coworld upload-policy <image> --name my-gozu \
  --run /bin/goofspiel-oshi-zumo-player \
  --secret-env PLAYER_PROMPT="Your bidding strategy here."
```

Or field a baseline: same image, `--env PLAYER_SCRIPTED=match` (or `hoard`).
External players send `{"type":"register","control":"external"}` after
connecting. At each open round, the `state.observation` object gives the seat's
legal bids, face-up prize or token position, public resources and bid history,
and its own private notes. The player replies with
`{"type":"bid","round":R,"bid":N,"say":"...","notes":"..."}`.
The game accepts one legal bid for that round, reveals all bids together, and
uses the `match` baseline if an external player does not reply before the
round deadline.
