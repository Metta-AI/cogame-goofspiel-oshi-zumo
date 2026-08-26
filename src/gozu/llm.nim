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
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, os, strutils],
  bitworld/runtime,
  curly,
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
    bid*: int
    say*: string
    notes*: string      ## "" when the reply carried none
    fellBack*: bool     ## the LLM path failed and the baseline decided

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string              ## anthropic transport
    bedrockEndpoint: string     ## bedrock transport: sidecar or public host
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

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  case sim.config.mode
  of mGoofspiel:
    "You are " & me & ", a cog playing GOOFSPIEL (the Game of Pure " &
      "Strategy) against " & $(sim.seats - 1) & " other cogs." & """

Rules:
- Every cog holds an identical hand of the cards 1 to """ &
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
  zero: the equal share scores 0, taking everything scores +1.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }."""
  of mOshiZumo:
    "You are " & me & ", a cog playing OSHI-ZUMO against one other cog." &
      """

Rules:
- A sumo token stands on a track of """ & $fieldCells(sim.config) &
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
- Nothing about the past is hidden: every bid either cog has made is public.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }."""

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

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
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

proc parseBidText(text: string, mode: Mode): int =
  ## A numeric string with surrounding whitespace or trailing prose
  ## ("11 — the king"), or, in goofspiel only, a card letter.
  let trimmed = text.strip()
  if trimmed.len == 0:
    raise newException(GozuError, "empty bid")
  if mode == mGoofspiel:
    case trimmed[0].toUpperAscii()
    of 'A': return 1
    of 'J': return 11
    of 'Q': return 12
    of 'K': return 13
    else: discard
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
  ## trailing prose, or - in goofspiel - a card letter A/J/Q/K.
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
  scripted: seq[ScriptKind]
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
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        ## Printing the legal set — computed by the same proc the validator
        ## applies — is what halves fallbacks in formal-output games.
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object; \"bid\" must be one of: " &
          bidList(sim.legalBids(seat)) & ".")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let decision = parseDecision(extractJsonObject(text), sim.config.mode)
        ## Reject illegal bids here so the retry carries the hint. This is
        ## the SAME predicate applyBids validates with.
        if decision.bid notin sim.legalBids(seat):
          raise newException(GozuError,
            "bid " & $decision.bid & " is not legal for this seat")
        result[index] = decision
      except CatchableError as error:
        echo "gozu llm: seat ", seat, " attempt ", attempt, " failed: ",
          cleanText(error.msg, MaxErrorLen)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "gozu llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skMatch)
    result[index].fellBack = true
