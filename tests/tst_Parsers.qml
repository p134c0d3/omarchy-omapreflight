import QtQuick
import QtTest
import "fixtures/CapturedOutput.js" as Captured
import "../parsers/Json.js" as Json
import "../parsers/OmarchyCommands.js" as OmarchyCommands
import "../parsers/OmarchyVersion.js" as OmarchyVersion
import "../parsers/HyprctlOutput.js" as HyprctlOutput
import "../parsers/PacmanQuery.js" as PacmanQuery
import "../parsers/ShellConfig.js" as ShellConfig

// Every parser, against the matrix the spec asks for: valid input, empty
// output, malformed output, and output carrying fields from a future version.
//
// The valid cases use output captured from a live machine rather than output
// invented to match the spec. That distinction has already paid for itself:
// `omarchy commands --json` returns an object with a `commands` array, not the
// bare array the spec assumed, and `omarchy plugin list --json` carries neither
// a source directory nor a version.
//
// The rule every one of these tests is really checking: a parser never throws
// and never guesses. It returns `ok: false` with a reason, and the check turns
// that into UNKNOWN.
TestCase {
  name: "Parsers"

  // ---- Json ------------------------------------------------------------

  function test_json_empty_is_not_ok() {
    var parsed = Json.parse("")
    compare(parsed.ok, false)
    compare(parsed.error, "empty output")
  }

  function test_json_whitespace_only_is_empty() {
    compare(Json.parse("   \n\n  ").ok, false)
  }

  function test_json_malformed_reports_why() {
    var parsed = Json.parse("{ not json")
    compare(parsed.ok, false)
    verify(parsed.error.indexOf("invalid JSON") === 0)
  }

  function test_json_shape_assertions() {
    compare(Json.parseArray("{}").ok, false)
    compare(Json.parseObject("[]").ok, false)
    compare(Json.parseArray("[1,2]").ok, true)
    compare(Json.parseObject('{"a":1}').ok, true)
  }

  function test_nonEmptyLines_drops_blanks_and_trims() {
    var lines = Json.nonEmptyLines("  a  \n\n   \n b\n")
    compare(lines.length, 2)
    compare(lines[0], "a")
    compare(lines[1], "b")
  }

  function test_clip_bounds_lines_and_characters() {
    var many = ""
    for (var i = 0; i < 100; i++) many += "line " + i + "\n"
    var clipped = Json.clip(many, 5)
    verify(clipped.split("\n").length <= 7)
    verify(clipped.indexOf("truncated") > 0)
  }

  function test_clip_leaves_short_text_alone() {
    compare(Json.clip("one\ntwo", 10), "one\ntwo")
  }

  // ---- omarchy commands ------------------------------------------------

  function test_commands_valid() {
    var catalog = OmarchyCommands.parse(Captured.OMARCHY_COMMANDS)
    compare(catalog.ok, true)
    verify(catalog.count > 0)
    compare(OmarchyCommands.hasRoute(catalog, "omarchy version"), true)
    compare(OmarchyCommands.hasRoute(catalog, "omarchy does not exist"), false)
  }

  function test_commands_privileged_route_is_present_but_not_callable() {
    // The distinction the whole snapshot story rests on: `omarchy snapshot`
    // exists and requires root, so it is discoverable and unusable.
    var catalog = OmarchyCommands.parse(Captured.OMARCHY_COMMANDS)
    compare(OmarchyCommands.hasRoute(catalog, "omarchy snapshot"), true)
    compare(OmarchyCommands.isCallable(catalog, "omarchy snapshot"), false)
    compare(OmarchyCommands.isCallable(catalog, "omarchy version"), true)
  }

  function test_commands_empty_output() {
    var catalog = OmarchyCommands.parse("")
    compare(catalog.ok, false)
    compare(catalog.count, 0)
    compare(OmarchyCommands.hasRoute(catalog, "omarchy version"), false)
  }

  function test_commands_malformed_output() {
    var catalog = OmarchyCommands.parse("<html>404</html>")
    compare(catalog.ok, false)
  }

  function test_commands_wrong_shape() {
    // A bare array is what the spec assumed the CLI returns. It does not, and
    // if it ever starts to, this must be a clean failure rather than a crash.
    compare(OmarchyCommands.parse('[{"route":"omarchy version"}]').ok, false)
    compare(OmarchyCommands.parse('{"ok":true}').ok, false)
  }

  function test_commands_tolerates_future_fields() {
    var payload = '{"ok":true,"nextGeneration":true,"commands":[' +
      '{"route":"omarchy warp","binary":"omarchy-warp","group":"warp","summary":"",' +
      '"requires_sudo":false,"hidden":false,"routes":["omarchy warp"],"quantum":42}]}'
    var catalog = OmarchyCommands.parse(payload)
    compare(catalog.ok, true)
    compare(OmarchyCommands.hasRoute(catalog, "omarchy warp"), true)
  }

  function test_commands_skips_hidden_routes() {
    var payload = '{"ok":true,"commands":[' +
      '{"route":"omarchy secret","hidden":true,"routes":["omarchy secret"]},' +
      '{"route":"omarchy shown","hidden":false,"routes":["omarchy shown"]}]}'
    var catalog = OmarchyCommands.parse(payload)
    compare(catalog.count, 1)
    compare(catalog.hiddenCount, 1)
    compare(OmarchyCommands.hasRoute(catalog, "omarchy secret"), false)
  }

  function test_commands_survives_junk_entries() {
    var payload = '{"ok":true,"commands":[null,42,"nonsense",' +
      '{"route":"omarchy real","routes":["omarchy real"]}]}'
    var catalog = OmarchyCommands.parse(payload)
    compare(catalog.ok, true)
    compare(catalog.count, 1)
  }

  // ---- omarchy version / channel ---------------------------------------

  function test_version_valid() {
    var parsed = OmarchyVersion.parseVersion(Captured.OMARCHY_VERSION)
    compare(parsed.ok, true)
    verify(parsed.version.length > 0)
  }

  function test_version_empty() {
    compare(OmarchyVersion.parseVersion("").ok, false)
  }

  function test_version_rejects_prose_but_keeps_it() {
    // The raw value is preserved so the UNKNOWN result can show what it saw.
    var parsed = OmarchyVersion.parseVersion("command not found")
    compare(parsed.ok, false)
    compare(parsed.version, "command not found")
  }

  function test_version_accepts_an_unfamiliar_shape() {
    // Refusing a future version format would be worse than recording it.
    compare(OmarchyVersion.parseVersion("5.0.0-rc.2+build7").ok, true)
  }

  function test_channel_known_and_unknown() {
    var known = OmarchyVersion.parseChannel(Captured.OMARCHY_CHANNEL)
    compare(known.ok, true)
    compare(known.known, true)

    var future = OmarchyVersion.parseChannel("canary")
    compare(future.ok, true)
    compare(future.known, false)
    compare(future.channel, "canary")
  }

  function test_channel_is_case_insensitive() {
    compare(OmarchyVersion.parseChannel("STABLE").channel, "stable")
    compare(OmarchyVersion.parseChannel("STABLE").known, true)
  }

  function test_version_components() {
    var parts = OmarchyVersion.components("4.0.1-1")
    compare(parts.upstream, "4.0.1")
    compare(parts.release, "1")
    compare(parts.parts.length, 3)
    compare(parts.parts[0], 4)
  }

  // ---- hyprctl ---------------------------------------------------------

  function test_configerrors_clean_output_is_no_errors() {
    // Hyprland 0.56.2 prints blank lines when there is nothing wrong. Counting
    // those as errors would make every scan report a phantom failure.
    var parsed = HyprctlOutput.parseConfigErrors(Captured.HYPRCTL_CONFIGERRORS_CLEAN)
    compare(parsed.count, 0)
  }

  function test_configerrors_banner_variants_are_clean() {
    compare(HyprctlOutput.parseConfigErrors("no config errors!").count, 0)
    compare(HyprctlOutput.parseConfigErrors("No Config Errors").count, 0)
  }

  function test_configerrors_real_errors_are_reported() {
    var parsed = HyprctlOutput.parseConfigErrors(
      "Config error in line 12: unknown keyword 'blurr'\nConfig error in line 40: bad value")
    compare(parsed.count, 2)
    verify(parsed.errors[0].indexOf("line 12") > 0)
  }

  function test_hyprctl_version_valid() {
    var parsed = HyprctlOutput.parseVersion(Captured.HYPRCTL_VERSION)
    compare(parsed.ok, true)
    verify(parsed.version.length > 0)
  }

  function test_hyprctl_version_empty_and_malformed() {
    compare(HyprctlOutput.parseVersion("").ok, false)
    compare(HyprctlOutput.parseVersion("something else entirely").ok, false)
  }

  function test_monitors_valid() {
    var parsed = HyprctlOutput.parseMonitors(Captured.HYPRCTL_MONITORS)
    compare(parsed.ok, true)
    verify(parsed.count >= 1)
    verify(parsed.monitors[0].name.length > 0)
    verify(parsed.monitors[0].width > 0)
  }

  function test_monitors_malformed_and_wrong_shape() {
    compare(HyprctlOutput.parseMonitors("not json").ok, false)
    compare(HyprctlOutput.parseMonitors('{"name":"DP-1"}').ok, false)
  }

  function test_monitors_counts_disabled() {
    var payload = '[{"name":"DP-1","disabled":true},{"name":"DP-2","disabled":false}]'
    var parsed = HyprctlOutput.parseMonitors(payload)
    compare(parsed.count, 2)
    compare(parsed.disabledCount, 1)
  }

  function test_binds_valid() {
    var parsed = HyprctlOutput.parseBinds(Captured.HYPRCTL_BINDS)
    compare(parsed.ok, true)
    verify(parsed.count >= 1)
  }

  function test_binds_empty_array_is_valid() {
    var parsed = HyprctlOutput.parseBinds("[]")
    compare(parsed.ok, true)
    compare(parsed.count, 0)
  }

  function test_binds_malformed() {
    compare(HyprctlOutput.parseBinds("").ok, false)
    compare(HyprctlOutput.parseBinds("{}").ok, false)
  }

  // ---- pacman ----------------------------------------------------------

  function test_pacman_owner_valid() {
    var parsed = PacmanQuery.parseOwner(Captured.PACMAN_OWNER)
    compare(parsed.ok, true)
    verify(parsed.packageName.length > 0)
    verify(parsed.version.length > 0)
  }

  function test_pacman_owner_not_owned() {
    // pacman writes this to stderr, but a parser must not fall over if it ends
    // up in the stream it is handed.
    var parsed = PacmanQuery.parseOwner("error: No package owns /usr/bin/quickshell")
    compare(parsed.ok, false)
  }

  function test_pacman_owner_empty() {
    compare(PacmanQuery.parseOwner("").ok, false)
  }

  function test_pacman_query_partial_results() {
    // With several names, pacman prints the ones it found and errors on the
    // rest, so stdout is parsed regardless of the exit code.
    var parsed = PacmanQuery.parseQuery("quickshell 0.3.1-1\nomarchy 4.0.1-1\n")
    compare(parsed.ok, true)
    compare(parsed.count, 2)
    compare(parsed.packages["omarchy"], "4.0.1-1")
  }

  // ---- shell.json ------------------------------------------------------

  function test_shell_config_valid() {
    var parsed = ShellConfig.parse(Captured.SHELL_JSON)
    compare(parsed.ok, true)
    compare(parsed.version, 1)
    compare(parsed.versionSupported, true)
    compare(parsed.hasBar, true)
    verify(parsed.barSections.length > 0)
  }

  function test_shell_config_malformed() {
    var parsed = ShellConfig.parse('{"version": 1,')
    compare(parsed.ok, false)
    compare(parsed.versionSupported, false)
  }

  function test_shell_config_future_schema_is_unsupported_not_broken() {
    var parsed = ShellConfig.parse('{"version": 99}')
    compare(parsed.ok, true)
    compare(parsed.version, 99)
    compare(parsed.versionSupported, false)
  }

  function test_shell_config_without_version() {
    var parsed = ShellConfig.parse('{"bar":{}}')
    compare(parsed.ok, true)
    compare(parsed.version, null)
    compare(parsed.versionSupported, false)
  }

  function test_shell_config_tolerates_unexpected_types() {
    var parsed = ShellConfig.parse('{"version":"one","bar":42,"plugins":[]}')
    compare(parsed.ok, true)
    compare(parsed.version, null)
    compare(parsed.hasBar, false)
    compare(parsed.pluginEntryCount, 0)
  }

  function test_shell_config_counts_layout_entries() {
    var payload = '{"version":1,"bar":{"position":"top","layout":' +
      '{"left":[{"id":"a"},{"id":"b"}],"right":[{"id":"c"}]}}}'
    var parsed = ShellConfig.parse(payload)
    compare(parsed.barWidgetCount, 3)
    compare(parsed.barWidgetIds.length, 3)
    compare(parsed.barPosition, "top")
  }
}
