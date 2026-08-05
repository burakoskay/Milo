# Disposable-VM verification runbook

Four items in `HANDOFF.md` section 18 are blocked on the same missing thing: a Mac that can be
broken and thrown away, running default security settings.

| Blocked item | Why this host cannot serve |
|---|---|
| Restart Helper recovery, including the `requiresApproval` branch | Exercising it means unregistering a helper the developer is relying on |
| Helper PID/path/start-time **rejection** paths | Needs a disposable root-owned fixture built in a controlled environment |
| The `system`-domain branch of the launchd disable | Needs a respawning root daemon; only a user agent has been measured |
| System Tuning recipe matrix, and Gatekeeper first-launch | **SIP is disabled on this host.** No result here transfers to a user's Mac |

The last row is the one that makes this infrastructure rather than a chore. It cannot be fixed by
being careful — a machine with SIP off is structurally unable to answer those questions, and it is
also the machine that signs the builds, so it can never test a quarantined first launch honestly.

`Tools/vm-verify.sh` is the harness. This document is how to get a VM for it to run on.

## 1. Build the VM

Apple silicon hosts can run macOS guests through `Virtualization.framework`. Any of the usual
front-ends work; `tart` is the one worth scripting against, because it is CLI-first and its images
are versioned.

```bash
brew install cirruslabs/cli/tart
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest milo-verify
tart set milo-verify --cpu 4 --memory 8192
tart run milo-verify
```

Three properties matter more than the tool:

- **Default security.** Do not disable SIP. Do not lower the startup security policy. The entire
  reason for the VM is to be the machine this host is not.
- **A clean snapshot before anything is installed.** Every check below is destructive, and the
  point of a VM is that re-running a check is cheap. Without a snapshot it is not.
- **A guest OS matching a supported release.** macOS 13 is Milo's floor. The discovery
  `criticalExecutablePaths` list and the `criticalLaunchdLabels` list are both keyed on values
  Apple moves between releases, so "it passed on 27.0" is a statement about 27.0 only.

Take the snapshot now, before Milo exists on the guest.

## 2. Mark the VM as disposable

Inside the guest:

```bash
sudo touch /etc/milo-disposable-vm
```

`Tools/vm-verify.sh` refuses every destructive check unless **both** `kern.hv_vmm_present` is `1`
**and** that marker exists. Two conditions and no environment-variable override, because a single
check is one typo away from running on a real Mac, and the value of this harness is that it is the
thing you can safely be careless with.

Verified on the development host: with neither condition met, `launchd-system` and `helper-restart`
both print their refusal and exit `2` without running anything.

## 3. Preflight

Copy the checkout (or just `Tools/vm-verify.sh`) into the guest and run:

```bash
Tools/vm-verify.sh preflight
```

Read-only, and safe to run anywhere — its job is to tell you whether conclusions drawn on this host
would mean anything. It reports the hypervisor, the marker, **SIP state**, the installed Milo build
and its signature, and whether the helper is registered. A `[FAIL]` on SIP means you are about to
produce results that do not transfer; stop and fix the VM.

## 4. Install the build under test

```bash
# On the host, from a clean checkout of the tag or commit being verified:
Tools/build-development-preview.sh
```

Copy `dist/Milo-Public-Preview.dmg` into the guest, verify the checksum sidecar produced by that
same run, install, and launch.

**This is also the only honest Gatekeeper test.** The DMG arrives on the guest carrying a
quarantine attribute, from a machine that did not sign it, so what the user sees at first launch is
what the guest shows. Record it verbatim — that first-launch experience is the entire argument for
notarized Developer ID distribution (section 18, nearest priority 1).

## 5. Run the checks

Snapshot before each, so a failed check can be re-run against the same starting state.

### System-domain launchd semantics

```bash
sudo Tools/vm-verify.sh launchd-system
```

Fully automated. Builds a root `LaunchDaemon` fixture with `KeepAlive`, then answers the question
Milo's code currently assumes: **does `launchctl disable` stop a running system daemon, or only
prevent it returning?**

In the `gui` domain it does not stop it — measured 2026-08-05, which is why Milo runs
`disable` then `bootout`. If the system domain differs, `ProcessManager.performLaunchdDisable` needs
revisiting, and the check says so in those words. The fixture is booted out, re-enabled, and its
plist deleted by an `EXIT` trap whether the check passes or fails.

### Restart Helper recovery

```bash
sudo Tools/vm-verify.sh helper-restart
```

Half automated, and honestly so. The script records the helper's pid and start time, waits while
you perform the two clicks in Milo's Settings, then measures whether the process was actually
replaced. It does not pretend to click. The `requiresApproval` branch — where macOS asks for
approval in Login Items & Extensions — is specifically the part no automated check can reach, which
is why it is called out on screen.

### Helper rejection paths

Not scriptable from a shell, and the harness does not pretend otherwise. Only signed Milo can open
the XPC connection, so a rejection test has to originate inside the app. That belongs in
`SelfTestRunner`'s destructive suite (`--self-test --self-test-destructive`), against a disposable
root-owned fixture the VM makes safe to create. Building it is the next piece of work here.

### System Tuning matrix

By hand, per recipe, with a snapshot before each: apply, verify the stated effect, revert, verify
the revert. Every recipe that cannot be made deterministic and reversible should be removed rather
than shipped — that is already section 18's position, and this is where it gets tested.

## 6. Record the evidence

```bash
Tools/vm-verify.sh report
```

Emits a markdown table of every claim and result from the run, with the guest's OS build, hardware
model, and SIP state on the end. Paste it into `HANDOFF.md` section 10 under a heading naming the
guest release.

A result recorded without its SIP state and OS build is not evidence. That is the specific mistake
this project has already made — a `2.0.0` bundle sat in `/Applications` for eight days while `main`
moved on, and its UI was mistaken for a regression that had been fixed two PRs earlier.
