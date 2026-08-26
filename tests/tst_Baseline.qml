import QtQuick
import QtTest
import "../core/Baseline.js" as Baseline

// The baseline document and the comparison built on it.
//
// Two properties matter more than the rest, and both are about not lying.
//
// The document must never contain file *contents* — it is metadata, and a
// baseline that quietly became a backup would change where the file may live
// and who may read it.
//
// The comparison must distinguish "this changed" from "I could not tell". A
// check that was skipped this run must not be reported as a value that
// changed, because the reader would act on it.
TestCase {
  name: "Baseline"

  property var facts: ({
    omarchy: { version: "4.0.1-1", channel: "stable" },
    quickshell: { version: "0.3.1-1" },
    hyprland: {
      version: "0.56.2",
      bindingCount: 249,
      monitors: ["DP-2 2560x1440@143.93Hz"],
      files: [
        { path: "~/.config/hypr/bindings.lua", sha256: "aaaaaaaaaaaa", mtime: "2026-08-01T00:00:00Z", size: 5282 },
        { path: "~/.config/hypr/monitors.lua", sha256: "bbbbbbbbbbbb", mtime: "2026-08-01T00:00:00Z", size: 667 }
      ]
    },
    shell: { configFingerprint: "ce0741d6", configVersion: 1 },
    plugins: {
      thirdParty: [
        { id: "b.okomart", enabled: true, kinds: ["service"], version: "", gitHead: "", dirty: false },
        { id: "dev.git", enabled: true, kinds: ["bar-widget"], version: "", gitHead: "", dirty: false }
      ],
      gitState: {
        "b.okomart": { gitHead: "1111111111111111111111111111111111111111", dirty: false },
        "dev.git": { gitHead: "2222222222222222222222222222222222222222", dirty: true }
      }
    }
  })

  // ---- building --------------------------------------------------------

  function test_build_captures_the_documented_shape() {
    var baseline = Baseline.build(facts, "0.1.0", "2026-08-26T00:00:00Z")
    compare(baseline.schemaVersion, 1)
    compare(baseline.pluginVersion, "0.1.0")
    compare(baseline.createdAt, "2026-08-26T00:00:00Z")
    compare(baseline.omarchy.version, "4.0.1-1")
    compare(baseline.omarchy.channel, "stable")
    compare(baseline.quickshell.version, "0.3.1-1")
    compare(baseline.hyprland.version, "0.56.2")
    compare(baseline.shell.configFingerprint, "ce0741d6")
    compare(baseline.files.length, 2)
  }

  function test_build_joins_inventory_and_git_state() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    compare(baseline.plugins.length, 2)
    compare(baseline.plugins[0].id, "b.okomart")
    compare(baseline.plugins[0].gitHead.substring(0, 4), "1111")
    compare(baseline.plugins[0].dirty, false)
    compare(baseline.plugins[1].id, "dev.git")
    compare(baseline.plugins[1].dirty, true)
  }

  function test_build_never_carries_file_contents() {
    // §19: metadata only. If a `content`-shaped key ever appears in a built
    // baseline, this is where it gets caught.
    var withContents = JSON.parse(JSON.stringify(facts))
    withContents.hyprland.files[0].contents = "bind = SUPER, Q, killactive"
    var baseline = Baseline.build(withContents, "0.1.0", "now")
    var serialized = JSON.stringify(baseline)
    verify(serialized.indexOf("killactive") < 0)
  }

  function test_build_survives_missing_facts() {
    var baseline = Baseline.build({}, "0.1.0", "now")
    compare(baseline.schemaVersion, 1)
    compare(baseline.omarchy.version, "")
    compare(baseline.plugins.length, 0)
    compare(baseline.files.length, 0)

    var empty = Baseline.build(null, "", "")
    compare(empty.schemaVersion, 1)
  }

  // ---- reading back ----------------------------------------------------

  function test_parse_round_trips() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var parsed = Baseline.parse(JSON.stringify(baseline))
    compare(parsed.ok, true)
    compare(parsed.baseline.omarchy.version, "4.0.1-1")
  }

  function test_parse_rejects_malformed_and_shapeless() {
    compare(Baseline.parse("").ok, false)
    compare(Baseline.parse("{ not json").ok, false)
    compare(Baseline.parse("[]").ok, false)
    compare(Baseline.parse('{"omarchy":{}}').ok, false)
  }

  function test_parse_refuses_a_newer_schema_rather_than_misreading_it() {
    var parsed = Baseline.parse('{"schemaVersion": 99}')
    compare(parsed.ok, false)
    verify(parsed.error.indexOf("newer") > 0)
  }

  function test_summarize() {
    var baseline = Baseline.build(facts, "0.1.0", "2026-08-26T00:00:00Z")
    var summary = Baseline.summarize(baseline)
    compare(summary.present, true)
    compare(summary.omarchyVersion, "4.0.1-1")
    compare(summary.pluginCount, 2)
    compare(summary.fileCount, 2)
    compare(Baseline.summarize(null).present, false)
  }

  // ---- comparison ------------------------------------------------------

  function test_identical_state_reports_no_changes() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var comparison = Baseline.compare(baseline, facts)
    compare(comparison.comparable, true)
    compare(comparison.changes.length, 0)
  }

  function test_no_baseline_is_not_comparable() {
    var comparison = Baseline.compare(null, facts)
    compare(comparison.comparable, false)
    compare(comparison.changes.length, 0)
  }

  function test_version_change_is_reported_with_both_sides() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var now = JSON.parse(JSON.stringify(facts))
    now.omarchy.version = "4.1.0-1"
    var changes = Baseline.compare(baseline, now).changes
    compare(changes.length, 1)
    compare(changes[0].kind, "value")
    compare(changes[0].before, "4.0.1-1")
    compare(changes[0].after, "4.1.0-1")
  }

  function test_a_missing_value_is_not_a_change() {
    // The case that matters: a check was skipped this run, so the fact is
    // absent. Reporting "Quickshell version: 0.3.1-1 → " would be a finding
    // the reader might act on, and it would be wrong.
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var now = JSON.parse(JSON.stringify(facts))
    delete now.quickshell.version
    compare(Baseline.compare(baseline, now).changes.length, 0)
  }

  function test_shell_config_fingerprint_change() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var now = JSON.parse(JSON.stringify(facts))
    now.shell.configFingerprint = "ffffffff"
    var changes = Baseline.compare(baseline, now).changes
    compare(changes.length, 1)
    compare(changes[0].label, "shell.json")
  }

  // ---- files -----------------------------------------------------------

  function test_file_hash_change_is_detected() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var now = JSON.parse(JSON.stringify(facts))
    now.hyprland.files[0].sha256 = "cccccccccccc"
    var changes = Baseline.compare(baseline, now).changes
    compare(changes.length, 1)
    compare(changes[0].kind, "file-changed")
    compare(changes[0].label, "~/.config/hypr/bindings.lua")
  }

  function test_file_added_and_removed() {
    var baseline = Baseline.build(facts, "0.1.0", "now")

    var added = JSON.parse(JSON.stringify(facts))
    added.hyprland.files.push({ path: "~/.config/hypr/input.lua", sha256: "dddddddddddd" })
    compare(Baseline.compare(baseline, added).changes[0].kind, "file-added")

    var removed = JSON.parse(JSON.stringify(facts))
    removed.hyprland.files.pop()
    compare(Baseline.compare(baseline, removed).changes[0].kind, "file-removed")
  }

  function test_mtime_alone_is_not_a_change() {
    // Touching a file without editing it is not a change to report. The hash
    // is what decides.
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var now = JSON.parse(JSON.stringify(facts))
    now.hyprland.files[0].mtime = "2026-12-25T00:00:00Z"
    compare(Baseline.compare(baseline, now).changes.length, 0)
  }

  // ---- plugins ---------------------------------------------------------

  function test_plugin_added_and_removed() {
    var baseline = Baseline.build(facts, "0.1.0", "now")

    var added = JSON.parse(JSON.stringify(facts))
    added.plugins.thirdParty.push({ id: "new.plugin", enabled: true, kinds: [] })
    var addedChanges = Baseline.compare(baseline, added).changes
    compare(addedChanges.length, 1)
    compare(addedChanges[0].kind, "plugin-added")
    compare(addedChanges[0].label, "new.plugin")

    var removed = JSON.parse(JSON.stringify(facts))
    removed.plugins.thirdParty.pop()
    var removedChanges = Baseline.compare(baseline, removed).changes
    compare(removedChanges.length, 1)
    compare(removedChanges[0].kind, "plugin-removed")
  }

  function test_plugin_head_move_is_reported_short() {
    var baseline = Baseline.build(facts, "0.1.0", "now")
    var now = JSON.parse(JSON.stringify(facts))
    now.plugins.gitState["b.okomart"].gitHead = "3333333333333333333333333333333333333333"
    var changes = Baseline.compare(baseline, now).changes
    compare(changes.length, 1)
    compare(changes[0].kind, "plugin-updated")
    compare(changes[0].before, "1111111")
    compare(changes[0].after, "3333333")
  }

  function test_plugin_ids_containing_dots_survive() {
    // Plugin ids are dotted by convention, and the fact recorder treats dots
    // as nesting. If git state ever got written one fact per plugin, this is
    // where the shredded ids would show up.
    var baseline = Baseline.build(facts, "0.1.0", "now")
    compare(baseline.plugins[0].id, "b.okomart")
    verify(baseline.plugins[0].gitHead.length > 0)
  }

  function test_describeChange_is_readable_for_every_kind() {
    verify(Baseline.describeChange({ kind: "value", label: "Omarchy version", before: "a", after: "b" })
      .indexOf("→") > 0)
    verify(Baseline.describeChange({ kind: "file-changed", label: "x" }).indexOf("changed") > 0)
    verify(Baseline.describeChange({ kind: "plugin-added", label: "x" }).indexOf("added") >= 0)
    verify(Baseline.describeChange({ kind: "plugin-removed", label: "x" }).indexOf("removed") >= 0)
    verify(Baseline.describeChange({ kind: "plugin-updated", label: "x", before: "a", after: "b" })
      .indexOf("moved") > 0)
    // An unknown kind still produces something rather than "undefined".
    compare(Baseline.describeChange({ kind: "future", label: "x" }), "x")
  }
}
