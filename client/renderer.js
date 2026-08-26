// goofspiel-oshi-zumo game block: the board, the readouts and the drivers.
//
// The chrome (names, feed rendering, scorebug plumbing, endscreen container,
// scrubber track, transport contract) is inherited VERBATIM from cogame-babel
// and lives in client/chrome_common.js as window.GozuChrome. This file is the
// game-specific half and nothing else: it declares NO identifier that
// GozuChrome exports (tools/ci/chrome_scope_check.mjs asserts it) and reaches
// the chrome only through `C.`, so a hoisted game-block function can never
// shadow a chrome one (tandem, 2026-08-23).
//
// It draws one state object per frame:
//   {mode, seats:[{name,alias,points,score,hand,coins,bid,say,notes,spent,
//                  budget,budgetFull,winner,award}],
//    round, maxRounds, roundsPlayed, prize, prizesLeft, position, cells,
//    push, overbid, margin, phase, gameDone, reason, ending}
// Ranks are always rendered numerically -- "10", "11", "12", "13", never
// T/J/Q/K -- so a casual spectator can read the table.
(function () {
  "use strict";

  var C = window.GozuChrome;

  // Which game the feed is describing. The inherited renderFeed threads a
  // scratch `ctx` through the events but knows nothing about modes, so the
  // driver sets this once when it attaches.
  var feedMode = "goofspiel";

  var CARD_RATIO = 0.72;          // width / height of a card face
  var OVERBID_MS = 900;           // the gasp banner holds this long
  var REVEAL_MS = 420;            // bid cards flip in over this
  var PUSH_MS = 380;              // the token slides one cell over this
  var MAX_SAY = 80;               // the server's own cap on `say`, in RUNES
  var SAY_MIN_PX = 7;             // the smallest legible band font
  var WIDE_RUNE = "\u6c38";       // one full-width glyph: the widest rune

  // Dwell per event kind in a replay, in ms. 13 rounds of
  // prize+reveal(+overbid) is ~29 events at ~900 ms => ~26 s of playback,
  // comfortably longer than the wasm-viewer job's 10 s soak.
  var DWELL = {
    start: 600, prize: 700, reveal: 1200, overbid: 900, push: 700, end: 1500
  };

  var SPRITES = ["soldier_red_front.png", "soldier_blue_front.png",
    "soldier_green_front.png", "soldier_yellow_front.png",
    "arena_floor.png", "sumo_token.png", "card_back.png"];

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    loadImages(assetBase, SPRITES, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function pointsText(value) {
    var n = Number(value) || 0;
    return Math.abs(n - Math.round(n)) < 1e-9 ? String(Math.round(n)) :
      n.toFixed(1);
  }

  function narrow() {
    return (document.documentElement.clientWidth || window.innerWidth || 0)
      < 420;
  }

  // The chrome's single scale factor. C.relayout() sets `--hudscale` on
  // :root from the window width and the CSS chrome scales with it; the say
  // band is sized from MaxSayLen "measured in the render font at the current
  // --hudscale" (design note), so the band reads the same variable instead
  // of only the canvas-derived layout scale.
  function hudScale() {
    var raw = getComputedStyle(document.documentElement)
      .getPropertyValue("--hudscale");
    var value = parseFloat(raw);
    return isFinite(value) && value > 0 ? value : 1;
  }

  // ---- Layout ---------------------------------------------------------------

  // A FIXED board: a centre piece (the prize, or the dohyo track) over one
  // panel per seat. It always fits the frame, which is why there is no
  // #viewpanel zoom bar and no minimap -- they would only steal height at
  // 360 px.
  function computeLayout(w, h, count) {
    var margin = Math.max(5, Math.round(Math.min(w, h) * 0.022));
    var cols = Math.max(1, count);
    var panelW = (w - 2 * margin) / cols;
    // The panel is only as tall as its content needs: sprite/card row, two
    // text lines, the budget bar, the spent strip and the reserved say band.
    // Everything left over goes to the centre piece, which is what the eye
    // is on.
    var natural = 118 + Math.min(panelW * 0.42, 92);
    var panelH = Math.max(70, Math.min(h * 0.46, h - 90, natural, 220));
    var panelTop = Math.max(margin + 40, h - margin - panelH);
    panelH = Math.min(panelH, h - margin - panelTop);
    return {
      margin: margin, cols: cols, panelW: panelW, panelH: panelH,
      panelTop: panelTop, topH: panelTop - margin, w: w, h: h,
      scale: Math.max(0.55, Math.min(1, Math.min(w / 960, h / 620))),
      hud: hudScale()
    };
  }

  // ---- Card faces -----------------------------------------------------------

  // Card FACES are drawn, not blitted, so a rank stays crisp at every scale.
  function drawCardFace(ctx, x, y, w, h, rank, accent, opts) {
    var options = opts || {};
    var r = Math.max(2, w * 0.09);
    ctx.save();
    if (options.lift) {
      ctx.shadowColor = "rgba(0,0,0,0.55)";
      ctx.shadowBlur = 8;
      ctx.shadowOffsetY = 3;
    }
    ctx.fillStyle = C.PAPER;
    roundRect(ctx, x, y, w, h, r);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = accent || C.CARD_EDGE;
    ctx.lineWidth = options.lift ? 3 : 1.5;
    ctx.stroke();
    if (options.tint) {
      ctx.fillStyle = C.rgba(accent || C.AMBER, 0.22);
      roundRect(ctx, x, y, w, h, r);
      ctx.fill();
    }
    var label = String(rank);
    var big = Math.max(9, Math.min(h * 0.5, w * 0.72));
    ctx.fillStyle = C.INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(big) + "px 'rajdhani', system-ui, sans-serif";
    ctx.fillText(C.ellipsize(ctx, label, w * 0.9), x + w / 2, y + h / 2);
    var small = Math.max(7, Math.round(h * 0.16));
    if (h > 44) {
      ctx.font = "600 " + small + "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "top";
      ctx.fillText(label, x + w * 0.1, y + h * 0.06);
      ctx.textAlign = "right";
      ctx.textBaseline = "bottom";
      ctx.fillText(label, x + w * 0.9, y + h * 0.94);
    }
    ctx.restore();
  }

  function drawCardBack(ctx, images, x, y, w, h) {
    var back = images["card_back.png"];
    ctx.save();
    if (back && back.width) {
      ctx.drawImage(back, x, y, w, h);
    } else {
      ctx.fillStyle = "rgba(232, 163, 61, 0.18)";
      ctx.strokeStyle = "rgba(242, 232, 216, 0.30)";
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 3]);
      roundRect(ctx, x, y, w, h, Math.max(2, w * 0.09));
      ctx.fill();
      ctx.stroke();
    }
    ctx.restore();
  }

  // ---- Centre piece ---------------------------------------------------------

  function drawPrize(ctx, images, layout, view) {
    var topH = layout.topH;
    if (topH < 40) return;
    var cy = layout.margin + topH / 2;
    var cardH = Math.max(34, Math.min(topH * 0.72, 210));
    var cardW = cardH * CARD_RATIO;
    var x = layout.w / 2 - cardW / 2;
    var y = cy - cardH / 2 + topH * 0.05;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = C.AMBER;
    ctx.font = "700 " + Math.max(8, Math.round(11 * layout.scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillText("PRIZE", layout.w / 2, Math.max(12, y - 6 * layout.scale));
    ctx.restore();
    if (view.prize > 0) {
      drawCardFace(ctx, x, y, cardW, cardH, view.prize, C.AMBER,
        { lift: true });
    } else {
      drawCardBack(ctx, images, x, y, cardW, cardH);
    }
    var left = view.prizesLeft || [];
    if (left.length && topH > 78) {
      ctx.save();
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.fillStyle = C.GHOST;
      ctx.font = "600 " + Math.max(8, Math.round(10 * layout.scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      var text = left.length + " PRIZES LEFT";
      ctx.fillText(C.ellipsize(ctx, text, layout.w - 20),
        layout.w / 2, y + cardH + 5 * layout.scale);
      ctx.restore();
    }
  }

  function drawTrack(ctx, images, layout, view, now) {
    var cells = view.cells || 7;
    var topH = layout.topH;
    if (topH < 40) return;
    var trackW = Math.min(layout.w - 2 * layout.margin, 74 * cells);
    var cellW = trackW / cells;
    var cellH = Math.max(24, Math.min(cellW, topH * 0.5));
    var x0 = layout.w / 2 - trackW / 2;
    var y0 = layout.margin + topH / 2 - cellH / 2;
    ctx.save();
    for (var i = 0; i < cells; i++) {
      var mid = (cells - 1) / 2;
      ctx.fillStyle = i === mid ? "rgba(232, 163, 61, 0.14)" :
        (i < mid ? "rgba(224, 82, 58, 0.10)" : "rgba(63, 124, 196, 0.10)");
      ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
      ctx.lineWidth = 1;
      roundRect(ctx, x0 + i * cellW + 1, y0, cellW - 2, cellH, 3);
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = C.GHOST;
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.font = "600 " + Math.max(7, Math.round(9 * layout.scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText(String(i), x0 + i * cellW + cellW / 2, y0 + cellH + 3);
    }
    ctx.restore();

    // The token slides one cell on a push and shakes on an equal bid.
    var pos = typeof view.position === "number" ? view.position : (cells - 1) / 2;
    var slide = 0;
    var shake = 0;
    if (view.pushAt) {
      var age = now - view.pushAt;
      if (age < PUSH_MS) {
        var t = Math.max(0, Math.min(1, age / PUSH_MS));
        if (view.push) slide = -(1 - t) * (view.push) * cellW;
        else shake = Math.sin(age / 24) * 3 * (1 - t);
      }
    }
    var size = Math.max(20, Math.min(cellW * 0.86, cellH * 0.94));
    var tx = x0 + pos * cellW + cellW / 2 + slide + shake;
    var ty = y0 + cellH / 2;
    var token = images["sumo_token.png"];
    ctx.save();
    if (token && token.width) {
      if (view.push < 0) {
        ctx.translate(tx, ty);
        ctx.scale(-1, 1);
        ctx.drawImage(token, -size / 2, -size / 2, size, size);
      } else {
        ctx.drawImage(token, tx - size / 2, ty - size / 2, size, size);
      }
    } else {
      ctx.fillStyle = C.PAPER;
      ctx.beginPath();
      ctx.arc(tx, ty, size * 0.4, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  // ---- Seat panels ----------------------------------------------------------

  // A run with no spaces in it -- a Japanese sentence is one "word" 80 runes
  // long -- is broken on RUNE boundaries (never inside a surrogate pair)
  // rather than cut: ellipsis is a design choice for a label and a defect
  // for a sentence.
  function splitToFit(ctx, word, maxWidth) {
    if (ctx.measureText(word).width <= maxWidth) return [word];
    var pieces = [];
    var piece = "";
    Array.from(word).forEach(function (rune) {
      if (piece && ctx.measureText(piece + rune).width > maxWidth) {
        pieces.push(piece);
        piece = rune;
      } else {
        piece += rune;
      }
    });
    if (piece) pieces.push(piece);
    return pieces;
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = String(text).split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      splitToFit(ctx, word, maxWidth).forEach(function (piece) {
        var probe = line ? line + " " + piece : piece;
        if (ctx.measureText(probe).width > maxWidth && line) {
          lines.push(line);
          line = piece;
        } else {
          line = probe;
        }
      });
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = lines[lines.length - 1] + "…";
    }
    return lines.map(function (l) { return C.ellipsize(ctx, l, maxWidth); });
  }

  function panelPad(layout) {
    return Math.max(3, 5 * layout.scale);
  }

  function panelContentW(layout) {
    return Math.min(layout.panelW - 2 * panelPad(layout), 380);
  }

  function sayFontPx(layout) {
    return Math.max(SAY_MIN_PX, Math.round(11 * layout.scale * layout.hud));
  }

  // The say band is RESERVED from the server's own cap (MAX_SAY = 80 runes)
  // measured in the font it will be drawn in at the current --hudscale, and
  // reserved for as many LINES as that many WORST-CASE (full-width) runes
  // need at this panel width -- whether or not a seat is speaking, so the
  // scene never jumps when a remark lands. A fixed two-line band held about
  // 136 px of run at 360 px with four seats while a full-cap remark needs
  // about 560, so its last line came out with an ellipsis on it: a defect
  // for a sentence (checklist item 15; cogchemists, 2026-08-24).
  function sayBand(ctx, layout) {
    var font = sayFontPx(layout);
    ctx.save();
    ctx.font = font + "px 'rajdhani', system-ui, sans-serif";
    var wide = ctx.measureText(WIDE_RUNE).width || font;
    ctx.restore();
    var usable = Math.max(12, panelContentW(layout) - 8);
    // +1 line of slack: word wrap leaves a ragged right edge, so the
    // arithmetic run length is a floor on the lines a real sentence needs,
    // not a ceiling.
    var needed = Math.max(2, Math.ceil(MAX_SAY * wide / usable) + 1);
    // The band never eats the panel: the block above it (sprite, bid card,
    // name, total, budget bar) keeps its share.
    var room = Math.max(2,
      Math.floor((layout.panelH * 0.55 - 6) / (font * 1.25)));
    var lines = Math.min(needed, room);
    return {
      font: font, lines: lines,
      height: Math.round(font * 1.25 * lines + 6)
    };
  }

  function drawSpentStrip(ctx, layout, view, seat, x, y, w) {
    // What this seat has already burned: one pip per card of the deck, lit
    // when the card is gone. In oshi-zumo it is a coins-spent bar instead.
    var pad = 2;
    if (view.mode === "goofspiel") {
      var cards = (seat.budgetFull === 91) ? 13 :
        Math.max(1, (seat.hand || []).length + (view.roundsPlayed || 0));
      var hand = {};
      (seat.hand || []).forEach(function (card) { hand[card] = true; });
      var pipW = Math.max(2, (w - (cards - 1) * pad) / cards);
      for (var i = 0; i < cards; i++) {
        var spent = !hand[i + 1];
        ctx.fillStyle = spent ? "rgba(242, 232, 216, 0.42)" :
          "rgba(242, 232, 216, 0.12)";
        ctx.fillRect(x + i * (pipW + pad), y, pipW, 5);
      }
    } else {
      var used = Math.max(0, Math.min(1,
        (seat.spent || 0) / (seat.budgetFull || 1)));
      ctx.fillStyle = "rgba(242, 232, 216, 0.12)";
      ctx.fillRect(x, y, w, 5);
      ctx.fillStyle = "rgba(242, 232, 216, 0.42)";
      ctx.fillRect(x, y, w * used, 5);
    }
  }

  function drawSeatPanel(ctx, images, layout, view, seat, index) {
    var x = layout.margin + index * layout.panelW;
    var y = layout.panelTop;
    var w = layout.panelW;
    var h = layout.panelH;
    var colour = C.seatColor(index);
    var hex = C.COLOR_HEX[colour];
    var pad = panelPad(layout);

    ctx.save();
    ctx.fillStyle = seat.winner ? C.rgba(hex, 0.12) : C.STRIP;
    ctx.strokeStyle = seat.winner ? C.rgba(hex, 0.85) :
      "rgba(242, 232, 216, 0.10)";
    ctx.lineWidth = seat.winner ? 2 : 1;
    roundRect(ctx, x + 2, y, w - 4, h, 6);
    ctx.fill();
    ctx.stroke();
    ctx.restore();

    var band = sayBand(ctx, layout);
    var bandH = band.height;
    var bodyH = h - bandH - pad * 2;
    // Two seats means very wide panels; the content block is centred inside
    // the panel rather than stretched to its edges.
    var contentW = panelContentW(layout);
    var contentX = x + (w - contentW) / 2;
    var cardH = Math.max(26, Math.min(bodyH * 0.52, contentW * 0.42, 92));
    var cardW = cardH * CARD_RATIO;
    var spriteSize = Math.max(18, Math.min(contentW - cardW - pad,
      bodyH * 0.52, cardH * 1.05));
    var sprite = images["soldier_" + colour + "_front.png"];
    var sx = contentX + spriteSize / 2;
    var sy = y + pad + spriteSize / 2;
    ctx.save();
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, sx - spriteSize / 2, sy - spriteSize / 2,
        spriteSize, spriteSize);
    } else {
      ctx.fillStyle = hex;
      ctx.fillRect(sx - spriteSize / 3, sy - spriteSize / 3,
        spriteSize / 1.5, spriteSize / 1.5);
    }
    ctx.restore();

    // This round's bid card, face down until the reveal, top right.
    var cardX = contentX + contentW - cardW;
    var cardY = y + pad;
    var flip = 1;
    if (view.revealAt) {
      flip = Math.max(0.08, Math.min(1, (view.now - view.revealAt) / REVEAL_MS));
    }
    if (typeof seat.bid === "number" && seat.bid >= 0) {
      var lift = seat.winner ? cardH * 0.1 * flip : 0;
      var sw = cardW * (0.55 + 0.45 * flip);
      drawCardFace(ctx, cardX + (cardW - sw) / 2, cardY - lift, sw, cardH,
        seat.bid, seat.winner ? hex : C.CARD_EDGE,
        { lift: !!seat.winner, tint: !!seat.winner });
    } else {
      drawCardBack(ctx, images, cardX, cardY, cardW, cardH);
    }

    // Name, running total, remaining-budget bar, spent strip.
    var textX = contentX;
    var textW = contentW;
    var flow = y + pad + Math.max(spriteSize, cardH) + Math.max(9,
      11 * layout.scale);
    ctx.save();
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.font = "600 " + Math.max(9, Math.round(13 * layout.scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = seat.winner ? C.AMBER : C.PAPER;
    ctx.fillText(C.ellipsize(ctx, seat.name || "", textW), textX, flow);
    ctx.font = "700 " + Math.max(10, Math.round(15 * layout.scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = C.AMBER;
    var totalText = view.mode === "oshizumo" ?
      (seat.coins + " coins") : (pointsText(seat.points) + " pts");
    var totalY = flow + Math.max(13, 17 * layout.scale);
    ctx.fillText(C.ellipsize(ctx, totalText, textW), textX, totalY);
    ctx.restore();

    var barY = totalY + Math.max(9, 11 * layout.scale);
    var full = seat.budgetFull || 1;
    var fill = Math.max(0, Math.min(1, (seat.budget || 0) / full));
    ctx.save();
    ctx.fillStyle = "rgba(242, 232, 216, 0.14)";
    ctx.fillRect(textX, barY, textW, 5);
    ctx.fillStyle = hex;
    ctx.fillRect(textX, barY, textW * fill, 5);
    ctx.restore();

    var stripY = barY + 9;
    if (stripY + 5 < y + h - bandH - 4) {
      drawSpentStrip(ctx, layout, view, seat, textX, stripY, textW);
    }

    // The say band, always reserved, drawn last.
    var bandY = y + h - bandH - 2;
    ctx.save();
    ctx.font = band.font + "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    if (seat.say) {
      ctx.fillStyle = "rgba(242, 232, 216, 0.90)";
      roundRect(ctx, contentX, bandY, contentW, bandH, 3);
      ctx.fill();
      ctx.fillStyle = C.INK;
      var lines = wrapLines(ctx, "\u201c" + seat.say + "\u201d",
        contentW - 8, band.lines);
      lines.forEach(function (line, i) {
        ctx.fillText(line, contentX + 4, bandY + 3 + i * band.font * 1.25);
      });
    } else {
      ctx.strokeStyle = "rgba(242, 232, 216, 0.10)";
      ctx.setLineDash([3, 3]);
      ctx.lineWidth = 1;
      roundRect(ctx, contentX, bandY, contentW, bandH, 3);
      ctx.stroke();
      ctx.setLineDash([]);
    }
    ctx.restore();
  }

  // ---- The gasp -------------------------------------------------------------

  function drawOverbid(ctx, layout, view) {
    if (!view.overbidAt) return;
    var age = view.now - view.overbidAt;
    if (age > OVERBID_MS) return;
    var alpha = 1 - Math.pow(age / OVERBID_MS, 3);
    var bandH = Math.max(26, Math.min(layout.topH * 0.42, 58));
    var y = layout.margin + Math.max(0, layout.topH / 2 - bandH / 2);
    ctx.save();
    ctx.globalAlpha = Math.max(0, alpha);
    ctx.fillStyle = C.rgba(C.AMBER, 0.88);
    ctx.fillRect(0, y, layout.w, bandH);
    ctx.fillStyle = C.INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(bandH * 0.52) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillText(C.ellipsize(ctx, "OVERBID", layout.w - 16),
      layout.w / 2, y + bandH / 2);
    ctx.restore();
  }

  // ---- The frame ------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    if (w < 60 || h < 60) return;
    var seats = view.seats || [];
    var layout = computeLayout(w, h, seats.length || 1);

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    if (view.mode === "oshizumo") {
      drawTrack(ctx, images, layout, view, view.now);
    } else {
      drawPrize(ctx, images, layout, view);
    }
    seats.forEach(function (seat, index) {
      drawSeatPanel(ctx, images, layout, view, seat, index);
    });
    // Above the board only, never into the transport band.
    drawOverbid(ctx, layout, view);
  }

  // ---- Effects --------------------------------------------------------------

  // Turns a growing event list into transient view effects: when the bids
  // were revealed, when the token was pushed, when the gasp fired.
  function makeGameEffects() {
    var seen = 0;
    var revealAt = null;
    var pushAt = null;
    var overbidAt = null;
    return {
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "prize") {
            revealAt = null;
            overbidAt = null;
          } else if (event.kind === "reveal") {
            revealAt = animate ? now : null;
            overbidAt = null;
          } else if (event.kind === "overbid") {
            overbidAt = animate ? now : null;
          } else if (event.kind === "push") {
            pushAt = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0; revealAt = null; pushAt = null; overbidAt = null;
      },
      view: function () {
        return { revealAt: revealAt, pushAt: pushAt, overbidAt: overbidAt };
      }
    };
  }

  // ---- Readouts -------------------------------------------------------------

  function modeOf(state, config) {
    return (state && state.mode) || (config && config.mode) || "goofspiel";
  }

  function clockText(state, config) {
    if (!state) return "";
    var mode = modeOf(state, config);
    var word = mode === "oshizumo" ? "OSHI-ZUMO" : "GOOFSPIEL";
    var total = state.maxRounds || (config && config.maxRounds) || 0;
    var shown = state.round >= 0 ? state.round + 1 : (state.roundsPlayed || 0);
    if (state.gameDone || state.done) shown = state.roundsPlayed || shown;
    var parts = [];
    // At 360 px the mode word goes: the round and the prize are what move.
    if (!narrow()) parts.push(word);
    parts.push("ROUND " + shown + (total ? " / " + total : ""));
    if (state.gameDone || state.done) {
      parts.push("FINAL");
    } else if (mode === "oshizumo") {
      parts.push("TOKEN " + (typeof state.position === "number" ?
        state.position : "?"));
    } else if (state.prize > 0) {
      parts.push("PRIZE " + state.prize);
    }
    return parts.join(" · ");
  }

  function paintScorebug(container, state, nameMap, config) {
    if (!container || !state || !state.seats) return;
    var mode = modeOf(state, config);
    var full = state.seats.length ? (state.seats[0].budgetFull || 1) : 1;
    container.className = state.seats.length <= 2 ? "seats2" : "";
    var html = "";
    state.seats.forEach(function (seat, index) {
      var policy = nameMap ? nameMap.seat(index) : seat.name;
      var alias = seat.name || "";
      var total = mode === "oshizumo" ? (seat.coins + " coins") :
        (pointsText(seat.points) + " pts");
      var fill = Math.max(0, Math.min(100,
        (seat.budget || 0) / (seat.budgetFull || full || 1) * 100));
      var bid = typeof seat.bid === "number" && seat.bid >= 0 ?
        '<span class="plate-bid">' + seat.bid + "</span>" : "";
      html += '<div class="plate ' + C.seatColor(index) +
        (seat.winner ? " plate-won" : "") + '">' +
        '<span class="plate-chip"></span>' +
        '<span class="plate-name">' +
        C.escapeHtml(C.clampName(policy)) + "</span>" +
        (alias && alias !== policy ?
          '<span class="plate-alias">' + C.escapeHtml(alias) + "</span>" : "") +
        '<span class="plate-score">' + C.escapeHtml(total) + "</span>" +
        '<span class="plate-bar"><span class="plate-bar-fill" style="width:' +
        fill.toFixed(1) + '%"></span></span>' + bid +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function endingLine(results) {
    if (!results) return "";
    var rounds = results.rounds || 0;
    switch (results.ending) {
      case "prizes-exhausted":
        return "complete — all " + rounds + " prizes awarded";
      case "pushout":
        return "complete — the token was pushed off the field";
      case "coins-exhausted":
        return "complete — both purses empty after " + rounds + " rounds";
      case "round-cap":
        return "complete — round cap reached with the token on cell " +
          results.finalPosition;
      case "wall-clock":
        return "deadline — stopped after " + rounds + " of " +
          (results.maxRounds || rounds) + " rounds";
      default:
        return results.reason || "";
    }
  }

  function paintEndcard(container, results, show, nameMap, config) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results) return;
    if (container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var mode = (results.mode) || (config && config.mode) || "goofspiel";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var points = results.points || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      return (scores[b] || 0) - (scores[a] || 0);
    });
    var top = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[top] || 0);
    });
    var verdict = !level && top >= 0 ?
      C.escapeHtml(names[top]) + " TAKES IT" : "ALL LEVEL";
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' +
      (!level && top >= 0 ? C.seatColor(top) : "") + '">' + verdict +
      "</div>" +
      '<div class="end-reason">' + C.escapeHtml(endingLine(results)) +
      "</div>" +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">' + (mode === "oshizumo" ? "result" : "points") +
      "</span>" +
      '<span class="end-head">spent</span>' +
      '<span class="end-head">fallbacks</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === top;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + C.seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' +
        C.escapeHtml(names[i] || "") + "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(pointsText(points[i] || 0)) +
        cell((results.spent || [])[i] || 0) +
        cell((results.fallbacks || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  // ---- Feed -----------------------------------------------------------------

  function verdictOf(event, nameMap, prize) {
    var winners = event.winners || [];
    var names = winners.map(function (seat) {
      return C.clampName(nameMap.seat(seat));
    });
    if (!winners.length) return "no bids";
    if (winners.length === 1) return names[0] + " takes " + prize;
    return names.join(" and ") + " split " +
      pointsText(prize / winners.length) + " each";
  }

  // Injected into the inherited renderFeed through GozuChrome.setFeedText.
  // `ctx` is the per-render scratch object renderFeed threads through the
  // events in order, so the prize of the round in progress rides on it.
  function feedLine(event, nameMap, ctx) {
    switch (event.kind) {
      case "start":
        return "Table set — sealed bids, nothing hidden but this round.";
      case "prize":
        ctx.prize = event.prize;
        return "PRIZE " + event.prize + " on the table" +
          ((event.prizesLeft || []).length ?
            " · still to come: " + event.prizesLeft.join(" ") : "");
      case "reveal":
        var lines = (event.bids || []).map(function (bid, seat) {
          var say = (event.says || [])[seat];
          return C.clampName(nameMap.seat(seat)) + " bids " + bid +
            (say ? " — “" + say + "”" : "");
        });
        if (feedMode === "oshizumo") {
          var delta = event.bids[0] === event.bids[1] ? 0 :
            (event.bids[0] > event.bids[1] ? 1 : -1);
          lines.push(delta === 0 ? "equal bids — no push" :
            C.clampName(nameMap.seat(delta > 0 ? 0 : 1)) + " pushes");
        } else {
          lines.push(verdictOf(event, nameMap, ctx.prize || 0));
        }
        return lines.join("\n");
      case "overbid":
        return "OVERBID — " + C.clampName(nameMap.seat(event.seat)) +
          " bids " + event.bid + " over " + event.over +
          " (margin " + event.margin + ")";
      case "push":
        return event.delta === 0 ? "the token holds at cell " +
          event.positionAfter :
          "the token slides to cell " + event.positionAfter;
      case "end":
        return "Final — " + (event.reason || "") + " / " +
          (event.ending || "") + " — scores " +
          (event.scores || []).map(function (s) {
            return s.toFixed(2);
          }).join(" · ");
      default:
        return JSON.stringify(event);
    }
  }

  // ---- Beats ----------------------------------------------------------------

  function beatLabel(event, nameMap) {
    switch (event.kind) {
      case "start": return "Episode start";
      case "prize": return "Round " + (event.round + 1) + ": prize " +
        event.prize;
      case "reveal": return "Round " + (event.round + 1) + ": bids revealed";
      case "overbid": return "Round " + (event.round + 1) + ": OVERBID by " +
        C.clampName(nameMap.seat(event.seat));
      case "push": return "Round " + (event.round + 1) + ": token to cell " +
        event.positionAfter;
      case "end": return "Final";
      default: return event.kind;
    }
  }

  function placeBeats(container, events, nameMap, onSeek) {
    events.forEach(function (event, index) {
      var seatClass = "";
      if (event.kind === "reveal" && (event.winners || []).length === 1) {
        seatClass = "seat" + (event.winners[0] % C.COLORS.length);
      } else if (event.kind === "overbid") {
        seatClass = "seat" + (event.seat % C.COLORS.length);
      }
      C.markRoundBeat(container, index, events.length, event.kind,
        beatLabel(event, nameMap), seatClass, onSeek);
    });
  }

  // ---- Drivers --------------------------------------------------------------

  function stateToView(state, nameMap, effects) {
    var view = effects.view();
    view.mode = state.mode || "goofspiel";
    view.seats = (state.seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.alias = seat.name;
      copy.name = C.clampName(nameMap.seat(i));
      return copy;
    });
    view.round = state.round;
    view.maxRounds = state.maxRounds || 0;
    view.roundsPlayed = state.roundsPlayed || 0;
    view.prize = state.prize;
    view.prizesLeft = state.prizesLeft || [];
    view.position = state.position;
    view.cells = state.cells || 0;
    view.push = state.push;
    view.margin = state.margin || 0;
    view.gameDone = !!state.gameDone;
    view.now = Date.now();
    return view;
  }

  // A player frame is redacted to its own seat, so it carries `seat` rather
  // than `seats`. Turn it into a one-panel table instead of drawing nothing.
  function normalizeLive(data) {
    if (data.seats) return data;
    var own = data.seat || {};
    return {
      mode: data.mode || "goofspiel",
      seats: [{
        name: data.name || "you",
        points: own.points || 0,
        score: own.score || 0,
        hand: own.hand || [],
        coins: own.coins || 0,
        bid: -1,
        say: "",
        spent: own.spent || 0,
        budget: own.coins || 0,
        budgetFull: own.coins || 1,
        winner: false
      }],
      round: typeof data.round === "number" ? data.round : -1,
      maxRounds: data.maxRounds || 0,
      roundsPlayed: data.roundsPlayed || 0,
      prize: -1,
      prizesLeft: [],
      position: data.position,
      cells: 0,
      gameDone: !!data.done,
      reason: data.reason || "",
      ending: data.ending || ""
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    C.setFeedText(feedLine);
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = C.makeNameMap([], null, []);
      var effects = makeGameEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = normalizeLive(data);
            if (latest) {
              feedMode = latest.mode || "goofspiel";
              nameMap = C.makeNameMap(
                (latest.seats || []).map(function (s) { return s.name; }),
                data.policyNames || latest.policyNames, []);
              effects.absorb(data.events || latest.events || []);
              if (options.feed) {
                C.renderFeed(options.feed, data.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = clockText(latest, latest);
              }
              paintScorebug(options.scorebug, latest, nameMap, latest);
            }
            if (data.type === "final") {
              paintEndcard(options.endscreen, data, true, nameMap, latest);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          renderer.draw(stateToView(latest, nameMap, effects));
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload, onFirstFrame}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = C.makeNameMap(payload.names, payload.policyNames, []);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var painted = false;
    feedMode = config.mode || "goofspiel";
    C.setFeedText(feedLine);

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeGameEffects();
      var scrub = C.buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      placeBeats(options.scrub, events, nameMap, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        var state = states[Math.min(index, states.length - 1)] ||
          { seats: [], mode: config.mode || "goofspiel", round: -1 };
        return state;
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) effects.reset();
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) C.renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = clockText(currentState(), config);
        }
        paintScorebug(options.scorebug, currentState(), nameMap, config);
        var atEnd = index >= events.length && events.length > 0;
        // EVERY seek dismisses the endcard: it stops at the transport band
        // and must never sit over a frame the viewer scrubbed back to.
        if (!atEnd && options.endscreen) {
          options.endscreen.classList.remove("show");
        }
        paintEndcard(options.endscreen, payload.results, atEnd, nameMap,
          config);
      }
      setIndex(0, true);
      C.relayout();

      (function frame(timestamp) {
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown ? (DWELL[shown.kind] || 700) : 600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw(stateToView(currentState(), nameMap, effects));
        if (!painted) {
          painted = true;
          // The attribute goes on the FIRST DRAWN FRAME, and only then does
          // the shell get to announce `ready` (chorus 3c11c953, 2026-08-24).
          document.documentElement.setAttribute("data-replay-loaded", "true");
          if (options.onFirstFrame) options.onFirstFrame();
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  window.GozuRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: C.renderFeed,
    bindFeedToggle: C.bindFeedToggle
  };
})();
