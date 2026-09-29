# Changelog

All notable changes to zz are recorded here. Versions follow `__version__` in the `zz` script; `zz --version` also shows the git commit when run from a checkout.

## [0.7.1] - 2026-09-28

### Security
- **Command injection through `zz:target`.** Remote commands were built as strings for the remote shell, and the target was only checked for a colon and a slash. A target like `backup:pool/x; <command>` ran the command as root on the backup host, and a host starting with `-` (e.g. `-oProxyCommand=...`) ran a command as root on the primary. This matters where ZFS permissions are delegated, since a user allowed to set user properties could set `zz:target`, and root's cron runs zz.
  - Every argument sent over ssh is now quoted, and `--` stops the host being read as an ssh option.
  - Targets are validated (host characters, never starting with `-`; dataset path characters), in `init` and `set` and again on every use. Local dataset names are validated too, and names with spaces are rejected clearly.
- README: new Security Considerations section (the trust model, delegated permissions, and push mode's root access to the backup host).

## [0.7.0] - 2026-09-28

### Added
- **Point-in-time restore:** `zz restore ... --at <snapshot|time>` restores as of an earlier snapshot, for when damage (ransomware, a bad deploy, an accidental delete) has already replicated. A time such as `'2026-09-28 01:00'` means the newest snapshot at or before it.
- By default the result is left unmanaged and the replica is untouched; zz prints the two ways to continue. `--rollback-remote` rolls the replica back to the restore point, permanently deleting its newer snapshots, and resumes replication. Re-running the same restore with the flag picks up where it left off without re-sending.

## [0.6.0] - 2026-09-28

First tagged release. Everything below 0.6.0 was developed on `main` without tags; it is summarized here so upgraders know what changed.

### Upgrading from an untagged version
Existing replications keep working without changes. Things you may notice:

- **Bridge holds.** The newest snapshot shared by both sides now carries a `zz_bridge` hold, so `zfs destroy` of that snapshot, or of the whole dataset, fails with "dataset is busy". Run `zz forget <dataset>` first (it releases zz's holds on both sides), or `zfs release -r zz_bridge <snapshot>`.
- **Send flags.** Replications set up before 0.5 have no stored send flags and send exactly as before. To use compressed/large-block sends: `zz set <dataset> send_flags -L -c`.
- **Replica settings.** Replicas created by `zz init` are now received with `readonly=on` and `canmount=noauto`. Older replicas aren't changed; set them by hand on the backup host if you like: `zfs set readonly=on canmount=noauto pool/data`.
- **Log format.** Each sync run starts with a version and timestamp header, and each send logs a start line and a one-line summary instead of zfs's per-second progress. A logrotate rule is in `util/zz.logrotate`.
- **Lock files** moved from `/tmp` to `/run/zz` (override with `ZZ_LOCK_DIR`). Old `/tmp/zz_*.lock` files can be deleted.
- **Exit codes.** `zz sync` and `zz status` exit 1 when anything failed or is unhealthy, so they can drive monitoring.
- Requires **Python 3.7+** (tested on 3.9 and 3.12).

### Added
- `zz status` reports replication **lag** and the states OK, LAGGING, STALLED and ERROR, with the last error for each dataset (`zz:last_sent`, `zz:last_error`).
- `zz snaps`: both sides' snapshots in one table with gaps, sizes (WRITTEN, per-side USED), state (both / pending / local only / remote only) and the bridge snapshot.
- `zz sync --now` (alias `--force`) takes a snapshot immediately without moving the schedule.
- `zz --version`, with the git commit when run from a checkout.
- Bridge snapshot holds on both sides, restored automatically if removed.
- Stored send flags (`zz:send_flags`): `-L -c` by default, `-w` (raw) for encrypted datasets, whose replicas never receive the key. Raw restores arrive locked, and zz prints the `zfs load-key` steps.
- Child datasets: a child deleted on the primary stays on the replica, recoverable until its snapshots age out, and is then removed. `status` and `snaps` note such children (`zz:stale_children`).
- `init` ends with a clear success/failure line, the dataset's status row, and next steps, including a reminder when no cron entry for `zz sync` is found.
- `util/zz.logrotate`, an MIT `LICENSE`, and real-ZFS integration tests (156 checks) plus unit tests, run on every push via GitHub Actions.

### Changed
- The remote target is honoured exactly (`host:pool/path`); previously everything after the pool name was ignored and the remote was looked up by the local name.
- Restore picks the newest `zz_auto_` snapshot explicitly, refuses to overwrite an existing dataset, is resumable, verifies the whole dataset tree before reporting success, and mounts the result.
- Durations accept `w` and `y`. `init` and `set` reject invalid values; an invalid stored value makes zz skip the affected step and report ERROR instead of treating it as zero.
- On-demand snapshots don't move the schedule; `sync` says when the next snapshot is due when none was taken.
- Only locally set `zz:` properties make a dataset managed, so a replica host never treats received copies as its own.

### Fixed
- Local pruning could delete snapshots that had not been sent yet, after which sync reported "up to date" forever.
- `status` reported OK while sends were failing.
- An unrecognized duration (including the README's own `1y` example) was treated as 0, which meant pruning everything beyond `keep_min`.
- A restore of a tree that had been interrupted could report success while child datasets were missing.
- A restore failed outright if a child dataset had been deleted on the primary.
- Replica child datasets auto-mounted at boot.
- Many error paths failed silently or with a traceback (bare `except:` blocks, pruning errors, `abort` on a missing dataset, `zz snaps | head`).
- Two runs starting at once could both take a snapshot.

[0.7.1]: https://github.com/moterpent/zz/releases/tag/v0.7.1
[0.7.0]: https://github.com/moterpent/zz/releases/tag/v0.7.0
[0.6.0]: https://github.com/moterpent/zz/releases/tag/v0.6.0
