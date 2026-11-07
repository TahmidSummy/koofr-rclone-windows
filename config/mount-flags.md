# Mount flags: what each one does and why

This is the exact flag set `scripts/Mount-Koofr.ps1` uses. It was benchmarked on 5 November 2026 against Koofr from the UK (29 ms to Koofr), with rclone 1.74.2 and 1.75.2 on Windows 11. Test IDs such as `U12` refer to [`docs/RESEARCH.md`](../docs/RESEARCH.md) and [`bench/results/results.csv`](../bench/results/results.csv).

## The command

```bat
rclone mount koofr: Z: ^
  --vfs-cache-mode full --network-mode --links --no-console ^
  --disable-http2 --transfers 16 --tpslimit 40 --tpslimit-burst 40 --timeout 30m ^
  --vfs-read-chunk-streams 16 --vfs-read-chunk-size 8M --vfs-read-ahead 256M ^
  --dir-cache-time 1h --vfs-fast-fingerprint --vfs-write-back 10s ^
  --vfs-cache-max-age 999h --vfs-cache-max-size 100G --vfs-cache-min-free-space 10G ^
  --vfs-cache-poll-interval 1m --cache-dir D:\rclone-koofr-cache ^
  --log-level INFO --log-file %USERPROFILE%\rclone-Koofr.log --log-file-max-size 5M --log-file-max-backups 3 ^
  --rc --rc-addr 127.0.0.1:5572
```

**Requires rclone 1.75.2 or newer.** `--vfs-read-chunk-streams` hung a read for 39 minutes once on 1.74.2 (test M06). Versions 1.75.0 and 1.75.1 fixed VFS reader deadlocks, and on 1.75.2 it ran cleanly every time.

## Flag by flag

| Flag | Value | rclone default | Why (evidence) |
|---|---|---|---|
| `--disable-http2` | on | off | **Most important flag for Koofr.** With HTTP/2 on, a single 1 GiB upload ran at 3.2 MiB/s vs 10.4 off (U11/U12). A 4-stream download ran at 2.7 vs 15.8 MiB/s, then 16.4 vs 30.5 on a repeat (D01/D03). A mount read ran at 17.7 vs 24.4 MiB/s (M02/M01). At 16 streams it made no difference (D05/D07), so it's the low-parallelism cases that suffer. |
| `--transfers` | 16 | 4 | Uploads from the mount's cache in parallel. Writing 20 × 25 MiB through the mount went from 11.5 to 18.5 MiB/s (W01 → W03). Copying 300 small files went from 4.4 to 21.8 files/s (U02b → U04). Koofr has no multipart upload, so parallel files are the only way to fill the upload link. |
| `--tpslimit` / `--tpslimit-burst` | 40 / 40 | unlimited | Koofr returns `429 Too Many Requests` after about 550 requests in about 10 s, with no `Retry-After`, and rclone gave up on those files (D14: 46 failures; D15: all 300 failed). At 40/s, 600 requests in 14 s gave 0 errors at 42 files/s (D17a/b). At 20/s it was safe but capped at 20 files/s (D14b/D16). Big files only make 3–4 requests/s, so they don't notice the cap. |
| `--timeout` | **30m** | 5m | **Must outlast Koofr's folder renames. Don't lower it.** Renaming a folder is one API call, and Koofr answers only when every file inside has been moved: about 11 ms per file (8,000 files took 86.5 s, Y1). If rclone gives up first, Koofr keeps moving in the background, and rclone's file-by-file fallback races it and **deletes files** (Y2: 8 of 2,000 lost, and 16 real files lost with the earlier `1m` value). 30m covers about 160,000 files. The cost is that a truly dead connection takes up to 30 min to drop (seen once in 70 runs, U02, on a background upload). See [RESEARCH.md §13](../docs/RESEARCH.md#13-incident-folder-renames-deleted-files-2026-11-07). |
| `--vfs-read-chunk-streams` | 16 | 0 (sequential) | **Biggest speed-up.** Downloads each file in 16 parallel ranged requests. A cold 1 GiB read went from 6.4–11.2 MiB/s to 20.4–27.5 MiB/s, across 4 interleaved rounds on 2 rclone versions (AB tests). Added in rclone 1.68. The 2023 forum thread about mount being "20× slower than copy" predates it. |
| `--vfs-read-chunk-size` | 8M | 128M | Chunk size used with the parallel streams. 16 × 8M and 8 × 32M were equally fast (AB tests). 16 × 8M is the one that never hung. |
| `--vfs-cache-mode` | full | off | Reads and writes go through the local cache. A re-read of a cached 1 GiB file ran at about 2.5 GB/s (M01w, served from Windows' RAM cache). Mode `writes` was slower on cold reads too: 16.3 vs 24.4 MiB/s (M07). |
| `--vfs-cache-max-size` | 100G (set to fit your disk) | off | Size cap. The oldest files are evicted first. |
| `--vfs-cache-min-free-space` | 10G | off | Safety net. The original setup had a 100G cap on a disk with 93 GB free, so it could have filled the disk. |
| `--vfs-cache-max-age` | 999h | 1h | Keep cached files for weeks, so re-opens are instant. |
| `--vfs-cache-poll-interval` | 1m | 1m | Only how often the cache is tidied. At 15s it wrote about 5,760 identical log lines a day: 19,976 of the last 20,000 lines in the old log. |
| `--vfs-read-ahead` | 256M | 0 | Extra prefetch, on disk, in full mode. Kept from the original setup. Not separately tested. |
| `--vfs-write-back` | 10s | 5s | Upload 10 s after a file is closed. Shorter starts uploads sooner (W04 used 2s and finished 8 s earlier), but a program that saves repeatedly then uploads more often. 10s is a good balance. |
| `--vfs-fast-fingerprint` | on | off | Skips slow metadata reads when checking cache validity. Removing it was no faster (S03 vs S01). |
| `--dir-cache-time` | 1h | 5m | Koofr has **no change notifications** (`ChangeNotify: false`). Changes made elsewhere show up when this expires, or when you use the refresh shortcut. Listings are cheap (0.1–0.5 s for 300 files: L01/L02, S01), so `10m` is fine if you'd rather not use the shortcut. |
| `--network-mode` | on | off | Shows as a network drive in Windows. Requires a drive letter. |
| `--links` | on | off | Stores symlinks as `.rclonelink` files. |
| `--log-file-max-size` / `--log-file-max-backups` | 5M / 3 | off | Log rotation. The old log had grown to 27.6 MB. |
| `--rc --rc-addr 127.0.0.1:5572` | on | off | Local-only remote control, used by the refresh shortcut (`vfs/forget` + `vfs/refresh`). The username and password come from the `RCLONE_RC_USER` / `RCLONE_RC_PASS` environment variables, so the password isn't visible in the process list. Without them it returns 401 (watchdog test T3). |

## Flags that don't help with Koofr

| Flag | Why not |
|---|---|
| `--fast-list` | Koofr has no recursive listing (`ListR: false`), so it does nothing. |
| `--multi-thread-streams` | Applies to `rclone copy`, not mount reads (use `--vfs-read-chunk-streams` there). For copy/sync, 16 is good (D05). |
| `--checkers` | No effect on the mount. |
| Chunked / multipart upload flags | Koofr has none (`OpenChunkWriter: false`). A single big upload is one stream, about 10 MiB/s here (U12). |

## For `rclone copy` / `sync` (not the mount)

```bat
rclone copy SRC koofr:DEST --disable-http2 --transfers 16 --multi-thread-streams 16 --tpslimit 40 --tpslimit-burst 40 --timeout 30m
```

`rclone move` / `moveto` of a folder makes the same single Koofr move call, so keep the long timeout there too (X1: with a 10 s timeout, a 2,000-file folder move turned into 3,994 errors and 5 minutes of retries).

## Renaming big folders

Explorer waits for the whole rename, so renaming a folder of *N* files on the drive freezes Explorer for about *N* × 11 ms (11,000 files ≈ 2 min). Windows may then close Explorer ("stopped interacting with Windows"), which takes the taskbar with it. Nothing is lost when that happens, as long as `--timeout` is long enough. For folders with thousands of files, it's nicer to rename them in the Koofr web app and then use the refresh shortcut.
