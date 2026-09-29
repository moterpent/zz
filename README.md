# zz (Zeasy) 
### *Minimalist, Snapshot-Aware ZFS Replication*

[![tests](https://github.com/moterpent/zz/actions/workflows/test.yml/badge.svg)](https://github.com/moterpent/zz/actions/workflows/test.yml)

**zz** is a lightweight Python utility designed to make ZFS off-site replication "Zeasy." It handles the heavy lifting of incremental sends, retention policies, and disaster recovery, ensuring your data is always backed up without the complexity of enterprise-grade storage orchestrators.

This project was started after years of frustration with other zfs replication tools.  There are far more mature, feature rich, and scalable solutions out there.  However, due to issues with setup, maintenance, breakage, recovery from breakage, and disaster recovery, and my own limitations, enough was enough.  It started with two main tenets.  Be simple and reliable.  A person with minimal zfs knowledge (ability to create/modify/destroy pools and datasets) should be able to do any of the following in under a minute:
1. Initialize and start replication with a replica server.
2. Determine the status of the replication.
3. Restore the primary from a replica and, once complete, resume replication with little or no fuss.

---

## 🚀 Key Features

* **Atomic Locking:** Internal file locking prevents overlapping cron jobs from colliding.
* **Sequential Catch-Up:** Automatically detects and sends missing snapshot history if the network or server was down.
* **Drift-Free Scheduling:** A 30-second allowance lets a snapshot fire on the cron run it is due, so the schedule doesn't creep later over time.
* **Dual Retention & Pruning:** Maintain independent history windows (e.g., keep 1 hour of history locally but 30 days remotely).
* **One-Command Recovery:** Rebuild a lost local dataset from your remote target with a single `restore` command.
* **Zero-Database:** All configuration is stored directly in ZFS user properties on the dataset itself.

---

## 🛠️ Installation

1.  Ensure **Python 3.7+** is installed on your host (Tested on Rocky Linux 9).
2.  Clone the repository and link the script onto your path (this lets `zz --version` report the exact commit):
    ```bash
    git clone https://github.com/moterpent/zz /usr/local/src/zz
    ln -s /usr/local/src/zz/zz /usr/local/bin/zz
    ```
    Or copy the `zz` script to `/usr/local/bin/` and `chmod +x` it.
3.  Ensure **SSH Key-Based Authentication** is configured from the local host to the remote host.

To update a cloned install: `git -C /usr/local/src/zz pull`.

---

## 📖 Usage Guide

### 1. Initialize a Relationship
To start backing up a dataset, use `init`. This performs the initial full transfer and sets the backup "contract."
```bash
zz init tank/data backup-server:pool/data --freq 5m --keep-local 1h --keep-remote 7d
```
When it finishes, `init` prints a clear success or failure line, the new dataset's status row, and next steps, including a reminder to schedule `zz sync` if no cron entry for it is found. If the initial transfer is interrupted, run the same command again to resume it.

### 2. Automate with Cron
Add zz sync to your crontab. It handles its own locking and timing checks.
```bash
* * * * * /usr/local/bin/zz sync >> /var/log/zz.out 2>&1
```
Each run logs a header with the version and time, then a line when each send starts and one when it finishes:
```
--- zz 0.6.0 (a1b2c3d) sync @ 2026-09-28 15:15:01 ---
[*] tank/data: Taking scheduled snapshot @zz_auto_1790630101...
    [>] Sending tank/data @zz_auto_1790626501 -> @zz_auto_1790630101...
    [+] Sent tank/data @zz_auto_1790626501 -> @zz_auto_1790630101: 5.8M in 0.4s
    [*] Pruning local...
    [*] Pruning remote (backup-server)...
```

Rotate the log with the included logrotate rule (weekly, 12 compressed weeks kept):
```bash
cp util/zz.logrotate /etc/logrotate.d/zz   # edit the path to match your cron line
```

#### Snapshot on demand
To take a snapshot and send it right away, without waiting for the next scheduled one:
```bash
zz sync tank/data --now      # --force is an alias
```
* Takes a snapshot now even if one isn't due, then runs a normal sync.
* Doesn't move the schedule: the next scheduled snapshot comes when it otherwise would have. If a scheduled snapshot happens to be due anyway, only one is taken.
* Doesn't force anything else. Locks, busy checks and errors (a diverged remote, a missing bridge snapshot) stop the sync exactly as without it, and the remote is never overwritten; zz never uses `zfs recv -F`.

Useful for a checkpoint before risky changes, or to test a new setup without waiting a full interval.

### 3. Check Status
View replication health for all managed datasets:
```bash
zz status
```
```
DATASET              | STATUS   | LAST SNAP          | LAG              | NEXT SNAP
------------------------------------------------------------------------------------------
tank/data            | OK       | 0:12:40 ago        | 0:12:40          | 0:47:20
```
* **LAST SNAP**: when the most recent scheduled snapshot was taken (`--now` snapshots aren't counted here).
* **LAG**: age of the newest snapshot confirmed on the remote, i.e. how far behind the replica is.
* **STATUS**: `OK`; `LAGGING` (lag over 2× freq + 5m); `STALLED` (lag over max(1 day, 4× freq)); `ERROR` (the last sync attempt failed; the reason is listed below the table); `INIT`; or `UNKNOWN` (no sync recorded yet).

`zz status` and `zz sync` exit non-zero when anything is unhealthy or failed, so either can drive monitoring or cron alerts.

### 3a. View Snapshots and Sizes
See both sides side by side, newest first:
```bash
zz snaps tank/data            # dataset is optional when only one is managed
```
```
SNAPSHOT (local time) |      GAP |  WRITTEN | LOCAL USED | REMOTE USED | STATE
------------------------------------------------------------------------------------------
2026-09-28 16:15      |     1:00 |     5.8M |       1.2M |           - | pending
2026-09-28 15:15      |     1:00 |     9.0M |       1.8M |          0B | both  <- bridge, held local + remote
2026-09-28 14:15      |     1:00 |   359.7M |       7.7M |        7.9M | both
...
LOCAL   167 snapshots, 41.6G held by snapshots, oldest 2026-09-21 16:55
REMOTE  191 snapshots, 46.0G held by snapshots, oldest 2026-09-20 16:55
```
* **GAP**: time since the previous snapshot; outages and `--now` snapshots stand out.
* **WRITTEN**: data changed during that interval, roughly the size of its send.
* **USED**: space that deleting that one snapshot would free on that side. Usually small, since data is shared with neighbouring snapshots; the newest snapshot on the remote typically shows 0B.
* **STATE**: `both`, `pending` (not yet sent), `local only`, or `remote only` (pruned locally, normal with a shorter local retention). The **bridge** is the newest snapshot on both sides; the next sync sends everything after it. It's marked with where it is protected by a `zz_bridge` hold (see Important Notes).
* Shows the newest 24 by default; `--limit N` or `--all` for more.

For any other `zfs list -t snap` output, including on a host that zz doesn't manage (such as the replica), `util/zz-delta` converts the epoch timestamps in `zz_auto_` names to readable times and gaps:
```bash
zfs list -t snap tank/data | util/zz-delta
```

### 4. Disaster Recovery (Restore)
Recreate a lost dataset from the remote (includes all metadata and history):
```bash
zz restore backup-server:pool/data tank/data
```
* Restores the newest `zz_auto_` snapshot with its full history (`--latest` for just that snapshot), mounts it, and makes it the managed primary again; the next `zz sync` resumes replication incrementally.
* If a restore is interrupted, run the same command again to resume it.
* Refuses to overwrite an existing dataset. Restoring to a different name while the original still replicates to that remote leaves the copy unmanaged.
* **Restore to an earlier point** with `--at`, for example when ransomware or a mistake has already replicated: `zz restore backup-server:pool/data tank/data --at "2026-09-28 01:00"` (the newest snapshot at or before that time), or `--at zz_auto_1790626501` (see `zz snaps`). The result is left unmanaged and the replica isn't touched; zz then shows two ways to continue: replicate to a new target, keeping the replica's history, or re-run with `--rollback-remote` to roll the replica back to that point, permanently deleting its newer snapshots, and resume replication.
* Child datasets are restored with it, and the whole tree is verified before the restore reports success. Children that had been deleted on the primary are left out (see Deleted Child Datasets below), and restore says where to find them.

### 5. Stop Tracking (Forget)
Remove zz management but keep your data.
```bash
zz forget tank/data
```
### 6. Manual Updates & Meta
Update a setting without re-initializing:
```bash
zz set tank/data freq 15m
```
`set` only works on datasets zz manages (start with `zz init`). `set target` is for reaching the **same** replica by another name (a new hostname, IP address or ssh alias): zz checks that the new location has the bridge snapshot, with the same GUID, before accepting it. To replicate somewhere new, `zz forget` the dataset and `zz init` it with the new target.
### 7. View the current "contract" for a specific dataset:
```bash
zz meta tank/data
```

## Command Line Usage
```
usage: zz [-h] [--version] <command> ...

Zeasy: Simplified ZFS Replication

options:
  -h, --help  show this help message and exit
  --version   show program's version number and exit

Commands:
  <command>
    init      Start replicating a dataset: <dataset> <host:pool/dataset> [--freq] [--keep-local] [--keep-remote] [--keep-min]
    sync      Snapshot if due and send to the remote: [dataset] [--now]
    status    Replication health of all managed datasets
    snaps     Snapshots on both sides with sizes: [dataset] [--limit N] [--all]
    meta      Show a dataset's settings: <dataset>
    set       Change a setting: <dataset> <prop> <value>
    abort     Discard an interrupted transfer on the remote: <dataset>
    forget    Stop managing a dataset (data is kept): <dataset>
    restore   Recreate a dataset from the remote: <host:pool/dataset> <dataset> [--at SNAPSHOT|TIME] [--latest]

Durations: 30m, 1h, 7d, 2w, 1y (a bare number means minutes).

Examples:
  zz init tank/data backup:pool/data --freq 1h
  zz status
  zz restore backup:pool/data tank/data
```

## 🔒 Security Considerations
* **zz runs as root and trusts `zz:` properties.** Any dataset with a locally set `zz:target` is replicated by `zz sync` (when no dataset is named) to wherever that property points. If you delegate ZFS permissions to other users (`zfs allow ... userprop`), they could set `zz:target` on their own datasets. In that case, name datasets explicitly in your cron line (`zz sync tank/data`) rather than running `zz sync` for everything.
* **Targets and dataset names are validated,** and every argument zz sends over ssh is quoted, so a crafted `zz:target` or dataset name can't run commands on either host. Hosts must be a hostname, `user@host`, an IP address or an ssh alias (use an ssh config alias for IPv6); dataset names may use letters, digits, `_ - . :` and `/`, but not spaces.
* **Push mode gives the primary root access to the backup host.** zz connects from the primary to the backup host as root and runs `zfs recv`, `zfs destroy` (pruning) and `zfs rollback` (only with `restore --rollback-remote`) there. If the primary is compromised, so are its backups on that host. Limit the exposure with a dedicated backup host and key, and keep other data off it. A pull mode, where the backup host connects to the primary instead, is being considered.
* **Encrypted datasets** are sent raw (`-w`), so the backup host never has the key and can't read the data.

## 🧪 Testing
Every push runs two suites on GitHub Actions:
* **Unit tests** (`tests/test_units.py`): parsing and formatting helpers, on Python 3.9 and 3.12. No ZFS or root needed:
  ```bash
  python3 tests/test_units.py
  ```
* **Integration tests** (`tests/run.sh`): real ZFS on two throwaway file-backed pools, covering init, sync, `--now`, bridge holds, send flags (compressed, large-block, encrypted raw, and pre-0.5 replications), child datasets (created, deleted, aged out, restored), point-in-time restore, command injection, locking between commands, concurrent runs, a diverged replica (pruning must never remove unsent snapshots), a missing bridge snapshot, and restores that resume after being interrupted mid-snapshot and between snapshots. Needs root and ZFS; existing pools are never touched, and everything it creates is destroyed on exit:
  ```bash
  sudo tests/run.sh             # everything (about 2 minutes)
  sudo tests/run.sh restore     # only tests whose name contains "restore"
  ```
  The "remote" is simulated on the same machine, so one host is enough.

## 🏷️ Versioning
`zz --version` reports the release version from `__version__` in the script. When run from a git checkout (e.g. `/usr/local/bin/zz` symlinked into a clone), the commit is appended, with `-dirty` if the script has local modifications:
```
zz 0.6.0 (06a5c6f)
```
The same string heads `zz status` output and each `zz sync` run in the log. Bump `__version__` for any behavior change.

## ⚙️ Configuration (The Contract)
zz stores configuration in ZFS user properties. The settings move with the dataset. `init` and `set` reject invalid values; if one is set some other way, zz skips the affected step and reports it as an `ERROR` rather than guessing.

Durations accept `m`, `h`, `d`, `w` and `y` (e.g. `30m`, `12h`, `7d`, `2w`, `1y`); a bare number means minutes.

|Property     |Description|Default|Example|
|-------------|---------------|-------------------|-------------|
|zz:target     |Remote host and the exact dataset to replicate into (parents are created by init)|-|backup:pool/backups/data|
|zz:freq       |How often to sync|60m|5m, 1h, 30d|
|zz:keep_local |Local retention window|7d|1h, 2h, 1d|
|zz:keep_remote|Remote retention window|30d|24h, 30d, 1y|
|zz:keep_min   |Safety floor: newest N snapshots never pruned, on either side, regardless of age|10|24|
|zz:send_flags |zfs send flags, chosen at init (see Send Flags below)|`-w` if encrypted, else `-L -c`|-L -c|
|zz:last_sync  |Time of last scheduled snapshot; the schedule counts from it (managed by zz)|-|1790626501|
|zz:last_sent  |Time of newest snapshot confirmed on remote (managed by zz)|-|1790626501|
|zz:last_error |Last sync failure, cleared on success (managed by zz)|-|1790626501 Could not retrieve...|
|zz:stale_children|Child datasets deleted here but still on the replica (managed by zz)|-|projects,archive|


## ⚠️ Important Notes
* **Snapshots:** zz only manages snapshots prefixed with @zz_auto_.
* **Bridge Holds:** Incremental replication needs the newest snapshot both sides share (the "bridge"). zz places a ZFS hold named `zz_bridge` on it on both sides, and moves the hold forward after each sync, so it can't be destroyed by accident. Deleting that one snapshot, or the whole dataset, fails with "dataset is busy" until the hold is released. To see holds: `zfs holds pool/data@zz_auto_...`. If you really mean to delete: `zfs release -r zz_bridge pool/data@zz_auto_...`, or run `zz forget` first, which releases zz's holds on both sides. `zz snaps` shows whether the bridge is held.
* **Remote Integrity:** zz uses incremental sends without the -F (Force) flag. Do
  not modify the remote dataset directly (keep it readonly=on) to avoid stream
divergence. Replicas created by `zz init` 0.5 or later are received with `readonly=on` and
`canmount=noauto`, so they can't be written to by accident and won't try to mount at the
primary's mountpoint when the backup host boots. For older replicas you can set these by
hand on the backup host: `zfs set readonly=on canmount=noauto pool/data`. If it is modified, syncs fail with "destination has been modified" and
`zz status` shows `ERROR`; roll the remote back to its newest `zz_auto_` snapshot
(`zfs rollback pool/data@zz_auto_...`) and the next sync catches up.
* **Send Flags:** `init` chooses how snapshots are sent and stores it in `zz:send_flags`, so it never changes underneath an existing replication:
  * **Unencrypted datasets: `-L -c`.** Compressed blocks travel compressed (often 2-3× less data for `lz4`/`zstd` datasets), and large records (`recordsize` over 128K) aren't split. `-e` is left out because its streams can't be received into an encrypted dataset on the backup host.
  * **Encrypted datasets: `-w` (raw).** Data is sent still encrypted. The backup host never has the key, so it can be an untrusted machine. After a `zz restore` of an encrypted dataset, load the key (`zfs load-key pool/data`) and mount it; zz prints the exact commands. A raw receive resets `keylocation` to `prompt`, so set it again if the key should load at boot.
  * **Replications set up before zz 0.5 have no send flags** and keep sending exactly as before. To opt in: `zz set pool/data send_flags -L -c`. In testing, switching an existing unencrypted replication this way worked on the next sync; if a sync fails with a message about flags not matching a previous receive, set it back with `zz set pool/data send_flags none`. Don't switch an unencrypted replication to `-w` or vice versa.
  * To choose flags yourself at init: `zz init ... --send-flags=-L` (use `=`, since the value starts with a dash), or `--send-flags=none`.
* **Deleted Child Datasets:** Replication includes child datasets (`tank/data/projects`, ...). If you delete a child on the primary, the replica keeps its copy, since zz never receives with `-F`, and it stays **recoverable there until its snapshots age out of `keep_remote`**. The same retention window applies as for any deleted file. While it's there, `zz status` and `zz snaps` note it. To recover files, on the backup host: `zfs mount pool/data/projects` (read-only; older versions are under `.zfs/snapshot/`). Once all of its snapshots have aged out, the next sync removes it from the replica. A full `zz restore` rebuilds the tree as the primary last was, leaving such children out.
* **Lock Files:** Stored in `/run/zz/` (root-only; override with `ZZ_LOCK_DIR`). A short lock serializes snapshotting, and a second lock prevents overlapping transfers, so snapshots are still taken on schedule while a long transfer runs. A third, "admin" lock serializes the commands that change a dataset's zz state (`init`, `restore`, `forget`, `abort`, `set`) with each other; `set` takes only that one, so it works while a sync is transferring. `init`, `restore`, `forget` and `abort` also hold both sync locks for the dataset they work on: if a sync is transferring it, they wait a few seconds and then refuse ("another zz operation is running"), and a sync that finds one of them running skips that dataset rather than queuing behind it. Locks only coordinate zz on one machine, so don't run operations against the same replica from two hosts at once (for example, restoring a copy on another machine while the primary is still syncing to that replica).
* **Schedule Drift:** A snapshot is taken when at least `freq` minus 30 seconds has
passed since the last one. Without that allowance, a cron run a second early would
defer the snapshot to the next run, and the schedule would creep later over time.

## 📜 Changelog
See [CHANGELOG.md](CHANGELOG.md) for what changed in each version, including notes for upgrading.

## 📄 License
[MIT](LICENSE) © 2026 Moter Pent. Provided "as is", without warranty of any kind.

Keep it Zeasy.
