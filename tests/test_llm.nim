## Tolerant reply parsing: what `parseDecision` accepts, and what it must
## refuse so the retry/fallback path fires instead of a silent wrong bid.
##
## The bid a seat plays is whatever this proc returns, and a value that
## happens to be a LEGAL card is accepted by every check downstream
## (`decideAll`'s validator and the server's own re-check), so a misread here
## is invisible: no retry, no recorded fallback, just a card the seat never
## asked for.

import std/[json, unittest]
import gozu/[llm, sim]

proc bid(text: string, mode = mGoofspiel): int =
  parseDecision(%*{"bid": text}, mode).bid

suite "tolerant bid parsing":
  test "numbers, with whitespace and trailing prose":
    check bid("11") == 11
    check bid("  13  ") == 13
    check bid("11 — the king") == 11
    check bid("7, keeping the ace back") == 7
    check parseDecision(%*{"bid": 9}, mGoofspiel).bid == 9
    check parseDecision(%*{"bid": 7.6}, mGoofspiel).bid == 8
    check parseDecision(%*{"bid": 3}, mOshiZumo).bid == 3

  test "a bare card letter is a rank, in goofspiel only":
    check bid("A") == 1
    check bid("j") == 11
    check bid(" Q ") == 12
    check bid("K.") == 13
    check bid("\"k\"") == 13
    ## Oshi-zumo bids coins; there are no cards to name.
    expect GozuError:
      discard bid("K", mOshiZumo)

  test "prose that merely STARTS with a card letter is not a bid":
    ## Each of these used to return a legal card (1, 11, 12, 13), which no
    ## validator downstream could reject: the seat bid a card it never asked
    ## for and `fallbacks` stayed 0. They must raise so the batch retries
    ## with the legal set and then falls back to the scripted move.
    expect GozuError:
      discard bid("a bid of 11")
    expect GozuError:
      discard bid("just 12")
    expect GozuError:
      discard bid("queen or king, whichever is left")
    expect GozuError:
      discard bid("keeping the 13 back")

  test "nothing numeric at all raises":
    expect GozuError:
      discard bid("")
    expect GozuError:
      discard bid("pass")
    expect GozuError:
      discard parseDecision(%*{"say": "hello"}, mGoofspiel)
