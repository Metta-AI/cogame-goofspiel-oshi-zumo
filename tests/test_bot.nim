## The scripted baselines. Assertions 12-15 of the design note's `## Tests`.
##
## They are both the no-credentials fallback (offline certification runs
## entirely on them) and fieldable policies, so a baseline that can propose
## an illegal bid, spend a card twice or fail to terminate is a broken
## episode on the hosted platform.

import std/[json, monotimes, random, times, unittest]
import gozu/[llm, sim]

proc goofConfig(seed: int, seats = 4): GameConfig =
  result = defaultGameConfig()
  result.mode = mGoofspiel
  result.seed = seed
  result.cards = 13
  result.maxRounds = 13
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< seats:
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

proc playAll(config: GameConfig, kinds: seq[ScriptKind]): Sim =
  ## One whole episode driven by the named baseline per seat, checking every
  ## bid against `legalBids` AT THE MOMENT IT IS PRODUCED.
  result = initSim(config)
  var spentCards = newSeq[seq[int]](result.seats)
  var rounds = 0
  while not result.done and rounds < 200:
    result.beginRound()
    var bids: seq[int]
    for seat in 0 ..< result.seats:
      let decision = scriptedAction(result, seat, kinds[seat])
      check decision.bid in result.legalBids(seat)
      check decision.say.len == 0
      check decision.notes.len == 0
      if config.mode == mGoofspiel:
        check decision.bid notin spentCards[seat]
        spentCards[seat].add(decision.bid)
      bids.add(decision.bid)
    let says = newSeq[string](result.seats)
    let notes = newSeq[string](result.seats)
    let scripted = newSeq[bool](result.seats)
    result.applyBids(bids, says, notes, scripted)
    for seat in 0 ..< result.seats:
      check result.coins[seat] >= 0
    rounds += 1
  check result.done

suite "12 bounded, legal orders":
  test "200 seeded episodes x both modes x both baselines":
    for seed in 0 ..< 200:
      for kind in [skMatch, skHoard]:
        let goof = playAll(goofConfig(seed), @[kind, kind, kind, kind])
        check goof.roundsPlayed == 13
        for seat in 0 ..< 4:
          check goof.hands[seat].len == 0
        let oshi = playAll(oshiConfig(seed), @[kind, kind])
        check oshi.roundsPlayed <= 20

  test "the baselines are legal against each other too":
    for seed in 0 ..< 50:
      discard playAll(goofConfig(seed), @[skMatch, skHoard, skMatch, skHoard])
      discard playAll(oshiConfig(seed), @[skMatch, skHoard])

suite "13 match is a real opponent":
  test "match beats a seeded uniform-random legal bidder":
    var rng = initRand(4242)
    var total = 0.0
    for seed in 0 ..< 200:
      var sim = initSim(goofConfig(seed))
      while not sim.done:
        sim.beginRound()
        var bids: seq[int]
        for seat in 0 ..< 4:
          if seat == 0:
            bids.add(scriptedBid(sim, seat, skMatch))
          else:
            let legal = sim.legalBids(seat)
            bids.add(legal[rng.rand(legal.high)])
        let says = newSeq[string](4)
        let notes = newSeq[string](4)
        let scripted = newSeq[bool](4)
        sim.applyBids(bids, says, notes, scripted)
      total += sim.score(0)
    check total / 200.0 > 0.0

suite "14 the two fillers play different games":
  test "match and hoard disagree on at least 30% of rounds":
    var rounds = 0
    var different = 0
    for seed in 0 ..< 200:
      var sim = initSim(goofConfig(seed))
      while not sim.done:
        sim.beginRound()
        var bids: seq[int]
        for seat in 0 ..< 4:
          bids.add(scriptedBid(sim, seat, skMatch))
        if scriptedBid(sim, 0, skMatch) != scriptedBid(sim, 0, skHoard):
          different += 1
        rounds += 1
        let says = newSeq[string](4)
        let notes = newSeq[string](4)
        let scripted = newSeq[bool](4)
        sim.applyBids(bids, says, notes, scripted)
      var oshi = initSim(oshiConfig(seed))
      while not oshi.done:
        oshi.beginRound()
        if scriptedBid(oshi, 0, skMatch) != scriptedBid(oshi, 0, skHoard):
          different += 1
        rounds += 1
        var bids: seq[int]
        for seat in 0 ..< 2:
          bids.add(scriptedBid(oshi, seat, skMatch))
        let says = newSeq[string](2)
        let notes = newSeq[string](2)
        let scripted = newSeq[bool](2)
        oshi.applyBids(bids, says, notes, scripted)
    check rounds > 0
    check different.float / rounds.float >= 0.30

suite "15 the certification fixture is fast":
  test "the scripted cert fixture plays well inside certify's 60 s default":
    ## `coworld certify` defaults to --timeout-seconds 60 covering start,
    ## the connect grace, every round and the post-game linger, so the
    ## fixture's own play time has to be a rounding error
    ## (cogame-commons-family 0.1.0).
    let manifest = parseJson(readFile("coworld_manifest_template.json"))
    let node = manifest["certification"]["game_config"]
    var withTokens = copy(node)
    var tokens = newJArray()
    for index in 0 ..< node["num_agents"].getInt():
      tokens.add(%("token-" & $index))
    withTokens["tokens"] = tokens
    var config = defaultGameConfig()
    config.update($withTokens)
    config = sampleEpisode(config)
    check config.turnDelayMs == 0
    let started = getMonoTime()
    let sim = playAll(config, @[skMatch, skMatch, skMatch, skMatch])
    let elapsed = (getMonoTime() - started).inMilliseconds.float / 1000.0
    check sim.roundsPlayed == 13
    check elapsed < 50.0
