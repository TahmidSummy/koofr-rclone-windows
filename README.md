# koofr-rclone-windows

Mount your **Koofr** cloud storage as a normal drive letter (like `Z:`) on **Windows**, using [rclone](https://rclone.org) with settings that were **benchmarked against Koofr**, plus a small watchdog that keeps the drive healthy.

Compared with a typical rclone mount, measured on the same connection:

| | Typical settings | These settings |
|---|---|---|
| Opening a big file (first time) | 6–11 MiB/s | **20–31 MiB/s** (~3×) |
| Saving files onto the drive | 11.5 MiB/s | **18.5 MiB/s** (~1.6×) |
| Uploading many small files | 4.4 files/s | **21.8 files/s** (~5×) |
| Koofr "429 Too Many Requests" failures | whole batches failed | **0** |
You also get:
- **Self-healing.** Every 15 minutes it checks the drive. If it's frozen or gone, it fixes it and tells you.
- **A "Refresh Koofr" desktop shortcut.** Click it to see files you just added from your phone or the website, without waiting.
- **A weekly health check.** It notifies you only if something's wrong.
- **Silence when everything is fine.** No windows popping up.

The full research, every test and every number is in **[docs/RESEARCH.md](docs/RESEARCH.md)**. What each rclone flag does is in **[config/mount-flags.md](config/mount-flags.md)**. If you'd like an AI agent (such as Claude Code) to set this up for you, point it at **[AGENTS.md](AGENTS.md)**.

---

## Setup (about 10 minutes)

> Use a **normal** PowerShell window for every step, **not** "Run as administrator". A drive mounted as admin is invisible in your Explorer.

### 1. Install rclone and WinFsp
```powershell
winget install Rclone.Rclone
winget install WinFsp.WinFsp
```
Close PowerShell and open a new window, then check:
```powershell
rclone version
```
It must say **v1.75.2 or newer**. If it's older, run `winget upgrade Rclone.Rclone`.

### 2. Make a Koofr app password
On the Koofr website go to **Preferences → Password → App passwords** and create one called something like "rclone".
Use this, **not** your normal Koofr password. You can revoke it any time without changing your main password.

### 3. Connect rclone to Koofr
```powershell
rclone config
```
Answer the prompts:
1. `n` for a new remote
2. name: `koofr`
3. storage type: type `koofr` and choose **Koofr, Digi Storage and other Koofr-compatible storage providers**
4. provider: **Koofr**
5. user: your Koofr e-mail
6. password: `y`, then paste the **app password** from step 2
7. press Enter for every other question (the defaults are fine), then `y` to save and `q` to quit

Check it works. You should see your Koofr folders:
```powershell
rclone lsd koofr: --disable-http2
```

### 4. Download this repo
Either click **Code → Download ZIP** on GitHub and unzip it, or:
```powershell
git clone https://github.com/TahmidSummy/koofr-rclone-windows.git
cd koofr-rclone-windows
```

### 5. Choose where the cache goes
rclone keeps a local copy of files you open, so they're instant next time. Put the cache on a **local SSD with plenty of free space**, ideally not a small C: drive.

### 6. Install
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-KoofrMount.ps1 -Letter Z: -CacheDir D:\rclone-koofr-cache -CacheMaxSize 100G
```
Change `Z:`, the cache folder and the size to suit your setup. The installer:
- checks rclone, WinFsp, your Koofr remote, the drive letter and the disk space
- copies the scripts to `%USERPROFILE%\KoofrMount`
- creates the scheduled tasks **Koofr Mount** (at logon + every 15 min) and **Koofr Health Check** (Sundays)
- puts a **Refresh Koofr (Z)** shortcut on your desktop
- mounts the drive

When it says **All set**, open `Z:` in Explorer.

---

## Day to day

| You see | What it means |
|---|---|
| Nothing | Everything's fine. Healthy checks are silent. |
| "Koofr: Z: was frozen" | rclone stopped responding. It was restarted automatically. |
| "Koofr: Z: had dropped" | rclone had quit. The drive was remounted. |
| "Koofr: no internet" | No connection for 5 minutes at startup. It keeps retrying every 15 min. |
| "Koofr: Z: failed to start - …" | rclone couldn't start. The message is rclone's own reason. |
| "Koofr: worth a look" | The weekly check found errors. Open `%USERPROFILE%\koofr-health.txt`. |

- **Added something from your phone or the web and can't see it?** Double-click **Refresh Koofr (Z)** on the desktop, then press **F5** in Explorer. Koofr can't notify rclone of changes, so otherwise new files can take up to an hour to show.
- **Big files open slowly the first time, then instantly.** That's the cache working.
- **Many small files open at about 0.3 s each.** That's Koofr's own per-file delay, and no setting removes it. Copying a whole folder is much faster than opening files one by one, because rclone does those in parallel.
- **Saving a file is instant.** It lands in the cache and uploads about 10 s after you close it. Don't shut the PC down in the middle of a big upload. If you do, it resumes next time.
- **Renaming a big folder freezes Explorer for a while.** Koofr moves every file inside it one by one, at about 11 ms per file, so 10,000 files take about 2 minutes. Explorer waits the whole time, and Windows may close it, which makes the taskbar vanish briefly. Your files are safe; just wait. For folders with thousands of files, it's smoother to rename them in the Koofr web app and then click **Refresh Koofr**. *(An earlier version of this repo used `--timeout 1m`, which made such renames delete files. See [RESEARCH.md §13](docs/RESEARCH.md#13-incident-folder-renames-deleted-files-2026-11-07). If you installed before 7 Nov 2026, update.)*

### Logs (all in `%USERPROFILE%`)
- `koofr-mount-script.log`: what the watchdog did (mounts, restarts, notifications)
- `rclone-Koofr.log`: rclone's own log, rotated at 5 MB, with 3 old copies kept
- `koofr-health.txt`: the latest weekly report. Run `%USERPROFILE%\KoofrMount\Check-KoofrHealth.ps1 -Always` to get one now.

---

## Changing settings
Run the installer again with new values and `-Force`:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-KoofrMount.ps1 -Letter Z: -CacheDir D:\rclone-koofr-cache -CacheMaxSize 200G -Force
```
To change rclone flags themselves, edit `$MountFlags` in `%USERPROFILE%\KoofrMount\Mount-Koofr.ps1` (each flag is commented), then restart the drive. The easiest way to restart is to sign out and back in.

## Uninstall
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-KoofrMount.ps1
```
This removes the tasks, shortcut, scripts and drive. Your **files on Koofr are never touched**. Add `-RemoveCache -CacheDir <folder>` and `-RemoveLogs` to delete those too. rclone and WinFsp stay installed.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Installer says "run from a NORMAL PowerShell" | You opened PowerShell as administrator. Open a normal window. |
| `Z:` works in PowerShell but isn't in Explorer | Something ran elevated. Uninstall, then reinstall from a normal window. |
| "a scheduled task called 'Koofr Mount' already exists" | Add `-Force`. If that says *Access is denied*, the old task was made as admin: delete it in Task Scheduler (run as admin), then re-run. |
| "rclone has no remote called 'koofr:'" | Do step 3 again. The remote name must match `-Remote`. |
| Very slow transfers | Make sure `--disable-http2` is in use (it is, in the script). Check your own internet speed. Koofr's speed varies by time of day. |
| Lots of `429` in the log | Something is opening many files at once. `--tpslimit 40` should handle it. Lower it to 30 if it persists. |
| Drive is there but empty or stuck | Wait for the next 15-minute check, or run the **Koofr Mount** task by hand in Task Scheduler. |
| Files missing after renaming or moving a folder | Look in the Koofr web app → **Trash** and restore them. Then check that `Mount-Koofr.ps1` has `--timeout 30m`, not `1m`. In `rclone-Koofr.log`, the sign of this bug is `Can't DirMove - falling back to file moves` followed by `Deleted` and `404` lines. |

## Security notes
- rclone stores your Koofr app password **obscured, not encrypted** in `%APPDATA%\rclone\rclone.conf`. Keep that file private. Revoke the app password in Koofr if the PC is lost.
- The refresh shortcut talks to rclone over `127.0.0.1` only, with a random password stored in `%LOCALAPPDATA%\KoofrMount\rc.pass`. The password never appears on the command line.

## Licence
[MIT](LICENSE). This project isn't affiliated with Koofr or rclone.
