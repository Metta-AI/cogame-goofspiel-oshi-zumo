## The rules. Assertions 1-11 of the design note's `## Tests`.

import std/[algorithm, json, math, random, sequtils, unittest]
import gozu/sim

proc goofConfig(seats = 4, seed = 0, cards = 13): GameConfig =
  result = defaultGameConfig()
  result.mode = mGoofspiel
  result.seed = seed
  result.cards = cards
  result.maxRounds = cards
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc oshiConfig(seed = 0, coins = 20, size = 3, minBid = 1,
    maxRounds = 20): GameConfig =
  result = defaultGameConfig()
  result.mode = mOshiZumo
  result.seed = seed
  result.coins = coins
  result.size = size
  result.minBid = minBid
  result.maxRounds = maxRounds
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< 2:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc blanks(n: int): (seq[string], seq[string], seq[bool]) =
  (newSeq[string](n), newSeq[string](n), newSeq[bool](n))

proc play(sim: var Sim, bids: seq[int]) =
  if not sim.roundOpen():
    sim.beginRound()
  let (says, notes, scripted) = blanks(bids.len)
  sim.applyBids(bids, says, notes, scripted)

proc eventsOfKind(sim: Sim, kind: EventKind): seq[GameEvent] =
  for event in sim.events:
    if event.kind == kind:
      result.add(event)

suite "1 goofspiel: a single winner takes the whole prize":
  test "the pool over 13 rounds is exactly 91":
    var sim = initSim(goofConfig(seed = 5))
    var pool = 0.0
    var single = 0
    for round in 0 ..< 13:
      sim.beginRound()
      let prize = sim.prize()
      ## Seat 0 always bids its highest card, everyone else their lowest.
      var bids: seq[int]
      for seat in 0 ..< 4:
        bids.add(if seat == 0: sim.hands[seat][^1] else: sim.hands[seat][0])
      var before: seq[float]
      for seat in 0 ..< 4:
        before.add(sim.points[seat])
      let (says, notes, scripted) = blanks(4)
      sim.applyBids(bids, says, notes, scripted)
      if sim.winners.len == 1:
        single += 1
        check sim.points[sim.winners[0]] - before[sim.winners[0]] ==
          prize.float
      pool += prize.float
    check single > 0
    check pool == 91.0
    var total = 0.0
    for seat in 0 ..< 4:
      total += sim.points[seat]
    ## Splitting keeps the pool constant, which is what keeps `scores`
    ## exactly zero-sum.
    check abs(total - 91.0) < 1e-9
    check sim.done
    check sim.reason == "complete"
    check sim.ending == "prizes-exhausted"

suite "2 goofspiel ties split the prize":
  test "two, three and four-way ties":
    ## Every seat holds 1..13, so a tie is arranged by bidding the same card.
    var two = initSim(goofConfig(seed = 7))
    two.beginRound()
    let prizeTwo = two.prize()
    let other = if prizeTwo == 13: 12 else: 13
    play(two, @[other, other, 1, 2])
    check two.points[0] == prizeTwo.float / 2.0
    check two.points[1] == prizeTwo.float / 2.0
    check two.points[2] == 0.0

    var three = initSim(goofConfig(seed = 7))
    three.beginRound()
    let prizeThree = three.prize()
    let top = if prizeThree == 13: 12 else: 13
    play(three, @[top, top, top, 1])
    for seat in 0 .. 2:
      check abs(three.points[seat] - prizeThree.float / 3.0) < 1e-9
    check three.points[3] == 0.0

    var four = initSim(goofConfig(seed = 7))
    four.beginRound()
    let prizeFour = four.prize()
    play(four, @[13, 13, 13, 13])
    for seat in 0 .. 3:
      check abs(four.points[seat] - prizeFour.float / 4.0) < 1e-9
    ## A tied top is never a blow-out, so no overbid fires.
    check four.margin == 0
    check four.eventsOfKind(evOverbid).len == 0

suite "3 goofspiel legality":
  test "a bid not in hand raises; each card is spent once":
    var sim = initSim(goofConfig(seed = 2))
    sim.beginRound()
    let (says, notes, scripted) = blanks(4)
    expect GozuError:
      sim.applyBids(@[14, 1, 2, 3], says, notes, scripted)
    expect GozuError:
      sim.applyBids(@[0, 1, 2, 3], says, notes, scripted)
    play(sim, @[7, 1, 2, 3])
    check 7 notin sim.hands[0]
    check sim.legalBids(0).len == 12
    sim.beginRound()
    expect GozuError:
      sim.applyBids(@[7, 4, 5, 6], says, notes, scripted)

  test "after 13 rounds every hand is empty and legalBids shrinks by one":
    var sim = initSim(goofConfig(seed = 3))
    for round in 0 ..< 13:
      sim.beginRound()
      check sim.legalBids(0).len == 13 - round
      var bids: seq[int]
      for seat in 0 ..< 4:
        bids.add(sim.hands[seat][0])
      let (says, notes, scripted) = blanks(4)
      sim.applyBids(bids, says, notes, scripted)
    for seat in 0 ..< 4:
      check sim.hands[seat].len == 0

suite "4 the prize deck":
  test "a permutation of 1..13, a pure function of the seed":
    let a = initSim(goofConfig(seed = 41))
    let b = initSim(goofConfig(seed = 41))
    let c = initSim(goofConfig(seed = 42))
    check a.prizeOrder == b.prizeOrder
    check a.prizeOrder != c.prizeOrder
    check a.prizeOrder.sorted() == toSeq(1 .. 13)

  test "reproduced from config.prizeOrder alone":
    let a = initSim(goofConfig(seed = 41))
    var pinned = goofConfig(seed = 999)
    pinned.prizeOrder = a.prizeOrder
    let d = initSim(pinned)
    check d.prizeOrder == a.prizeOrder

suite "5 oshi-zumo bidding":
  test "higher bid pushes one cell; equal bids do not move the token":
    var up = initSim(oshiConfig(seed = 1))
    play(up, @[5, 3])
    check up.position == 4
    check up.coins == @[15, 17]

    var down = initSim(oshiConfig(seed = 1))
    play(down, @[3, 5])
    check down.position == 2
    check down.coins == @[17, 15]

    var level = initSim(oshiConfig(seed = 1))
    play(level, @[4, 4])
    check level.position == 3
    check level.coins == @[16, 16]
    check level.eventsOfKind(evPush)[0].delta == 0

  test "a bid above the purse or below minBid raises":
    var sim = initSim(oshiConfig(seed = 1))
    sim.beginRound()
    let (says, notes, scripted) = blanks(2)
    expect GozuError:
      sim.applyBids(@[21, 1], says, notes, scripted)
    expect GozuError:
      sim.applyBids(@[0, 1], says, notes, scripted)

  test "with coins < minBid the only legal bid is coins":
    var sim = initSim(oshiConfig(seed = 1, coins = 4))
    play(sim, @[4, 3])
    check sim.coins[0] == 0
    check sim.legalBids(0) == @[0]
    check sim.minBidOf(0) == 0

suite "6 oshi-zumo endings":
  test "pushout from cell 6 wins for seat 0":
    var sim = initSim(oshiConfig(seed = 1))
    for step in 0 ..< 4:
      play(sim, @[2, 1])
    check sim.done
    check sim.position == 7
    check sim.reason == "complete"
    check sim.ending == "pushout"
    check sim.score(0) == 1.0
    check sim.score(1) == -1.0

  test "coins-exhausted is scored by position":
    var sim = initSim(oshiConfig(seed = 1, coins = 6))
    play(sim, @[2, 1])          ## token 4
    play(sim, @[4, 5])          ## token 3, purses 0 / 0
    check sim.coins == @[0, 0]
    check sim.done
    check sim.ending == "coins-exhausted"
    check sim.score(0) == 0.0
    check sim.score(1) == 0.0

  test "round-cap at maxRounds, and cell 3 is a draw":
    var sim = initSim(oshiConfig(seed = 1, coins = 20, maxRounds = 4))
    play(sim, @[1, 1])
    play(sim, @[1, 1])
    play(sim, @[1, 1])
    play(sim, @[1, 1])
    check sim.done
    check sim.ending == "round-cap"
    check sim.position == 3
    check sim.score(0) == 0.0
    check sim.score(1) == 0.0

suite "7 oshi-zumo termination":
  test "every seeded episode ends within 20 rounds, for any legal bidder":
    ## The note's assertion 7 names the two baselines; the episodes THEY play
    ## are asserted to terminate inside 20 rounds over the same 200 seeds by
    ## tests/test_bot.nim (assertion 12), which calls the real `scriptedBid`.
    ## This sweep is the wider claim -- termination is a property of the
    ## rules, not of the bidder -- so it drives arbitrary legal bids instead.
    for seed in 0 ..< 200:
      for hoard in [false, true]:
        var sim = initSim(oshiConfig(seed = seed))
        var rounds = 0
        while not sim.done and rounds < 100:
          sim.beginRound()
          var bids: seq[int]
          for seat in 0 ..< 2:
            let legal = sim.legalBids(seat)
            bids.add(
              if hoard: legal[0]
              else: legal[min(legal.high, seat + rounds mod 3)])
          let (says, notes, scripted) = blanks(2)
          sim.applyBids(bids, says, notes, scripted)
          rounds += 1
        check sim.done
        check rounds <= 20

suite "8 scores are zero-sum":
  test "200 seeded goofspiel and oshi-zumo episodes sum to 0":
    var rng = initRand(90210)
    for seed in 0 ..< 200:
      var goof = initSim(goofConfig(seed = seed))
      while not goof.done:
        goof.beginRound()
        var bids: seq[int]
        for seat in 0 ..< 4:
          let legal = goof.legalBids(seat)
          bids.add(legal[rng.rand(legal.high)])
        let (says, notes, scripted) = blanks(4)
        goof.applyBids(bids, says, notes, scripted)
      var total = 0.0
      for seat in 0 ..< 4:
        total += goof.score(seat)
      check abs(total) < 1e-9

      var oshi = initSim(oshiConfig(seed = seed))
      while not oshi.done:
        oshi.beginRound()
        var bids: seq[int]
        for seat in 0 ..< 2:
          let legal = oshi.legalBids(seat)
          bids.add(legal[rng.rand(legal.high)])
        let (says, notes, scripted) = blanks(2)
        oshi.applyBids(bids, says, notes, scripted)
      check abs(oshi.score(0) + oshi.score(1)) < 1e-9

  test "score == +1 iff a seat took every point awarded":
    ## Hands are identical, so no seat can strictly outbid three others for
    ## all 13 rounds (round 7 is a forced four-way tie at 7). Six rounds of
    ## clean wins plus a deadline stop is the reachable +1, and it exercises
    ## the deadline scoring at the same time.
    var sweep = initSim(goofConfig(seed = 11))
    var pool = 0.0
    for round in 0 ..< 6:
      sweep.beginRound()
      pool += sweep.prize().float
      var bids: seq[int]
      for seat in 0 ..< 4:
        bids.add(if seat == 0: sweep.hands[seat][^1] else: sweep.hands[seat][0])
      let (says, notes, scripted) = blanks(4)
      sweep.applyBids(bids, says, notes, scripted)
      check sweep.winners == @[0]
    sweep.endEarly()
    check sweep.reason == "deadline"
    check sweep.ending == "wall-clock"
    check sweep.points[0] == pool
    check abs(sweep.score(0) - 1.0) < 1e-9
    for seat in 1 ..< 4:
      check abs(sweep.score(seat) + 1.0 / 3.0) < 1e-9
    var total = 0.0
    for seat in 0 ..< 4:
      total += sweep.score(seat)
    check abs(total) < 1e-9

suite "9 the overbid boundary":
  test "margin 5 emits nothing, margin 6 emits exactly one overbid":
    var quiet = initSim(goofConfig(seed = 4))
    quiet.beginRound()
    play(quiet, @[8, 3, 2, 1])
    check quiet.margin == 5
    check quiet.eventsOfKind(evOverbid).len == 0

    var gasp = initSim(goofConfig(seed = 4))
    gasp.beginRound()
    play(gasp, @[9, 3, 2, 1])
    check gasp.margin == 6
    let events = gasp.eventsOfKind(evOverbid)
    check events.len == 1
    check events[0].seat == 0
    check events[0].bid == 9
    check events[0].over == 3
    check events[0].margin == 6

  test "the same predicate fires in oshi-zumo":
    var sim = initSim(oshiConfig(seed = 4))
    play(sim, @[8, 2])
    let events = sim.eventsOfKind(evOverbid)
    check events.len == 1
    check events[0].seat == 0
    check events[0].over == 2

suite "10 the collusion index":
  test "0 when nobody stood aside, k/13 when k rounds are constructed":
    ## Everyone bids its lowest remaining card every round: the margin is 0
    ## in all 13 rounds, so standing aside never happens.
    var clean = initSim(goofConfig(seed = 6))
    for round in 0 ..< 13:
      clean.beginRound()
      var bids: seq[int]
      for seat in 0 ..< 4:
        bids.add(clean.hands[seat][0])
      let (says, notes, scripted) = blanks(4)
      clean.applyBids(bids, says, notes, scripted)
      check clean.margin == 0
    for seat in 0 ..< 4:
      check clean.collusionIndex(seat) == 0.0

    ## Seat 0 bids its highest and seats 1..3 their lowest, all 13 rounds.
    ## The margins run 12, 10, 8, 6 and then drop below the threshold, so
    ## exactly FOUR rounds are blow-outs a low bidder stood aside for.
    var dirty = initSim(goofConfig(seed = 6))
    var blowouts = 0
    for round in 0 ..< 13:
      dirty.beginRound()
      var bids: seq[int]
      for seat in 0 ..< 4:
        bids.add(if seat == 0: dirty.hands[seat][^1] else: dirty.hands[seat][0])
      let (says, notes, scripted) = blanks(4)
      dirty.applyBids(bids, says, notes, scripted)
      if dirty.margin >= OverbidMargin:
        blowouts += 1
    check blowouts == 4
    for seat in 1 ..< 4:
      check abs(dirty.collusionIndex(seat) - 4.0 / 13.0) < 1e-9
    ## The seat that WON those blow-outs never bid its lowest card.
    check dirty.collusionIndex(0) == 0.0

suite "11 every shipped game_config constructs a Sim":
  test "both variants and the certification fixture":
    ## A fixture-only test hid a defect that killed every league episode
    ## (cogame-collab-cooking 0.1.1) -- so every variant is checked too.
    let manifest = parseJson(readFile("coworld_manifest_template.json"))
    var configs: seq[JsonNode]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    configs.add(manifest["certification"]["game_config"])
    for node in configs:
      var config = defaultGameConfig()
      var withTokens = copy(node)
      var tokens = newJArray()
      for index in 0 ..< node["num_agents"].getInt():
        tokens.add(%("token-" & $index))
      withTokens["tokens"] = tokens
      config.update($withTokens)
      config = sampleEpisode(config)
      let sim = initSim(config)
      check sim.seats == node["num_agents"].getInt()
      check sim.config.maxRounds >= 2
      check sim.legalBids(0).len > 0
