# ssv-watch: re-apply the IntelXe system-volume component after a macOS update

`ssv-install.sh --apply` puts `NVMTLDriver.bundle` (plugin, Mesa, translator) into `/System/Library/Extensions` so
WebKit's GPU process (Safari WebGL) can load it. A macOS update replaces the sealed system snapshot and the component is
gone. NMXAccel then falls back to `/Library/GPUBundles/NVMTLDriverLib.bundle`: the desktop keeps Metal, only Safari
WebGL is lost. ssv-watch notices that at login and offers to put the component back, the way OpenCore Legacy Patcher
offers its root patches after an update. It never writes to the system volume without the user's click.

## Design

| Part | Runs as | What it does |
|---|---|---|
| `io.github.yusufklncc.intelxe.ssv-watch.plist` | LaunchAgent (`/Library/LaunchAgents`, Aqua sessions, `RunAtLoad`) | starts the agent at every login |
| `ssv-watch-agent.sh` | the logged-in user | read-only check; dialog; on "Yeniden kur" starts the helper through macOS's administrator prompt; offers a restart |
| `ssv-watch-helper.sh` | root, only after the click and the admin password | verifies the package and the system again, `ssv-install.sh --preflight`, then `--apply` |
| `ssv-watch-lib.sh` | both | fixed paths and the checks |

No daemon, no socket, no setuid, no sudoers entry: nothing runs as root unless the user clicks and authenticates. The
elevated command is a constant in the agent:
`/usr/bin/env -i PATH=... /bin/bash -p '/Library/Application Support/IntelXe/ssv-watch/ssv-watch-helper.sh' apply`.
The helper takes exactly one verb (`apply` or `dry-run`), refuses to run as root from anywhere but the installed path,
checks that it and its library are root-owned and not group/other-writable before sourcing, ignores the environment
(`env -i`, `bash -p`), and passes no string from the user or the system into a shell command. Dialog texts go to
`osascript` as arguments, never into the script source.

### Installed layout

```
/Library/Application Support/IntelXe/            root:wheel 755
    ssv/                                      the package (only files listed in its SHA256SUMS), 755/644
    ssv-watch/ssv-watch-agent.sh              755
    ssv-watch/ssv-watch-helper.sh             755
    ssv-watch/ssv-watch-lib.sh                644
    ssv-watch/ssv-watch.conf                  644: pinned SHA256SUMS hash, plugin hash, Darwin major, tested builds
/Library/LaunchAgents/io.github.yusufklncc.intelxe.ssv-watch.plist   root:wheel 644
/Library/Logs/IntelXe/                           root:wheel 755
    ssv-watch.log                             root:wheel 644: the helper (every check, full ssv-install.sh output)
    ssv-watch-agent.<user>.log                <user> 644: the agent
~/Library/Application Support/IntelXe/ssv-watch/suppressed     the user's "Bir daha sorma" keys
```

## What is checked

At login the agent reads the marker `/Library/GPUBundles/nvmtl/ssv-component.plist` (written by `ssv-install.sh --apply`):

| State | Condition | Action |
|---|---|---|
| none | no marker (component never installed, or `--uninstall`) | nothing |
| ok | system copy present, plugin hash = marker, build = marker | nothing |
| missing | marker, but `/System/Library/Extensions/NVMTLDriver.bundle` absent | ask |
| hash | system copy present, plugin hash differs from the marker | ask |
| build | copy intact but the macOS build changed (e.g. a security response) | ask |
| pending | re-applied on this build after this boot (marker newer than `kern.boottime`) | one notification: restart pending |

Before offering anything, and again as root before applying:

* **Package**: SHA256SUMS hash equals the one pinned at install time; every listed file matches; no unlisted files, no
  symlinks, no `..` or absolute paths; `ssv-install.sh`, `sigcheck` and the plugin are listed; everything under
  `/Library/Application Support/IntelXe` root-owned and not group/other-writable; the package's plugin hash equals the
  marker's (the staged package is the one that was installed). Code signatures: `ssv-install.sh --preflight` runs `sigcheck`.
* **This macOS still takes the component** (hard failures: a clear message, no install button):
  same Darwin major as the package; NMXAccel loaded and probing `/System/Library/Extensions` (`NMXMetalPluginFrom`);
  WindowServer has B580 Metal device clients (the same plugin, from the `/Library` copy, works on this build); WebKit's
  `com.apple.WebKit.GPUProcess.sb` still allows `file-map-executable` from `/System/Library/Extensions`.
  A build that is not in `TESTED_BUILDS` but passes all of this gets a note in the dialog.
* **`ssv-install.sh --preflight`** (SIP 0x800, AMFI boot-arg, FileVault, snapshot, free space, signatures, NMXAccel,
  shadowing copy). Only if it passes does the helper run `--apply`, then checks that the marker now names this build and
  this plugin.

## The dialogs (Turkish, as the user sees them)

1. Offer: "Yeniden kur" (default) / "Daha sonra" / "Bir daha sorma". Unanswered for 30 min = "Daha sonra".
   "Bir daha sorma" is remembered for this state, this build and this plugin; a later update asks again.
   `ssv-watch-agent.sh --reset` forgets every such answer.
2. Incompatible or unverifiable: what failed, "Sistem birimine dokunulmadı", "Tamam" / "Bir daha sorma".
3. After "Yeniden kur": macOS's administrator prompt; then "kuruldu" with "Yeniden başlat" / "Daha sonra" (restart via
   loginwindow, with its own confirmation), or "kurulmadı" with the helper's reason and the log path.

## Install / remove

```
sudo ./install-service.sh install --package ~/b580/ssv8      # the package installed now
sudo ./install-service.sh update-package --package DIR       # after installing a newer package by hand
sudo ./install-service.sh uninstall [--keep-package]
./install-service.sh status
```

`install` checks `./SHA256SUMS` (these files), the package (as above, minus ownership), copies only the listed files,
pins the hashes, writes the LaunchAgent and loads it for the sudo user (`--no-load`: at the next login).

## Testing without touching the system (`--test`)

```
./ssv-watch-agent.sh --test SCENARIO [--answer reinstall|later|never] [--package DIR]
```

Scenarios: `ok`, `missing`, `hash`, `build`, `major`, `noaccel`, `sandbox`, `pending`, `nomarker`. The check is pointed
at a private `mktemp -d` dir (a non-existent or fake `NVMTLDriver.bundle`, a simulated build, a fake sandbox profile);
the real `/System` is only read. "Yeniden kur" runs `ssv-watch-helper.sh dry-run` as the user (no password prompt): the
same package, compatibility and `ssv-install.sh --preflight` checks, then it reports what `--apply` would have run.
Test mode refuses to run as root, and the helper honours the test environment only for a non-root `dry-run`, so no test
can reach `--apply`, `mount` or `bless`. Restart is skipped. Logs and state stay in the temp dir (printed at the end).

`--answer` skips the dialogs (for ssh). Without it the real dialogs appear: run it from Terminal in the GUI session.

`ssv-watch-agent.sh --check` prints the state and every check without a dialog (exit 0 nothing to do, 1 action needed,
2 incompatible, 3 restart pending).
