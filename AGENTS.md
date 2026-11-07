# AGENTS.md: setting up a Koofr drive on Windows with this repo

You are an AI agent (Claude Code or similar) helping a person mount their **Koofr** cloud storage as a Windows drive, using the tuned rclone settings and scripts in this repo. This file tells you what to do, what to check, and what not to do. The human-facing guide is [README.md](README.md). The evidence behind every setting is in [docs/RESEARCH.md](docs/RESEARCH.md).

## What "done" looks like

- rclone **1.75.2 or newer** and **WinFsp** are installed.
- The user has an rclone remote for Koofr, created by **them**, using a Koofr **app password**.
- `scripts/Install-KoofrMount.ps1` has been run from a **non-elevated** PowerShell, and it finished with "All set".
- The drive letter shows up in the user's Explorer and lists their Koofr folders.
- The scheduled tasks `Koofr Mount` (logon + every 15 min) and `Koofr Health Check` (weekly) exist, run as the user, and are **not** set to "highest privileges".
- A desktop shortcut "Refresh Koofr (Z)" exists and works.

## Hard rules

1. **Never handle the Koofr password.** Don't type it, ask for it in chat, or put it in a command. The user runs `rclone config` themselves (or types the password into the prompt you start). Tell them to create a Koofr **app password** (Koofr website → Preferences → Password → App passwords).
2. **Never print or upload `rclone.conf`.** It contains an obscured, *recoverable* password. To check a remote exists, use `rclone listremotes`. Don't use `rclone config show`.
3. **Never mount or install from an elevated (admin) shell.** A drive mounted by an admin process is invisible to the user's normal Explorer. Scheduled tasks created from an admin shell can't be edited later without admin (`Set-ScheduledTask` → "Access is denied"; we hit this). The installer refuses to run elevated. Don't work around that.
4. **Don't kill a running rclone mount while uploads are pending.** Check the last `vfs cache: cleaned:` line in `%USERPROFILE%\rclone-Koofr.log`, and only stop it if it says `to upload 0, uploading 0`. Pending uploads do resume on the next start, but don't rely on it.
5. **Don't touch the user's real Koofr data during tests.** Use a throwaway folder such as `koofr:_rclone-lab`, and purge it afterwards. Check free quota first with `rclone about koofr:`.
6. Ask before installing software, deleting anything, or changing settings that aren't in this file.
7. **Never lower `--timeout` below `30m`** on a Koofr mount, and never "tune" it for faster stall recovery. A Koofr folder rename takes about 11 ms per file, and if rclone times out first, its fallback deletes files (RESEARCH.md §13). This happened for real with `1m`.

## Steps

### 1. Look at the machine (read-only)
```powershell
rclone version                      # need 1.75.2+
Test-Path "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll"
rclone listremotes                  # is there a koofr: remote?
Get-PSDrive -PSProvider FileSystem  # which letters are taken, and free space per disk
Get-PhysicalDisk | Select FriendlyName, MediaType, BusType   # pick an SSD for the cache
Get-ScheduledTask | Where TaskName -like 'Koofr*'           # existing install?
```

### 2. Install the prerequisites (ask first)
```powershell
winget install Rclone.Rclone        # or: winget upgrade Rclone.Rclone
winget install WinFsp.WinFsp
```
After installing rclone, **open a new shell**, because winget changes PATH. Check with `rclone version`.

### 3. The user creates the remote
Have the user run `rclone config` in their own terminal: `n` (new remote) → name `koofr` → storage `koofr` → provider `koofr` → their e-mail → **app password** → accept the defaults → `q`. Then check it works:
```powershell
rclone lsd koofr: --disable-http2
```
Always pass `--disable-http2` on Koofr commands (see RESEARCH.md §5.1).

### 4. Choose the settings
| Setting | How to choose |
|---|---|
| `-Letter` | A free letter. Z: is conventional. |
| `-CacheDir` | A folder on a local SSD with space. **Not** on the system drive if it's small, and **not** on exFAT/FAT (no sparse files, so `full` cache mode performs very badly). |
| `-CacheMaxSize` | About 20–50% of that disk's free space. The installer warns if it's bigger than free space minus `-MinFreeSpace`. |
| `-MinFreeSpace` | `10G` unless the disk is tiny. |
| `-Remote` | `koofr:` for the whole account, or `koofr:SomeFolder`. |

### 5. Run the installer (non-elevated)
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-KoofrMount.ps1 -Letter Z: -CacheDir D:\rclone-koofr-cache -CacheMaxSize 100G
```
- If tasks named `Koofr Mount` / `Koofr Health Check` already exist, it stops. Re-run with `-Force` to replace them. If a task was created by an admin, `-Force` fails with "Access is denied": ask the user to delete that task in Task Scheduler (run as admin), or use `-TaskPrefix`.
- If the drive letter is already mounted by rclone, the installer restarts it with the new settings. Check rule 4 first.

### 6. Verify
```powershell
Test-Path Z:\; Get-ChildItem Z:\ | Select -First 5          # the user's folders
Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Select CommandLine   # flags present, no rc password on the command line
Get-Content $env:USERPROFILE\koofr-mount-script.log -Tail 5   # "Z: mounted after 5s"
Get-ScheduledTask 'Koofr Mount' | Select -Expand Principal    # RunLevel Limited, LogonType Interactive
Start-Process conhost.exe -ArgumentList '--headless','powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',"$env:USERPROFILE\KoofrMount\Refresh-Koofr.ps1",'-NoToast' -Wait
Get-Content $env:USERPROFILE\koofr-mount-script.log -Tail 1   # "refresh: folder listings cleared"
```
Ask the user to confirm that the drive shows in **their** Explorer. Your shell may see it while Explorer doesn't, if anything ran elevated.

### 7. Optional: re-tune for this connection
The settings were tuned on a 770/110 Mbit line, 29 ms from Koofr. On a very different connection, re-run the relevant benchmarks in `bench/` (see [bench/README.md](bench/README.md)), especially `50-ab-read-tests.ps1` (mount read streams) and `60-tpslimit-test.ps1` (rate limit). Use a throwaway Koofr folder and clean up afterwards.

## Pitfalls we actually hit (don't repeat them)

| Pitfall | What happens | Do this instead |
|---|---|---|
| `conhost.exe --headless powershell ...` run with `&` from inside an interactive console | Silently does nothing | Launch it with `Start-Process` (that's what Task Scheduler and shortcuts do). We confirmed it works from a scheduled task. |
| A PowerShell function parameter named `$Args` | Clashes with the automatic `$args`, so the arguments silently arrive empty | Use another name (`$MArgs`) |
| Reading rclone's log with `[IO.File]::ReadLines` | "being used by another process" | Open it with `FileShare.ReadWrite` (see `Check-KoofrHealth.ps1`) |
| `Set-ScheduledTask` on a task an admin created | "Access is denied" | Recreate it as the user (the installer does) or ask the user to edit it as admin |
| Cloudflare `speed.cloudflare.com/__down?bytes=200000000` | 403 for big sizes | Use ≤25 MB, or `https://proof.ovh.net/files/1Gb.dat` for download speed |
| Short benchmark runs | Koofr speed swings up to 2× through the evening | Repeat runs and interleave A/B, and trust only gaps bigger than that |
| Hammering many small files | 429 from Koofr, files fail, and the next test fails too | Keep `--tpslimit 40`, and pause about 90 s between heavy tests |
| `--timeout 1m` (our first tuned value) | Renaming an 11,000-file folder in Explorer: Explorer froze and was killed by Windows, and **16 files were deleted** (recovered from Koofr's Trash) | `--timeout 30m`. If a user reports files missing after a rename, look for `Can't DirMove - falling back` followed by `Deleted` / `404` in the rclone log, and send them to Koofr web → Trash |
| Testing renames inside a small test folder only | A rename of 6 files is instant, so it hides the problem | Test with thousands of files (`bench/98-mount-rename-repro.ps1`) |

## Repo map
```
scripts/   KoofrCommon.ps1  Mount-Koofr.ps1  Refresh-Koofr.ps1  Check-KoofrHealth.ps1
           Install-KoofrMount.ps1  Uninstall-KoofrMount.ps1
config/    mount-flags.md (every flag + evidence), rclone.conf.example
docs/      RESEARCH.md (full write-up), report.html (original lab report)
bench/     benchmark scripts, results/*.csv, logs/ (cleaned of personal details)
```
