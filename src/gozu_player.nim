## Goofspiel / Oshi-Zumo player: prompt, scripted, or external Jev policy.
##
## Prompt policies deliver PLAYER_PROMPT and wait for the final frame.
## PLAYER_JEV=1 ranks legal bids from each seat observation in this process.
##
## PLAYER_SCRIPTED=match|hoard registers the seat as one of the built-in
## baselines instead: the server plays it deterministically, no LLM.
## (1/true/yes are accepted as synonyms for match.)
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <image> --name my-gozu \
##     --run /bin/goofspiel-oshi-zumo-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  gozu/jev_policy,
  whisky

const DefaultPrompt = """
Bid to win the prizes that are worth winning and no others. Spend in
proportion to value, keep your high cards for the high prizes, and watch
what every rival has already spent - their remaining resources are public.
Reply with only the JSON object.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip().toLowerAscii()
  let jevRequested = getEnv("PLAYER_JEV") == "1"
  let jev = jevRequested and (
    getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("METTA_CAPTURE_URL").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0)

  proc promptFrame(): string =
    if jev: $ %*{"type": "register", "control": "external"}
    else: $ %*{"type": "prompt", "prompt": prompt,
      "scripted": (if jevRequested: "match" else: scripted)}

  echo "gozu player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "gozu player: registered ",
    (if jev: "Jev external policy" else: "prompt/scripted policy")

  ## whisky RAISES on a close frame or a truncated read (only a timeout
  ## returns none), and the game's quit(0) can outrun the flushed `final`
  ## frame. A dead socket is a normal end of episode, not a failure: the
  ## player must exit 0 or hosted certification reports player_error.
  ##
  ## The read is BOUNDED. whisky's default timeout is -1, i.e. block until a
  ## frame arrives or the socket dies; the bound here is the platform's whole
  ## episode timeout plus a margin, which is longer than any legitimate gap
  ## between frames (the game broadcasts every round and sends `final` before
  ## it quits) and still an explicit end to the wait rather than an open one.
  let episodeSeconds =
    try:
      max(60.0, parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200").strip()))
    except ValueError:
      1200.0
  let idleTimeoutMs = int(episodeSeconds * 1000.0) + 120_000
  try:
    while true:
      let received = socket.receiveMessage(timeout = idleTimeoutMs)
      if received.isNone:
        echo "gozu player: no frame for ", idleTimeoutMs div 1000,
          "s or connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "gozu player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "state":
          if jev and payload.hasKey("observation"):
            socket.send($chooseBid(payload["observation"]))
        of "final":
          echo "gozu player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "gozu player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "gozu player: socket ended (", error.msg, "); exiting"
  try:
    socket.close()
  except CatchableError:
    discard
