import QtQuick
import QtTest
import "../core/Sanitizer.js" as Sanitizer

// Tests for report redaction (spec §25).
//
// These are the tests it is worth being pedantic about. Everything else in the
// plugin fails locally and visibly; a sanitization gap fails on someone else's
// screen, after the user has already pasted the report into a public issue.
//
// The negative cases matter as much as the positive ones. Redaction that eats
// the diagnostic content makes reports useless, which makes people stop
// sanitizing — so `127.0.0.1` and version numbers have to survive intact.
TestCase {
  name: "Sanitizer"

  property var ctx: Sanitizer.makeContext({ home: "/home/alice", user: "alice", host: "workstation" })

  // ---- paths -----------------------------------------------------------

  function test_home_path_becomes_tilde() {
    compare(Sanitizer.sanitize("/home/alice/.config/omarchy/shell.json", ctx),
            "~/.config/omarchy/shell.json")
  }

  function test_home_path_is_replaced_everywhere_it_appears() {
    compare(Sanitizer.sanitize("read /home/alice/a and /home/alice/b", ctx),
            "read ~/a and ~/b")
  }

  function test_other_users_home_directories_are_redacted() {
    compare(Sanitizer.sanitize("/home/bob/secret", ctx), "/home/<user>/secret")
  }

  function test_root_home_is_redacted() {
    verify(Sanitizer.sanitize("/root/.ssh/id_ed25519", ctx).indexOf("/root/") < 0)
  }

  function test_runtime_and_temp_paths() {
    compare(Sanitizer.sanitize("/run/user/1000/wayland-1", ctx), "/run/user/<uid>/wayland-1")
    compare(Sanitizer.sanitize("/tmp/omapreflight-XyZ123/lint", ctx), "/tmp/<temp>/lint")
  }

  // ---- names -----------------------------------------------------------

  function test_bare_username_is_redacted() {
    compare(Sanitizer.sanitize("started by alice", ctx), "started by <user>")
  }

  function test_username_is_matched_whole_word_only() {
    // "alice" must not turn "malice" into "m<user>".
    compare(Sanitizer.sanitize("malice and alicensing", ctx), "malice and alicensing")
  }

  function test_hostname_is_redacted() {
    compare(Sanitizer.sanitize("workstation.local is up", ctx), "<host>.local is up")
  }

  function test_missing_context_is_not_an_error() {
    var empty = Sanitizer.makeContext({})
    compare(Sanitizer.sanitize("plain text", empty), "plain text")
  }

  function test_very_short_names_are_not_used_as_patterns() {
    // A one- or two-character username would redact half the report.
    var shortCtx = Sanitizer.makeContext({ home: "", user: "a", host: "" })
    compare(Sanitizer.sanitize("a quick brown fox", shortCtx), "a quick brown fox")
  }

  // ---- addresses -------------------------------------------------------

  function test_mac_and_bluetooth_addresses() {
    compare(Sanitizer.sanitize("device AA:BB:CC:11:22:33 paired", ctx), "device <mac> paired")
  }

  function test_ipv4_is_redacted() {
    compare(Sanitizer.sanitize("gateway 192.168.1.1", ctx), "gateway <ip>")
  }

  function test_loopback_survives() {
    // Redacting 127.0.0.1 removes the diagnostic content and protects nothing.
    compare(Sanitizer.sanitize("bound to 127.0.0.1", ctx), "bound to 127.0.0.1")
    compare(Sanitizer.sanitize("listening on 0.0.0.0", ctx), "listening on 0.0.0.0")
  }

  function test_version_numbers_are_not_mistaken_for_addresses() {
    compare(Sanitizer.sanitize("Omarchy 4.0.1-1", ctx), "Omarchy 4.0.1-1")
    compare(Sanitizer.sanitize("Hyprland 0.56.2", ctx), "Hyprland 0.56.2")
    compare(Sanitizer.sanitize("Quickshell 0.3.1-1 (package quickshell).", ctx),
            "Quickshell 0.3.1-1 (package quickshell).")
  }

  function test_uuid_and_email() {
    compare(Sanitizer.sanitize("id 550e8400-e29b-41d4-a716-446655440000", ctx), "id <uuid>")
    compare(Sanitizer.sanitize("mail alice@example.com now", ctx), "mail <email> now")
  }

  // ---- secret-shaped lines ---------------------------------------------

  function test_key_value_secret_keeps_the_key() {
    // Keeping the key is deliberate: a reader needs to know a token was there.
    compare(Sanitizer.sanitize("api_key=sk-live-1234567890", ctx), "api_key= <redacted>")
    compare(Sanitizer.sanitize("Authorization: Bearer abcdef", ctx), "Authorization: <redacted>")
  }

  function test_secret_without_a_separator_loses_the_whole_line() {
    compare(Sanitizer.sanitize("my password hunter2", ctx), "<redacted line>")
  }

  function test_secret_redaction_is_per_line() {
    var input = "safe line\npassword: hunter2\nanother safe line"
    var out = Sanitizer.sanitize(input, ctx).split("\n")
    compare(out[0], "safe line")
    compare(out[1], "password: <redacted>")
    compare(out[2], "another safe line")
  }

  function test_secret_matching_is_case_insensitive() {
    verify(Sanitizer.sanitize("SECRET_TOKEN=abc", ctx).indexOf("abc") < 0)
    verify(Sanitizer.sanitize("PrivateKey: xyz", ctx).indexOf("xyz") < 0)
  }

  function test_ordinary_text_is_left_alone() {
    var text = "Hyprland reports no configuration errors."
    compare(Sanitizer.sanitize(text, ctx), text)
  }

  // ---- edges -----------------------------------------------------------

  function test_null_and_undefined_are_empty_strings() {
    compare(Sanitizer.sanitize(null, ctx), "")
    compare(Sanitizer.sanitize(undefined, ctx), "")
    compare(Sanitizer.sanitize("", ctx), "")
  }

  function test_non_string_input_is_coerced() {
    compare(Sanitizer.sanitize(42, ctx), "42")
  }

  // ---- whole results ---------------------------------------------------

  function test_sanitizeResult_covers_every_text_field() {
    var result = {
      id: "test.check", title: "T", category: "test", status: "fail", severity: "error",
      summary: "failed reading /home/alice/x",
      details: ["token=abc123", "at /home/alice/y"],
      evidence: [{ type: "command", label: "cat /home/alice/z", value: "gateway 10.0.0.1" }],
      remediation: "check /home/alice/z",
      material: true, startedAt: "now", durationMs: 5, fingerprint: "deadbeef"
    }

    var safe = Sanitizer.sanitizeResult(result, ctx)
    compare(safe.summary, "failed reading ~/x")
    compare(safe.details[0], "token= <redacted>")
    compare(safe.details[1], "at ~/y")
    compare(safe.evidence[0].label, "cat ~/z")
    compare(safe.evidence[0].value, "gateway <ip>")
    compare(safe.remediation, "check ~/z")

    // Structural fields are carried through untouched — they are what makes
    // the finding identifiable across scans.
    compare(safe.id, "test.check")
    compare(safe.status, "fail")
    compare(safe.fingerprint, "deadbeef")
  }

  function test_sanitizeResult_does_not_mutate_the_original() {
    var result = {
      id: "a", title: "A", category: "test", status: "pass",
      summary: "/home/alice/x", details: [], evidence: [], remediation: null
    }
    Sanitizer.sanitizeResult(result, ctx)
    compare(result.summary, "/home/alice/x")
  }

  function test_sanitizeResult_survives_missing_fields() {
    var safe = Sanitizer.sanitizeResult({ id: "a", status: "pass" }, ctx)
    compare(safe.details.length, 0)
    compare(safe.evidence.length, 0)
    compare(safe.remediation, null)
  }

  function test_sanitizeResult_passes_null_through() {
    compare(Sanitizer.sanitizeResult(null, ctx), null)
  }
}
