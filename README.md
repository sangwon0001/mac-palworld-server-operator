# Palworld Dedicated Server on macOS (Apple Silicon, no Docker)

*English · [한국어](README.ko.md)*

Scripts and a native macOS app for running a Palworld dedicated server directly on an
Apple Silicon Mac, using **Rosetta 2 and a Wine compatibility layer** — no
virtualization, no Docker.

---

## ⚠️ Read this before you start

1. **Palworld ships no macOS server build.** SteamCMD pulls the Windows depot and Wine
   runs it, with Wine itself executing as x86_64 under Rosetta 2. That is **two
   translation layers** (Wine: Win32 API → macOS, Rosetta: x86_64 → ARM64).
2. It is a UE5 dedicated server, so **crashes and degraded performance are real
   possibilities**. Four to eight players generally holds up; large player counts or
   sprawling bases may not.
3. **Box64 is irrelevant here** (it targets ARM Linux), and **Whisky is discontinued**.
   The official WineHQ casks (`wine-stable`, `wine@devel`, `wine@staging`) fail the
   macOS Gatekeeper check, are deprecated, and **will be disabled on 2026-09-01**.
   → The free path that currently works cleanly is the **Gcenx repackaging of Apple's
   Game Porting Toolkit**.
4. Nothing here is tied to a specific Wine build. Changing the single `WINE_BIN` line
   switches compatibility layers.
5. **Rosetta 2 is unavoidable.** GPTK's `wine64`, Gcenx's plain builds
   (`...-osx64.tar.xz`) and CrossOver are all x86_64 binaries, and `PalServer.exe` is
   itself Windows x86-64. Rosetta 2 is the only x86→ARM translator on macOS (there is
   no FEX or box64 equivalent). This is why macOS shows a **"Support Ending for
   Intel-based Apps"** notice after installing GPTK — expected, and identical for any
   Wine you pick.

> ### ⚠️ Operational advice: hold off on major macOS upgrades
>
> Apple has said Rosetta 2 will remain for a few more releases and then be narrowed.
> **Upgrading macOS on the machine running this server can silently kill it.** Before
> upgrading, take a backup with `./backup_save.sh`, and afterwards confirm Wine still
> runs with `./setup.sh`.
>
> When Rosetta does go away, the durable answer is a **native Linux server**. App ID
> 2394010 provides a Linux depot, so a low-power mini PC or a VPS runs it with no
> translation at all. Save data is compatible as-is: extract a `./backup_save.sh`
> archive into `Pal/Saved/` there (only the config path differs,
> `Config/WindowsServer/` → `Config/LinuxServer/`).

> If stability matters more than convenience, a small Linux box is the better host.
> This project targets "run it on the MacBook I already own, for a few friends."

---

## Features

| | |
|---|---|
| **Safe shutdown** | RCON `Save` → `Shutdown` → SIGINT → SIGTERM → SIGKILL, escalating only on failure |
| **Backups** | Timestamped archives, integrity-checked, with named backups exempt from cleanup |
| **Restore / migrate** | Roll back to any backup, or import a `Saved` folder from another server |
| **Auto-restart** | Handles the memory leak: back up → stop → (optionally) update → start → verify |
| **Game settings** | All 119 `PalWorldSettings.ini` options, read and written safely |
| **Version & updates** | Compare the installed build against Steam's latest, then update in one step |
| **macOS app** | Menu bar + dashboard, built with `swiftc` alone — no Xcode required |
| **Localized** | App UI in English, Korean and Japanese |

---

## Requirements

- Apple Silicon Mac (Intel works but is untested here)
- macOS 14 or newer
- About 7 GB of free disk space
- Xcode Command Line Tools and Homebrew (see below)

---

## Installation

### On a fresh Mac, two things must be done by hand first

```bash
xcode-select --install
```

This makes `python3` usable. On a new Mac `/usr/bin/python3` exists as a file but is a
**stub** — running it only opens the developer-tools installer. RCON safe shutdown,
status queries and settings editing all depend on python3, so `install.sh` checks that
it actually runs and stops early if it does not.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && exec zsh
```

Homebrew. The installer deliberately does **not** run this for you — fetching and
executing a remote script is a decision you should make yourself.

### Then run the installer

```bash
git clone git@github.com:sangwon0001/mac-palworld-server-operator.git palworld-server
cd palworld-server && ./install.sh
```

It handles dependency checks, the server download, config generation and building and
installing the GUI app.

- **Idempotent** — finished steps are skipped, so re-running after an interruption is safe.
- **Non-destructive** — existing saves and a configured `AdminPassword` are never overwritten.
- **Runs as you** — Homebrew refuses to run as root, so nothing is wrapped in `sudo`.
  Only Rosetta, which genuinely needs it, asks for a password.

```bash
./install.sh --check     # report state only, change nothing
./install.sh --yes       # unattended
./install.sh --no-app    # CLI only, skip the GUI app
```

> **Why not a `.pkg`?** A `.pkg` runs its postinstall as root, and Homebrew refuses to
> run as root. Putting a 5.6 GB download inside an installer wizard also hides progress
> and makes interruption hard to recover from. A drag-to-Applications `.dmg` is no better
> here: the app drives the shell scripts in this folder, so the app alone does nothing.

---

## Daily use

```bash
./start_server.sh      # start (background, waits for the port to bind)
./status.sh            # PID, CPU, RAM, port, players, saves, backups
./stop_server.sh       # safe shutdown
./backup_save.sh       # back up now
./update_check.sh      # is there a newer build?
```

Or use the app: **Palworld Server.app** lives in the menu bar with a dashboard window.

---

## How it is put together

The shell scripts hold **all** the server-control logic. The app only invokes them, so
the app, the terminal and cron run exactly the same code and anything done in the app is
reproducible from the CLI.

```
palworld-server/
├── install.sh              ★ one-shot installer — start here
├── config.sh               shared settings, helpers, shell RCON client
├── config.local.sh.example template for personal settings
├── setup.sh                prerequisite check and guidance
├── install_update.sh       install/update via SteamCMD
├── start_server.sh         start (nohup / tmux / foreground)
├── stop_server.sh          safe shutdown (RCON → SIGINT → SIGTERM → SIGKILL)
├── backup_save.sh          backups, naming, renaming
├── restore_save.sh         restore, or import a save from another server
├── status.sh               status (human-readable and --json)
├── auto_restart.sh         backup + restart, for cron
├── install_cron.sh         install/remove the crontab entries
├── settings.sh             read/write the 119 game settings
├── update_check.sh         installed build vs Steam's latest (1-hour cache)
└── app/                    macOS GUI app (SwiftUI)
    ├── Sources/
    │   ├── PalworldServerApp.swift   @main, menu bar + window
    │   ├── ContentView.swift         dashboard and tabs
    │   ├── GameSettingsView.swift    settings editor
    │   ├── SettingsCatalog.swift     labels, categories and ranges for 119 settings
    │   ├── ServerController.swift    script execution, polling, settings
    │   ├── RconClient.swift          native RCON (players, broadcast, kick, ban)
    │   ├── Localization.swift        en / ko / ja
    │   └── Models.swift              maps status.sh --json
    ├── Resources/<lang>.lproj/       translations
    └── build.sh                      builds the .app without Xcode
```

Runtime locations, all created automatically:

```
~/PalworldServer/        the server itself, plus logs/ and run/
~/palworld_backups/      backup archives
~/.palworld_wine/        Wine prefix
```

---

## Safe shutdown

```bash
./stop_server.sh            # warn over RCON, then stop
./stop_server.sh --now      # save and stop immediately
./stop_server.sh --force    # also clean up an unresponsive process
```

Each stage runs only if the previous one failed: **RCON `Save` + `Shutdown` → SIGINT →
SIGTERM → SIGKILL**. The RCON path is the one least likely to lose a save because the
game flushes its own data, so setting `RCON_PASSWORD` is strongly recommended.

---

## Backups

```bash
./backup_save.sh                        # back up now
./backup_save.sh --name "before boss"   # named backup
./backup_save.sh --list                 # list, with names
./backup_save.sh --rename 20260805_1130 "important"
./backup_save.sh --rename 20260805_1130 ""     # clear the name
```

- If the server is running, the save is flushed over RCON **first**, so progress held
  only in memory is not missed.
- Every archive is verified with `tar -tzf` immediately after creation; a corrupt one is
  deleted rather than left to be trusted.
- Retention: older than 14 days is removed, but the newest 10 are always kept.
- **Named backups are never auto-deleted.** Naming one means you want to keep it.
  Clearing the name puts it back in scope for cleanup.

The name goes *after* the timestamp
(`palworld_backup_20260805_113000_before_boss.tar.gz`) so the existing glob and the
fixed-width date parsing keep working unchanged.

### Restore and migration

```bash
./stop_server.sh                        # required first
./restore_save.sh --latest              # roll back to the newest backup
./restore_save.sh <backup.tar.gz>       # roll back to a specific one
./restore_save.sh --import ~/Downloads/Saved   # import from another server
```

The current state is snapshotted as `prerestore_*.tar.gz` before anything is
overwritten, so a wrong restore is still recoverable.

> Keep the world ID folder name (a random hex string) exactly as it was — renaming it
> makes the server treat it as a new world. If `SaveGames/0/` holds more than one world,
> name the one to use in `DedicatedServerName`.

---

## Game settings

```bash
./settings.sh --json                    # all settings as JSON (what the app reads)
./settings.sh --get ExpRate
./settings.sh --diff                    # only what differs from the defaults
./settings.sh --set ExpRate=2.0 Difficulty=Casual ServerName="My Server"
./settings.sh --reset                   # reset gameplay values
./settings.sh --reset --all             # reset operational keys too (careful)
```

In the app: the **Game Settings** tab groups all 119 options into eight categories with
typed controls (switches, sliders, pickers, masked password fields) and search. Edits are
staged and written in one batch on **Apply**, so nothing touches the file until you
confirm.

> **Safety design.** Rather than re-serialising the whole `OptionSettings=(...)` line,
> only the requested keys are rewritten in place. A key added by a future game update is
> therefore never lost just because this toolkit doesn't know about it. The file is
> backed up to `PalWorldSettings.ini.bak_<timestamp>` before every write, and a value
> whose type doesn't match (text where a number belongs) is rejected without touching
> the file.

> **`--reset` protects operational keys.** Clearing `AdminPassword` and flipping
> `RCONEnabled` back to `False` would drop safe shutdown to signals and risk losing the
> save, so those are excluded by default. `--all` overrides this; naming a key
> explicitly always honours the request.

---

## Version and updates

```bash
./update_check.sh          # installed build vs Steam's latest
./auto_restart.sh --update # back up → stop → update → start
```

Two version concepts are shown:

| Shown as | Source | Available when |
|---|---|---|
| Game version (`v1.0.2.101103`) | RCON `Info` | only while the server runs |
| Build number (`24466863`) | `appmanifest_2394010.acf` | always (a file read) |

Update detection compares **build numbers**. The latest build comes from the official
`steamcmd +app_info_print`, which takes about 6 seconds, so **the result is cached for an
hour** — a warm cache answers in 0.03 s without touching the network.

If the backup fails, the update is aborted; the server is never changed without a point
to return to.

> Automatic updates are deliberately **not** enabled. A game update can affect save
> compatibility or mods, so the timing should be yours. To automate anyway, add to cron:
> `0 4 * * 1 cd <this folder> && ./auto_restart.sh --update --if-empty`

---

## Scheduled maintenance

```bash
./install_cron.sh --show      # preview
./install_cron.sh --install
./install_cron.sh --remove
```

| When | What |
|---|---|
| hourly | back up the save |
| daily 05:00 | back up and restart (clears the memory leak) |
| daily 06:00 | restart only if memory exceeds 8 GB and nobody is connected |

> **Required on macOS:** cron needs permission to reach your home directory.
> System Settings → Privacy & Security → **Full Disk Access** → add `/usr/sbin/cron`.
> Without it, cron jobs fail silently — check `~/PalworldServer/logs/cron.log` afterwards.

---

## Networking

```bash
./status.sh --address     # the addresses to hand out
```

1. **Port forwarding:** `UDP 8211` → this Mac's LAN IP.
2. **Reserve the IP** in your router's DHCP settings, or players lose the address on reboot.
3. **Wi-Fi is fine.** Palworld uses tens to hundreds of KB/s per player; what matters is
   packet loss and jitter, not bandwidth. Check with:
   ```bash
   ping -c 100 -i 0.2 "$(route -n get default | awk '/gateway:/{print $2}')"
   ```
   0% loss with single-digit millisecond deviation is plenty.
4. **Sleep:** `start_server.sh` handles this. It reads the *actual* assertions from
   `pmset -g assertions` rather than the policy in `pmset -g custom`, leaves things alone
   if something (Amphetamine, say) already holds sleep off, and otherwise runs
   `caffeinate -dims -w <server PID>`, which releases automatically when the server stops.
   **Closing the lid still sleeps** without an external display, whatever is holding
   assertions.

---

## The macOS app

```bash
cd app && ./build.sh --install
```

Builds with the Command Line Tools' `swiftc` alone — **no Xcode**.

The app carries no server-control logic of its own; pressing a button runs the
corresponding `.sh` script. Deleting the app changes nothing about how the server runs.
State is read from `./status.sh --json` rather than by parsing human-readable output.

**Player management uses a native Swift RCON client** rather than the shell helper,
because going through the shell spawns bash and python3 every time:

| Path | Round trip |
|---|---|
| via shell (`bash` + `python3` startup) | ~260 ms |
| native Swift | **~36 ms** |

Server lifecycle stays with the scripts, though. RCON cannot start a stopped server, read
CPU/RAM/PID, or handle backups — and `stop_server.sh`'s four-stage fallback exists
precisely for when RCON is unresponsive, so the app must not reimplement it.

> ### Palworld's non-ASCII RCON bug
>
> When a response body contains non-ASCII text, the server declares a length **larger**
> than what it actually sends:
>
> ```
> Info         declared 74 / sent 58   ⚠      Save         declared 24 / sent 24  ✔
> Broadcast    declared 54 / sent 39   ⚠      ShowPlayers  declared 33 / sent 33  ✔
> ```
>
> Trusting the declared length means waiting for bytes that never arrive — a 5-second
> timeout in practice. **A player with a non-ASCII nickname trips this via `ShowPlayers`.**
>
> Both clients (Swift and shell) now treat the declared length as an upper bound and stop
> at the packet terminator (`00 00`), which mis-declared responses still send correctly.
>
> The truncation itself is server-side and cannot be fixed from here, so broadcasts are
> most reliable in plain letters and numbers. (Spaces are converted to underscores —
> Palworld's RCON treats them as argument separators.)

### Localization

274 UI strings in English, Korean and Japanese. **Settings (⚙️) → Language** switches
immediately, with no restart. The default follows the system language, falling back to
English.

- The **Korean source text doubles as the lookup key**, so untranslated entries fall back
  to readable text instead of a blank label.
- Building without Xcode rules out String Catalogs (`.xcstrings`), so the classic
  `app/Resources/<lang>.lproj/Localizable.strings` files are copied into the bundle.
- `NSLocalizedString` follows the system language and would need a restart, so the
  matching `.lproj` bundle is opened directly instead.

> The Japanese was written by hand rather than machine-translated, but has not been
> reviewed by a native speaker. Corrections to
> `app/Resources/ja.lproj/Localizable.strings` followed by
> `cd app && ./build.sh --install` are welcome.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| "Wine not found" | Set an absolute `WINE_BIN` in `config.local.sh` |
| SteamCMD platform error | `+@sSteamCmdForcePlatformType windows` must come before `+login` |
| Port never binds | Run `./start_server.sh --fg` to see Wine's errors directly |
| Crashes on start | `./install_update.sh --validate` to verify file integrity |
| RCON auth fails | `AdminPassword` (ini) and `RCON_PASSWORD` (config.local.sh) must match, and `RCONEnabled=True` |
| Next start fails | A stale process is still around — `./stop_server.sh --force` |
| cron does nothing | Grant Full Disk Access to `/usr/sbin/cron`; check `logs/cron.log` |
| Save not found | World ID folder must keep its original name, and `SaveGames/0/` should hold only one |

```bash
tail -f ~/PalworldServer/logs/palserver.log      # server log
tail -f ~/PalworldServer/logs/auto_restart.log   # scheduled restarts
tail -f ~/PalworldServer/logs/operations.log     # audit trail
```

> The server log is buffered. When checking whether something just happened, trust the
> **timestamps inside the log** rather than the file's size or mtime.

---

## Notes for contributors

- Shell scripts must stay **bash 3.2 compatible** — cron runs `/bin/bash`, which is 3.2
  on macOS. No `mapfile`, no associative arrays.
- Everything in the scripts is English: comments, messages and `--help` output.
  Only the app UI is translated, and there the **Korean source text is the lookup key**
  (see `app/Sources/Localization.swift`), so `SettingsCatalog` labels stay in Korean
  by design.
- `config.local.sh` holds the RCON password and is gitignored. It is generated by
  `install.sh` with mode 600.

---

## License

[MIT](LICENSE) — use it, change it, redistribute it, just keep the copyright notice.
No warranty: running a Windows game server through two translation layers is
inherently fragile, so back up your saves.

Palworld is a trademark of Pocketpair, Inc. This project is unaffiliated with and
unendorsed by Pocketpair.
