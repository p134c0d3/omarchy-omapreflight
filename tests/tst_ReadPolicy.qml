import QtQuick
import QtTest
import "../core/ReadPolicy.js" as ReadPolicy
import "../core/ExecPolicy.js" as ExecPolicy

// Tests for the file-read policy.
//
// The path allowlist in ExecPolicy decides what may be *named*. This module
// decides what may actually be opened and how much of it may be kept, which is
// the half a name cannot answer: an allowlisted path can be a symlink, a FIFO,
// or a file that grew to a gigabyte since the last scan.
//
// The commands themselves are verified against real coreutils behaviour under
// LC_ALL=C — `stat` without `-L` reporting "symbolic link", `dd` failing an
// O_NOFOLLOW open with ELOOP — so these tests pin the argv and the parsing
// that turn that behaviour into a check result.
//
// A failure here is a security regression, not a cosmetic one.
TestCase {
  name: "ReadPolicy"

  readonly property string target: "/home/u/.config/omarchy/shell.json"

  // ---- the probe -------------------------------------------------------

  function test_probe_does_not_dereference() {
    var argv = ReadPolicy.probeArgv(target)
    compare(argv[0], "stat")
    // `-L` would report a symlink as whatever it points at, which is precisely
    // the answer that must not be trusted.
    verify(argv.indexOf("-L") < 0)
    // `--` so a path can never be read as an option, on top of the leading-dash
    // rule in ExecPolicy.
    verify(argv.indexOf("--") < argv.length - 1)
    compare(argv[argv.length - 1], target)
  }

  function test_probe_argv_passes_the_execution_policy() {
    compare(ExecPolicy.validateArgv(ReadPolicy.probeArgv(target), {
      dataArgs: ReadPolicy.probeDataArgs(),
      allowedRoots: ["/home/u/.config/omarchy/"]
    }), "")
  }

  function test_probe_argv_is_refused_outside_the_roots() {
    verify(ExecPolicy.validateArgv(ReadPolicy.probeArgv("/etc/shadow"), {
      dataArgs: ReadPolicy.probeDataArgs(),
      allowedRoots: ["/home/u/.config/omarchy/"]
    }).indexOf("outside the permitted roots") > 0)
  }

  function test_parses_type_and_size() {
    var probe = ReadPolicy.parseProbe("regular file|5282\n")
    verify(probe.ok)
    compare(probe.type, "regular file")
    compare(probe.sizeBytes, 5282)
  }

  function test_parses_the_types_stat_actually_emits() {
    compare(ReadPolicy.parseProbe("symbolic link|11").type, "symbolic link")
    compare(ReadPolicy.parseProbe("fifo|0").type, "fifo")
    compare(ReadPolicy.parseProbe("directory|4096").type, "directory")
    compare(ReadPolicy.parseProbe("character special file|0").type, "character special file")
  }

  function test_unparseable_probe_is_not_a_silent_pass() {
    verify(!ReadPolicy.parseProbe("").ok)
    verify(!ReadPolicy.parseProbe("nonsense").ok)
    verify(!ReadPolicy.parseProbe("regular file|not-a-number").ok)
    verify(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("")) !== "")
  }

  // ---- what may be read ------------------------------------------------

  function test_a_regular_file_is_readable() {
    compare(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("regular file|5282")), "")
  }

  function test_an_empty_file_is_readable() {
    // GNU stat calls this "regular empty file", and an empty config file is an
    // ordinary thing for a check to have an opinion about.
    compare(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("regular empty file|0")), "")
  }

  function test_a_symlink_is_refused() {
    var refusal = ReadPolicy.probeRefusal(ReadPolicy.parseProbe("symbolic link|11"))
    verify(refusal.indexOf("symbolic link") >= 0)
    verify(refusal.indexOf("not a regular file") > 0)
  }

  function test_special_files_and_directories_are_refused() {
    verify(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("fifo|0")) !== "")
    verify(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("directory|4096")) !== "")
    verify(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("socket|0")) !== "")
    verify(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("character special file|0")) !== "")
    verify(ReadPolicy.probeRefusal(ReadPolicy.parseProbe("block special file|0")) !== "")
  }

  function test_an_oversized_file_is_refused_before_it_is_read() {
    var refusal = ReadPolicy.probeRefusal(
      ReadPolicy.parseProbe("regular file|" + (ReadPolicy.CEILING_BYTES + 1)))
    verify(refusal.indexOf("read limit") > 0)
  }

  function test_a_file_exactly_at_the_ceiling_is_allowed() {
    compare(ReadPolicy.probeRefusal(
      ReadPolicy.parseProbe("regular file|" + ReadPolicy.CEILING_BYTES)), "")
  }

  // ---- the read --------------------------------------------------------

  function test_read_opens_with_the_flags_that_carry_the_guarantee() {
    var argv = ReadPolicy.readArgv(target)
    compare(argv[0], "dd")
    compare(argv[1], "if=" + target)

    var flags = ""
    for (var i = 0; i < argv.length; i++) {
      if (argv[i].indexOf("iflag=") === 0) flags = argv[i].substring(6)
    }
    // O_NOFOLLOW: a symlink swapped in after the probe fails the open rather
    // than being followed. O_NONBLOCK: a FIFO cannot hang the scan.
    verify(flags.indexOf("nofollow") >= 0)
    verify(flags.indexOf("nonblock") >= 0)
    // count in bytes, and counted as data rather than as short reads, so the
    // ceiling is a ceiling.
    verify(flags.indexOf("count_bytes") >= 0)
    verify(flags.indexOf("fullblock") >= 0)
    verify(argv.indexOf("count=" + ReadPolicy.READ_BYTES) > 0)
  }

  function test_read_asks_for_one_byte_past_the_ceiling() {
    // So "too big" is observed rather than inferred from a length that landed
    // exactly on the limit.
    compare(ReadPolicy.READ_BYTES, ReadPolicy.CEILING_BYTES + 1)
  }

  function test_read_argv_passes_the_execution_policy() {
    compare(ExecPolicy.validateArgv(ReadPolicy.readArgv(target), {
      dataArgs: ReadPolicy.readDataArgs(),
      allowedRoots: ["/home/u/.config/omarchy/"]
    }), "")
  }

  function test_read_argv_is_path_checked_through_its_prefix() {
    // The path hides behind `if=`, and it is still subject to every path rule.
    var roots = ["/home/u/.config/omarchy/"]
    verify(ExecPolicy.validateArgv(ReadPolicy.readArgv("/etc/shadow"),
      { dataArgs: ReadPolicy.readDataArgs(), allowedRoots: roots })
      .indexOf("outside the permitted roots") > 0)
    verify(ExecPolicy.validateArgv(ReadPolicy.readArgv("/home/u/.config/omarchy/../../.ssh/id_ed25519"),
      { dataArgs: ReadPolicy.readDataArgs(), allowedRoots: roots })
      .indexOf("parent traversal") > 0)
  }

  function test_ceiling_overrun_is_detected_from_the_output() {
    var atLimit = new Array(ReadPolicy.CEILING_BYTES + 1).join("x")   // exactly the ceiling
    compare(atLimit.length, ReadPolicy.CEILING_BYTES)
    verify(!ReadPolicy.exceededCeiling(atLimit))
    verify(ReadPolicy.exceededCeiling(atLimit + "x"))
    verify(!ReadPolicy.exceededCeiling(""))
  }

  // ---- failures --------------------------------------------------------

  function test_missing_is_recognised_from_either_command() {
    verify(ReadPolicy.isMissing("stat: cannot statx '/x/shell.json': No such file or directory"))
    verify(ReadPolicy.isMissing("dd: failed to open '/x/shell.json': No such file or directory"))
    verify(!ReadPolicy.isMissing("dd: failed to open '/x/shell.json': Permission denied"))
    verify(!ReadPolicy.isMissing(""))
  }

  function test_failure_text_keeps_the_reason_and_drops_the_path() {
    // The caller already has the path; a home directory in an error string
    // only creates something else the report has to sanitize.
    compare(ReadPolicy.describeFailure(
      "dd: failed to open '/home/u/.config/omarchy/shell.json': Too many levels of symbolic links", "x"),
      "Too many levels of symbolic links")
    compare(ReadPolicy.describeFailure(
      "stat: cannot statx '/home/u/.config/omarchy/shell.json': Permission denied", "x"),
      "Permission denied")
  }

  function test_failure_text_falls_back_when_a_command_said_nothing() {
    compare(ReadPolicy.describeFailure("", "dd exited 1"), "dd exited 1")
    compare(ReadPolicy.describeFailure("   \n", "dd exited 1"), "dd exited 1")
  }

  function test_only_the_first_line_of_a_diagnostic_is_used() {
    compare(ReadPolicy.describeFailure("dd: failed to open '/x': Permission denied\nnoise\n", "x"),
      "Permission denied")
  }
}
