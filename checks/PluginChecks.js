.pragma library
.import "../core/ResultModel.js" as R
.import "../parsers/Json.js" as Json
.import "../parsers/PluginList.js" as PluginList
.import "../parsers/GitStatus.js" as GitStatus

// Spec §17.4 — Plugins.
//
// These are the first checks in the catalog whose commands take a value the
// plugin did not author. `omarchy plugin list --json` returns ids that anyone
// who can create a directory under `~/.config/omarchy/plugins/` chooses, and
// those ids become both a path and an argv element.
//
// So every one of them is declared as a data argument with an allowed root
// (see docs/security.md), and the id's shape is checked before it is turned
// into a path at all. A `--` separator would be a third layer, but not every
// program takes one — `omarchy plugin validate` reads it as the folder name —
// which is exactly why the runner's leading-dash rule is the defence that
// carries the weight.

// How many third-party plugins one scan will validate or inspect. The cap
// exists because the scan has a time ceiling; it is announced in the result
// rather than applied silently, because a check that quietly stops early is
// worse than one that says it did.
var MAX_PLUGINS = 12

var DISCOVERY = {
  id: "plugins.discovery",
  title: "Installed plugins",
  category: "plugins",
  description: "Reads the plugin inventory the Omarchy CLI reports.",
  requiredCapabilities: ["omarchy.pluginList"],
  defaultSeverity: "warning",
  timeoutMs: 8000,
  run: function (ctx, done) {
    ctx.exec(["omarchy", "plugin", "list", "--json"], { timeoutMs: 8000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read the plugin list.",
          details: result.stderr ? [Json.clip(result.stderr, 5)] : [],
          evidence: [R.evidence("command", "omarchy plugin list --json", "exit " + result.exitCode)]
        })
        return
      }

      var parsed = PluginList.parse(result.stdout)
      if (!parsed.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "The plugin list could not be interpreted: " + parsed.error + ".",
          evidence: [R.evidence("command", "omarchy plugin list --json", Json.clip(result.stdout, 5))]
        })
        return
      }

      var counts = PluginList.counts(parsed)
      var third = PluginList.thirdParty(parsed)
      var names = []
      var inventory = []
      for (var i = 0; i < third.length; i++) {
        names.push(third[i].id)
        inventory.push({
          id: third[i].id,
          enabled: third[i].enabled,
          kinds: third[i].kinds,
          // Filled in by plugins.local-changes, which is the check that already
          // has to talk to git. Recorded here so the baseline has a complete
          // row per plugin even when that check is skipped.
          version: "",
          gitHead: "",
          dirty: false
        })
      }
      ctx.fact("plugins.thirdParty", inventory)
      ctx.fact("plugins.counts", counts)

      var details = []
      if (names.length > 0) details.push("Third-party: " + names.join(", ") + ".")

      done({
        status: R.STATUS.PASS,
        summary: counts.total + " plugins installed — " + counts.firstParty + " first-party, "
          + counts.thirdParty + " third-party, " + counts.enabled + " enabled.",
        details: details,
        evidence: [R.evidence("command", "omarchy plugin list --json",
          counts.total + " plugins")]
      })
    })
  }
}

var THIRD_PARTY_VALIDATION = {
  id: "plugins.third-party-validation",
  title: "Third-party plugin validity",
  category: "plugins",
  description: "Compares the plugin directories on disk against the plugins "
    + "the shell actually loaded, and validates anything it finds missing.",
  requiredCapabilities: ["omarchy.pluginList", "omarchy.pluginValidate"],
  defaultSeverity: "error",
  // Generous: each plugin gets its own 15 s budget (§23.6) and they run one at
  // a time, so the check's own watchdog has to allow for the whole sequence.
  timeoutMs: 60000,
  run: function (ctx, done) {
    var pluginsDir = String(ctx.paths.pluginsDir || "")
    if (pluginsDir.length === 0) {
      done(R.skippedResult(THIRD_PARTY_VALIDATION, "No plugin directory is known."))
      return
    }

    ctx.exec(["omarchy", "plugin", "list", "--json"], { timeoutMs: 8000 }, function (listResult) {
      if (!listResult.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read the plugin list.",
          evidence: [R.evidence("command", "omarchy plugin list --json", "exit " + listResult.exitCode)]
        })
        return
      }

      var parsed = PluginList.parse(listResult.stdout)
      if (!parsed.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "The plugin list could not be interpreted: " + parsed.error + "."
        })
        return
      }

      var known = {}
      for (var k = 0; k < parsed.plugins.length; k++) known[parsed.plugins[k].id] = true

      // A single level, bounded explicitly by -mindepth/-maxdepth. The argv
      // itself is the proof that this is not a recursive scan (§33.6), which
      // is why `find` is used rather than something that would need a flag
      // read carefully to know the same thing.
      ctx.exec(["find", pluginsDir, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\\n"],
        { timeoutMs: 5000, dataArgs: [1], allowedRoots: [pluginsDir] },
        function (findResult) {
          _validateAll(ctx, done, pluginsDir, parsed, known,
                       findResult.ok ? Json.nonEmptyLines(findResult.stdout) : null,
                       findResult.ok ? "" : "Could not list the plugin directory, so only "
                         + "plugins the shell already loaded were checked.")
        })
    })
  }
}

// The interesting half of this check.
//
// `omarchy plugin list --json` only reports plugins that already passed
// validation: PluginRegistry drops an invalid manifest during discovery, warns
// once into the shell log, and carries on. So a plugin can be installed,
// enabled in the past, and completely absent from every user-facing surface —
// with no indication anywhere the user is looking.
//
// Validating the plugins the CLI *does* list would therefore almost never find
// anything: they have already passed the same validator. Comparing the
// directories on disk against that list is what surfaces the failure that
// actually happens.
function _validateAll(ctx, done, pluginsDir, parsed, known, onDisk, listNote) {
  var notes = []
  if (listNote.length > 0) notes.push(listNote)

  var unloaded = []
  var unusable = []

  if (onDisk !== null) {
    for (var i = 0; i < onDisk.length; i++) {
      var name = onDisk[i]
      if (known[name]) continue
      if (!PluginList.isSafeId(name)) {
        // Also where a directory name containing a newline ends up, since it
        // arrives here as fragments. Reported rather than silently dropped.
        unusable.push(name)
        continue
      }
      unloaded.push(name)
    }
  }

  // Listed third-party plugins are still validated. It costs one command each
  // and it catches the case where the CLI validator and the shell's own
  // discovery ever disagree.
  var listed = PluginList.thirdParty(parsed)
  var targets = unloaded.slice()
  for (var t = 0; t < listed.length; t++) targets.push(listed[t].id)

  if (targets.length > MAX_PLUGINS) {
    notes.push("Only the first " + MAX_PLUGINS + " of " + targets.length
      + " plugin directories were validated, to stay inside the scan's time budget.")
    targets = targets.slice(0, MAX_PLUGINS)
  }

  var failures = []
  var validated = 0

  _forEachSeries(targets, function (id, next) {
    var directory = PluginList.directoryFor(pluginsDir, id)
    if (directory === "") {
      next()
      return
    }

    // No `--` here: `omarchy plugin validate` does not accept one — it reads it
    // as the folder to validate and fails with "plugin folder not found: --".
    // Verified on Omarchy 4.0.1. This is precisely why the runner's
    // leading-dash rule is the primary defence and a separator is only ever a
    // second layer where a program happens to support it.
    ctx.exec(["omarchy", "plugin", "validate", directory],
      { timeoutMs: 15000, dataArgs: [3], allowedRoots: [pluginsDir] },
      function (result) {
        if (result.blocked) {
          notes.push("Not checked: " + id + " (" + result.blockedReason + ")")
          next()
          return
        }
        validated++
        if (!result.ok) {
          var reason = String(result.stderr || result.stdout || "").trim()
          failures.push({
            id: id,
            loaded: known[id] === true,
            reason: reason.length > 0
              ? Json.clip(reason, 2, 200)
              : (result.timedOut ? "validation timed out" : "exit " + result.exitCode)
          })
        }
        next()
      })
  }, function () {
    var details = []
    var silent = 0

    for (var f = 0; f < failures.length; f++) {
      var failure = failures[f]
      if (!failure.loaded) silent++
      details.push(failure.id + (failure.loaded ? "" : " (installed but not loaded)")
        + " — " + failure.reason)
    }

    for (var u = 0; u < unusable.length; u++) {
      details.push("Ignored: a directory name that is not a usable plugin id")
    }

    details = details.concat(notes)

    if (failures.length === 0) {
      done({
        status: R.STATUS.PASS,
        summary: validated === 1
          ? "1 plugin directory validates cleanly."
          : validated + " plugin directories validate cleanly.",
        details: details
      })
      return
    }

    done({
      status: R.STATUS.FAIL,
      summary: silent > 0
        ? (silent === 1
            ? "1 installed plugin is invalid and is being silently ignored by the shell."
            : silent + " installed plugins are invalid and are being silently ignored by the shell.")
        : (failures.length === 1
            ? "1 plugin fails validation."
            : failures.length + " plugins fail validation."),
      details: details,
      remediation: silent > 0
        ? "The shell drops a plugin with an invalid manifest during discovery and only "
          + "warns once in its log, so it disappears from every menu without explanation. "
          + "Fix the manifest or remove the directory."
        : "Run `omarchy plugin validate ~/.config/omarchy/plugins/<id>` for the full output, "
          + "and consider disabling the plugin before updating."
    })
  })
}

var LOCAL_CHANGES = {
  id: "plugins.local-changes",
  title: "Local plugin modifications",
  category: "plugins",
  description: "Reports uncommitted changes inside git-managed plugin "
    + "checkouts. Informational — it explains why a plugin update might refuse "
    + "to fast-forward.",
  requiredCapabilities: ["omarchy.pluginList"],
  defaultSeverity: "info",
  timeoutMs: 45000,
  // Local edits are a fact about the machine, not a fault. They never move
  // readiness on their own.
  material: false,
  run: function (ctx, done) {
    _withThirdPartyPlugins(ctx, done, function (plugins, pluginsDir, notes) {
      if (plugins.length === 0) {
        done({
          status: R.STATUS.PASS,
          summary: "No third-party plugin checkouts to inspect.",
          details: notes,
          material: false
        })
        return
      }

      var dirty = []
      var inspected = 0
      // Collected into one map and recorded once at the end. A plugin id
      // legitimately contains dots — `p134c0d3.omapreflight` does — and
      // ctx.fact() reads dots as nesting, so writing one fact per plugin would
      // shred the ids into a tree.
      var gitState = {}

      _forEachSeries(plugins, function (plugin, next) {
        var directory = PluginList.directoryFor(pluginsDir, plugin.id)
        if (directory === "") {
          next()
          return
        }

        // `git -C <dir> status` only ever reads. Nothing fetches and no remote
        // is contacted (§17.4).
        ctx.exec(["git", "-C", directory, "status", "--porcelain=v1"],
          { timeoutMs: 8000, dataArgs: [2], allowedRoots: [pluginsDir] },
          function (statusResult) {
            // A plugin that is not a git checkout is normal, not an error.
            if (statusResult.blocked || !statusResult.ok) {
              next()
              return
            }
            inspected++

            var status = GitStatus.parseStatus(statusResult.stdout)
            if (status.clean) {
              ctx.exec(["git", "-C", directory, "rev-parse", "HEAD"],
                { timeoutMs: 5000, dataArgs: [2], allowedRoots: [pluginsDir] },
                function (headResult) {
                  var cleanHead = headResult.ok ? GitStatus.parseHead(headResult.stdout) : { sha: "" }
                  gitState[plugin.id] = { gitHead: String(cleanHead.sha || ""), dirty: false }
                  next()
                })
              return
            }

            ctx.exec(["git", "-C", directory, "rev-parse", "HEAD"],
              { timeoutMs: 5000, dataArgs: [2], allowedRoots: [pluginsDir] },
              function (headResult) {
                var head = headResult.ok ? GitStatus.parseHead(headResult.stdout) : { ok: false, sha: "", shortSha: "" }
                gitState[plugin.id] = { gitHead: String(head.sha || ""), dirty: true }
                dirty.push(plugin.id + " — " + GitStatus.describe(status)
                  + (head.ok ? " at " + head.shortSha : ""))
                next()
              })
          })
      }, function () {
        ctx.fact("plugins.gitState", gitState)
        var details = notes.concat(dirty)

        if (dirty.length === 0) {
          done({
            status: R.STATUS.PASS,
            summary: inspected === 0
              ? "No git-managed third-party plugins found."
              : "All " + inspected + " git-managed plugin checkouts are clean.",
            details: details,
            material: false
          })
          return
        }

        done({
          status: R.STATUS.WARN,
          summary: dirty.length === 1
            ? "1 plugin checkout has local changes."
            : dirty.length + " plugin checkouts have local changes.",
          details: details,
          material: false,
          remediation: "Local changes can stop `omarchy plugin update` from fast-forwarding. "
            + "Commit or stash them first if you want that plugin updated."
        })
      })
    })
  }
}

// ---- shared helpers ----------------------------------------------------

// Both plugin checks need the same inventory, and it comes from the same
// memoized command, so this costs one process for all of them.
function _withThirdPartyPlugins(ctx, done, callback) {
  var pluginsDir = String(ctx.paths.pluginsDir || "")
  if (pluginsDir.length === 0) {
    done(R.unknownResult({ id: "plugins" }, "No plugin directory is known."))
    return
  }

  ctx.exec(["omarchy", "plugin", "list", "--json"], { timeoutMs: 8000 }, function (result) {
    if (!result.ok) {
      done({
        status: R.STATUS.UNKNOWN,
        summary: "Could not read the plugin list.",
        evidence: [R.evidence("command", "omarchy plugin list --json", "exit " + result.exitCode)]
      })
      return
    }

    var parsed = PluginList.parse(result.stdout)
    if (!parsed.ok) {
      done({
        status: R.STATUS.UNKNOWN,
        summary: "The plugin list could not be interpreted: " + parsed.error + "."
      })
      return
    }

    var plugins = PluginList.thirdParty(parsed)
    var notes = []
    if (plugins.length > MAX_PLUGINS) {
      // Said out loud. A cap the reader does not know about turns a partial
      // answer into a false one.
      notes.push("Only the first " + MAX_PLUGINS + " of " + plugins.length
        + " third-party plugins were checked, to stay inside the scan's time budget.")
      plugins = plugins.slice(0, MAX_PLUGINS)
    }

    callback(plugins, pluginsDir, notes)
  })
}

// Serial iteration with a callback per item. The command runner serializes
// anyway; doing it explicitly here keeps the "one broken plugin does not stop
// the rest" guarantee visible in the control flow rather than implied by it.
function _forEachSeries(items, step, finished) {
  var index = 0
  function next() {
    if (index >= items.length) {
      finished()
      return
    }
    var item = items[index++]
    step(item, next)
  }
  next()
}

var ALL = [DISCOVERY, THIRD_PARTY_VALIDATION, LOCAL_CHANGES]
