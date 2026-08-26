## Pure game rules for Goofspiel / Oshi-Zumo. No IO, no networking, no LLM —
## the server, the tests and the wasm replay viewer all drive this same
## module, which is what makes a replay re-derivable.
##
## Both modes are simultaneous-move, zero-sum resource-depletion games with
## no hidden information about the past: every bid ever made is public the
## instant the round resolves. A `Sim` is one whole episode: the seeded
## aliases and prize deck, each seat's remaining resource, the live round's
## bids, the tallies, and the append-only event log.

import std/[algorithm, json, random, strutils], types

export types

const
  ## The anonymous table names. Policy display names never reach a seat.
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## One predicate, both modes: a blow-out is a top bid this far clear of
  ## the best bid under it. The smallest gap on a 1..13 scale that cannot be
  ## a one-rank duel, and it reads the same on 20 coins.
  OverbidMargin* = 6
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 120_000
  MinRounds* = 2

type
  Phase* = enum
    phBidding = "bidding"
    phReveal = "reveal"
    phBetween = "between"
    phDone = "done"

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous cog aliases, seeded shuffle
    prizeOrder*: seq[int]          ## goofspiel: the shuffled deck
    hands*: seq[seq[int]]          ## goofspiel: remaining cards, ascending
    coins*: seq[int]               ## oshizumo: each seat's purse
    position*: int                 ## oshizumo: token cell 0..2K; -1 elsewhere
    points*: seq[float]            ## goofspiel prize points (fractional)
    outcome*: seq[float]           ## oshizumo 1 / 0.5 / 0
    spent*: seq[int]
    bidsMade*: seq[int]
    bids*: seq[int]                ## this round; -1 before the reveal
    bidsShown*: bool
    says*: seq[string]             ## this round
    notes*: seq[string]            ## latest private notes per seat
    scripted*: seq[bool]           ## per seat, this round
    fellBack*: seq[bool]           ## per seat, this round
    fallbacks*: seq[int]
    lowBidStandAside*: seq[int]    ## numerator of collusionIndex
    winners*: seq[int]             ## this round's top bidders
    award*: seq[float]             ## this round's award per seat
    margin*: int                   ## this round's blow-out margin
    delta*: int                    ## oshizumo: this round's push
    overbidSeat*: int              ## this round's overbid seat, -1 for none
    round*, roundsPlayed*: int
    done*: bool
    reason*, ending*: string
    events*: seq[GameEvent]

# ---- Setup ------------------------------------------------------------------

proc seats*(sim: Sim): int = sim.config.players.len

proc fieldCells*(config: GameConfig): int = 2 * config.size + 1

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc roundCap*(config: GameConfig): int =
  if config.mode == mGoofspiel: config.cards else: config.coins

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the round count to the resource the mode depletes. Idempotent: a
  ## config that already carries the fit (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  let cap = roundCap(config)
  var rounds = if config.maxRounds <= 0: cap else: min(config.maxRounds, cap)
  rounds = max(rounds, MinRounds)
  result.maxRounds = rounds
  result.turnDelayMs = min(config.turnDelayMs, PacingBudgetMs div max(rounds, 1))
  result.sampled = true

proc drawPrizeOrder*(cards, seed: int): seq[int] =
  ## The prize deck: cards 1..N shuffled once from the episode seed.
  var rng = initRand(int64(seed) * 7919 + 17)
  for card in 1 .. cards:
    result.add(card)
  rng.shuffle(result)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, prize: -1, seat: -1, bid: -1, over: -1,
    margin: 0, delta: 0, positionAfter: -1)

proc initSim*(config: GameConfig): Sim =
  if config.players.len < 2 or config.players.len > 10:
    raise newException(GozuError, "gozu needs 2..10 players")
  if config.mode == mOshiZumo and config.players.len != 2:
    raise newException(GozuError, "oshizumo is a two-seat game")
  let n = config.players.len
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  if result.config.maxRounds <= 0:
    result.config.maxRounds = roundCap(config)
  result.points = newSeq[float](n)
  result.outcome = newSeq[float](n)
  result.spent = newSeq[int](n)
  result.bidsMade = newSeq[int](n)
  result.bids = newSeq[int](n)
  result.says = newSeq[string](n)
  result.notes = newSeq[string](n)
  result.scripted = newSeq[bool](n)
  result.fellBack = newSeq[bool](n)
  result.fallbacks = newSeq[int](n)
  result.lowBidStandAside = newSeq[int](n)
  result.award = newSeq[float](n)
  result.coins = newSeq[int](n)
  for seat in 0 ..< n:
    result.bids[seat] = -1
  result.overbidSeat = -1
  result.round = -1
  result.position = -1
  case config.mode
  of mGoofspiel:
    ## The deck is a pure function of the seed; a replay pins it explicitly
    ## so the viewer never has to trust its own RNG.
    if config.prizeOrder.len == config.cards:
      result.prizeOrder = config.prizeOrder
    else:
      result.prizeOrder = drawPrizeOrder(config.cards, config.seed)
    for seat in 0 ..< n:
      var hand: seq[int]
      for card in 1 .. config.cards:
        hand.add(card)
      result.hands.add(hand)
  of mOshiZumo:
    for seat in 0 ..< n:
      result.coins[seat] = config.coins
      result.hands.add(@[])
    result.position = config.size
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc minBidOf*(sim: Sim, seat: int): int =
  ## Normally M, but a seat holding fewer coins than M must bid what it has
  ## (a seat holding none must bid 0).
  min(sim.config.minBid, sim.coins[seat])

proc legalBids*(sim: Sim, seat: int): seq[int] =
  ## The seat's legal set. THE PROMPT, THE RETRY HINT AND THE VALIDATOR ALL
  ## CALL THIS SAME PROC, so they cannot drift apart.
  case sim.config.mode
  of mGoofspiel:
    result = sim.hands[seat]
  of mOshiZumo:
    for bid in sim.minBidOf(seat) .. sim.coins[seat]:
      result.add(bid)

proc phase*(sim: Sim): Phase =
  if sim.done: phDone
  elif sim.round < 0 or sim.round != sim.roundsPlayed: phBetween
  elif sim.bidsShown: phReveal
  else: phBidding

proc roundOpen*(sim: Sim): bool =
  not sim.done and sim.round >= 0 and sim.round == sim.roundsPlayed and
    not sim.bidsShown

proc prize*(sim: Sim): int =
  ## The prize on the table (or the last one shown); -1 in oshizumo.
  if sim.config.mode != mGoofspiel or sim.round < 0 or
      sim.round >= sim.prizeOrder.len:
    -1
  else:
    sim.prizeOrder[sim.round]

proc prizesLeft*(sim: Sim, afterRound: int): seq[int] =
  ## The prizes still to come after `afterRound`, sorted — the ORDER of the
  ## remaining deck is the one thing a seat does not know.
  for index in (afterRound + 1) ..< sim.prizeOrder.len:
    result.add(sim.prizeOrder[index])
  result.sort()

proc awardedPool*(sim: Sim): float =
  ## The prize value handed out so far. For a complete episode this is the
  ## whole pool (1+…+13 = 91); for a deadline stop it is what was actually
  ## awarded, which keeps `scores` summing to zero either way.
  for index in 0 ..< min(sim.roundsPlayed, sim.prizeOrder.len):
    result += sim.prizeOrder[index].float

proc handTotal*(sim: Sim, seat: int): int =
  ## Goofspiel remaining-budget bar: the sum of the ranks still in hand.
  for card in sim.hands[seat]:
    result += card

proc budgetLeft*(sim: Sim, seat: int): int =
  case sim.config.mode
  of mGoofspiel: sim.handTotal(seat)
  of mOshiZumo: sim.coins[seat]

proc budgetFull*(sim: Sim): int =
  case sim.config.mode
  of mGoofspiel: sim.config.cards * (sim.config.cards + 1) div 2
  of mOshiZumo: sim.config.coins

proc pushesNeeded*(sim: Sim, seat: int): int =
  ## Pushes still needed to send the token off the opponent's edge.
  if sim.config.mode != mOshiZumo: 0
  elif seat == 0: fieldCells(sim.config) - sim.position
  else: sim.position + 1

proc score*(sim: Sim, seat: int): float =
  case sim.config.mode
  of mGoofspiel:
    let n = sim.seats
    let pool = sim.awardedPool()
    if n < 2 or pool <= 0.0:
      return 0.0
    let share = sim.points[seat] / pool
    (n.float * share - 1.0) / (n.float - 1.0)
  of mOshiZumo:
    if not sim.done: 0.0
    else: 2.0 * sim.outcome[seat] - 1.0

proc collusionIndex*(sim: Sim, seat: int): float =
  ## The share of goofspiel rounds in which the seat bid its LOWEST
  ## remaining card while the round was a blow-out — it stood aside for
  ## someone else's win. Reported, never enforced.
  if sim.config.mode != mGoofspiel or sim.roundsPlayed == 0: 0.0
  else: sim.lowBidStandAside[seat].float / sim.roundsPlayed.float

# ---- Play -------------------------------------------------------------------

proc settle*(sim: var Sim, reason, ending: string) =
  ## THE single proc that ends the game, on record AND on playback. A
  ## wall-clock stop is not derivable from the bids, so it must be applied
  ## by the same code on both paths or the replay diverges at the stop.
  if sim.done:
    return
  if sim.config.mode == mOshiZumo:
    var winner = -1
    if ending == "pushout":
      winner = if sim.position > fieldCells(sim.config) - 1: 0 else: 1
    elif sim.position > sim.config.size:
      winner = 0
    elif sim.position < sim.config.size:
      winner = 1
    if winner < 0:
      sim.outcome[0] = 0.5
      sim.outcome[1] = 0.5
    else:
      sim.outcome[winner] = 1.0
      sim.outcome[1 - winner] = 0.0
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.reason = reason
  event.ending = ending
  for seat in 0 ..< sim.seats:
    event.scores.add(sim.score(seat))
    event.collusionIndex.add(sim.collusionIndex(seat))
  sim.addEvent(event)

proc beginRound*(sim: var Sim) =
  ## Opens the next round. In goofspiel it reveals the prize.
  if sim.done:
    raise newException(GozuError, "the episode is over")
  if sim.roundOpen():
    raise newException(GozuError, "a round is already in progress")
  sim.round = sim.roundsPlayed
  sim.bidsShown = false
  sim.margin = 0
  sim.delta = 0
  sim.overbidSeat = -1
  sim.winners = @[]
  for seat in 0 ..< sim.seats:
    sim.bids[seat] = -1
    sim.says[seat] = ""
    sim.scripted[seat] = false
    sim.fellBack[seat] = false
    sim.award[seat] = 0.0
  if sim.config.mode == mGoofspiel:
    var event = blankEvent(evPrize)
    event.round = sim.round
    event.prize = sim.prize()
    event.prizesLeft = sim.prizesLeft(sim.round)
    sim.addEvent(event)

proc applyBids*(sim: var Sim, bids: seq[int], says, notes: seq[string],
    scripted: seq[bool], fellBack: seq[bool] = @[]) =
  ## The whole resolution of one round, in one atomic step: legality, the
  ## award or the push, the spend, the events, and the end checks. Raises
  ## GozuError naming the offending seat and bid if any bid is illegal —
  ## the server probes a copy with this before committing.
  if sim.done:
    raise newException(GozuError, "the episode is over")
  if not sim.roundOpen():
    raise newException(GozuError, "no round is open")
  let n = sim.seats
  if bids.len != n:
    raise newException(GozuError,
      "expected " & $n & " bids, got " & $bids.len)
  for seat in 0 ..< n:
    if bids[seat] notin sim.legalBids(seat):
      raise newException(GozuError,
        "seat " & $seat & " bid " & $bids[seat] & ", which is not legal")

  for seat in 0 ..< n:
    sim.bids[seat] = bids[seat]
    sim.bidsMade[seat] += 1
    sim.spent[seat] += bids[seat]
    if seat < says.len:
      sim.says[seat] = cleanText(says[seat], MaxSayLen).replace("\n", " ")
    if seat < notes.len and notes[seat].len > 0:
      sim.notes[seat] = cleanText(notes[seat], MaxNotesLen)
    if seat < scripted.len:
      sim.scripted[seat] = scripted[seat]
    if seat < fellBack.len:
      sim.fellBack[seat] = fellBack[seat]
      if fellBack[seat]:
        sim.fallbacks[seat] += 1

  var top = bids[0]
  for bid in bids:
    top = max(top, bid)
  sim.winners = @[]
  for seat in 0 ..< n:
    if bids[seat] == top:
      sim.winners.add(seat)
  ## The blow-out margin: the top bid over the best bid strictly below it.
  ## A tied top is never a blow-out.
  if sim.winners.len > 1:
    sim.margin = 0
  else:
    var under = -1
    for seat in 0 ..< n:
      if bids[seat] < top:
        under = max(under, bids[seat])
    sim.margin = if under < 0: 0 else: top - under
  let overTarget =
    if sim.winners.len == 1 and sim.margin >= OverbidMargin: top - sim.margin
    else: -1

  var reveal = blankEvent(evReveal)
  reveal.round = sim.round
  reveal.bids = bids
  reveal.winners = sim.winners
  reveal.margin = sim.margin

  case sim.config.mode
  of mGoofspiel:
    let prize = sim.prize().float
    let share = prize / sim.winners.len.float
    for seat in sim.winners:
      sim.points[seat] += share
      sim.award[seat] = share
    for seat in 0 ..< n:
      ## Bid cards are spent whether they won or not. The audit looks at
      ## the hand BEFORE the card leaves it.
      let lowest = sim.hands[seat][0]
      if sim.margin >= OverbidMargin and bids[seat] == lowest:
        sim.lowBidStandAside[seat] += 1
      let at = sim.hands[seat].find(bids[seat])
      sim.hands[seat].delete(at)
    sim.roundsPlayed += 1
  of mOshiZumo:
    ## BOTH seats pay, unconditionally (Buro 2004).
    for seat in 0 ..< n:
      sim.coins[seat] -= bids[seat]
    sim.delta =
      if bids[0] > bids[1]: 1
      elif bids[1] > bids[0]: -1
      else: 0            ## equal bids: the wrestler does not move
    sim.position += sim.delta
    sim.roundsPlayed += 1

  sim.bidsShown = true
  for seat in 0 ..< n:
    reveal.coinsAfter.add(sim.coins[seat])
    reveal.handsAfter.add(sim.hands[seat])
    reveal.points.add(sim.points[seat])
    reveal.award.add(sim.award[seat])
    reveal.says.add(sim.says[seat])
    reveal.notes.add(sim.notes[seat])
    reveal.scripted.add(sim.scripted[seat])
    reveal.fellBack.add(sim.fellBack[seat])
  sim.addEvent(reveal)

  if overTarget >= 0:
    sim.overbidSeat = sim.winners[0]
    var gasp = blankEvent(evOverbid)
    gasp.round = sim.round
    gasp.seat = sim.overbidSeat
    gasp.bid = top
    gasp.margin = sim.margin
    gasp.over = overTarget
    sim.addEvent(gasp)

  if sim.config.mode == mOshiZumo:
    var push = blankEvent(evPush)
    push.round = sim.round
    push.delta = sim.delta
    push.positionAfter = sim.position
    sim.addEvent(push)

  case sim.config.mode
  of mGoofspiel:
    if sim.roundsPlayed >= sim.config.maxRounds:
      sim.settle("complete", "prizes-exhausted")
  of mOshiZumo:
    if sim.position > fieldCells(sim.config) - 1:
      sim.settle("complete", "pushout")
    elif sim.position < 0:
      sim.settle("complete", "pushout")
    elif sim.coins[0] == 0 and sim.coins[1] == 0:
      sim.settle("complete", "coins-exhausted")
    elif sim.roundsPlayed >= sim.config.maxRounds:
      sim.settle("complete", "round-cap")

proc endEarly*(sim: var Sim) =
  ## The play deadline stopped the episode between rounds. The game is
  ## still fully scored at the stop, so this is a real result.
  if sim.done:
    return
  sim.settle("deadline", "wall-clock")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var
    names = newJArray()
    scores = newJArray()
    points = newJArray()
    spent = newJArray()
    bidsMade = newJArray()
    fallbacks = newJArray()
    collusion = newJArray()
  for seat in 0 ..< sim.seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    points.add(%(if sim.config.mode == mGoofspiel: sim.points[seat]
                 else: sim.outcome[seat]))
    spent.add(%sim.spent[seat])
    bidsMade.add(%sim.bidsMade[seat])
    fallbacks.add(%sim.fallbacks[seat])
    collusion.add(%sim.collusionIndex(seat))
  %*{
    "names": names,
    "scores": scores,
    "points": points,
    "spent": spent,
    "bidsMade": bidsMade,
    "fallbacks": fallbacks,
    "collusionIndex": collusion,
    "finalPosition": (if sim.config.mode == mOshiZumo: sim.position else: -1),
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.maxRounds,
    "mode": $sim.config.mode,
    "ending": sim.ending,
    "reason": sim.reason
  }

# ---- Viewer state -----------------------------------------------------------

proc tableStateJson*(sim: Sim): JsonNode =
  var seatsNode = newJArray()
  for seat in 0 ..< sim.seats:
    var hand = newJArray()
    for card in sim.hands[seat]:
      hand.add(%card)
    seatsNode.add(%*{
      "name": sim.names[seat],
      "points": (if sim.config.mode == mGoofspiel: sim.points[seat]
                 else: sim.outcome[seat]),
      "score": sim.score(seat),
      "hand": hand,
      "coins": sim.coins[seat],
      "bid": (if sim.bidsShown: sim.bids[seat] else: -1),
      "say": (if sim.bidsShown: sim.says[seat] else: ""),
      "notes": sim.notes[seat],
      "spent": sim.spent[seat],
      "budget": sim.budgetLeft(seat),
      "budgetFull": sim.budgetFull(),
      "winner": (sim.bidsShown and seat in sim.winners),
      "award": sim.award[seat],
      "scripted": sim.scripted[seat],
      "fellBack": sim.fellBack[seat]
    })
  var left = newJArray()
  for value in sim.prizesLeft(sim.round):
    left.add(%value)
  var winners = newJArray()
  for seat in sim.winners:
    winners.add(%seat)
  %*{
    "mode": $sim.config.mode,
    "seats": seatsNode,
    "round": sim.round,
    "maxRounds": sim.config.maxRounds,
    "roundsPlayed": sim.roundsPlayed,
    "prize": sim.prize(),
    "prizesLeft": left,
    "position": sim.position,
    "cells": (if sim.config.mode == mOshiZumo: fieldCells(sim.config) else: 0),
    "push": (if sim.config.mode == mOshiZumo and sim.bidsShown: %sim.delta
             else: newJNull()),
    "overbid": (if sim.overbidSeat >= 0: %sim.overbidSeat else: newJNull()),
    "margin": sim.margin,
    "winners": winners,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason,
    "ending": sim.ending
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart:
    discard
  of evPrize:
    result["prize"] = %event.prize
    var left = newJArray()
    for value in event.prizesLeft:
      left.add(%value)
    result["prizesLeft"] = left
  of evReveal:
    var
      bids = newJArray()
      winners = newJArray()
      award = newJArray()
      coinsAfter = newJArray()
      handsAfter = newJArray()
      points = newJArray()
      says = newJArray()
      notes = newJArray()
      scripted = newJArray()
      fellBack = newJArray()
    for value in event.bids: bids.add(%value)
    for value in event.winners: winners.add(%value)
    for value in event.award: award.add(%value)
    for value in event.coinsAfter: coinsAfter.add(%value)
    for hand in event.handsAfter:
      var node = newJArray()
      for card in hand:
        node.add(%card)
      handsAfter.add(node)
    for value in event.points: points.add(%value)
    for value in event.says: says.add(%value)
    for value in event.notes: notes.add(%value)
    for value in event.scripted: scripted.add(%value)
    for value in event.fellBack: fellBack.add(%value)
    result["bids"] = bids
    result["winners"] = winners
    result["award"] = award
    result["margin"] = %event.margin
    result["coinsAfter"] = coinsAfter
    result["handsAfter"] = handsAfter
    result["points"] = points
    result["says"] = says
    result["notes"] = notes
    result["scripted"] = scripted
    result["fellBack"] = fellBack
  of evOverbid:
    result["seat"] = %event.seat
    result["bid"] = %event.bid
    result["margin"] = %event.margin
    result["over"] = %event.over
  of evPush:
    result["delta"] = %event.delta
    result["positionAfter"] = %event.positionAfter
  of evEnd:
    result["reason"] = %event.reason
    result["ending"] = %event.ending
    var scores = newJArray()
    for value in event.scores: scores.add(%value)
    var collusion = newJArray()
    for value in event.collusionIndex: collusion.add(%value)
    result["scores"] = scores
    result["collusionIndex"] = collusion

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    prize: node{"prize"}.getInt(-1),
    margin: node{"margin"}.getInt(0),
    seat: node{"seat"}.getInt(-1),
    bid: node{"bid"}.getInt(-1),
    over: node{"over"}.getInt(-1),
    delta: node{"delta"}.getInt(0),
    positionAfter: node{"positionAfter"}.getInt(-1),
    reason: node{"reason"}.getStr(""),
    ending: node{"ending"}.getStr("")
  )
  if node.hasKey("prizesLeft"):
    for value in node["prizesLeft"]: result.prizesLeft.add(value.getInt())
  if node.hasKey("bids"):
    for value in node["bids"]: result.bids.add(value.getInt())
  if node.hasKey("winners"):
    for value in node["winners"]: result.winners.add(value.getInt())
  if node.hasKey("award"):
    for value in node["award"]: result.award.add(value.getFloat())
  if node.hasKey("coinsAfter"):
    for value in node["coinsAfter"]: result.coinsAfter.add(value.getInt())
  if node.hasKey("handsAfter"):
    for hand in node["handsAfter"]:
      var cards: seq[int]
      for card in hand: cards.add(card.getInt())
      result.handsAfter.add(cards)
  if node.hasKey("points"):
    for value in node["points"]: result.points.add(value.getFloat())
  if node.hasKey("says"):
    for value in node["says"]: result.says.add(value.getStr())
  if node.hasKey("notes"):
    for value in node["notes"]: result.notes.add(value.getStr())
  if node.hasKey("scripted"):
    for value in node["scripted"]: result.scripted.add(value.getBool())
  if node.hasKey("fellBack"):
    for value in node["fellBack"]: result.fellBack.add(value.getBool())
  if node.hasKey("scores"):
    for value in node["scores"]: result.scores.add(value.getFloat())
  if node.hasKey("collusionIndex"):
    for value in node["collusionIndex"]:
      result.collusionIndex.add(value.getFloat())

# ---- Replay bytes -----------------------------------------------------------

const ReplayProtocol* = "gozu.replay.v1"

proc replayConfigJson*(sim: Sim): JsonNode =
  ## Everything the viewer needs to re-derive the episode: the mode, the
  ## seed, the fitted round cap and the shuffled deck. The viewer contacts
  ## nothing but S3 for the file.
  var order = newJArray()
  for value in sim.prizeOrder:
    order.add(%value)
  %*{
    "mode": $sim.config.mode,
    "seats": sim.seats,
    "seed": sim.config.seed,
    "cards": sim.config.cards,
    "prizeOrder": order,
    "coins": sim.config.coins,
    "size": sim.config.size,
    "minBid": sim.config.minBid,
    "maxRounds": sim.config.maxRounds,
    "sampled": true
  }

proc replayPayloadJson*(sim: Sim, policyNames: seq[string],
    results: JsonNode): JsonNode =
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policies = newJArray()
  for name in policyNames:
    policies.add(%name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  %*{
    "protocol": ReplayProtocol,
    "names": names,
    "policyNames": policies,
    "config": sim.replayConfigJson(),
    "events": events,
    "results": results
  }

# ---- Replay -----------------------------------------------------------------

proc nearly(a, b: float): bool = abs(a - b) < 1e-9

proc checkReveal(event, logged: GameEvent) =
  if event.bids != logged.bids or event.winners != logged.winners or
      event.margin != logged.margin or event.coinsAfter != logged.coinsAfter or
      event.handsAfter != logged.handsAfter:
    raise newException(GozuError,
      "round " & $event.round & " reveal does not match the re-derivation")
  if event.points.len != logged.points.len:
    raise newException(GozuError,
      "round " & $event.round & " points array does not match the " &
      "re-derivation")
  for index in 0 ..< event.points.len:
    if not nearly(event.points[index], logged.points[index]):
      raise newException(GozuError,
        "round " & $event.round & " points do not match the re-derivation")

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the bids through the same rules. frames[i] = state after events[0..<i].
  ## `prize`, `overbid` and `push` are re-derived and CHECKED against the
  ## recording, so a drift is a raised error rather than a silent divergence.
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first event
  ## is that same start.
  sim.events = @[]
  result.add(sim)
  var pending: seq[GameEvent]
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evPrize:
      sim.beginRound()
      let logged = sim.events[^1]
      if logged.kind != evPrize or logged.round != event.round or
          logged.prize != event.prize or logged.prizesLeft != event.prizesLeft:
        raise newException(GozuError,
          "round " & $event.round & " prize does not match the seeded deck")
    of evReveal:
      if not sim.roundOpen():
        sim.beginRound()
      let before = sim.events.len
      sim.applyBids(event.bids, event.says, event.notes, event.scripted,
        event.fellBack)
      pending = sim.events[before .. ^1]
      checkReveal(event, pending[0])
      pending.delete(0)
    of evOverbid:
      if pending.len == 0 or pending[0].kind != evOverbid or
          pending[0].seat != event.seat or pending[0].bid != event.bid or
          pending[0].over != event.over or pending[0].margin != event.margin:
        raise newException(GozuError,
          "round " & $event.round & " overbid does not match the re-derivation")
      pending.delete(0)
    of evPush:
      if pending.len == 0 or pending[0].kind != evPush or
          pending[0].delta != event.delta or
          pending[0].positionAfter != event.positionAfter:
        raise newException(GozuError,
          "round " & $event.round & " push does not match the re-derivation")
      pending.delete(0)
    of evEnd:
      if pending.len > 0 and pending[0].kind == evEnd:
        if pending[0].reason != event.reason or
            pending[0].ending != event.ending:
          raise newException(GozuError,
            "the recorded ending does not match the re-derivation")
        pending.delete(0)
      elif not sim.done:
        ## A wall-clock stop is not derivable from the bids — the SAME
        ## settle applies it here as on the recording path.
        sim.settle(event.reason, event.ending)
    result.add(sim)
