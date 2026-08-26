# Baseline tuning

The two scripted baselines (`match`, `hoard`) are the no-credentials fallback, the fallback for
every failed LLM decision, and two of the four shipped policies, so the constants inside their
rules are load-bearing. They were not guessed: `scripts/tune_baselines.nim` sweeps each of them
over a grid and reports the mean score the swept seat takes over the same 200 seeds at every
grid point.

Three constants are free in the rules the design note prescribes:

| baseline | constant | shipped value |
|---|---|---|
| goofspiel `hoard` | the cheap/dear split — bid `min(H)` at or below it, `max(H)` above | `(cards + 1) div 2` = 7 |
| oshi-zumo `match` | the spend-rate multiplier `k` in `ceil(k * coins / pushesNeeded)` | `1.0` |
| oshi-zumo `hoard` | the desperation divisor `f` in `ceil(coins / f)` one loss from defeat | `2` |

The harness plays the swept bidder in seat 0 against the shipped opponents, and at the shipped
grid point it asserts every bid equals `scriptedBid`'s — so the table describes the code that
ships, not a lookalike written beside it.

Reproduce with:

```
nim c -r scripts/tune_baselines.nim 200
```

## The grid, 200 seeds per point

```
goofspiel `hoard`: cheap/dear split (vs match, vs random)
|    split | vs match |   vs rnd |
|---------:|---------:|---------:|
|        1 |  0.1234 |  0.0183 |
|        2 |  0.1436 |  0.0440 |
|        3 |  0.1613 |  0.0713 |
|        4 |  0.1768 |  0.0954 |
|        5 |  0.1821 |  0.1219 |
|        6 |  0.1872 |  0.1406 |
|        7 |  0.1882 |  0.1514 |  <- shipped
|        8 |  0.1765 |  0.1594 |
|        9 |  0.1595 |  0.1560 |
|       10 |  0.1387 |  0.1425 |
|       11 |  0.1154 |  0.1208 |
|       12 |  0.0894 |  0.0743 |
|       13 |  0.1126 |  0.0163 |

oshi-zumo `match`: spend rate multiplier k (vs hoard, vs random)
|        k | vs hoard |   vs rnd |
|---------:|---------:|---------:|
|     0.50 |  0.0000 |  0.8600 |
|     0.75 | -1.0000 |  0.9800 |
|     1.00 | -1.0000 |  0.9800 |  <- shipped
|     1.25 | -1.0000 |  0.8800 |
|     1.50 | -1.0000 |  0.7750 |
|     2.00 | -1.0000 |  0.4450 |

oshi-zumo `hoard`: desperation divisor f (vs match, vs random)
|        f | vs match |   vs rnd |
|---------:|---------:|---------:|
|     1.00 | -1.0000 |  0.0900 |
|     1.50 |  1.0000 |  0.8400 |
|     2.00 |  1.0000 |  0.9800 |
|     3.00 |  1.0000 |  0.9800 |
|     4.00 |  1.0000 |  0.9400 |
```

## What the grid says

- **Goofspiel `hoard`, split = 7.** The shipped value is the maximum against `match` (0.1882) and
  within noise of the maximum against a uniform-random legal bidder (0.1514 against 0.1594 at
  split 8). The curve is single-peaked in both columns, so the split is where it belongs.
- **Oshi-zumo `match`, k = 1.** Against a random bidder the curve peaks flat at k ∈ {0.75, 1.0}
  (0.98) and falls away on both sides — spending under the even rate concedes pushes, spending
  over it empties the purse early. The shipped rate is at the peak.
- **Oshi-zumo `hoard`, f = 2.** Every `f ≥ 1.5` beats `match` head to head; against a random
  bidder the peak is flat at f ∈ {2, 3} (0.98). The shipped divisor is at the peak.

One asymmetry worth recording: in oshi-zumo `hoard` **beats** `match` head to head at every
tested rate above 0.5. `hoard` holds its purse at `minBid` and spends half of it exactly when it
is one loss from defeat, which is enough to reverse `match`'s even spend. That is the ladder
having a shape rather than two copies of one bot, which is what the second filler is for
(`tests/test_bot.nim` assertion 14 pins that the two disagree on ≥ 30 % of rounds), and `match`
remains the right fallback: assertion 13 shows it beating a uniform-random legal bidder with a
mean score > 0 over 200 episodes, and it is the reference opponent Ross (1971) proves optimal
against uniform random play in goofspiel.
