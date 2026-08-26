## Grid-tuning harness for the two scripted baselines.
##
##   nim c -r scripts/tune_baselines.nim [seeds]
##
## The baselines are rule-shaped, but three constants inside those rules could
## have been guessed rather than measured:
##
##   goofspiel `hoard`  the cheap/dear split, shipped at `(cards + 1) div 2`
##   oshi-zumo `match`  the spend rate `k` in `ceil(k * coins / pushesNeeded)`,
##                      shipped at `k = 1.0`
##   oshi-zumo `hoard`  the desperation divisor `f` in `ceil(coins / f)` when
##                      one loss from defeat, shipped at `f = 2`
##
## This sweeps each of them over a grid and prints the mean score the swept
## seat takes against the shipped opponents over the SAME seeds at every grid
## point, so the columns are comparable.
##
## The swept bidders are the shipped procs generalised, and at the shipped
## grid point every bid is asserted equal to `scriptedBid`'s: the table is
## about the code that ships, not about a lookalike written next to it. The
## recorded output is `docs/baseline-tuning.md`.

import std/[math, os, random, strformat, strutils]
import gozu/[llm, sim]

type Variant = object
  split: int         ## goofspiel hoard: bid low at or below this prize
  rate: float        ## oshi-zumo match: multiplier on the even spend rate
  desperation: float ## oshi-zumo hoard: divisor when one loss from defeat

proc shipped(cards: int): Variant =
  Variant(split: (cards + 1) div 2, rate: 1.0, desperation: 2.0)

proc clampToLegal(sim: Sim, seat, bid: int): int =
  ## Oshi-zumo's legal set is the contiguous range minBid_i .. coins_i.
  let legal = sim.legalBids(seat)
  max(legal[0], min(bid, legal[^1]))

proc variantBid(sim: Sim, seat: int, kind: ScriptKind, v: Variant): int =
  case sim.config.mode
  of mGoofspiel:
    case kind
    of skHoard:
      let hand = sim.hands[seat]
      if sim.prize() <= v.split: hand[0] else: hand[hand.high]
    else:
      scriptedBid(sim, seat, kind)      ## goofspiel `match` has no constant
  of mOshiZumo:
    case kind
    of skHoard:
      let doomed =
        if seat == 0: sim.position == 0
        else: sim.position == fieldCells(sim.config) - 1
      if doomed:
        sim.clampToLegal(seat, int(ceil(sim.coins[seat].float / v.desperation)))
      else:
        sim.minBidOf(seat)
    else:
      let need = max(1, sim.pushesNeeded(seat))
      sim.clampToLegal(seat,
        int(ceil(v.rate * sim.coins[seat].float / need.float)))

proc checkedBid(sim: Sim, seat: int, kind: ScriptKind, v: Variant): int =
  ## At the shipped grid point the harness must reproduce `scriptedBid`
  ## exactly, or the sweep is measuring something the game does not play.
  result = variantBid(sim, seat, kind, v)
  if v == shipped(sim.config.cards):
    let real = scriptedBid(sim, seat, kind)
    if result != real:
      quit("harness diverged from scriptedBid: " & $result & " vs " & $real, 1)

proc goofConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.mode = mGoofspiel
  result.seed = seed
  result.cards = 13
  result.maxRounds = 13
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< 4:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc oshiConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.mode = mOshiZumo
  result.seed = seed
  result.coins = 20
  result.size = 3
  result.minBid = 1
  result.maxRounds = 20
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< 2:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

type Opponent = enum
  oMatch, oHoard, oRandom

proc playEpisode(config: GameConfig, kind: ScriptKind, v: Variant,
    opponent: Opponent, rng: var Rand): float =
  ## Seat 0 plays the swept variant, every other seat the named opponent.
  var sim = initSim(config)
  while not sim.done:
    sim.beginRound()
    var bids: seq[int]
    for seat in 0 ..< sim.seats:
      if seat == 0:
        bids.add(sim.checkedBid(seat, kind, v))
      else:
        case opponent
        of oMatch: bids.add(scriptedBid(sim, seat, skMatch))
        of oHoard: bids.add(scriptedBid(sim, seat, skHoard))
        of oRandom:
          let legal = sim.legalBids(seat)
          bids.add(legal[rng.rand(legal.high)])
    let says = newSeq[string](sim.seats)
    let notes = newSeq[string](sim.seats)
    let scripted = newSeq[bool](sim.seats)
    sim.applyBids(bids, says, notes, scripted)
  sim.score(0)

proc meanScore(mode: Mode, kind: ScriptKind, v: Variant, opponent: Opponent,
    seeds: int): float =
  var rng = initRand(20260826)
  var total = 0.0
  for seed in 0 ..< seeds:
    let config = if mode == mGoofspiel: goofConfig(seed) else: oshiConfig(seed)
    total += playEpisode(config, kind, v, opponent, rng)
  total / seeds.float

proc row(label: string, values: seq[float], isShipped: bool) =
  var cells: seq[string]
  for value in values:
    cells.add(&"{value: >8.4f}")
  echo &"| {label: >8} |" & cells.join(" |") & " |" &
    (if isShipped: "  <- shipped" else: "")

when isMainModule:
  let seeds =
    if paramCount() >= 1: parseInt(paramStr(1))
    else: 200
  echo "seeds per grid point: ", seeds
  echo ""

  echo "goofspiel `hoard`: cheap/dear split (vs match, vs random)"
  echo "|    split | vs match |   vs rnd |"
  echo "|---------:|---------:|---------:|"
  for split in 1 .. 13:
    var v = shipped(13)
    v.split = split
    row($split, @[
      meanScore(mGoofspiel, skHoard, v, oMatch, seeds),
      meanScore(mGoofspiel, skHoard, v, oRandom, seeds)],
      split == shipped(13).split)
  echo ""

  echo "oshi-zumo `match`: spend rate multiplier k (vs hoard, vs random)"
  echo "|        k | vs hoard |   vs rnd |"
  echo "|---------:|---------:|---------:|"
  for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]:
    var v = shipped(13)
    v.rate = rate
    row(&"{rate:.2f}", @[
      meanScore(mOshiZumo, skMatch, v, oHoard, seeds),
      meanScore(mOshiZumo, skMatch, v, oRandom, seeds)],
      rate == shipped(13).rate)
  echo ""

  echo "oshi-zumo `hoard`: desperation divisor f (vs match, vs random)"
  echo "|        f | vs match |   vs rnd |"
  echo "|---------:|---------:|---------:|"
  for desperation in [1.0, 1.5, 2.0, 3.0, 4.0]:
    var v = shipped(13)
    v.desperation = desperation
    row(&"{desperation:.2f}", @[
      meanScore(mOshiZumo, skHoard, v, oMatch, seeds),
      meanScore(mOshiZumo, skHoard, v, oRandom, seeds)],
      desperation == shipped(13).desperation)
