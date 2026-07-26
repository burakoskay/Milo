# Security Policy

Milo is a single-maintainer project. It is pre-1.0 software distributed as a **Development
Preview**, and it performs privileged operations — it signals processes and, with explicit user
approval, runs a fixed set of commands as root. Security reports are taken seriously.

## Supported versions

| Version | Supported |
|---|---|
| Latest public release | Yes |
| Older releases | No, unless a release note says otherwise |
| Unofficial builds, forks, or modified binaries | No |

Fixes land on `main` and in the next tagged release.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting:**

**[Report a vulnerability →](https://github.com/burakoskay/Milo/security/advisories/new)**

That opens a private advisory visible only to the maintainer. No email address is required and
nothing is disclosed publicly while the issue is being investigated.

**Please do not open a public issue** for anything affecting privilege escalation, the
privileged helper's XPC authentication or command policy, process-identity validation, code
signature verification, or the update path.

Ordinary bugs — a process that will not terminate, a tuning recipe that does not revert, a UI
defect — belong in normal public issues.

### What helps

- The Milo version, from the About section in Settings.
- Your macOS version and whether SIP is enabled.
- Concrete reproduction steps, and what an attacker gains.
- Whether the privileged helper was enabled at the time.

### Response

This is a personal project without an on-call rotation, so no response-time guarantee is
offered. Reports are typically acknowledged within a few days. Reports involving privilege
escalation or code-signature bypass are handled ahead of everything else.

You will be credited in the release notes unless you prefer otherwise.

## Security design

The properties a report should try to break:

- **Process identity.** Every action carries PID, absolute executable path, and kernel process
  start time. That identity is revalidated by the app before `SIGTERM` and before `SIGKILL`, and
  again independently by the helper before any privileged signal. A PID alone is never
  sufficient.
- **Helper authentication.** The privileged helper verifies the calling process's Team ID and
  signing identifier, and refuses a client running as root. Authentication is enforced in both
  directions.
- **No shell.** Privileged commands are executed via direct `argv`, never through a shell. A
  fixed executable and argument grammar rejects anything outside it. This is enforced by
  regression tests that fail the build if `/bin/sh`, `Process()`, or `NSAppleScript` appear in
  the helper.
- **Bounded execution.** Request size, output size, and execution deadline are all capped, and
  output truncation surfaces as an explicit failure rather than a silent partial result.
- **Runtime integrity.** The app validates its own code signature against an expected Team ID
  and bundle identifier at launch.

## Known limitations

Stated plainly, because they affect what a report should be measured against:

- **Releases are not notarized.** Builds are Apple Development signed. Gatekeeper blocks the
  first launch by design. Verify the SHA-256 published in the release notes before running a
  download.
- **Automatic updates are disabled** in preview builds, so there is no in-app delivery channel
  for a fix. Users must download a new release.
- **The privileged execution path has not been exercised end-to-end against a disposable
  root-owned fixture**, and System Tuning has not been validated on clean virtual machines
  across every supported macOS release. Both are tracked in [ROADMAP.md](ROADMAP.md).
- **No independent security assessment has been performed.**

Commercial licensing, payment, and backend components referenced elsewhere in the project's
history are **not part of this repository** and are not in scope for reports here.
