#!/bin/bash
#
# Verification harness for a disposable macOS VM.
#
# Four separate items in HANDOFF section 18 are blocked on the same missing thing: a Mac that can
# be broken and thrown away, with default security settings. This host cannot serve, and not only
# because it is someone's working machine -- SIP is disabled on it, so it can never validate a
# System Tuning recipe or a Gatekeeper behaviour that depends on default security.
#
# What this script does and does not do is a deliberate line. It automates every check that can be
# made from a shell and measured from the kernel, refuses to run the destructive ones anywhere but
# a marked VM, and for the steps that genuinely require a human at the GUI it prints the exact
# sequence and then measures the result. It does not pretend to click buttons.
#
# Usage:
#   Tools/vm-verify.sh preflight              Read-only. Safe anywhere. Run this first.
#   Tools/vm-verify.sh launchd-system         Platform semantics of disable/bootout, system domain.
#   Tools/vm-verify.sh helper-restart         Restart Helper recovery, measured around a GUI step.
#   Tools/vm-verify.sh report                 Emit a HANDOFF section 10 block from the last run.
#
# Everything except `preflight` and `report` requires BOTH:
#   1. a hypervisor (`kern.hv_vmm_present` = 1), and
#   2. /etc/milo-disposable-vm to exist.
#
# Two conditions, and no environment-variable override, on purpose. A single check is one typo away
# from running on a real Mac, and the whole value of this harness is that it is the thing you can
# safely be careless with.

set -euo pipefail

readonly MARKER="/etc/milo-disposable-vm"
readonly HELPER_LABEL="com.gonggong.milo.helper"
readonly APP="/Applications/Milo.app"
readonly EVIDENCE_DIR="${TMPDIR:-/tmp}/milo-vm-verify"

pass_count=0
fail_count=0
skip_count=0

say() { printf '%s\n' "$*"; }
ok()   { printf '[PASS] %s\n' "$*"; pass_count=$((pass_count + 1)); record "PASS" "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; fail_count=$((fail_count + 1)); record "FAIL" "$*"; }
skip() { printf '[SKIP] %s\n' "$*"; skip_count=$((skip_count + 1)); record "SKIP" "$*"; }
note() { printf '       %s\n' "$*"; }

record() {
    mkdir -p "$EVIDENCE_DIR"
    printf '%s\t%s\n' "$1" "$2" >> "$EVIDENCE_DIR/results.tsv"
}

# --- Safety -------------------------------------------------------------------------------------

is_virtual_machine() {
    [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = "1" ]
}

require_disposable_vm() {
    local refused=0

    if ! is_virtual_machine; then
        say "REFUSED: kern.hv_vmm_present is not 1, so this is not a virtual machine."
        refused=1
    fi

    if [ ! -f "$MARKER" ]; then
        say "REFUSED: $MARKER does not exist."
        say "         On a VM you are willing to destroy, run:"
        say "           sudo touch $MARKER"
        refused=1
    fi

    if [ "$refused" -ne 0 ]; then
        say ""
        say "These checks unregister daemons, kill root processes, and rewrite launchd"
        say "configuration. They are meant for a machine you can discard. Nothing was run."
        exit 2
    fi
}

# --- preflight ----------------------------------------------------------------------------------

# Read-only, and deliberately safe to run anywhere: its job is to tell you whether conclusions
# drawn on this host would mean anything.
cmd_preflight() {
    rm -f "$EVIDENCE_DIR/results.tsv"
    say "Milo VM verification preflight"
    say "=============================="
    say ""
    say "Host:        $(sysctl -n hw.model 2>/dev/null || echo unknown)"
    say "macOS:       $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    say "Arch:        $(uname -m)"
    say ""

    if is_virtual_machine; then
        ok "Running under a hypervisor"
    else
        bad "Not a virtual machine — destructive checks will refuse to run here"
    fi

    if [ -f "$MARKER" ]; then
        ok "Disposable-VM marker present at $MARKER"
    else
        bad "No disposable-VM marker — create it with: sudo touch $MARKER"
    fi

    # SIP is the reason this host can never validate System Tuning, and the single most common way
    # to draw a conclusion that does not transfer to a user's Mac.
    local sip
    sip="$(csrutil status 2>/dev/null | head -1)"
    case "$sip" in
        *enabled*) ok "SIP is enabled — representative of a user's Mac" ;;
        *disabled*) bad "SIP is disabled — System Tuning and Gatekeeper results will not transfer" ;;
        *) skip "SIP status could not be read: ${sip:-no output}" ;;
    esac

    if [ -d "$APP" ]; then
        local version build
        version="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
        build="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "?")"
        ok "Milo installed: $version ($build)"

        if codesign --verify --strict "$APP" >/dev/null 2>&1; then
            ok "Installed bundle signature is valid"
        else
            bad "Installed bundle fails codesign --verify"
        fi
    else
        skip "Milo is not installed at $APP — install the DMG before the live checks"
    fi

    if launchctl print "system/$HELPER_LABEL" >/dev/null 2>&1; then
        ok "Privileged helper is registered"
    else
        skip "Privileged helper is not registered — enable it in Milo before the helper checks"
    fi

    summary
}

# --- launchd system-domain semantics --------------------------------------------------------------

# The gui-domain behaviour was measured on 2026-08-05: `launchctl disable` records the job as
# disabled and does NOT stop the running instance, which respawns immediately. Milo's disable path
# therefore runs disable followed by bootout. This check asks whether the *system* domain behaves
# the same way, because that branch of Milo's code has never been measured -- and a platform
# assumption that holds in one domain and not the other is exactly the kind of thing that ships.
cmd_launchd_system() {
    require_disposable_vm

    local label="tech.gonggong.milovmfixture"
    local plist="/Library/LaunchDaemons/$label.plist"

    say "System-domain launchd semantics"
    say "==============================="
    say ""
    note "Fixture: $label as a root LaunchDaemon running /bin/sleep 1200, KeepAlive."

    cleanup_system_fixture() {
        launchctl bootout "system/$label" 2>/dev/null || true
        launchctl enable "system/$label" 2>/dev/null || true
        rm -f "$plist"
    }
    trap cleanup_system_fixture EXIT

    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sleep</string><string>1200</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
    chown root:wheel "$plist"
    chmod 644 "$plist"

    if ! launchctl bootstrap system "$plist" 2>/dev/null; then
        bad "Could not bootstrap the fixture — are you running with sudo?"
        summary
        return
    fi
    sleep 2

    local first
    first="$(fixture_pid "$label")"
    if [ -z "$first" ]; then
        bad "Fixture did not start"
        summary
        return
    fi
    ok "Fixture running as pid $first in the system domain"

    # 1. Does it respawn at all?
    kill "$first" 2>/dev/null || true
    sleep 3
    local second
    second="$(fixture_pid "$label")"
    if [ -n "$second" ] && [ "$second" != "$first" ]; then
        ok "System daemon respawns after a kill: $first -> $second"
    else
        bad "Fixture did not respawn — the rest of this check proves nothing"
        summary
        return
    fi

    # 2. The load-bearing question: is `disable` alone enough here?
    launchctl disable "system/$label"
    kill "$second" 2>/dev/null || true
    sleep 3
    local third
    third="$(fixture_pid "$label")"
    if [ -n "$third" ]; then
        ok "disable alone does NOT stop a system daemon (came back as $third) — matches gui"
        note "Milo's disable+bootout sequence is correct for this domain too."
    else
        bad "disable alone DID stop it — the system domain differs from gui; revisit ProcessManager"
    fi

    # 3. And does disable+bootout do the job?
    launchctl bootout "system/$label" 2>/dev/null || true
    sleep 2
    if [ -z "$(fixture_pid "$label")" ]; then
        ok "disable + bootout stops the system daemon"
    else
        bad "disable + bootout left the daemon running"
    fi

    if launchctl print-disabled system 2>/dev/null | grep -q "\"$label\" => disabled"; then
        ok "Job remains disabled, so it will not return after a restart"
    else
        bad "Job is not recorded as disabled — the change would not survive a reboot"
    fi

    summary
}

fixture_pid() {
    launchctl print "system/$1" 2>/dev/null | awk -F'= ' '/^\tpid = /{print $2; exit}'
}

# --- helper restart ------------------------------------------------------------------------------

# Restart Helper's recovery is the one path stale-helper detection could not prove on a working
# machine, because exercising it means unregistering a helper somebody is relying on. The script
# measures the helper identity before and after; the two clicks in between are the operator's.
cmd_helper_restart() {
    require_disposable_vm

    say "Restart Helper recovery"
    say "======================="
    say ""

    local before
    before="$(helper_pid)"
    if [ -z "$before" ]; then
        bad "No helper is running — enable it in Milo first"
        summary
        return
    fi
    ok "Helper running as pid $before"
    note "Start time: $(ps -o lstart= -p "$before" 2>/dev/null || echo unknown)"

    say ""
    say "Now, in Milo:"
    say "  1. Open Settings and turn the background helper OFF."
    say "  2. Turn it back ON. Approve in Login Items & Extensions if macOS asks."
    say "     (That approval branch is the part no automated check can reach.)"
    say ""
    printf 'Press return when the helper is enabled again... '
    read -r _

    local after
    after="$(helper_pid)"
    if [ -z "$after" ]; then
        bad "No helper is running after the restart"
    elif [ "$after" = "$before" ]; then
        bad "Helper pid is unchanged ($after) — the old process was never torn down"
    else
        ok "Helper was replaced: $before -> $after"
        note "New start time: $(ps -o lstart= -p "$after" 2>/dev/null || echo unknown)"
    fi

    say ""
    say "Finally, in Milo: confirm no stale-helper banner is showing, and run a privileged"
    say "action (DNS flush or memory purge) to confirm the new helper answers."
    summary
}

helper_pid() {
    launchctl print "system/$HELPER_LABEL" 2>/dev/null | awk -F'= ' '/^\tpid = /{print $2; exit}'
}

# --- report ---------------------------------------------------------------------------------------

cmd_report() {
    if [ ! -f "$EVIDENCE_DIR/results.tsv" ]; then
        say "No results recorded. Run a check first."
        exit 1
    fi
    say "Paste into HANDOFF section 10:"
    say ""
    say "| Claim | Result |"
    say "|---|---|"
    while IFS=$'\t' read -r status claim; do
        printf '| %s | %s |\n' "$claim" "$status"
    done < "$EVIDENCE_DIR/results.tsv"
    say ""
    say "Host: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model), SIP $(csrutil status 2>/dev/null | sed 's/.*: //;s/\.$//')"
}

summary() {
    say ""
    say "Summary: $pass_count passed, $fail_count failed, $skip_count skipped"
    say "Run 'Tools/vm-verify.sh report' for a HANDOFF-ready block."
    [ "$fail_count" -eq 0 ]
}

# --- entry ----------------------------------------------------------------------------------------

case "${1:-}" in
    preflight)      cmd_preflight ;;
    launchd-system) cmd_launchd_system ;;
    helper-restart) cmd_helper_restart ;;
    report)         cmd_report ;;
    *)
        say "Usage: Tools/vm-verify.sh {preflight|launchd-system|helper-restart|report}"
        say ""
        say "  preflight       Read-only. Safe anywhere. Reports whether this host is a valid"
        say "                  verification target, and why not."
        say "  launchd-system  Does 'launchctl disable' stop a running system daemon? Needs sudo."
        say "  helper-restart  Restart Helper recovery, measured around two clicks in Milo."
        say "  report          Emit a HANDOFF section 10 block from the last run."
        exit 1
        ;;
esac
