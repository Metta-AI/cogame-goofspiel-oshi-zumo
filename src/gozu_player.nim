## Goofspiel / Oshi-Zumo player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default bidding strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt plus the public table to Claude every round.
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

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "gozu player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "gozu player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky RAISES on a close frame or a truncated read (only a timeout
  ## returns none), and the game's quit(0) can outrun the flushed `final`
  ## frame. A dead socket is a normal end of episode, not a failure: the
  ## player must exit 0 or hosted certification reports player_error.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "gozu player: connection closed, exiting"
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
