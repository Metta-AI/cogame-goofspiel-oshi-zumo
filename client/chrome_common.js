// goofspiel-oshi-zumo chrome: the cogame-babel chrome, COPIED.
//
// Every numbered region below is a byte-for-byte copy of the named lines of
// `client/renderer.js` in cogame-babel at commit d55d999 ("0.1.4: static
// viewer announces loading/ready/error to its host"). Nothing in a copied
// region is rewritten, renamed in place, or tidied: the starter's naming,
// escaping, feed insertion and transport behaviour are proven, and a rewrite
// of working chrome is a defect, not an improvement
// (cogame-gridlock, 2026-08-23).
//
// EXACTLY ONE copied line is edited, and it is named here so a reviewer can
// find it: inside `renderFeed`, babel's direct call to
// `describeEvent(event, nameMap, ctx)` becomes `feedText(event, nameMap, ctx)`,
// where `feedText` is injected once by `GozuChrome.setFeedText(fn)` from the
// game block (client/renderer.js). Babel's game-specific procs
// (describeEvent, spellTokens, endText, phaseText, matchHeader, stateToView,
// attachLive, attachReplay and the scene/glyph/ribbon drawing) are NOT copied;
// their replacements live in the game block.
//
// Everything after the "goofspiel-oshi-zumo additions" banner is APPENDED, not
// spliced into a copied region: relayout(), markRoundBeat() and setFeedText().
//
// tools/ci/chrome_scope_check.mjs asserts the region markers are still here
// and that the game block re-declares none of the identifiers exported below.
(function () {
  "use strict";

  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 20-37 ----
  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Babel
  // seats four cogs: red, blue, green, yellow. The extra colours stay so
  // the chrome's seatN classes keep lining up with the CSS.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  var STRIP = "rgba(242, 232, 216, 0.06)";

  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 85-87 ----
  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 101-127 ----
  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // Nominal cog size; everything around a cog is measured as a multiple of
  // it so the whole seat block scales as one unit.

  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 327-334 ----
  // The seat whose decision the table is waiting on.
  function pendingSeat(phase, pairs) {
    var m = /^(speak|pick)([01])$/.exec(phase || "");
    if (!m) return -1;
    var pair = pairs[Number(m[2])];
    if (!pair) return -1;
    return m[1] === "speak" ? pair.speaker : pair.listener;
  }

  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 680-734 ----
  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }


  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 735-745 ----
  // ---- Event feed ----------------------------------------------------------

  // Round numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first round event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "round") return events[i].round === 1 ? 1 : 0;
    }
    return 0;
  }


  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 790-864 ----
  // (THE ONE EDIT: describeEvent -> feedText, injected by setFeedText)
  function blockHead(block) {
    return block < 0 ? "SETUP" : "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { pairs: null, successes: 0, pairRounds: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      if (event.kind === "round") ctx.pairs = event.pairs || [];
      if (event.kind === "pick") {
        ctx.pairRounds += 1;
        if (event.correct) ctx.successes += 1;
      }
      var scored = event.kind === "pick" && event.correct;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "speak" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (scored ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(feedText(event, nameMap, ctx)) + "</div>";
      // Notes: say-styled, only when the seat's notes changed.
      if ((event.kind === "speak" || event.kind === "pick") && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }


  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 865-901 ----
  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // per pair, when its message landed (the ribbon slides in from it) and
  // when its pick landed (the verdict flash fades from it).
  function makeEffects() {
    var seen = 0;
    var speakAt = [null, null];
    var pickAt = [null, null];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest events get to animate — replaying every historical
      // verdict as a fresh flash would strobe the table.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "round") {
            speakAt = [null, null];
            pickAt = [null, null];
          } else if (event.kind === "speak") {
            speakAt[event.pair] = animate ? now : null;
          } else if (event.kind === "pick") {
            pickAt[event.pair] = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0; speakAt = [null, null]; pickAt = [null, null];
      },
      view: function () {
        return { effects: { speakAt: speakAt.slice(), pickAt: pickAt.slice() } };
      }
    };
  }


  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 934-1049 ----
  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var pending = pendingSeat(state.phase, state.pairs || []);
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.asSpeaker || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      for (var q = 0; q < Math.min(seat.asListener || 0, 12); q++) {
        pips += '<span class="plate-pip hollow"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (pending === index && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + (seat.correct || 0) + "</span>" +
        '<span class="plate-label">correct</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.rounds || 0) +
          " of " + (results.maxRounds || results.rounds || 0) + " rounds";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var correct = results.correct || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (correct[b] || 0) - (correct[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " LEADS THE TABLE" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">correct</span>' +
      '<span class="end-head">as speaker</span>' +
      '<span class="end-head">as listener</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(correct[i] || 0) +
        cell((results.asSpeaker || [])[i] || 0) +
        cell((results.asListener || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }


  // ---- copied from cogame-babel@d55d999 client/renderer.js lines 1145-1222 ----
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "pick" && kind !== "end") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "pick" && event.correct ?
          " seat" + (event.seat % COLORS.length) : "") +
        (kind === "end" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  // ===== goofspiel-oshi-zumo additions to the inherited cogame-babel chrome =====

  // The feed's line text is game-specific. The copied `renderFeed` above
  // calls `feedText`; the game block injects the real one exactly once, and
  // nothing in a copied region had to change to make that work.
  var feedText = function (event) { return JSON.stringify(event); };
  function setFeedText(fn) {
    if (typeof fn === "function") feedText = fn;
  }

  // relayout(): the transport contract. `--band` is the MEASURED height of
  // the transport strip and `--hudscale` the chrome's single scale factor,
  // both set on :root, so nothing is ever overlaid in the transport band --
  // the endcard stops at `bottom: var(--band, 0px)` and the scrubber and play
  // button stay clickable at every width. Runs on load, on resize, and on
  // every feed toggle (bindFeedToggle dispatches a resize).
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var band = transport ? Math.round(transport.offsetHeight) : 0;
    root.style.setProperty("--band", band + "px");
    var scale = Math.max(0.72, Math.min(window.innerWidth / 1280, 1));
    root.style.setProperty("--hudscale", scale.toFixed(3));
  }
  window.addEventListener("load", relayout);
  window.addEventListener("resize", relayout);

  // markRoundBeat(): one LABELLED, CLICKABLE beat on the scrubber per
  // recorded event. It is called markRoundBeat and NOT markBeat on purpose:
  // a game-block `function markBeat` is hoisted over the chrome alias
  // `var markBeat = C.markBeat` and silently turns every beat into an
  // unlabelled div that never seeks (tandem, 2026-08-23).
  function markRoundBeat(container, index, total, kind, label, seatClass,
      onSeek) {
    if (!container || !total) return null;
    var beat = document.createElement("button");
    beat.type = "button";
    beat.className = "beat-marker beat-" + kind +
      (seatClass ? " " + seatClass : "");
    beat.style.left = ((index + 1) / total * 100) + "%";
    beat.setAttribute("aria-label", label);
    beat.title = label;
    // The scrub track seeks on pointerdown; let the button own its own hit
    // area so a click on a beat lands exactly on that event.
    beat.addEventListener("pointerdown", function (evt) {
      evt.stopPropagation();
    });
    beat.addEventListener("click", function (evt) {
      evt.stopPropagation();
      evt.preventDefault();
      if (onSeek) onSeek(index + 1);
    });
    container.appendChild(beat);
    return beat;
  }

  window.GozuChrome = {
    COLORS: COLORS,
    COLOR_HEX: COLOR_HEX,
    PAPER: PAPER,
    INK: INK,
    AMBER: AMBER,
    GHOST: GHOST,
    CARD_EDGE: CARD_EDGE,
    STRIP: STRIP,
    seatColor: seatColor,
    ellipsize: ellipsize,
    hexToRgb: hexToRgb,
    shade: shade,
    rgba: rgba,
    pendingSeat: pendingSeat,
    isBaselineFiller: isBaselineFiller,
    makeNameMap: makeNameMap,
    applyNames: applyNames,
    clampName: clampName,
    roundBase: roundBase,
    blockHead: blockHead,
    renderFeed: renderFeed,
    escapeHtml: escapeHtml,
    makeEffects: makeEffects,
    updateScorebug: updateScorebug,
    reasonLine: reasonLine,
    updateEndscreen: updateEndscreen,
    bindFeedToggle: bindFeedToggle,
    buildScrub: buildScrub,
    relayout: relayout,
    markRoundBeat: markRoundBeat,
    setFeedText: setFeedText
  };
})();
