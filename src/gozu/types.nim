## Config, events and the shared string caps for Goofspiel / Oshi-Zumo.
##
## Fork of cogame-babel's src/babel/types.nim: same GameConfig / GameEvent
## shape, same `update` contract over a runtime JSON blob, extended with the
## mode switch and the bid-resolution event vocabulary.

import std/[json, strutils, unicode]

const
  ## Caps for every string that can reach the replay, an event, or a log
  ## line. Truncation is always on a RUNE boundary (`cleanText`): a byte
  ## cut mid-UTF-8 renders in a browser and fails a strict JSON parser.
  MaxSayLen* = 80
  MaxNotesLen* = 400
  MaxPromptLen* = 4000
  MaxErrorLen* = 200

type
  GozuError* = object of CatchableError

  Mode* = enum
    mGoofspiel = "goofspiel"
    mOshiZumo = "oshizumo"

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]            ## connection tokens, injected by the runner
    players*: seq[PlayerConfig]     ## policy display names, by slot
    mode*: Mode
    seed*: int
    cards*: int                     ## goofspiel: 13
    coins*: int                     ## oshizumo: 20
    size*: int                      ## oshizumo: K = 3 (field is 2K+1 cells)
    minBid*: int                    ## oshizumo: M = 1
    maxRounds*: int                 ## 0 = derive (cards / coins)
    episodeTimeoutSeconds*: int     ## 1200
    batchSpacingSeconds*: int       ## 0 = derive 4 * seats
    turnDelayMs*: int               ## 400 (0 in the cert fixture)
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int
    sampled*: bool                  ## true once the budget fit was applied
    prizeOrder*: seq[int]           ## replay only: pins the shuffled deck

  EventKind* = enum
    evStart = "start"
    evPrize = "prize"
    evReveal = "reveal"
    evOverbid = "overbid"
    evPush = "push"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int                ## 0-based round; start: -1; end: rounds played
    ## prize
    prize*: int
    prizesLeft*: seq[int]
    ## reveal
    bids*: seq[int]
    winners*: seq[int]
    award*: seq[float]
    margin*: int
    coinsAfter*: seq[int]
    handsAfter*: seq[seq[int]]
    points*: seq[float]
    says*: seq[string]
    notes*: seq[string]
    scripted*: seq[bool]
    fellBack*: seq[bool]
    ## overbid
    seat*: int
    bid*: int
    over*: int
    ## push
    delta*: int
    positionAfter*: int
    ## end
    reason*: string
    ending*: string
    scores*: seq[float]
    collusionIndex*: seq[float]

proc cleanText*(text: string, limit: int): string =
  ## The one truncation in this repo. Text over the cap is cut on a RUNE
  ## boundary with the cut marked, so the bytes stay valid UTF-8 and a
  ## strict JSON parser accepts the replay.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    mode: mGoofspiel,
    seed: 0,
    cards: 13,
    coins: 20,
    size: 3,
    minBid: 1,
    maxRounds: 0,
    episodeTimeoutSeconds: 1200,
    batchSpacingSeconds: 0,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc parseMode*(text: string): Mode =
  case text.strip().toLowerAscii()
  of "goofspiel", "gops": mGoofspiel
  of "oshizumo", "oshi-zumo", "oshi_zumo": mOshiZumo
  else:
    raise newException(GozuError, "unknown mode: " & text)

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults, and rejects
  ## anything the rules cannot express.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(GozuError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("mode"):
    config.mode = parseMode(node["mode"].getStr())
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("cards"):
    config.cards = node["cards"].getInt()
  if node.hasKey("coins"):
    config.coins = node["coins"].getInt()
  if node.hasKey("size"):
    config.size = node["size"].getInt()
  if node.hasKey("minBid"):
    config.minBid = node["minBid"].getInt()
  if node.hasKey("maxRounds"):
    config.maxRounds = node["maxRounds"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("batchSpacingSeconds"):
    config.batchSpacingSeconds = node["batchSpacingSeconds"].getInt()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.cards < 4 or config.cards > 13:
    raise newException(GozuError, "cards must be 4..13")
  if config.coins < 4 or config.coins > 50:
    raise newException(GozuError, "coins must be 4..50")
  if config.size < 1 or config.size > 5:
    raise newException(GozuError, "size must be 1..5")
  if config.minBid < 0 or config.minBid > 2:
    raise newException(GozuError, "minBid must be 0..2")
  if config.maxRounds != 0 and (config.maxRounds < 2 or config.maxRounds > 60):
    raise newException(GozuError, "maxRounds must be 2..60")
  if config.players.len < 2 or config.players.len > 10:
    raise newException(GozuError, "players must be 2..10 seats")
  if config.mode == mOshiZumo and config.players.len != 2:
    raise newException(GozuError, "oshizumo is a two-seat game")
