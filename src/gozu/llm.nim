## Claude-backed decision making for Goofspiel / Oshi-Zumo. Each seat's
## policy is just a prompt: the game server composes the seat's view (the
## prize, every seat's remaining resource, the full public bid history, its
## own notes) plus that seat's prompt and asks Claude for one number.
##
## Decisions in a round are SIMULTANEOUS by rule, so every open seat's call
## goes out as ONE parallel batch (curly.RequestBatch + makeRequests, the
## `decideAll` shape ported from cogame-bullwhip/src/bullwhip/llm.nim);
## invalid replies are retried as a smaller batch carrying the legal set,
## and anything still failing falls back to the `match` baseline.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, options, os, strutils],
  bitworld/decision_trajectory,
  bitworld/runtime,
  curly,
  prompts,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skMatch = "match"
    skHoard = "hoard"

  Decision* = object
    nativeAttempts*: seq[DecisionAttempt]
    bid*: int
    say*: string
    notes*: string      ## "" when the reply carried none
    fellBack*: bool     ## the LLM path failed and the baseline decided

  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string              ## anthropic transport
    sidecarEndpoint: string
    bedrockEndpoint: string     ## local Bedrock transport
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string               ## direct-Anthropic transport only
    maxOutputTokens: int
    timeoutSeconds*: int
    disabled*: bool             ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"match" play the match-the-prize
  ## bot, "hoard" the save-for-the-big-ones bot, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "match": skMatch
  of "hoard", "hoarder": skHoard
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "gozu llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      cleanText(error.msg, MaxErrorLen)
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. `us.anthropic.claude-sonnet-4-6` is NOT a
  ## candidate: it times out on every sidecar call (raid, 2026-08-23), and
  ## one throttle then cascades into scripted fallbacks.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "gozu llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "gozu llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "gozu llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "gozu llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc clampBid(sim: Sim, seat, bid: int): int =
  ## Every baseline goes through this, so no baseline can produce an
  ## illegal bid: the legal set is the one `legalBids` computes.
  let legal = sim.legalBids(seat)
  if bid in legal:
    return bid
  var best = legal[0]
  for value in legal:
    if abs(value - bid) < abs(best - bid) or
        (abs(value - bid) == abs(best - bid) and value < best):
      best = value
  best

proc matchBid(sim: Sim, seat: int): int =
  ## `match`: pay what the prize is worth, no more.
  case sim.config.mode
  of mGoofspiel:
    let hand = sim.hands[seat]
    let prize = sim.prize()
    if prize in hand:
      return prize
    for card in hand:            ## ascending: the first one over the prize
      if card > prize:
        return card
    hand[hand.high]
  of mOshiZumo:
    ## Spend the even rate that would carry the token off the edge with the
    ## purse in hand.
    let need = max(1, sim.pushesNeeded(seat))
    let rate = int(ceil(sim.coins[seat].float / need.float))
    sim.clampBid(seat, rate)

proc hoardBid(sim: Sim, seat: int): int =
  ## `hoard`: concede the cheap prizes, then swing.
  case sim.config.mode
  of mGoofspiel:
    let hand = sim.hands[seat]
    if sim.prize() <= (sim.config.cards + 1) div 2: hand[0]
    else: hand[hand.high]
  of mOshiZumo:
    let doomed =
      if seat == 0: sim.position == 0
      else: sim.position == fieldCells(sim.config) - 1
    if doomed:
      sim.clampBid(seat, int(ceil(sim.coins[seat].float / 2.0)))
    else:
      sim.minBidOf(seat)

proc scriptedBid*(sim: Sim, seat: int, kind: ScriptKind): int =
  ## Deterministic given the sim state, and always legal.
  let raw =
    case kind
    of skHoard: hoardBid(sim, seat)
    else: matchBid(sim, seat)
  sim.clampBid(seat, raw)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## The baselines never produce `say` or `notes`.
  Decision(bid: scriptedBid(sim, seat, kind))

# ---- Prompt building --------------------------------------------------------

proc bidList(values: seq[int]): string =
  var parts: seq[string]
  for value in values:
    parts.add($value)
  parts.join(", ")

proc pointsText(value: float): string =
  ## Fractional scores are legal (a split prize); print them the short way.
  if abs(value - value.round) < 1e-9: $int(value.round)
  else: formatFloat(value, ffDecimal, 1)

proc verdictText(sim: Sim, event: GameEvent): string =
  ## The one-line result of a resolved goofspiel round.
  let prize = sim.prizeOrder[event.round]
  if event.winners.len == 1:
    sim.names[event.winners[0]] & " takes " & $prize
  else:
    var names: seq[string]
    for seat in event.winners:
      names.add(sim.names[seat])
    names.join(" and ") & " split " &
      pointsText(prize.float / event.winners.len.float) & " each"

proc historyText(sim: Sim): string =
  ## Goofspiel: every bid ever made, every round. No hidden past.
  var lines: seq[string]
  for event in sim.events:
    if event.kind != evReveal:
      continue
    var parts: seq[string]
    for other in 0 ..< sim.seats:
      parts.add(sim.names[other] & " " & $event.bids[other])
    lines.add("Round " & $(event.round + 1) & " — prize " &
      $sim.prizeOrder[event.round] & " — " & parts.join(", ") & " — " &
      sim.verdictText(event) & ".")
  if lines.len == 0:
    return "(no rounds resolved yet)"
  lines.join("\n")

proc oshiHistoryText(sim: Sim, seat: int): string =
  ## Oshi-zumo history needs the token position after each round, which
  ## rides on the push event rather than the reveal.
  var positions: seq[int]
  for event in sim.events:
    if event.kind == evPush:
      positions.add(event.positionAfter)
  var lines: seq[string]
  var index = 0
  for event in sim.events:
    if event.kind != evReveal:
      continue
    let other = 1 - seat
    let push =
      if event.bids[seat] > event.bids[other]: "you pushed"
      elif event.bids[seat] < event.bids[other]: sim.names[other] & " pushed"
      else: "equal, no push"
    let cell = if index < positions.len: positions[index] else: sim.position
    lines.add("Round " & $(event.round + 1) & " — you " & $event.bids[seat] &
      ", " & sim.names[other] & " " & $event.bids[other] & " — " & push &
      " — token " & $cell & ".")
    index += 1
  if lines.len == 0:
    return "(no rounds resolved yet)"
  lines.join("\n")

proc systemPrompt*(sim: Sim, seat: int, selection: PromptSelection): string =
  let me = sim.names[seat]
  case sim.config.mode
  of mGoofspiel:
    result = selection.introduction(me, "GOOFSPIEL (the Game of Pure Strategy)", $(sim.seats - 1) & " other cogs") & (if selection.selectedVariant == pvCanonical: "\nRules:\n" else: "\n\nRules:\n")
    case selection.selectedVariant
    of pvCanonical:
      result.add("""- Every cog holds an identical hand of the cards 1 to """ &
      $sim.config.cards & """.
- Each round one prize card is turned face up. Every cog secretly bids ONE
  card from its hand; the bids are revealed together.
- The highest bid takes the prize and scores the prize's rank. If several
  cogs tie for the highest bid they SPLIT the prize equally (fractional
  points are normal).
- Bid cards are SPENT whether they win or not, so all hands empty together
  and the whole episode is about pacing your budget.
- Nothing about the past is hidden: every bid anyone has ever made is
  public. The only unknowns are what the others bid THIS round, and the
  order of the prizes still to come.
- Your score is your share of the prize pool, rescaled so the table sums to
  zero: the equal share scores 0, taking everything scores +1.""")
    of pvPlain:
      result.add("Everyone starts with the same cards, 1 through " & $sim.config.cards & ". Each round reveals one prize, " &
        "then everyone secretly selects one hand card; bids are revealed together. The highest bid " &
        "wins the prize rank in points. Tied high bidders share it equally, including fractions. " &
        "Every bid card is spent even on a loss, so hands empty together and you must pace your " &
        "cards. All previous bids are public. Rivals’ current bids and future prize order remain " &
        "unknown. Scores rescale prize shares to sum to zero: an equal share is 0 and taking the " &
        "entire pool is +1.")
    of pvNumbered:
      result.add("1. Resource: identical hands containing cards 1–" & $sim.config.cards & ".\n2. Round: reveal a prize; each " &
        "cog secretly bids one hand card; reveal bids together.\n3. Award: highest bid scores the " &
        "prize rank. Tied highest bidders split it equally; fractions count.\n4. Cost: all bid " &
        "cards are spent, win or lose. All hands empty together; pace this finite budget.\n5. " &
        "Knowledge: every past bid is public; this round’s rival bids and future prize order are " &
        "unknown.\n6. Score: prize share rescaled to a zero-sum table. Equal share = 0; whole pool " &
        "= +1.")
    of pvQuestions:
      result.add("What do you hold? The same 1–" & $sim.config.cards & " hand as every cog. What happens each round? A prize " &
        "is shown; everyone secretly bids one hand card and bids are revealed together. Who " &
        "scores? Highest bidder gets the prize rank; ties share it equally, even fractionally. Is " &
        "a losing bid returned? No, every card is spent and all hands empty together, so pace your " &
        "budget. What is hidden? Only rivals’ bids this round and the future prize order; all past " &
        "bids are public. How is score normalized? Prize shares sum to zero after rescaling: equal " &
        "share 0, entire pool +1.")
    of pvReordered:
      result.add("Budget pacing matters because every bid card is spent, winning or losing, and all hands " &
        "empty together. You and every rival start with cards 1–" & $sim.config.cards & ". A round shows a prize, " &
        "collects one secret hand-card bid from each cog, and reveals bids together. The highest " &
        "bid wins the prize rank; tied highs split it equally with fractional points allowed. Past " &
        "bids are fully public. Unknowns are this round’s rival bids and future prize order. Your " &
        "prize share is rescaled to zero-sum scores: equal share 0, taking everything +1.")
    of pvHeldoutBriefing:
      result.add("Manage a hand of cards 1–" & $sim.config.cards & ", identical to every rival’s. After seeing a round’s " &
        "prize, commit one card secretly; all bids appear together. The high bid claims the prize " &
        "rank in points, with equal fractional shares for tied highs. Commitments consume their " &
        "cards regardless of success, and all hands finish together. Use the public record of " &
        "every past bid; neither current rival bids nor the remaining prize order is known. Final " &
        "scores rescale prize shares to sum to zero, assigning 0 to an equal share and +1 to the " &
        "full pool.")
    of pvHeldoutReference:
      result.add("Starting resource: identical 1–" & $sim.config.cards & " hands. Round inputs: visible prize, one secret " &
        "card bid per cog. Reveal: simultaneous. Award: prize rank to highest bid, equally split " &
        "among tied highs; fractional points permitted. Resource cost: every bid card, regardless " &
        "of win; hands empty together, making pacing essential. Public information: all past bids. " &
        "Unknown: current rival bids and future prize order. Score scale: zero-sum prize shares, " &
        "equal share 0, entire pool +1.")
    of pvMixed: raise newException(ValueError, "mixed selection must resolve")
  of mOshiZumo:
    result = selection.introduction(me, "OSHI-ZUMO", "one other cog") & (if selection.selectedVariant == pvCanonical: "\nRules:\n" else: "\n\nRules:\n")
    case selection.selectedVariant
    of pvCanonical:
      result.add("""- A sumo token stands on a track of """ & $fieldCells(sim.config) &
      """ cells, numbered 0 to """ & $(fieldCells(sim.config) - 1) & """.
- You each start with """ & $sim.config.coins & """ coins. Every round both
  cogs secretly bid coins; the bids are revealed together.
- BOTH bids are paid, win or lose. The higher bid pushes the token one cell
  toward the other cog's edge. EQUAL BIDS DO NOT MOVE THE TOKEN, and both
  bids are still spent.
- Pushing the token off the far edge wins outright. If the coins or the
  round cap run out first, whoever's half the token is NOT in wins; the
  centre cell is a draw.
- The minimum bid is """ & $sim.config.minBid & """ while you still have
  coins, so the episode is bounded and stalling costs money.
- Nothing about the past is hidden: every bid either cog has made is public.""")
    of pvPlain:
      result.add("The track has " & $fieldCells(sim.config) & " cells numbered 0–" & $(fieldCells(sim.config) - 1) & ", and each player starts with " & $sim.config.coins & " coins. " &
        "Choose bids secretly each round, then reveal them together. Both bids are spent " &
        "regardless of result. A higher bid pushes the token one cell toward your opponent’s edge; " &
        "equal bids leave it still while still costing both bids. Push it off the far edge to win " &
        "immediately. If coins or the round cap run out first, the player whose half does not " &
        "contain the token wins; center is a draw. While you have coins the minimum bid is " &
        "" & $sim.config.minBid & ", so stalling costs money and play is bounded. All past bids are public.")
    of pvNumbered:
      result.add("1. Board: " & $fieldCells(sim.config) & " track cells, numbered 0–" & $(fieldCells(sim.config) - 1) & ".\n2. Budget: " & $sim.config.coins & " coins per player.\n3. " &
        "Round: secret bids, revealed together; both bids are paid, win or lose.\n4. Movement: the " &
        "higher bid pushes one cell toward the rival edge; equal bids cost both sides but do not " &
        "move the token.\n5. Win: push off the far edge immediately. At coin exhaustion or round " &
        "cap, win if the token is not in your half; center draws.\n6. Minimum: " & $sim.config.minBid & " while coins " &
        "remain; stalling costs money and bounds play.\n7. Information: all earlier bids are public.")
    of pvQuestions:
      result.add("How large is the track? " & $fieldCells(sim.config) & " cells, 0–" & $(fieldCells(sim.config) - 1) & ". What is your budget? Each player starts " &
        "with " & $sim.config.coins & " coins. How are bids made? Secretly, then revealed together. Who pays? Both " &
        "players, even on ties or losses. What moves the token? A higher bid pushes it one cell " &
        "toward the other edge; equal bids never move it. How do you win? Push off the far edge, " &
        "or have the token outside your half when coins or the round cap end play; center is a " &
        "draw. Can you stall freely? No: minimum bid is " & $sim.config.minBid & " while you have coins, so play is " &
        "bounded and stalling costs. What is public? Every past bid.")
    of pvReordered:
      result.add("Win by pushing the token off the opponent’s far edge. If coins or the round limit end " &
        "play first, the player whose half lacks the token wins; the center draws. The track has " &
        "" & $fieldCells(sim.config) & " cells, 0–" & $(fieldCells(sim.config) - 1) & ", and each player begins with " & $sim.config.coins & " coins. Secret bids are " &
        "revealed together. Both are always spent. The higher bid pushes one cell toward the " &
        "opponent; equal bids spend both amounts without moving the token. Minimum bid is " & $sim.config.minBid & " " &
        "while coins remain, bounding play and charging for stalling. Every previous bid is public.")
    of pvHeldoutBriefing:
      result.add("Use " & $sim.config.coins & " starting coins to push a token along a " & $fieldCells(sim.config) & "-cell track numbered 0–" & $(fieldCells(sim.config) - 1) & ". " &
        "Each round, commit coins secretly and reveal both bids together. Both commitments are " &
        "paid regardless of who wins. The higher commitment moves the token one cell toward the " &
        "opposing edge; a tie pays both bids but causes no movement. Crossing the far edge wins " &
        "outright. Otherwise, at coin exhaustion or the round cap, the player whose half is free " &
        "of the token wins, with a draw at center. Bids have minimum " & $sim.config.minBid & " while coins remain, " &
        "so stalling spends resources and play is bounded. Consult the public history of all bids.")
    of pvHeldoutReference:
      result.add("Track: " & $fieldCells(sim.config) & " cells, indices 0–" & $(fieldCells(sim.config) - 1) & ". Initial purse: " & $sim.config.coins & " per player. Bidding: " &
        "secret, simultaneous reveal. Cost: both bids always paid. Higher bid: one-cell push " &
        "toward opponent edge. Equal bids: both paid, no motion. Immediate win: token off far " &
        "edge. Exhausted coins/round cap: token outside your half wins; center draws. Minimum bid " &
        "with coins remaining: " & $sim.config.minBid & ", making stalling costly and play bounded. Past bids: " &
        "public.")
    of pvMixed: raise newException(ValueError, "mixed selection must resolve")
  result.add("\n\n" & "OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no\nanalysis, no explanation, no markdown fences, no text before or after the\nobject. Your reply must begin with the character { and end with }.")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc replyContract(sim: Sim, seat: int): string =
  "Reply with ONLY {\"bid\": <one of your legal bids>, \"say\": \"…\", " &
    "\"notes\": \"…\"} — `say` is one short line for the spectators (at " &
    "most " & $MaxSayLen & " characters), `notes` is your private memo " &
    "carried to the next round (at most " & $MaxNotesLen & " characters). " &
    "`bid` must be one of: " & bidList(sim.legalBids(seat)) & "."

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  var names: seq[string]
  for other in 0 ..< sim.seats:
    names.add(sim.names[other])
  result.add("Round " & $(sim.round + 1) & " of " & $sim.config.maxRounds &
    ". You are " & sim.names[seat] & ". Seats: " & names.join(", ") & ".\n\n")
  case sim.config.mode
  of mGoofspiel:
    result.add("THE PRIZE THIS ROUND: " & $sim.prize() & "\n")
    let left = sim.prizesLeft(sim.round)
    result.add("PRIZES STILL TO COME (order unknown): " &
      (if left.len == 0: "(none)" else: bidList(left)) & "\n\n")
    result.add("YOUR HAND: " & bidList(sim.hands[seat]) & "\n")
    result.add("YOUR LEGAL BIDS: " & bidList(sim.legalBids(seat)) & "\n\n")
    result.add("EVERY SEAT'S REMAINING HAND:\n")
    for other in 0 ..< sim.seats:
      result.add("  " & sim.names[other] & ": " &
        bidList(sim.hands[other]) & "\n")
    result.add("\nPOINTS SO FAR:\n")
    for other in 0 ..< sim.seats:
      result.add("  " & sim.names[other] & ": " &
        pointsText(sim.points[other]) & "\n")
    let pool = sim.config.cards * (sim.config.cards + 1) div 2
    result.add("EQUAL SHARE WOULD BE " &
      formatFloat(pool.float / sim.seats.float, ffDecimal, 2) & "\n\n")
    result.add("HISTORY:\n" & sim.historyText() & "\n\n")
  of mOshiZumo:
    let cells = fieldCells(sim.config)
    let edge = if seat == 0: cells - 1 else: 0
    result.add("THE FIELD: cells 0.." & $(cells - 1) & ", token at " &
      $sim.position & ". You push toward cell " & $edge &
      ". Pushing it past cell " & $edge & " wins; if the round cap or your " &
      "purses run out first, whoever's half the token is NOT in wins, and " &
      "cell " & $sim.config.size & " is a draw.\n")
    result.add("YOUR PURSE: " & $sim.coins[seat] & " coins. OPPONENT'S " &
      "PURSE: " & $sim.coins[1 - seat] & " coins.\n")
    result.add("YOUR LEGAL BIDS: " & $sim.minBidOf(seat) & ".." &
      $sim.coins[seat] & " (minimum bid " & $sim.minBidOf(seat) & ").\n")
    result.add("PUSHES YOU STILL NEED: " & $sim.pushesNeeded(seat) & "\n\n")
    result.add("HISTORY:\n" & sim.oshiHistoryText(seat) & "\n\n")
  result.add("YOUR NOTES FROM EARLIER ROUNDS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add(sim.replyContract(seat))

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    raise newException(GozuError, "no JSON object in response: " &
      cleanText(text.replace("\n", " "), MaxErrorLen))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a GozuError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(GozuError, "llm transport: " &
      cleanText(error, MaxErrorLen))
  if response.code == 401 or response.code == 403:
    let detail = cleanText(response.body, MaxErrorLen)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(GozuError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(GozuError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = cleanText(response.body, MaxErrorLen)
    discard client.tryNextBedrockModel("throttled")
    raise newException(GozuError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(GozuError, "anthropic error " & $response.code &
      ": " & cleanText(response.body, MaxErrorLen))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GozuError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GozuError, "reply cut off at max_tokens before any " &
      "JSON: " & cleanText(result.replace("\n", " "), MaxErrorLen))

proc rankLetter(text: string): int =
  ## The goofspiel card letters are a BARE token — "K", "k", "K." — and not
  ## any reply that merely STARTS with one: `"a bid of 11"` read as the ace
  ## and `"just 12"` read as the jack are legal cards, so nothing downstream
  ## rejects them and the seat silently bids a card it never asked for.
  ## Prose falls through to the numeric scan, whose raise is what triggers
  ## the retry-with-the-legal-set and then the scripted fallback.
  let token = text.strip(chars = Whitespace + {'"', '\'', '.', '!', ',', ':',
    ';', '*', '`'})
  if token.len != 1:
    return 0
  case token[0].toUpperAscii()
  of 'A': 1
  of 'J': 11
  of 'Q': 12
  of 'K': 13
  else: 0

proc parseBidText(text: string, mode: Mode): int =
  ## A numeric string with surrounding whitespace or trailing prose
  ## ("11 — the king"), or, in goofspiel only, a bare card letter.
  let trimmed = text.strip()
  if trimmed.len == 0:
    raise newException(GozuError, "empty bid")
  if mode == mGoofspiel:
    let rank = rankLetter(trimmed)
    if rank > 0:
      return rank
  var head = ""
  for index in 0 ..< trimmed.len:
    let c = trimmed[index]
    if c in {'0' .. '9'} or (head.len == 0 and c == '-') or
        (c == '.' and '.' notin head and head.len > 0):
      head.add(c)
    elif head.len > 0:
      break
    else:
      raise newException(GozuError,
        "bid is not a number: " & cleanText(trimmed, MaxErrorLen))
  if head.len == 0 or head == "-":
    raise newException(GozuError,
      "bid is not a number: " & cleanText(trimmed, MaxErrorLen))
  try:
    int(round(parseFloat(head)))
  except ValueError:
    raise newException(GozuError,
      "bid is not a number: " & cleanText(trimmed, MaxErrorLen))

proc parseDecision*(payload: JsonNode, mode: Mode): Decision =
  ## "bid" is an integer, a float (rounded half-up), a numeric string with
  ## trailing prose, or - in goofspiel - a bare card letter A/J/Q/K.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen).replace("\n", " ")
  let node = payload{"bid"}
  if node.isNil:
    raise newException(GozuError, "no bid in response")
  case node.kind
  of JInt: result.bid = node.getInt()
  of JFloat: result.bid = int(round(node.getFloat()))
  of JString: result.bid = parseBidText(node.getStr(), mode)
  else:
    raise newException(GozuError, "bid must be a number: " &
      cleanText($node, MaxErrorLen))

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  selection: PromptSelection
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the scripted baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  ##
  ## Every LLM seat is called in ONE parallel batch, because the rules make
  ## the round simultaneous; sequential per-seat calls are the documented
  ## way to blow the 720 s play budget.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skMatch else: kind))
      result[index].fellBack = kind == skNone
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    var evidenceByIndex = newSeq[DecisionAttempt](seats.len)
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        ## Printing the legal set — computed by the same proc the validator
        ## applies — is what halves fallbacks in formal-output games.
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object; \"bid\" must be one of: " &
          bidList(sim.legalBids(seat)) & ".")
      let request = client.requestFor(systemPrompt(sim, seat, selection), user, seat)
      evidenceByIndex[index] = newDecisionAttempt("attempt-" & $attempt, client.model, aoModel)
      captureInferenceRequest(evidenceByIndex[index], parseJson(request.body), systemPrompt(sim, seat, selection), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      var evidence = evidenceByIndex[index]
      let response = responses[position].response
      var raw = ""
      try:
        captureInferenceResponse(evidence, response.body, response.code,
          response.headers["x-softmax-llm-call-id"], response.headers["x-coworld-checkpoint-sha256"],
          response.headers["x-coworld-tokenizer-sha256"], response.headers["x-coworld-chat-template-sha256"],
          client.timeoutSeconds, 2)
        raw = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var decision = parseDecision(extractJsonObject(raw), sim.config.mode)
        ## Reject illegal bids here so the retry carries the hint. This is
        ## the SAME predicate applyBids validates with.
        if decision.bid notin sim.legalBids(seat):
          raise newException(GozuError,
            "bid " & $decision.bid & " is not legal for this seat")
        evidence.response = %raw
        evidence.accepted = true
        decision.nativeAttempts = result[index].nativeAttempts & @[evidence]
        result[index] = decision
      except CatchableError as error:
        evidence.response = %raw
        evidence.rejectionReason = some(error.msg)
        result[index].nativeAttempts.add(evidence)
        echo "gozu llm: seat ", seat, " attempt ", attempt, " failed: ",
          cleanText(error.msg, MaxErrorLen)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "gozu llm: seat ", seat, " falling back to scripted decision"
    let retained = result[index].nativeAttempts
    result[index] = scriptedAction(sim, seat, skMatch)
    result[index].nativeAttempts = retained
    result[index].fellBack = true
