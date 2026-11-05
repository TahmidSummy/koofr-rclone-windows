# Tuning rclone for Koofr on Windows: research, tests and findings

*Lab session: 5 November 2026, 18:58–20:57 (benchmarks), plus watchdog tests afterwards. 71 timed benchmark runs and 17 watchdog tests. Every raw number is in [`bench/results/results.csv`](../bench/results/results.csv) and every rclone log in [`bench/logs/`](../bench/logs/).*

---

## Contents
1. [Summary](#1-summary)
2. [Test environment](#2-test-environment)
3. [Starting point: the original setup and its problems](#3-starting-point-the-original-setup-and-its-problems)
4. [What the research said](#4-what-the-research-said)
5. [Method](#5-method)
6. [Results](#6-results)
7. [Problems and incidents during testing](#7-problems-and-incidents-during-testing)
8. [Reliability: watchdog, internet check and refresh](#8-reliability-watchdog-internet-check-and-refresh)
9. [Final configuration and before/after](#9-final-configuration-and-beforeafter)
10. [Limits of this study](#10-limits-of-this-study)
11. [Reproducing the tests](#11-reproducing-the-tests)
12. [Sources](#12-sources)

---

## 1. Summary

| Finding | Evidence | Action |
|---|---|---|
| HTTP/2 badly hurts Koofr, and not only for parallel transfers as forum posts said | Single 1 GiB upload: 3.2 MiB/s with HTTP/2 vs 10.4 without (U11/U12). 4-stream download: 2.7 vs 15.8 and 16.4 vs 30.5 (D01/D03, two rounds) | Keep `--disable-http2` everywhere |
| Mount reads were single-stream and slow. Parallel chunk reads fix it | Cold 1 GiB read via mount: 6.4–11.2 MiB/s → 20.4–27.5 MiB/s, in 4 of 4 interleaved rounds (AB tests) | `--vfs-read-chunk-streams 16 --vfs-read-chunk-size 8M` |
| That feature hung once on rclone 1.74.2 | M06 read froze for 39 min with the whole file already cached | Require rclone ≥ 1.75.2 (0 hangs in 7 runs) |
| Koofr rate-limits at roughly 50+ requests/s, with no `Retry-After`. rclone doesn't retry the 429s | D14: 46/300 files failed. D15: 300/300 failed | `--tpslimit 40 --tpslimit-burst 40` (0 errors in 600 requests) |
| Parallel uploads are the main upload lever, because Koofr has no multipart upload | Small files 4.4 → 37.3 files/s (4 → 32 transfers). Mount writes 11.5 → 18.5 MiB/s (4 → 16) | `--transfers 16` |
| Dead connections can sit for rclone's full 5-minute timeout | U02: no progress for exactly 5 m 0 s, then done in about 40 s | `--timeout 1m` |
| Koofr has a fixed ~0.3 s per-file cost | Downloads 12.8 files/s at 4 transfers ≈ 0.31 s/file/stream (D12). Mount sequential opens 2.9 files/s ≈ 0.34 s/file (S01) | Nothing to tune. Parallelism is the only cure |
| Koofr speed varies up to ~2× across an evening | D03 15.8 → 30.5 MiB/s, same settings, 70 min apart | Repeat and interleave comparisons |
| Koofr has no change notifications | rclone log: `poll-interval is not supported by this remote`. Backend feature `ChangeNotify: false` | Refresh shortcut (`vfs/forget` over the rc API) |

---

## 2. Test environment

| Item | Value |
|---|---|
| OS | Windows 11 Pro 25H2 (build 26200) |
| rclone | 1.74.2 (installed via winget). 1.75.2 portable for comparison, checksum-verified against `downloads.rclone.org` SHA256SUMS |
| WinFsp | installed (launcher service running) |
| Internet | ~770 Mbit/s down (1 GB from `proof.ovh.net` at 96.6 MB/s), ~110 Mbit/s up (Cloudflare `__up`, 13.3–17.2 MB/s) |
| Latency to Koofr | 29 ms average (28–31) to `app.koofr.net` (Koofr is in Slovenia; client in the UK) |
| Koofr account | 1 TiB plan, ~743 GiB used, ~290 GiB free |
| Koofr backend features (`rclone backend features koofr:`) | `About`, `Copy`, `Move`, `DirMove`, `PutStream`, `PublicLink`, `CaseInsensitive`, `CanHaveEmptyDirectories` = true. **`ChangeNotify`, `ListR`, `OpenChunkWriter`, `OpenWriterAt`, `Purge` = false** |
| Cache / lab disk | Kingston A400 480 GB **SATA** SSD, NTFS, 93 GB free |
| Live mount during tests | The user's real `Z:` mount stayed up the whole time, idle. Test mounts used `W:` with their own cache folders |

What the backend features mean in practice:
- **No `ChangeNotify`:** changes made elsewhere only appear after `--dir-cache-time` expires.
- **No `ListR`:** `--fast-list` does nothing.
- **No `OpenChunkWriter` / `OpenWriterAt`:** no multipart or multi-thread upload of a single file.
- **No `Purge`:** `rclone purge` falls back to deleting files one at a time.

---

## 3. Starting point: the original setup and its problems

The original mount, started at logon by a scheduled task through a PowerShell script:

```
rclone mount koofr: Z: --vfs-cache-mode full --network-mode --links --no-console --disable-http2
  --dir-cache-time 1h --vfs-cache-max-age 999h --vfs-cache-max-size 100G --vfs-cache-poll-interval 15s
  --vfs-read-ahead 256M --vfs-fast-fingerprint --vfs-write-back 10s --cache-dir E:\main-rclone-cache
  --log-level INFO --log-file %USERPROFILE%\rclone-Koofr.log
```

Problems found by reviewing it, before any benchmarking:

| # | Problem | Detail |
|---|---|---|
| 1 | Nothing remounted the drive if rclone died | The script only ran at logon. A crash meant no drive until the next logon, with no notification. |
| 2 | Cache cap bigger than the disk | `--vfs-cache-max-size 100G` on a disk with 93 GB free. Heavy use could fill the disk. |
| 3 | Log grew forever, almost all noise | 27.6 MB since June. 19,976 of the last 20,000 lines were the same message, `vfs cache: cleaned: objects 0 …`, written every 15 s because of `--vfs-cache-poll-interval 15s`. There was no rotation. |
| 4 | The internet check had a bug | It used `BeginConnect` + `AsyncWaitHandle.WaitOne(3000)`, which is true once the attempt *completes*, including when the connection is refused. It also looped forever with no notification. Proven in watchdog test T2: the old check reported a refused port as "up". |
| 5 | Changes from other devices invisible for up to an hour | `--dir-cache-time 1h`, and Koofr can't push changes. |
| 6 | It waited 60 s even when rclone failed instantly | The script polled for the drive 12 × 5 s without checking whether rclone had already exited. |

The live log had **no errors**. The mount itself was healthy, just not tuned.

---

## 4. What the research said

### 4.1 Forum threads (forum.rclone.org)

| Thread | Date | What it found |
|---|---|---|
| *Multithread upload speed slowed down to single-thread-speed for Koofr* | Jan 2023 | rclone 1.61.1, `--transfers 16` to Koofr dropped from 32 Mbps to 12 Mbps, the single-thread speed. Only Koofr was affected (not pCloud or HiDrive). Fix: `--disable-http2`. The reporter: "indeed, --disable-http2 did the trick". No maintainer diagnosis. |
| *Download transfer speed via mount 20x slower than via copy/sync* | Jun 2023 | A 4.5 GB file read about 1 MB/s through the mount against about 20 MB/s with `rclone copy`, even with `--disable-http2 --transfers 20 --multi-thread-streams 20`. Switching `writes` → `full` cache made no difference. Maintainer view: mounts aren't multi-threaded on downloads, but copy/sync are. It remained unresolved, and points to GitHub issue #4760 (multi-threaded downloads into the VFS cache). |
| *Ways to improve upload speed of large single file* | Jun 2023 | No multipart upload or chunk size for Koofr, so a single file is one stream, bound by latency. A respondent said `--disable-http2` was "only relevant to parallel transfers". **Our U11/U12 contradicts that.** |
| *Disable HTTP2 in conf file* | Dec 2024 | A user cited 10 MB/s with HTTP/2 vs 40 MB/s without on Koofr. The answer: it's a global flag, not a config option "for now". |
| *FRQ: --disable-http2 as standard* | Jan 2025 | A proposal to make HTTP/2 off the default, because Go "won't fix their bug". Koofr was the first provider this was reported for. Results on OneDrive were mixed. A maintainer asked for benchmarks. It was closed without a change. |

### 4.2 rclone documentation
- **Koofr backend options:** `provider`, `endpoint`, `user`, `password` (an app password, obscured), `mountid`, `setmtime` (default true), `encoding`. There are **no** chunk, upload or HTTP options. Koofr is case-insensitive.
- **VFS:**
  - `--vfs-read-chunk-streams` (added in **v1.68.0**, 2024-09-08): ">0 = that many parallel chunks of constant size", with an S3 example of `16` streams × `4M`. Defaults are `--vfs-read-chunk-size 128Mi`, `--vfs-cache-poll-interval 1m`, `--dir-cache-time 5m`, `--vfs-write-back 5s` and `--vfs-cache-max-age 1h`.
  - `--vfs-cache-min-free-space` exists (default off).
  - `--transfers` sets parallel uploads from the VFS cache. `--checkers` has no effect on the VFS.
  - FAT/exFAT has no sparse files, so full mode "performs very badly" there.
- **Global flags:** `--multi-thread-streams` default 4 and `--multi-thread-cutoff` default 256M. Log rotation via `--log-file-max-size`, `--log-file-max-backups` and `--log-file-max-age`. Every option can be set as `RCLONE_<FLAG>`, for example `RCLONE_RC_PASS`. A remote's config section can contain `override.disable_http2 = true`. That's documented, but we didn't test it.
- **Changelog items that matter:**
  - v1.75.0 "chunkedreader: Fix spurious errors when a parallel stream is closed early"
  - v1.75.0 "fserrors: Make http2 'server sent GOAWAY' a retriable error"
  - v1.75.1 "vfscache: Fix reader deadlock when the item size drops below the read offset"
  - v1.75.2 "Fix reads returning zeros after a file changes during handle caching", plus Go/x/net HTTP/2 security fixes

  No Koofr-specific entries were found in the parts read (v1.62 → v1.75.2).

### 4.3 What nobody had tried
None of the Koofr threads tried `--vfs-read-chunk-streams`, because it didn't exist yet in 2023. Nobody had measured Koofr's rate limit either. Those became the two main experiments.

---

## 5. Method

### 5.1 Layout
- **On E: (`E:\rclone-lab`):** `data\` (test files), `scripts\`, `logs\`, `results\`, `dl\` (download targets, wiped after each run), `cache\<test-id>\` (a fresh VFS cache per mount test).
- **On Koofr:** `koofr:_rclone-lab/` (a throwaway folder). It held `src/` (the download source, seeded once), `up/<id>/` (one new folder per upload test) and `up-mount/<id>/`. It was **purged afterwards**, and Koofr usage returned to exactly 743.428 GiB.
- **Test data** (random, incompressible bytes from `RandomNumberGenerator`):
  - **small:** 300 × 64 KiB (18.75 MiB). Lots of per-file overhead.
  - **medium:** 20 × 25 MiB (500 MiB). Below the 256M multi-thread cutoff.
  - **large:** 1 × 1 GiB. Above the cutoff, a single stream unless multi-threaded.

### 5.2 How each kind of test was measured
- **Upload / download (`rclone copy`):** wall-clock time of the whole rclone process, with `--retries 1 --low-level-retries 3`, so failures show up instead of being hidden by retries. Each run got its own `--log-file`. Every download was size-checked against the source.
- **Mount reads:** a fresh test mount on `W:` with an **empty cache** each time, then the file read sequentially with a 1 MiB buffer into nothing. That measures what a video player or `copy` would see.
- **Mount small files:** list a folder of 300 files, then open and read each one in turn (64 KiB buffer). Then re-list to measure the warm directory cache.
- **Mount writes:** `Copy-Item` 20 × 25 MiB onto `W:`, then poll `rclone lsjson` on the remote every 2 s until all 20 files are there at full size. The time includes the `--vfs-write-back` delay.
- **A/B rounds:** after the first mount-read pass looked noisy, the candidates were run **interleaved** (A, B, C, A, B, C) with a 5-minute watchdog per read. Both versions got the same conditions.

### 5.3 Noise
Speeds on identical settings varied up to about 2× over the evening (D03 15.8 → 30.5 MiB/s). Conclusions are only drawn where the gap is bigger than that, or where it held in every interleaved round.

---

## 6. Results

All speeds are MiB/s unless marked files/s. "H2" means HTTP/2. `--disable-http2` = H2 off.

### 6.1 Uploads (`rclone copy` E: → Koofr), 18:58–19:21

| ID | Data | Settings | Time | Speed |
|---|---|---|---|---|
| U01 | 300 × 64 KiB | H2 on, 4 transfers (rclone defaults) | 47.9 s | 6.26 files/s |
| U02 | 300 × 64 KiB | H2 off, 4 transfers (original setup) | **348.5 s** | 0.86 files/s (5-minute stall, §7.1) |
| U02b | 300 × 64 KiB | same, re-run | 68.0 s | 4.41 files/s |
| U03 | 300 × 64 KiB | H2 off, 8 transfers | 24.2 s | 12.41 files/s |
| U04 | 300 × 64 KiB | H2 off, 16 transfers | 13.8 s | 21.79 files/s |
| U05 | 300 × 64 KiB | H2 off, 32 transfers | 8.1 s | 37.29 files/s |
| U06 | 300 × 64 KiB | H2 on, 16 transfers | 11.8 s | 25.53 files/s |
| U07 | 20 × 25 MiB | H2 on, 4 transfers | 62.9 s | 7.95 |
| U08 | 20 × 25 MiB | H2 off, 4 transfers | 50.0 s | 10.01 |
| U09 | 20 × 25 MiB | H2 off, 8 transfers | 34.3 s | 14.57 |
| U10 | 20 × 25 MiB | H2 off, 16 transfers | 32.0 s | 15.61 |
| U11 | 1 × 1 GiB | H2 on | 317.9 s | **3.22** |
| U12 | 1 × 1 GiB | H2 off | 98.4 s | **10.41** |

**Reading it:**
- **Small files:** these scale almost linearly with parallelism up to 32. Each file costs a fixed few hundred ms of round trips.
- **Medium files:** these level off at 8–16 transfers, around 15 MiB/s. That's about the upload line, which Cloudflare measured at 13.3–17.2 MB/s.
- **HTTP/2 on a single large upload:** 3.2× slower. This contradicts the forum view that HTTP/2 only matters for parallel transfers.
- **HTTP/2 with small files:** on vs off was similar at 16 transfers (U06 vs U04), and on was faster at 4 (U01 vs U02b). For tiny files, HTTP/2's multiplexing helps a little. For anything substantial it's a disaster. Net decision: off.

### 6.2 Downloads (`rclone copy` Koofr → E:), 19:27–19:37, with repeats at 19:39–19:44

| ID | Data | Settings | Round 1 | Round 2 |
|---|---|---|---|---|
| D02 | 1 GiB | H2 off, single stream (`--multi-thread-streams 0`) | 5.10 | – |
| D01 / D01b | 1 GiB | H2 on, 4 streams (rclone defaults) | **2.74** | 16.44 |
| D03 / D03b | 1 GiB | H2 off, 4 streams | 15.78 | 30.45 |
| D04 | 1 GiB | H2 off, 8 streams | 20.20 | – |
| D06 | 1 GiB | H2 off, 8 streams, 16M chunks | 25.36 | – |
| D05 / D05b | 1 GiB | H2 off, 16 streams | 25.75 | 36.07 |
| D07 / D07b | 1 GiB | H2 on, 16 streams | 28.79 | 38.56 |
| D08 | 20 × 25 MiB | H2 off, 4 transfers | 14.11 | – |
| D09 | 20 × 25 MiB | H2 off, 8 transfers | 21.24 | – |
| D10 | 20 × 25 MiB | H2 off, 16 transfers | 22.82 | – |
| D11 | 20 × 25 MiB | H2 on, 8 transfers | 24.03 | – |
| D12 | 300 × 64 KiB | H2 off, 4 transfers | 12.83 files/s | – |
| D13 / D13b | 300 × 64 KiB | H2 off, 16 transfers | 53.87 files/s | 52.68 files/s |
| D14 | 300 × 64 KiB | H2 off, 32 transfers | 77 files/s, **46 files failed (429)** | – |
| D15 | 300 × 64 KiB | H2 on, 16 transfers | **all 300 failed (429)** | 74.19 files/s (D15b, after a 90 s pause) |
| L01 | list 300 files | H2 on | 0.32 s | – |
| L02 | list 300 files | H2 off | 0.53 s | – |

**Reading it:**
- **Multi-stream downloads help a lot.** One stream got 5.1 MiB/s and 16 streams got 26–36 MiB/s.
- **HTTP/2 at 4 streams was terrible in both rounds** (2.7 and 16.4, against 15.8 and 30.5 with it off). At 16 streams it was about the same as off. With HTTP/2, rclone multiplexes all streams over one TCP connection, so a single slow connection limits everything.
- **The CSV's "306 files/s" for D15 is not real.** All 300 requests failed instantly.

### 6.3 Koofr's rate limit

| ID | Settings | Result |
|---|---|---|
| D13 → D14 → D15 | 16, then 32, then 16 transfers back to back | The first 429 came about 550 requests into the burst (254 files into D14, after D13's 300). The 429s came within about 2 s, and the limit had cleared when checked a minute or two later |
| D14b, D16 | 32 or 16 transfers, `--tpslimit 20 --tpslimit-burst 20` | 0 errors, but capped at 20.5 files/s |
| D17a + D17b | 32 transfers, `--tpslimit 40 --tpslimit-burst 40`, two runs back to back (600 requests in about 14 s) | **0 errors**, 42.1 / 42.8 files/s |

The 429 response is a bare HTML page with `Cache-Control: no-cache`. It has **no `Retry-After` header**. rclone reported `failed to open source object: Invalid response status! Got 429, expected [200 206]` and didn't retry within `--low-level-retries 3`. Our reading is a request-rate limiter somewhere above about 50 requests/s, with a short memory, because a 90 s pause fully reset it.

### 6.4 Mount: reading a 1 GiB file, cold cache (first pass, 19:46–20:30)

| ID | Settings (on top of the original flags) | Speed |
|---|---|---|
| M01 | original flags | 24.43 |
| M01w | same file read again (warm) | 2,570 (served from Windows' RAM file cache; see §7.9) |
| M02 | HTTP/2 on | 17.66 |
| M07 | `--vfs-cache-mode writes` (no read cache) | 16.29 |
| M03 | 4 chunk streams × 16M | 18.20 |
| M04 | 8 × 16M | 22.84 |
| M05 | 16 × 8M | 32.94 |
| M06 | 8 × 32M | **HUNG for 39 min** (§7.3) |

That pass suggested 16 × 8M was best, but the gap (24 → 33) was within the noise. So the main candidates were re-run interleaved.

### 6.5 Mount: interleaved A/B reads (20:39–20:53)

| Settings | 1.74.2 round 1 | 1.74.2 round 2 | 1.75.2 round 1 | 1.75.2 round 2 |
|---|---|---|---|---|
| original flags | 6.40 | 7.90 | 9.57 | 11.22 |
| + 16 streams × 8M | **20.42** | **23.68** | **26.82** | **27.48** |
| + 8 streams × 32M | 22.59 | 24.84 | 29.65 | 27.73 |

- **Parallel chunk reads won all 8 comparisons, by 2.4–3.3×.**
- 8 × 32M didn't hang in these 4 runs, even on 1.74.2, so the hang is intermittent.
- 16 × 8M was chosen because it never hung (7/7 runs across M05 and the AB tests). It's as fast as 8 × 32M, and on 1.75.2 it's covered by the reader-deadlock fixes.
- 1.75.2 looked a bit faster than 1.74.2. But the versions ran 7 minutes apart and the gap is within the noise, so **no speed claim is made for the upgrade itself.**

### 6.6 Mount: folder browsing and small files (20:32–20:35)

| ID | Settings | List 300 files | Open + read 300 × 64 KiB one by one | Re-list (warm) |
|---|---|---|---|---|
| S01 | original flags | 0.12 s | 103.1 s (2.91 files/s) | 0.01 s |
| S02 | + 16 × 8M chunk streams | 0.10 s | 71.3 s (4.21 files/s) | 0.01 s |
| S03 | original minus `--vfs-fast-fingerprint` | 0.10 s | 79.2 s (3.79 files/s) | 0.01 s |

About 0.25–0.34 s per file, sequentially. That's the same per-file cost as `rclone copy` (D12: 12.83 files/s ÷ 4 streams ≈ 0.31 s per file per stream). So it's **Koofr's per-request latency, not the mount**. The S01–S03 differences are within the noise. Listings are fast, and the warm dir cache is instant.

### 6.7 Mount: writing (20:35–20:37)

| ID | Settings | Copy onto W: | Until all 20 files on Koofr | Effective speed |
|---|---|---|---|---|
| W01 | original (4 uploads at once) | 0.9 s | 43.6 s | 11.47 |
| W02 | + `--transfers 8` | 0.7 s | 34.2 s | 14.64 |
| W03 | + `--transfers 16` | 0.7 s | 27.1 s | 18.46 |
| W04 | `--transfers 8` + `--vfs-write-back 2s` | 0.7 s | 18.2 s | 27.50 |

- Writing to the mount is instant every time (the files land in the cache).
- The upload time drops with more parallel uploads.
- **W04's gain is partly an artefact.** Uploads start 8 s earlier (write-back of 2 s vs 10 s), and that's included in the time. Shorter write-back also means more re-uploads when a program saves the same file repeatedly, so 10s was kept.

### 6.8 Smoke test of the final flags (20:57)
A mount with every recommended flag, on rclone 1.75.2: a cold 1 GiB read ran at **30.81 MiB/s**, with no errors or unknown-flag warnings in the log.

---

## 7. Problems and incidents during testing

### 7.1 The 5-minute stall (U02)
The rclone log shows `Transferred: 0 / 300` in every stats line from 18:58:56 until about 19:03:55, with nothing moving. Then all 300 files went through in about 43 s. Five minutes is exactly rclone's default `--timeout`, the IO idle timeout. A connection went dead silently, and rclone waited the full timeout before abandoning it. The re-run (U02b) took 68 s with no stall. We couldn't reproduce it on demand. **Mitigation:** `--timeout 1m`.

### 7.2 Rate limiting (D14/D15)
See §6.3. It also showed that **one heavy test can break the next one**, since D15 failed purely because D14 had just tripped the limiter. From then on, heavy tests had pauses between them (90 s, then 20 s between runs).

### 7.3 The M06 hang (rclone 1.74.2)
A cold read with `--vfs-read-chunk-streams 8 --vfs-read-chunk-size 32M` stopped making progress. 39 minutes later the cache held the whole 1,024 MiB file, but the reader never returned. The log just repeated `vfs cache: cleaned: objects 1 (was 1) in use 1 …`. The mount was killed and the run recorded as a hang. This matches the kind of bugs fixed in v1.75.0 (parallel stream closed early) and v1.75.1 (reader deadlock). **Mitigation:** require rclone ≥ 1.75.2, and use 16 × 8M. The A/B script got a 5-minute watchdog per read so a hang can't stall a run again.

### 7.4 Speed swings
The same test varied by up to 2× over 70 minutes (D03 15.8 → D03b 30.5, D01 2.7 → D01b 16.4). Original-flag mount reads went from 24.4 MiB/s (M01, 19:46) to 6.4 (AB, 20:40). That's why the conclusions rest on repeats and interleaving, not single runs.

### 7.5 Cloudflare speed test refused big downloads
`speed.cloudflare.com/__down?bytes=200000000` returned **HTTP 403**, with a 1-byte body. 25 MB worked. Download speed was taken from `proof.ovh.net/files/1Gb.dat` (96.6 MB/s) and `nbg1-speed.hetzner.com/1GB.bin` (31.5 MB/s) instead. Cloudflare upload worked.

### 7.6 A harness bug: `$Args`
The first watchdog test run reported several failures that took only 0.6–0.8 s. The test helper had a parameter named `$Args`, which clashes with PowerShell's automatic `$args`, so the mount script got no arguments and did nothing. After renaming it to `$MArgs`, all tests passed. Lesson: a test that "fails" in under a second is probably testing nothing.

### 7.7 Reading rclone's log while rclone is writing it
`[IO.File]::ReadLines` threw "being used by another process". The health check now opens the log with `FileShare.ReadWrite`.

### 7.8 Scheduled tasks
- `Set-ScheduledTask` on the original "Koofr Mount" task returned **Access is denied**, because it had been created from an elevated session. The watchdog was added as a separate user-level task instead. A named mutex in the script stops two copies running at once. The installer in this repo creates everything as the user, so this can't happen on a fresh install.
- `conhost.exe --headless powershell.exe …`, used so the 15-minute task doesn't flash a window, **did nothing when started with `&` from an interactive console**. Started with `Start-Process`, or from a real scheduled task (verified with a temporary task that wrote a file), it works.

### 7.9 A correction: the "2.5 GB/s from the E: cache"
M01w read a cached 1 GiB file at 2,570 MiB/s. A SATA SSD tops out around 550 MB/s, so that read came from **Windows' RAM file cache**, not the disk. Reads from the on-disk cache after a reboot will be at SSD speed (hundreds of MB/s), which is still far faster than Koofr. The practical point stands. It's also why moving the cache to NVMe was judged not worth doing: Koofr, at about 30 MiB/s, is the bottleneck either way.

---

## 8. Reliability: watchdog, internet check and refresh

### 8.1 Design
`Mount-Koofr.ps1` runs at logon and every 15 minutes:
1. **Health check in a separate process** (`Start-Job`, 30 s timeout). The script lists the drive root. If it answers, the script exits silently in about 1 s. A frozen WinFsp drive can block the caller forever, which is why the check runs in a separate process.
2. **Frozen:** wait 30 s, check again, and if it's still frozen, kill rclone, remount and notify *"was frozen"*.
3. **Missing:** if an rclone process for that letter exists, wait 20 s, then clear it. If the drive had been mounted earlier in this logon (a flag file newer than `explorer.exe`'s start time), notify *"had dropped"* after remounting.
4. **Internet:** a TCP connect to 1.1.1.1:443 must actually succeed (`ConnectAsync` + `Connected`). It gives up after 5 minutes and notifies at most once an hour.
5. **Mount:** start rclone with `-PassThru`. If the process exits during the wait, read rclone's last `ERROR`/`CRITICAL` log line since launch and put it in the notification.
6. **Remote control:** `--rc --rc-addr 127.0.0.1:5572`, with the username and password passed as `RCLONE_RC_USER`/`RCLONE_RC_PASS` environment variables. The password is random, stored in `%LOCALAPPDATA%\KoofrMount\rc.pass`, and never on the command line. The refresh shortcut calls `vfs/forget` and then `vfs/refresh`.
7. Notifications for ongoing problems are throttled, so they don't repeat every 15 minutes.

### 8.2 Tests (throwaway `W:` mount, notifications logged instead of shown)

| Test | What | Result |
|---|---|---|
| T1 | All 4 scripts parse | PASS |
| T2 | Internet check: 1.1.1.1:443 up, refused port down, unreachable address down | PASS. The **old** check said the refused port was **up** (bug confirmed) |
| T3 | Fresh mount, rc answers with the password, refuses without it (401), password not on the command line | PASS (mounted in 5.8 s) |
| T4 | Healthy drive: watchdog takes no action, same rclone PID | PASS (0.6 s, 0 log lines) |
| T5 | Refresh script clears the listings | PASS |
| T6 | Frozen drive (rclone suspended with `NtSuspendProcess`): detected, restarted | PASS (95.8 s total = 30 s timeout + 30 s wait + 30 s re-check + 5 s mount) |
| T7 | Dropped drive (rclone killed): remounted, "had dropped" notification | PASS (5.8 s) |
| T8 | Broken config (`nosuchremote:`): fails fast with rclone's reason | PASS (5.8 s, `didn't find section in config file ("nosuchremote")`) |
| T9 | Health check runs, writes a report, and flags the test's restarts | PASS |

The first run of this suite showed 7 false failures, caused by the `$Args` harness bug (§7.6). Raw results: `bench/results/watchdog-tests.csv`.

### 8.3 Installer tests
The repo's `Install-KoofrMount.ps1` and `Uninstall-KoofrMount.ps1` were tested end to end on a throwaway `W:` drive. They used their own task prefix, rc port, log and cache, while the live `Z:` mount kept running. All 15 checks passed. Raw results: `bench/results/installer-tests.csv`.

| Check | Result |
|---|---|
| Installer finishes ("All set") and the drive mounts | PASS |
| Mount task has logon + every-15-minute triggers, runs as the user (RunLevel Limited), hidden via `conhost --headless` | PASS |
| Weekly health-check task created | PASS |
| rclone runs with every tuned flag, and the rc password isn't on the command line | PASS |
| A scheduled watchdog run leaves a healthy drive alone (same PID, result 0) | PASS |
| The desktop shortcut refreshes the drive | PASS |
| Re-running without `-Force` refuses (task already exists) | PASS |
| Refuses a drive letter used by something else (`C:`) | PASS |
| Uninstall removes the tasks, drive, shortcut, scripts and cache | PASS |
| Uninstall keeps the shared state folder while another Koofr drive still uses it | PASS |
| Live `Z:` untouched (same rclone PID) and its refresh still works | PASS |

Two bugs were found and fixed while writing this test, before it ran. A second drive would have shared the first drive's rclone log file, so there's now a `-LogName` parameter. Uninstalling one drive would also have deleted the refresh password the other drive uses; it now keeps the state folder while another Koofr task exists.

---

## 9. Final configuration and before/after

The flags and the reason for each are in [`config/mount-flags.md`](../config/mount-flags.md). In short, compared with the original:

| Added or changed | From → to |
|---|---|
| rclone | 1.74.2 → **1.75.2** |
| `--transfers` | 4 → **16** |
| `--vfs-read-chunk-streams` / `--vfs-read-chunk-size` | off / 128M → **16 / 8M** |
| `--tpslimit` / `--tpslimit-burst` | none → **40 / 40** |
| `--timeout` | 5m → **1m** |
| `--vfs-cache-min-free-space` | none → **10G** |
| `--vfs-cache-poll-interval` | 15s → **1m** |
| `--log-file-max-size` / `--log-file-max-backups` | none → **5M / 3** |
| `--rc --rc-addr 127.0.0.1:5572` | none → **on** (for the refresh shortcut) |
| Kept | `--disable-http2`, `--vfs-cache-mode full`, `--dir-cache-time 1h`, `--vfs-read-ahead 256M`, `--vfs-fast-fingerprint`, `--vfs-write-back 10s`, `--vfs-cache-max-age 999h`, `--vfs-cache-max-size 100G` |

| Day-to-day effect | Before | After |
|---|---|---|
| Big file, first open | 6–11 MiB/s | 20–31 MiB/s |
| Saving 500 MB onto the drive (until it's on Koofr) | 44 s | 27 s |
| Uploading 300 small files (copy) | 68 s | 14 s |
| Folder listing | 0.1 s | 0.1 s (unchanged) |
| Re-opening a cached file | instant | instant (unchanged) |
| Burst of many files | 429 failures | 0 failures |
| Dead connection | up to 5 min frozen | ≤ 1 min |
| rclone crash | drive gone until the next logon | back within 15 min, with a notification |

---

## 10. Limits of this study
- **One location, one evening.** Results come from one connection (770/110 Mbit, 29 ms) between 19:00 and 21:00. A very different connection, especially with higher latency, should re-run `bench/50-ab-read-tests.ps1` and `bench/60-tpslimit-test.ps1`.
- **Small number of runs.** 1–4 runs per setting, which is enough to see 2× and larger effects, not small ones.
- **Not tested:** `--buffer-size`, `--vfs-read-ahead` sizes, `--attr-timeout`, `--use-mmap`, random-access workloads (video seeking, databases), Explorer thumbnail storms, multi-hour soak with the new flags, `override.disable_http2` in the config file, and Koofr's limit for other request types (listings, uploads).
- **The `--timeout 1m` choice** is reasoned from one observed stall, not a reproduced one.
- **Koofr's rate limit** was observed, not documented by Koofr. It may change.

---

## 11. Reproducing the tests
See [`bench/README.md`](../bench/README.md). In short: set `KOOFR_LAB` to a lab folder on a local SSD (default `E:\rclone-lab`), make sure `koofr:_rclone-lab` doesn't hold anything you need, then run the numbered scripts in order. `90-cleanup.ps1` purges the Koofr test folder and the local test data. The whole suite moves about 8 GiB to and from Koofr and takes about 2 hours, mostly because of the deliberately slow configurations.

---

## 12. Sources
- rclone docs: [Koofr backend](https://rclone.org/koofr/), [rclone mount / VFS](https://rclone.org/commands/rclone_mount/), [global flags and config](https://rclone.org/docs/), [changelog](https://rclone.org/changelog/)
- forum.rclone.org:
  - [Multithread upload speed slowed down to single-thread speed for Koofr](https://forum.rclone.org/t/multithread-upload-speed-slowed-down-to-single-thread-speed-for-koofr/35427)
  - [Download transfer speed via mount 20x slower than via copy/sync](https://forum.rclone.org/t/download-transfer-speed-via-mount-20x-slower-than-via-copy-sync/39028)
  - [Ways how to improve upload speed of large single file](https://forum.rclone.org/t/ways-how-to-improve-upload-speed-of-large-single-file-with-sync-copy/39116)
  - [Disable HTTP2 in conf file](https://forum.rclone.org/t/disable-http2-in-conf-file/49149)
  - [FRQ: --disable-http2 as standard](https://forum.rclone.org/t/frq-disable-http2-as-standard/49467)
- GitHub: [rclone issue #4760](https://github.com/rclone/rclone/issues/4760), multi-threaded downloads into the VFS cache
