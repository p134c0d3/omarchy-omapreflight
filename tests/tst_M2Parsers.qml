import QtQuick
import QtTest
import "../parsers/PluginList.js" as PluginList
import "../parsers/SystemctlFailed.js" as SystemctlFailed
import "../parsers/DiskUsage.js" as DiskUsage
import "../parsers/GitStatus.js" as GitStatus
import "../parsers/FileMeta.js" as FileMeta
import "../parsers/OmarchyVersion.js" as OmarchyVersion

// Parsers added in Milestone 2, against the same matrix as the first set:
// valid, empty, malformed, and shapes a future version might produce.
//
// Two of these carry more weight than the rest. `PluginList.isSafeId` is the
// gate between a directory name anyone can create and a value that becomes a
// path and an argv element. `OmarchyVersion.compare` decides whether the
// recovery check says "you rolled back", and a version comparison that guesses
// is worse than one that admits it cannot tell.
TestCase {
  name: "M2Parsers"

  // ---- plugin list -----------------------------------------------------

  readonly property string pluginJson: '[' +
    '{"id":"akitaonrails.ai-usagebar","name":"AI Usage","kinds":["bar-widget"],' +
    '"enabled":true,"active":false,"canDisable":true,"firstParty":false,"clonedFrom":""},' +
    '{"id":"omarchy.bar","name":"Bar","kinds":["bar"],"enabled":true,"active":true,' +
    '"canDisable":false,"firstParty":true,"clonedFrom":""},' +
    '{"id":"b.okomart","name":"Okomart","kinds":["service","panel"],"enabled":false,' +
    '"active":false,"canDisable":true,"firstParty":false,"clonedFrom":""}]'

  function test_plugin_list_valid() {
    var parsed = PluginList.parse(pluginJson)
    compare(parsed.ok, true)
    compare(parsed.count, 3)
    compare(parsed.plugins[0].id, "akitaonrails.ai-usagebar")
  }

  function test_plugin_list_partitions_by_provenance() {
    var parsed = PluginList.parse(pluginJson)
    compare(PluginList.thirdParty(parsed).length, 2)
    compare(PluginList.enabled(parsed).length, 2)

    var counts = PluginList.counts(parsed)
    compare(counts.total, 3)
    compare(counts.firstParty, 1)
    compare(counts.thirdParty, 2)
  }

  function test_plugin_list_malformed_and_wrong_shape() {
    compare(PluginList.parse("").ok, false)
    compare(PluginList.parse("{}").ok, false)
    compare(PluginList.parse("not json").ok, false)
  }

  function test_plugin_list_skips_entries_without_an_id() {
    var parsed = PluginList.parse('[{"name":"nameless"},null,{"id":"real.one"}]')
    compare(parsed.ok, true)
    compare(parsed.count, 1)
    compare(parsed.plugins[0].id, "real.one")
  }

  function test_plugin_list_tolerates_future_fields() {
    var parsed = PluginList.parse('[{"id":"a.b","name":"A","kinds":[],"quantum":true}]')
    compare(parsed.ok, true)
    compare(parsed.count, 1)
  }

  // ---- plugin ids become paths and argv --------------------------------

  function test_safe_ids_are_accepted() {
    verify(PluginList.isSafeId("b.okomart"))
    verify(PluginList.isSafeId("p134c0d3.omapreflight"))
    verify(PluginList.isSafeId("akitaonrails.ai-usagebar"))
    verify(PluginList.isSafeId("A1"))
  }

  function test_hostile_ids_are_refused() {
    // Every one of these would otherwise become part of a path, an argv
    // element, or both.
    verify(!PluginList.isSafeId("../../etc/passwd"))
    verify(!PluginList.isSafeId(".."))
    verify(!PluginList.isSafeId("."))
    verify(!PluginList.isSafeId("-rf"))
    verify(!PluginList.isSafeId("a/b"))
    verify(!PluginList.isSafeId("a b"))
    verify(!PluginList.isSafeId(""))
    verify(!PluginList.isSafeId("$(whoami)"))
    verify(!PluginList.isSafeId("a;b"))
  }

  function test_directoryFor_refuses_to_build_a_path_from_a_bad_id() {
    compare(PluginList.directoryFor("/home/u/.config/omarchy/plugins", ".."), "")
    compare(PluginList.directoryFor("/home/u/.config/omarchy/plugins", "../../etc"), "")
    compare(PluginList.directoryFor("", "b.okomart"), "")
  }

  function test_directoryFor_builds_a_clean_path() {
    compare(PluginList.directoryFor("/home/u/.config/omarchy/plugins", "b.okomart"),
            "/home/u/.config/omarchy/plugins/b.okomart")
    // A trailing slash on the root must not produce a double slash.
    compare(PluginList.directoryFor("/home/u/.config/omarchy/plugins/", "b.okomart"),
            "/home/u/.config/omarchy/plugins/b.okomart")
  }

  // ---- systemctl -------------------------------------------------------

  function test_no_failed_units() {
    var parsed = SystemctlFailed.parse("")
    compare(parsed.count, 0)
  }

  function test_failed_units_are_listed() {
    var output = "● foo.service loaded failed failed Some description here\n"
      + "bar.timer loaded failed failed Another one"
    var parsed = SystemctlFailed.parse(output)
    compare(parsed.count, 2)
    compare(parsed.units[0].unit, "foo.service")
    compare(parsed.units[0].active, "failed")
    compare(parsed.units[1].unit, "bar.timer")
    compare(SystemctlFailed.unitNames(parsed).length, 2)
  }

  function test_leading_bullet_is_stripped_either_spelling() {
    compare(SystemctlFailed.parse("* baz.service loaded failed failed x").units[0].unit,
            "baz.service")
  }

  function test_lines_that_do_not_name_a_unit_are_ignored() {
    // A stray summary line from a systemd that ignored --no-legend must not
    // become a phantom failed service.
    var parsed = SystemctlFailed.parse("2 loaded units listed.\nfoo.service loaded failed failed x")
    compare(parsed.count, 1)
    compare(parsed.units[0].unit, "foo.service")
  }

  // ---- df --------------------------------------------------------------

  readonly property string dfOutput:
    "Filesystem       1024-blocks     Used Available Capacity Mounted on\n" +
    "/dev/mapper/root   486270976 68104880 415745440      15% /"

  function test_df_valid() {
    var usage = DiskUsage.parse(dfOutput)
    compare(usage.ok, true)
    compare(usage.mountedOn, "/")
    compare(usage.filesystem, "/dev/mapper/root")
    compare(usage.availableKiB, 415745440)
    verify(usage.availableGiB > 390 && usage.availableGiB < 400)
  }

  function test_df_handles_a_device_name_containing_spaces() {
    // Fields are read from the right precisely so this works.
    var output = "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
      + "my weird device 1000 500 500 50% /mnt/x"
    var usage = DiskUsage.parse(output)
    compare(usage.ok, true)
    compare(usage.filesystem, "my weird device")
    compare(usage.mountedOn, "/mnt/x")
  }

  function test_df_empty_and_malformed() {
    compare(DiskUsage.parse("").ok, false)
    compare(DiskUsage.parse("Filesystem 1024-blocks\n").ok, false)
    compare(DiskUsage.parse("header\nnot enough fields").ok, false)
  }

  function test_df_rejects_unreadable_block_counts() {
    var output = "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
      + "/dev/x - - - - /"
    compare(DiskUsage.parse(output).ok, false)
  }

  function test_disk_thresholds() {
    function usageWithGiB(gib) {
      return { ok: true, availableGiB: gib }
    }
    compare(DiskUsage.assess(usageWithGiB(50)).level, "ok")
    compare(DiskUsage.assess(usageWithGiB(4)).level, "low")
    compare(DiskUsage.assess(usageWithGiB(1)).level, "critical")
    // Exactly on a threshold is not below it.
    compare(DiskUsage.assess(usageWithGiB(5)).level, "ok")
    compare(DiskUsage.assess(usageWithGiB(2)).level, "low")
    compare(DiskUsage.assess(null).level, "unknown")
  }

  function test_formatGiB_scales_precision() {
    compare(DiskUsage.formatGiB(396.5), "397 GiB")
    compare(DiskUsage.formatGiB(396.4), "396 GiB")
    compare(DiskUsage.formatGiB(12.34), "12.3 GiB")
    compare(DiskUsage.formatGiB(1.234), "1.23 GiB")
    compare(DiskUsage.formatGiB(NaN), "unknown")
  }

  // ---- git -------------------------------------------------------------

  function test_git_status_clean() {
    var status = GitStatus.parseStatus("")
    compare(status.clean, true)
    compare(GitStatus.describe(status), "clean")
  }

  function test_git_status_counts_by_kind() {
    // Column-sensitive on purpose: " M" is modified in the worktree, "M " is
    // staged. A parser that trims the line cannot tell them apart.
    var status = GitStatus.parseStatus(" M README.md\n?? new.txt\nM  staged.qml\n")
    compare(status.total, 3)
    compare(status.modified, 1)
    compare(status.untracked, 1)
    compare(status.staged, 1)
    compare(status.clean, false)
  }

  function test_git_status_samples_are_capped() {
    var lines = ""
    for (var i = 0; i < 20; i++) lines += " M file" + i + ".txt\n"
    compare(GitStatus.parseStatus(lines).samples.length, 5)
  }

  function test_git_head_valid_and_invalid() {
    var head = GitStatus.parseHead("0c2cc2df5b3edbce40a7899e161660c5caee1ccd")
    compare(head.ok, true)
    compare(head.shortSha, "0c2cc2d")

    compare(GitStatus.parseHead("").ok, false)
    compare(GitStatus.parseHead("fatal: not a git repository").ok, false)
  }

  // ---- stat and sha256sum ----------------------------------------------

  function test_stat_parses_and_skips_error_lines() {
    var output = "5282 1787626873 /home/u/.config/hypr/bindings.lua\n"
      + "stat: cannot statx '/home/u/.config/hypr/nope.lua': No such file or directory\n"
      + "667 1787701694 /home/u/.config/hypr/monitors.lua"
    var stats = FileMeta.parseStat(output)
    compare(stats.count, 2)
    compare(stats.byPath["/home/u/.config/hypr/bindings.lua"].sizeBytes, 5282)
  }

  function test_sha256sum_parses_and_skips_error_lines() {
    var output = "a48a67100364032fa52f360ac12aa673caf6ff4d5ff951470d9084b734d48993  /home/u/a.lua\n"
      + "sha256sum: /home/u/nope.lua: No such file or directory"
    var hashes = FileMeta.parseHashes(output)
    compare(hashes.count, 1)
    compare(hashes.byPath["/home/u/a.lua"].substring(0, 8), "a48a6710")
  }

  function test_combine_marks_absent_files_absent() {
    var paths = ["/a", "/b"]
    var stats = FileMeta.parseStat("10 100 /a")
    var hashes = FileMeta.parseHashes(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /a")
    var files = FileMeta.combine(paths, stats, hashes)
    compare(files.length, 2)
    compare(files[0].present, true)
    compare(files[0].hash.length, 12)
    compare(files[1].present, false)
    compare(files[1].hash, "")
  }

  function test_isoFromMtime() {
    verify(FileMeta.isoFromMtime(1787626873).indexOf("20") === 0)
    compare(FileMeta.isoFromMtime(0), "")
    compare(FileMeta.isoFromMtime("nonsense"), "")
  }

  // ---- version ordering ------------------------------------------------

  function test_version_compare_orders_releases() {
    compare(OmarchyVersion.compare("4.0.1-1", "4.0.1-1"), 0)
    compare(OmarchyVersion.compare("4.0.2-1", "4.0.1-1"), 1)
    compare(OmarchyVersion.compare("4.0.1-1", "4.0.2-1"), -1)
    compare(OmarchyVersion.compare("4.0.1-2", "4.0.1-1"), 1)
    compare(OmarchyVersion.compare("5.0.0-1", "4.9.9-1"), 1)
  }

  function test_version_compare_is_numeric_not_lexical() {
    // The bug this exists for: string comparison puts "10" before "9".
    compare(OmarchyVersion.compare("4.10.0-1", "4.9.0-1"), 1)
  }

  function test_version_compare_handles_different_component_counts() {
    compare(OmarchyVersion.compare("4.0", "4.0.1"), -1)
    compare(OmarchyVersion.compare("4.0.1", "4.0"), 1)
  }

  function test_version_compare_admits_when_it_cannot_tell() {
    // The important case. A format this parser has never seen must produce
    // null, not a confident wrong answer.
    compare(OmarchyVersion.compare("4.0.1-rc2", "4.0.1-1"), null)
    compare(OmarchyVersion.compare("4.0.beta", "4.0.1"), null)
    compare(OmarchyVersion.compare("", "4.0.1-1"), null)
    compare(OmarchyVersion.compare("4.0.1-1", ""), null)
  }
}
