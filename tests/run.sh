#!/bin/bash
# Integration tests for zz against real ZFS.
#
# Creates two throwaway file-backed pools (unique names, mounted under a temp
# directory), runs every scenario, and destroys everything it created on exit.
# Existing pools are never touched.
#
# Requirements: root, ZFS kernel module + zfsutils, python3.
#   sudo tests/run.sh                 # all tests
#   sudo tests/run.sh restore         # only tests whose name contains "restore"
#
# The "remote" is a stand-in ssh that runs commands locally, so no sshd is
# needed; zz still goes through its normal ssh code paths.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILTER=${1:-}
RUNID=$$
SRC=zztsrc$RUNID
DST=zztdst$RUNID
WORK=$(mktemp -d /var/tmp/zztest.XXXXXX)
MNT=$WORK/mnt
PASS=0; FAIL=0; FAILED=()

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 2; }
command -v zpool >/dev/null || { echo "zpool not found (install ZFS)"; exit 2; }

cleanup() {
    for p in "$SRC" "$DST"; do zpool list "$p" >/dev/null 2>&1 && zpool destroy -f "$p"; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- environment ---
mkdir -p "$WORK/bin" "$MNT"
cat > "$WORK/bin/ssh" <<'EOF'
#!/bin/bash
# Stand-in for ssh: drop options and the host, run the command locally.
while [[ $# -gt 0 && "$1" == -* ]]; do case "$1" in -o|-p|-i|-l) shift 2 ;; *) shift ;; esac; done
host=$1; shift
[ "$host" = zzunreachable ] && { echo "ssh: connect to host zzunreachable: No route to host" >&2; exit 255; }
# Tests can slow the remote receive down, to have a transfer reliably in progress
[ -n "${ZZTEST_SLOW_RECV:-}" ] && [[ "$*" == *"zfs recv"* ]] && sleep "$ZZTEST_SLOW_RECV"
[ -n "${ZZTEST_SLOW_SSH:-}" ] && sleep "$ZZTEST_SLOW_SSH"
exec bash -c "$*"
EOF
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH" ZZ_LOCK_DIR="$WORK/locks"

truncate -s 1G "$WORK/src.img" "$WORK/dst.img"
zpool create -R "$MNT" "$SRC" "$WORK/src.img" || exit 2
zpool create -R "$MNT" "$DST" "$WORK/dst.img" || exit 2

DS=$SRC/data                 # local dataset under test
RP=$DST/bk/data              # remote path (nested; parent created by init)
TARGET=zzremote:$RP

# --- helpers ---
zz() { python3 "$REPO/zz" "$@"; }
# run: capture output in $OUT and exit code in $RC
run() { OUT=$(zz "$@" 2>&1); RC=$?; }
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  {
    FAIL=$((FAIL+1)); FAILED+=("$CUR: $*"); echo "  FAIL $*"
    # On GitHub Actions, also emit an annotation: those are readable via the public API,
    # unlike job logs. Include the tail of the last zz output (newlines encoded as %0A).
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        local tail; tail=$(tail -6 <<<"${OUT:-}" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
        echo "::error title=$CUR: $*::zz exit ${RC:-?}. Last output:%0A$tail"
    fi
}
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
rc_is() { [ "$RC" = "$1" ] || { echo "       expected exit $1, got $RC; output:"; sed 's/^/       | /' <<<"$OUT"; return 1; }; }
out_has() { grep -qF -- "$1" <<<"$OUT" || { echo "       missing: $1"; sed 's/^/       | /' <<<"$OUT"; return 1; }; }
out_lacks() { ! grep -qF -- "$1" <<<"$OUT" || { echo "       unexpected: $1"; return 1; }; }
exists() { zfs list -H -o name "$1" >/dev/null 2>&1; }
# zz_bridge holds on a dataset's snapshots (one name per line)
held()   { zfs list -H -t snapshot -o name -d 1 "$1" | xargs -r zfs holds -H 2>/dev/null | awk -F'\t' '$2=="zz_bridge"{print $1}'; }
# Release zz's holds, as an admin deliberately deleting something would have to
unhold() { held "$1" | xargs -r -n1 zfs release -r zz_bridge; }
wipe()   { unhold "$1"; zfs destroy -r "$1"; }
# zz-managed datasets on this host that aren't ours: status and no-argument commands
# consider every managed dataset, so host-wide assertions only hold when there are none
others() { zfs get -H -t filesystem -s local -o name zz:target 2>/dev/null | grep -v "^$SRC/"; }
alone()  { [ -z "$(others)" ]; }
nsnaps() { zfs list -H -t snapshot -o name -d 1 "$1" 2>/dev/null | grep -c '@zz_auto_'; }
newest() { zfs list -H -t snapshot -o name -S creation -d 1 "$1" | grep '@zz_auto_' | head -1 | cut -d@ -f2; }
prop()   { zfs get -H -s local -o value "zz:$1" "${2:-$DS}"; }
val()    { zfs get -H -o value "$1" "$2"; }
# bytes reported by the last "[+] Sent ...: <size> in" line in $OUT, as an integer
sent_bytes() { grep -o '\[+\] Sent .*: [0-9.]*[BKMGT] in' <<<"$OUT" | tail -1 | sed -E 's/.*: ([0-9.]+)([BKMGT]) in/\1 \2/' |
               awk '{m=($2=="K")?1024:($2=="M")?1048576:($2=="G")?1073741824:1; printf "%d", $1*m}'; }
# mountpoint may or may not already include the pool's altroot, depending on ZFS version
mnt()    { local m; m=$(zfs get -H -o value mountpoint "$1"); [ -d "$m" ] && echo "$m" || echo "$MNT$m"; }
write()  { head -c "$2" /dev/urandom > "$(mnt "$DS")/$1"; }
tick()   { sleep 1.1; }   # snapshot names are per-second

T() { CUR=$1; if [ -n "$FILTER" ] && [[ "$CUR" != *"$FILTER"* ]]; then SKIP=1; else SKIP=0; echo "== $CUR"; fi; }

# --- tests (order matters: later tests build on earlier state) ---

T init
if [ $SKIP = 0 ] || true; then   # always runs: everything depends on it
    zfs create "$DS"; write f1 40M
    run init "$DS" "$TARGET" --freq 1h --keep-local 1m --keep-min 1
    check "init succeeds"                 rc_is 0
    check "…says so, with source and target" out_has "[+] Init successful: $DS -> $TARGET"
    check "…shows the new dataset's status row" bash -c "grep -F '$DS ' <<<\"\$0\" | grep -qF '| OK '" "$OUT"
    check "…lists next steps"             out_has "Next steps:"
    if crontab -l 2>/dev/null | grep -Eq '(^|[[:space:]/])zz[[:space:]]+sync'; then
        check "…no cron hint (already scheduled)" out_lacks "no cron entry"
    else
        check "…reminds to schedule syncs"  out_has "no cron entry running 'zz sync' was found"
    fi
    check "remote parent created"         exists "$DST/bk"
    check "data landed at exact path"     [ "$(nsnaps "$RP")" = 1 ]
    check "last_sent recorded"            [ -n "$(prop last_sent)" ]
    check "default send flags -L -c"      [ "$(prop send_flags)" = "-L -c" ]
    check "replica won't auto-mount"      [ "$(val canmount "$RP")" = noauto ]
    check "replica is read-only"          [ "$(val readonly "$RP")" = on ]
    run init "$DS" "$TARGET"
    check "re-running init on a set-up dataset is harmless" rc_is 0
    check "…says it's already replicating" out_has "already replicating"
    zfs create "$SRC/other0"
    run init "$SRC/other0" "$TARGET"
    check "init refuses someone else's existing replica" rc_is 1
    check "…and says so"                  out_has "[!] Init failed: $RP already exists"
    zfs destroy "$SRC/other0"
    zfs create "$SRC/lonely"
    run init "$SRC/lonely" zzunreachable:$DST/bk/lonely
    check "unreachable host: init fails"  rc_is 1
    check "…says it couldn't connect"     out_has "could not reach zzunreachable over ssh"
    check "…nothing marked as managed"    [ -z "$(prop target "$SRC/lonely")" ]
    zfs destroy "$SRC/lonely"
fi

T validation
if [ $SKIP = 0 ]; then
    run init "$DS" zzremote:$DST/x --keep-remote 7days
    check "init rejects bad duration"     rc_is 2
    run init "$DS" nocolon
    check "init rejects bad target"       rc_is 1
    run set "$DS" keep_remote 1year
    check "set rejects bad duration"      rc_is 1
    run set "$DS" keep_min lots
    check "set rejects bad keep_min"      rc_is 1
    check "…value unchanged"              [ "$(prop keep_remote)" = 30d ]
    for c in "abort $SRC/nope" "meta $SRC/nope" "forget $SRC/nope" "sync $SRC/nope" "snaps $SRC/nope"; do
        run $c; check "'$c' reports missing dataset" rc_is 1
    done
fi

T sync_status_snaps
if [ $SKIP = 0 ]; then
    write f2 20M; tick
    run sync "$DS" --now
    check "sync succeeds"                 rc_is 0
    check "send announced when it starts" out_has "[>] Sending $DS @"
    check "one-line send summary"         out_has "[+] Sent $DS @"
    check "…announcement comes first"     [ "$(grep -n '\[>\] Sending' <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n '\[+\] Sent' <<<"$OUT" | cut -d: -f1)" ]
    check "no zfs -v progress lines"      out_lacks "estimated size"
    check "replica caught up"             [ "$(newest "$RP")" = "$(newest "$DS")" ]
    run status
    alone && check "status OK, exit 0"    rc_is 0
    check "…our dataset shows OK"         bash -c "grep -F '$DS ' <<<\"\$0\" | grep -qF '| OK '" "$OUT"
    if alone; then
        run snaps
        check "snaps works without dataset arg" rc_is 0
    else
        run snaps
        check "snaps asks which dataset when several are managed" out_has "$DS"
        echo "       (other zz datasets on this host: $(others | tr '\n' ' '))"
        run snaps "$DS"
    fi
    check "…marks the bridge"             out_has "<- bridge"
    # Reader gone before zz writes anything (like '| head' on long output)
    zz snaps "$DS" 2>"$WORK/err" | true
    check "snaps into a closed pipe: no traceback" bash -c "! grep -q Traceback '$WORK/err'"
    write f4 2M; tick
    zz sync "$DS" --now 2>"$WORK/err" | true
    check "sync into a closed pipe: no traceback" bash -c "! grep -q Traceback '$WORK/err'"
    check "…and still finished its work"  [ "$(newest "$RP")" = "$(newest "$DS")" ]
fi

T bridge_hold
if [ $SKIP = 0 ]; then
    b=$(newest "$RP")
    check "bridge held locally"             [ "$(held "$DS")" = "$DS@$b" ]
    check "bridge held on remote"           [ "$(held "$RP")" = "$RP@$b" ]
    check "local bridge can't be destroyed" bash -c "! zfs destroy '$DS@$b' 2>/dev/null"
    check "remote bridge can't be destroyed" bash -c "! zfs destroy '$RP@$b' 2>/dev/null"
    run snaps "$DS"
    check "snaps shows it held on both sides" out_has "held local + remote"
    write f3 5M; tick; run sync "$DS" --now
    nb=$(newest "$RP")
    check "hold moves to the new bridge (local)"  [ "$(held "$DS")" = "$DS@$nb" ]
    check "…and on the remote"              [ "$(held "$RP")" = "$RP@$nb" ]
    unhold "$DS"; unhold "$RP"; run sync "$DS"
    check "holds restored if removed (self-heal)" [ "$(held "$DS")" = "$DS@$nb" ] && [ "$(held "$RP")" = "$RP@$nb" ]
fi

T set_rules
if [ $SKIP = 0 ]; then
    zfs create "$SRC/plain2"
    run set "$SRC/plain2" freq 1h
    check "set refuses an unmanaged dataset" rc_is 1
    check "…says it isn't managed"          out_has "not managed by zz"
    check "…and leaves no stray property"   [ -z "$(zfs get -H -s local -o value zz:freq "$SRC/plain2")" ]
    run set "$SRC/plain2" target "zzremote:$DST/bk/plain2"
    check "set target can't make a dataset managed without init" [ -z "$(prop target "$SRC/plain2")" ]
    zfs destroy "$SRC/plain2"

    zfs create "$DST/bk/other"
    run set "$DS" target "zzremote:$DST/bk/other"
    check "set target refuses a different replica" rc_is 1
    check "…explains, and points to forget + init" out_has "zz forget $DS, then zz init"
    check "…target unchanged"               [ "$(prop target "$DS")" = "$TARGET" ]
    run set "$DS" target "zzremote:$DST/bk/nothing"
    check "set target refuses a path that doesn't exist" out_has "does not exist"
    zfs destroy "$DST/bk/other"

    run set "$DS" target "zzalias:$RP"          # same replica, reached by another name
    check "set target accepts the same replica under another name" rc_is 0
    tick; run sync "$DS" --now
    check "…and syncing carries on"         rc_is 0
    run set "$DS" target "$TARGET"
    check "…and back again"                 rc_is 0
fi

T set_admin_lock
if [ $SKIP = 0 ]; then
    lockf() { echo "$ZZ_LOCK_DIR/$(echo "$1" | tr / _).$2.lock"; }
    mkdir -p "$ZZ_LOCK_DIR"
    # Another admin command (forget, restore, ...) holds the admin lock: set waits, then refuses
    flock -o "$(lockf "$DS" admin)" sleep 20 & holder=$!; sleep 0.5
    run set "$DS" freq 2h
    check "set refused while another zz command holds the dataset" rc_is 1
    check "…and says why"                   out_has "another zz command is running"
    check "…value unchanged"                [ "$(prop freq)" = 1h ]
    tick; run sync "$DS" --now
    check "a sync isn't blocked by the admin lock" rc_is 0
    kill $holder 2>/dev/null; wait $holder 2>/dev/null
    # A running sync holds the transfer lock: set must NOT be blocked by it
    flock -o "$(lockf "$DS" sync)" sleep 20 & holder=$!; sleep 0.5
    run set "$DS" keep_remote 60d
    check "set works while a sync is transferring" rc_is 0
    run set "$DS" keep_remote 30d
    kill $holder 2>/dev/null; wait $holder 2>/dev/null

    # set target spends seconds checking the replica over ssh (slowed here); a forget arriving
    # meanwhile must be refused. Before 0.7.4 the forget succeeded and set then wrote the
    # target back, leaving an "unmanaged" dataset with a zz:target.
    ZZTEST_SLOW_SSH=5 zz set "$DS" target "zzalias:$RP" >"$WORK/set.out" 2>&1 & s=$!
    sleep 1; run forget "$DS"; wait $s
    check "forget refused while set is working on the dataset" rc_is 1
    check "…set completed"                  [ "$(prop target)" = "zzalias:$RP" ]
    run set "$DS" target "$TARGET"
    check "…and the dataset is still fully managed" rc_is 0
fi

T now_keeps_schedule
if [ $SKIP = 0 ]; then
    anchor=$(prop last_sync); n=$(nsnaps "$DS"); tick
    run sync "$DS" --now
    check "--now takes a snapshot"        [ "$(nsnaps "$DS")" = $((n+1)) ]
    check "…labelled on-demand"           out_has "on-demand"
    check "…schedule anchor unchanged"    [ "$(prop last_sync)" = "$anchor" ]
    tick; run sync "$DS" --force
    check "--force still works"           out_has "on-demand"
    n=$(nsnaps "$DS"); run sync "$DS"
    check "plain sync takes nothing when not due" [ "$(nsnaps "$DS")" = "$n" ]
    check "…and says when the next one is"  out_has "Next snapshot in"
    check "…and how to force one"         out_has "use --now"
fi

T concurrent_snapshot
if [ $SKIP = 0 ]; then
    zfs set zz:last_sync=$(( $(date +%s) - 7200 )) "$DS"
    before=$(zfs list -H -t snapshot -o name -d 1 "$DS" | sort)
    zz sync "$DS" >/dev/null 2>&1 & zz sync "$DS" >/dev/null 2>&1 & wait
    # Compare names, not totals: with the 1m test retention, these syncs may also prune old
    # snapshots (on a slow machine, earlier ones are over a minute old by now)
    new=$(comm -13 <(echo "$before") <(zfs list -H -t snapshot -o name -d 1 "$DS" | sort) | grep -c .)
    check "two simultaneous syncs take one snapshot" [ "$new" = 1 ]
    run sync "$DS"
    check "…and it gets sent"             [ "$(newest "$RP")" = "$(newest "$DS")" ]
fi

T diverged_replica
if [ $SKIP = 0 ]; then
    bridge=$(newest "$RP")
    zfs mount "$RP" 2>/dev/null
    check "read-only replica is mounted for this test" [ "$(val mounted "$RP")" = yes ]
    check "read-only replica refuses writes" bash -c "! date 2>/dev/null > '$(mnt "$RP")/diverge'" 2>/dev/null
    zfs set readonly=off "$RP"; date > "$(mnt "$RP")/diverge"
    tick; run sync "$DS" --now
    check "sync fails on modified replica"  rc_is 1
    check "…with zfs's reason"              out_has "has been modified"
    echo "       (waiting 65s so pending snapshots pass the 1m local retention)"
    # Everything from the bridge onward is unsent (or the incremental base) and must survive.
    # Older, already-sent snapshots may legitimately be pruned.
    sleep 65
    keep=$(zfs list -H -t snapshot -o name -s creation -d 1 "$DS" | sed -n "/@$bridge\$/,\$p")
    run sync "$DS" --now
    check "pending snapshots and bridge never pruned" bash -c "for s in $(echo $keep); do zfs list -H -o name \$s >/dev/null || exit 1; done"
    check "…and the new one was added"      [ "$(zfs list -H -t snapshot -o name -s creation -d 1 "$DS" | sed -n "/@$bridge\$/,\$p" | wc -l)" = $(( $(wc -w <<<"$keep") + 1 )) ]
    run status
    check "status ERROR, exit 1"            rc_is 1
    check "…lists the error"                out_has "Transfer failed"
    zfs rollback "$RP@$bridge"; zfs unmount "$RP" 2>/dev/null; zfs set readonly=on "$RP"
    run sync "$DS"
    check "recovers after rollback"         rc_is 0
    check "…sends every pending snapshot"   [ "$(newest "$RP")" = "$(newest "$DS")" ]
    run status
    alone && check "…status back to OK, exit 0" rc_is 0
    check "…our dataset back to OK"         bash -c "grep -F '$DS ' <<<\"\$0\" | grep -qF '| OK '" "$OUT"
fi

T missing_bridge
if [ $SKIP = 0 ]; then
    b=$(newest "$DS")
    check "held bridge refuses deletion"    bash -c "! zfs destroy '$DS@$b' 2>/dev/null"
    unhold "$DS"; zfs destroy "$DS@$b"; tick
    run sync "$DS" --now
    check "missing bridge is an error"      rc_is 1
    check "…says intervention needed"       out_has "manual intervention required"
fi

T restore_refuses_overwrite
if [ $SKIP = 0 ]; then
    run restore "$TARGET" "$DS"
    check "restore refuses live dataset"    rc_is 1
    check "…and says why"                   out_has "not a partial restore"
fi

T restore_resume_token
if [ $SKIP = 0 ]; then
    (cd "$(mnt "$DS")" && sha256sum f1 f2) > "$WORK/sums"
    wipe "$DS"
    # Cut the stream inside the first (40M+) snapshot: leaves a real resume token
    zfs send -R -L -c "$RP@$(newest "$RP")" 2>/dev/null | head -c 15M | zfs recv -s -u "$DS" 2>/dev/null
    check "partial receive left a resume token" [ "$(zfs get -H -o value receive_resume_token "$DS" 2>/dev/null)" != "-" ]
    run status
    check "partial dataset not treated as managed" out_lacks "$DS "
    run restore "$TARGET" "$DS"
    check "restore resumes and completes"   rc_is 0
    check "…resumed from the token"         out_has "Resuming interrupted restore"
    check "…then caught up the rest"        out_has "Catching up"
    check "all snapshots restored"          [ "$(nsnaps "$DS")" = "$(nsnaps "$RP")" ]
    check "newest GUIDs match"              [ "$(zfs get -H -o value guid "$DS@$(newest "$DS")")" = "$(zfs get -H -o value guid "$RP@$(newest "$RP")")" ]
    check "data intact (checksums)"         bash -c "cd '$(mnt "$DS")' && sha256sum -c --quiet '$WORK/sums'"
    check "mounted"                         [ "$(zfs get -H -o value mounted "$DS")" = yes ]
    check "managed again"                   [ "$(prop target)" = "$TARGET" ]
    check "restored primary's bridge held"  [ "$(held "$DS")" = "$DS@$(newest "$DS")" ]
    tick; run sync "$DS" --now
    check "sync after restore: one incremental" [ "$(grep -c '\[+\] Sent' <<<"$OUT")" = 1 ]
fi

T restore_partial_between_snapshots
if [ $SKIP = 0 ]; then
    wipe "$DS"
    oldest=$(zfs list -H -t snapshot -o name -s creation -d 1 "$RP" | grep '@zz_auto_' | head -1)
    zfs send -L -c "$oldest" | zfs recv -u "$DS"
    run restore "$TARGET" "$DS"
    check "restore continues a partial copy" rc_is 0
    check "…detected as partial"            out_has "Continuing partial restore"
    check "all snapshots restored"          [ "$(nsnaps "$DS")" = "$(nsnaps "$RP")" ]
fi

T restore_latest_unmanaged_copy
if [ $SKIP = 0 ]; then
    run restore "$TARGET" "$SRC/copy" --latest
    check "restore --latest to new name"    rc_is 0
    check "…left unmanaged"                 out_has "left unmanaged"
    check "…only the latest snapshot"       [ "$(nsnaps "$SRC/copy")" = 1 ]
    check "…and no holds on the copy"       [ -z "$(held "$SRC/copy")" ]
    run forget "$SRC/copy"
    check "forget on unmanaged copy errors" rc_is 1
fi

T send_flags_compressed
if [ $SKIP = 0 ]; then
    C=$SRC/comp; zfs create -o compression=lz4 "$C"
    run init "$C" zzremote:$DST/bk/comp --freq 1h
    yes 'zz compressible test line ' 2>/dev/null | head -c 30M > "$(mnt "$C")/text"; tick
    run sync "$C" --now
    check "compressed sync succeeds"        rc_is 0
    check "30M of compressible data sends under 5M with -c" [ "$(sent_bytes)" -lt 5242880 ]
fi

T send_flags_legacy
if [ $SKIP = 0 ]; then
    G=$SRC/legacy; zfs create -o compression=lz4 "$G"
    run init "$G" zzremote:$DST/bk/legacy --freq 1h --send-flags none
    zfs inherit zz:send_flags "$G"   # exactly as a replication set up before 0.5 looks
    run meta "$G"
    check "meta explains missing send flags" out_has "none (set up before zz 0.5)"
    yes 'zz compressible test line ' 2>/dev/null | head -c 30M > "$(mnt "$G")/text"; tick
    run sync "$G" --now
    check "flagless (pre-0.5) replication still syncs" rc_is 0
    check "…sending uncompressed (over 25M)" [ "$(sent_bytes)" -gt 26214400 ]
    run set "$G" send_flags "-L -c"
    check "set send_flags accepted"         rc_is 0
    yes 'more compressible text ' 2>/dev/null | head -c 30M > "$(mnt "$G")/text2"; tick
    run sync "$G" --now
    echo "       (switching an existing replication to -L -c: exit $RC, sent $(sent_bytes) bytes)"
    check "switching to -L -c works on an existing replication" rc_is 0
    check "…and sends compressed from then on" [ "$(sent_bytes)" -lt 5242880 ]
    run set "$G" send_flags -F
    check "set rejects unknown send flags"  rc_is 1
    run set "$G" send_flags -L -c
    check "set takes unquoted flags"        rc_is 0
    check "…stored as given"                [ "$(prop send_flags "$G")" = "-L -c" ]
fi

T send_flags_large_blocks
if [ $SKIP = 0 ]; then
    B=$SRC/big; zfs create -o recordsize=1M "$B"
    run init "$B" zzremote:$DST/bk/big --freq 1h
    head -c 8M /dev/urandom > "$(mnt "$B")/rand"; tick
    run sync "$B" --now
    check "1M-recordsize dataset syncs"     rc_is 0
    check "…replica keeps 1M records"       [ "$(val recordsize $DST/bk/big)" = 1M ]
fi

T send_flags_encrypted
if [ $SKIP = 0 ]; then
    E=$SRC/enc; ER=$DST/bk/enc
    echo "zz-test-passphrase" > "$WORK/key"
    zfs create -o encryption=on -o keyformat=passphrase -o keylocation="file://$WORK/key" "$E"
    run init "$E" zzremote:$ER --freq 1h
    check "encrypted dataset: init succeeds" rc_is 0
    check "…chooses raw sends (-w)"         [ "$(prop send_flags "$E")" = "-w" ]
    check "replica is encrypted"            [ "$(val encryption "$ER")" != off ]
    check "…and never had the key"          [ "$(val keystatus "$ER")" = unavailable ]
    head -c 6M /dev/urandom > "$(mnt "$E")/secret"; tick
    run sync "$E" --now
    check "raw incremental sync"            rc_is 0
    (cd "$(mnt "$E")" && sha256sum secret) > "$WORK/encsums"
    wipe "$E"
    run restore "zzremote:$ER" "$E"
    check "raw restore succeeds"            rc_is 0
    check "…says the key must be loaded"    out_has "zfs load-key"
    check "…arrives locked"                 [ "$(val keystatus "$E")" = unavailable ]
    zfs load-key -L "file://$WORK/key" "$E" && zfs mount "$E"
    check "after load-key: data intact"     bash -c "cd '$(mnt "$E")' && sha256sum -c --quiet '$WORK/encsums'"
    head -c 1M /dev/urandom > "$(mnt "$E")/more"; tick
    run sync "$E" --now
    check "raw sync continues after restore" rc_is 0
    check "…replica still never had the key" [ "$(val keystatus "$ER")" = unavailable ]
fi

T child_datasets
if [ $SKIP = 0 ]; then
    F=$SRC/fam; FR=$DST/bk/fam
    zfs create "$F"; for c in a a/x b d; do zfs create "$F/$c"; done
    for d in "$F" "$F/a" "$F/a/x" "$F/b" "$F/d"; do head -c 2M /dev/urandom > "$(mnt "$d")/data"; done
    run init "$F" "zzremote:$FR" --freq 1h --keep-local 1m --keep-remote 1m --keep-min 1
    check "init of a dataset tree succeeds" rc_is 0
    check "whole tree arrives on the replica" bash -c "for c in a a/x b d; do zfs list -H -o name '$FR/'\$c >/dev/null || exit 1; done"
    check "children have the same snapshot" exists "$FR/a/x@$(newest "$F")"
    check "replica children are read-only"  [ "$(val readonly "$FR/a/x")" = on ]
    check "replica children won't auto-mount" bash -c "for c in a a/x b d; do [ \$(zfs get -H -o value canmount '$FR/'\$c) = noauto ] || exit 1; done"
    b1=$(newest "$F")
    check "bridge hold covers children (local)"  bash -c "zfs holds -H '$F/a/x@$b1' | grep -q zz_bridge"
    check "bridge hold covers children (remote)" bash -c "zfs holds -H '$FR/a/x@$b1' | grep -q zz_bridge"

    # changes in a child, plus a child created after init
    head -c 1M /dev/urandom > "$(mnt "$F/a/x")/more"; zfs create "$F/c"; head -c 1M /dev/urandom > "$(mnt "$F/c")/data"; tick
    run sync "$F" --now
    check "sync of the tree succeeds"       rc_is 0
    check "child's new snapshot replicated" exists "$FR/a/x@$(newest "$F")"
    check "child created after init is picked up" exists "$FR/c@$(newest "$F")"
    check "…and won't auto-mount on the replica" [ "$(val canmount "$FR/c")" = noauto ]
    check "bridge hold moved on the children too" bash -c "zfs holds -H '$FR/a/x@$(newest "$F")' | grep -q zz_bridge && ! zfs holds -H '$FR/a/x@$b1' 2>/dev/null | grep -q zz_bridge"

    # a child deleted on the source: kept on the replica, noted, then removed once aged out
    unhold "$F"; zfs destroy -r "$F/b"; tick
    run sync "$F" --now
    check "sync still works after a child is deleted" rc_is 0
    check "…replica keeps the deleted child (zz never uses recv -F)" exists "$FR/b"
    check "…and records it"                 [ "$(prop stale_children "$F")" = b ]
    run status
    check "status notes the deleted child"  out_has "the replica still has b (deleted here)"
    run snaps "$F"
    check "snaps notes it too"              out_has "deleted here: b"
    echo "       (waiting 65s so older snapshots pass the 1m retention)"
    sleep 65; tick; run sync "$F" --now
    check "pruning succeeds on the tree"    rc_is 0
    for side in "$F" "$FR"; do
        check "children pruned in step with the parent ($side)" bash -c "
            p=\$(zfs list -H -t snapshot -o name -d 1 '$side' | cut -d@ -f2 | sort)
            c=\$(zfs list -H -t snapshot -o name -d 1 '$side/a/x' | cut -d@ -f2 | sort)
            [ \"\$p\" = \"\$c\" ]"
    done
    check "aged-out deleted child removed from the replica" bash -c "! zfs list '$FR/b' >/dev/null 2>&1"
    check "…says so"                        out_has "Removing $FR/b from the replica"
    check "…and is no longer recorded"      [ "$(prop stale_children "$F")" = "-" ]

    # a child deleted recently (still within retention on the replica), then the primary is lost
    unhold "$F"; zfs destroy -r "$F/d"; tick; run sync "$F" --now
    check "recently deleted child still on the replica" exists "$FR/d"
    dsnaps=$(zfs list -H -t snapshot -o name -r "$FR/d" | sort)
    for d in "$F" "$F/a" "$F/a/x" "$F/c"; do
        (cd "$(mnt "$d")" && find . -maxdepth 1 -type f -exec sha256sum {} +) > "$WORK/sums_$(echo "$d" | tr / _)"
    done
    tree_ok() {   # every restored dataset present, data intact, mounted, writable, mounts at boot
        local ok=1; for d in "$F" "$F/a" "$F/a/x" "$F/c"; do
            exists "$d" || { ok=0; continue; }
            (cd "$(mnt "$d")" && sha256sum -c --quiet "$WORK/sums_$(echo "$d" | tr / _)") >/dev/null 2>&1 || ok=0
            [ "$(val mounted "$d")" = yes ] && [ "$(val canmount "$d")" = on ] || ok=0
            touch "$(mnt "$d")/writable" 2>/dev/null || ok=0
        done; [ $ok = 1 ]; }
    wipe "$F"
    run restore "zzremote:$FR" "$F"
    check "restore of the tree succeeds"    rc_is 0
    check "…leaves out the deleted child, and says how to recover it" out_has "Not restoring 1 child dataset(s)"
    check "deleted child not resurrected"   bash -c "! zfs list '$F/d' >/dev/null 2>&1"
    check "every restored dataset intact, mounted, writable, mounts at boot" tree_ok
    check "replica's copy of the deleted child untouched" [ "$(zfs list -H -t snapshot -o name -r "$FR/d" | sort)" = "$dsnaps" ]
    check "no temporary restore snapshots left behind" bash -c "! zfs list -H -t snapshot -o zz:restore_temp -r '$FR' | grep -q on"
    tick; run sync "$F" --now
    check "sync after restoring the tree"   rc_is 0

    # resumed restore where the top dataset arrived but the children didn't
    wipe "$F"
    oldest=$(zfs list -H -t snapshot -o name -s creation -d 1 "$FR" | grep '@zz_auto_' | head -1)
    zfs send -L -c "$oldest" | zfs recv -u "$F"
    run restore "zzremote:$FR" "$F"
    check "resumed tree restore succeeds"   rc_is 0
    check "…fills in the children that hadn't arrived" out_has "Restoring missing $F/a"
    check "…whole tree intact"              tree_ok
fi

T restore_point_in_time
if [ $SKIP = 0 ]; then
    # The ransomware case: good data, then damage that replicates, then restore from before it
    P=$SRC/pit; PR=$DST/bk/pit
    zfs create "$P"; echo "good data" > "$(mnt "$P")/doc"
    run init "$P" "zzremote:$PR" --freq 1h
    good=$(newest "$P"); good_time=$(date -d "@$(zfs get -H -p -o value creation "$P@$good")" '+%Y-%m-%d %H:%M:%S')
    tick; echo "ENCRYPTED BY RANSOMWARE" > "$(mnt "$P")/doc"; run sync "$P" --now
    tick; echo "still encrypted" > "$(mnt "$P")/doc2"; run sync "$P" --now
    bad=$(newest "$P"); nrep=$(nsnaps "$PR")

    wipe "$P"
    run restore "zzremote:$PR" "$P" --at "$good_time"
    check "restore --at <time> succeeds"    rc_is 0
    check "…picks the newest snapshot at or before that time" out_has "Restore point: @$good"
    check "…data is from before the damage" [ "$(cat "$(mnt "$P")/doc")" = "good data" ]
    check "…later files aren't there"       [ ! -e "$(mnt "$P")/doc2" ]
    check "…left unmanaged by default"      [ -z "$(prop target "$P")" ]
    check "…explains both ways to continue" out_has "--rollback-remote"
    check "…replica untouched"              [ "$(nsnaps "$PR")" = "$nrep" ]

    run restore "zzremote:$PR" "$P" --at "$good" --rollback-remote
    check "rerun with --rollback-remote succeeds" rc_is 0
    check "…replica rolled back to the restore point" [ "$(newest "$PR")" = "$good" ]
    check "…damaged snapshots gone from the replica" bash -c "! zfs list '$PR@$bad' >/dev/null 2>&1"
    check "…managed again"                  [ "$(prop target "$P")" = "zzremote:$PR" ]
    check "…bridge held on both sides"      [ "$(held "$P")" = "$P@$good" ] && [ "$(held "$PR")" = "$PR@$good" ]
    check "…data still good"                [ "$(cat "$(mnt "$P")/doc")" = "good data" ]
    echo "recovered" > "$(mnt "$P")/doc3"; tick; run sync "$P" --now
    check "replication continues from the restore point" rc_is 0
    check "…new snapshot reaches the replica" [ "$(newest "$PR")" = "$(newest "$P")" ]

    wipe "$P"
    run restore "zzremote:$PR" "$P" --at zz_auto_1
    check "--at unknown snapshot fails"     rc_is 1
    run restore "zzremote:$PR" "$P" --at "2001-01-01 00:00"
    check "--at before the oldest snapshot fails" rc_is 1
    check "…and says which is oldest"      out_has "the oldest is"
    run restore "zzremote:$PR" "$P" --at "last tuesday"
    check "--at with an unreadable time fails" rc_is 1
    check "…nothing was created"            bash -c "! zfs list '$P' >/dev/null 2>&1"
fi

T injection
if [ $SKIP = 0 ]; then
    # zz:target is a user property: with delegated ZFS permissions a non-root user could set it,
    # then root's cron runs zz. Set it directly (bypassing zz's own checks) and try to inject.
    V=$SRC/evil; zfs create "$V"
    i=0; for t in "zzremote:$DST/x;touch $WORK/pwned" "zzremote:$DST/x\$(touch $WORK/pwned)" \
                  "zzremote:$DST/x\`touch $WORK/pwned\`" "-oProxyCommand=touch $WORK/pwned:$DST/x" \
                  "zzremote:$DST/x|touch $WORK/pwned"; do
        i=$((i+1)); zfs set "zz:target=$t" "$V"
        run sync "$V" --now
        check "injected target #$i refused"      rc_is 1
        check "…as an invalid remote"           out_has "Invalid remote"
    done
    check "no injected command ever ran"    [ ! -e "$WORK/pwned" ]
    run init "$DS" "zzremote:$DST/y;touch $WORK/pwned"
    check "init refuses an injected target" rc_is 1
    run restore "zzremote:$DST/y\$(touch $WORK/pwned)" "$SRC/r"
    check "restore refuses an injected target" rc_is 1
    run init "$SRC/has space" "zzremote:$DST/z"
    check "dataset names with spaces rejected clearly" out_has "no spaces"
    check "still nothing ran"               [ ! -e "$WORK/pwned" ]
    zfs destroy -r "$V"
fi

T locking
if [ $SKIP = 0 ]; then
    # A sync holds the dataset's transfer lock for as long as it transfers. Simulate that with
    # flock(1), which takes the same kind of lock zz does.
    lockf() { echo "$ZZ_LOCK_DIR/$(echo "$1" | tr / _).sync.lock"; }
    L=$SRC/lk; zfs create "$L"
    run init "$L" "zzremote:$DST/bk/lk" --freq 1h
    check "setup: init succeeds"            rc_is 0
    mkdir -p "$ZZ_LOCK_DIR"
    flock -o "$(lockf "$L")" sleep 20 & holder=$!; sleep 0.5
    run forget "$L"
    check "forget refused while a sync holds the dataset" rc_is 1
    check "…and says why"                   out_has "another zz operation"
    check "…nothing was forgotten"          [ "$(prop target "$L")" = "zzremote:$DST/bk/lk" ]
    run abort "$L"
    check "abort refused while a sync holds the dataset" rc_is 1
    run sync "$L" --now
    check "a second sync skips instead of waiting" out_has "another zz operation is running"
    flock -o "$(lockf "$SRC/lk2")" sleep 20 & holder2=$!; sleep 0.5
    zfs create "$SRC/lk2"
    run init "$SRC/lk2" "zzremote:$DST/bk/lk2"
    check "init refused while its dataset is locked" rc_is 1
    zfs destroy "$SRC/lk2"
    run restore "zzremote:$DST/bk/lk" "$SRC/lk2"
    check "restore refused while its target is locked" rc_is 1
    check "…nothing was created"            bash -c "! zfs list '$SRC/lk2' >/dev/null 2>&1"
    kill $holder $holder2 2>/dev/null; wait $holder $holder2 2>/dev/null
    run forget "$L"
    check "forget works once the sync is done" rc_is 0

fi

T forget_during_sync
if [ $SKIP = 0 ]; then
    # A forget while a real sync is mid-transfer (the receive is slowed to 8s, longer than the
    # 5s the lock waits). The dataset must end up consistent: fully forgotten (no zz properties,
    # no holds) or still fully managed. Before 0.7.2, forget succeeded mid-transfer and the
    # finishing sync then wrote zz:last_sent and the bridge holds back.
    R=$SRC/race; zfs create "$R"; head -c 5M /dev/urandom > "$(mnt "$R")/big"
    run init "$R" "zzremote:$DST/bk/race" --freq 1h
    check "setup: init succeeds"            rc_is 0
    tick; ZZTEST_SLOW_RECV=8 zz sync "$R" --now >"$WORK/race.out" 2>&1 & s=$!
    sleep 1; run forget "$R"; wait $s
    props=$(zfs get -H -s local -o property all "$R" | grep -c '^zz:'); holds=$(held "$R" | grep -c .)
    if [ -z "$(prop target "$R")" ]; then consistent=$([ "$props" = 0 ] && [ "$holds" = 0 ] && echo yes); else consistent=yes; fi
    echo "       (forget during the transfer: exit $RC; afterwards target='$(prop target "$R")', $props zz props, $holds holds)"
    check "forget during a transfer is refused" rc_is 1
    check "…and the dataset is left consistent" [ "$consistent" = yes ]
    run forget "$R"
    check "forget works once the sync is done" rc_is 0
fi

T crash_recovery
if [ $SKIP = 0 ]; then
    # zz dies abruptly (exit 137, as with kill -9) at each step; the next run, or re-running the
    # same command, must recover. Dataset K replicates to KR.
    crash() { local at=$1; shift; OUT=$(ZZTEST_CRASH_AT=$at python3 "$REPO/zz" "$@" 2>&1); RC=$?; }
    tokens() { zfs get -H -r -o name,value receive_resume_token "$1" | awk -F'\t' '$1 !~ /@/ && $2 != "-"' | grep -c .; }
    K=$SRC/crash; KR=$DST/bk/crash; zfs create "$K"; zfs create "$K/c"
    head -c 2M /dev/urandom > "$(mnt "$K")/f"; head -c 2M /dev/urandom > "$(mnt "$K/c")/f"

    # --- init ---
    crash init:after-snapshot init "$K" "zzremote:$KR" --freq 1h
    check "init crash after snapshot: exits abruptly" rc_is 137
    check "…dataset not left half-managed"  [ -z "$(prop target "$K")" ]
    run init "$K" "zzremote:$KR" --freq 1h
    check "…re-running init completes"      rc_is 0
    run forget "$K"; unhold "$KR"; zfs destroy -r "$KR"
    crash init:after-transfer init "$K" "zzremote:$KR" --freq 1h
    check "init crash after transfer"       rc_is 137
    check "…not managed yet"                [ -z "$(prop target "$K")" ]
    run init "$K" "zzremote:$KR" --freq 1h
    check "…re-run adopts the finished replica" out_has "already a replica of $K"
    check "…and completes"                  rc_is 0
    run forget "$K"; unhold "$KR"; zfs destroy -r "$KR"
    crash init:mid-finalize init "$K" "zzremote:$KR" --freq 1h
    check "init crash while writing settings" rc_is 137
    check "…not managed yet"                [ -z "$(prop target "$K")" ]
    run init "$K" "zzremote:$KR" --freq 1h
    check "…re-run completes"               rc_is 0
    check "…bridge held on both sides"      [ -n "$(held "$K")" ] && [ -n "$(held "$KR")" ]

    # --- sync ---
    tick; crash sync:after-snapshot sync "$K" --now
    check "sync crash after snapshot"       rc_is 137
    run sync "$K"
    check "…next sync recovers and sends it" rc_is 0
    check "…replica caught up"              [ "$(newest "$KR")" = "$(newest "$K")" ]
    tick; crash sync:after-send sync "$K" --now
    check "sync crash after sending, before bookkeeping" rc_is 137
    run sync "$K"; run status
    check "…next sync recovers, status OK"  bash -c "grep -F '$K ' <<<\"\$0\" | grep -qF '| OK '" "$OUT"
    tick; crash pin:after-hold sync "$K" --now
    check "crash between holding the new bridge and releasing the old" rc_is 137
    run sync "$K"
    check "…next sync leaves exactly one held bridge each side" [ "$(held "$K" | grep -c .)" = 1 ] && [ "$(held "$KR" | grep -c .)" = 1 ]

    # --- an interrupted receive inside a CHILD dataset (the token lands on the child) ---
    head -c 6M /dev/urandom > "$(mnt "$K/c")/g"; tick
    zfs snapshot -r "$K@zz_auto_$(date +%s)"; n=$(newest "$K"); b=$(newest "$KR")
    zfs send -R -L -c -i "@$b" "$K@$n" 2>/dev/null | head -c 3M | zfs recv -s -u "$KR" 2>/dev/null
    check "setup: token left on the child"  [ "$(tokens "$KR")" -ge 1 ]
    run sync "$K"
    check "sync resumes the child's interrupted receive" rc_is 0
    check "…no tokens left"                 [ "$(tokens "$KR")" = 0 ]
    check "…child has the snapshot"         exists "$KR/c@$n"
    head -c 6M /dev/urandom > "$(mnt "$K/c")/h"; tick
    zfs snapshot -r "$K@zz_auto_$(date +%s)"; n=$(newest "$K"); b=$(newest "$KR")
    zfs send -R -L -c -i "@$b" "$K@$n" 2>/dev/null | head -c 3M | zfs recv -s -u "$KR" 2>/dev/null
    run abort "$K"
    check "abort clears tokens on children too" [ "$(tokens "$KR")" = 0 ]
    run sync "$K"
    check "…and sync continues normally"    rc_is 0

    # --- forget ---
    crash forget:mid-inherit forget "$K"
    check "forget crash part-way"           rc_is 137
    check "…dataset still managed (target removed last)" [ -n "$(prop target "$K")" ]
    run forget "$K"
    check "…re-running forget completes"    rc_is 0
    check "…no zz properties or holds left" [ -z "$(zfs get -H -s local -o property all "$K" | grep '^zz:')" ] && [ -z "$(held "$K")" ]

    # --- restore ---
    run init "$K" "zzremote:$KR" --freq 1h 2>/dev/null
    good=$(newest "$KR"); tick; echo bad > "$(mnt "$K")/f"; echo bad > "$(mnt "$K/c")/f"; run sync "$K" --now
    wipe "$K"
    crash restore:mid-props restore "zzremote:$KR" "$K"
    check "restore crash while writing settings" rc_is 137
    run restore "zzremote:$KR" "$K"
    check "…re-running restore completes (stray settings don't block it)" rc_is 0
    check "…managed"                        [ "$(prop target "$K")" = "zzremote:$KR" ]
    wipe "$K"
    run restore "zzremote:$KR" "$K" --at "$good"
    crash restore:mid-rollback restore "zzremote:$KR" "$K" --at "$good" --rollback-remote
    check "restore --rollback-remote crash after the first rollback" rc_is 137
    run restore "zzremote:$KR" "$K" --at "$good" --rollback-remote
    check "…re-run completes"               rc_is 0
    check "…every replica dataset rolled back" [ "$(newest "$KR")" = "$good" ] && [ "$(zfs list -H -t snapshot -o name -s creation -d 1 "$KR/c" | tail -1 | cut -d@ -f2)" = "$good" ]
    tick; run sync "$K" --now
    check "…and replication continues"      rc_is 0
fi

T restore_crash_in_child
if [ $SKIP = 0 ]; then
    # A restore that dies while receiving a CHILD dataset leaves the resume token on that child.
    tokens() { zfs get -H -r -o name,value receive_resume_token "$1" | awk -F'\t' '$1 !~ /@/ && $2 != "-"' | grep -c .; }
    Q=$SRC/rq; QR=$DST/bk/rq; zfs create "$Q"; zfs create "$Q/c"
    head -c 100K /dev/urandom > "$(mnt "$Q")/f"; head -c 8M /dev/urandom > "$(mnt "$Q/c")/f"
    run init "$Q" "zzremote:$QR" --freq 1h
    head -c 8M /dev/urandom > "$(mnt "$Q/c")/g"; tick; run sync "$Q" --now
    (cd "$(mnt "$Q/c")" && sha256sum f g) > "$WORK/rq_sums"
    wipe "$Q"
    # Full recursive stream cut partway through the child (the top dataset is small, the child large)
    zfs send -R -L -c "$QR@$(newest "$QR")" 2>/dev/null | head -c 6M | zfs recv -s -u "$Q" 2>/dev/null
    check "setup: top arrived, the child holds a partial receive" [ "$(tokens "$Q")" -ge 1 ]
    run restore "zzremote:$QR" "$Q"
    check "re-running restore finishes the child's interrupted receive" rc_is 0
    check "…no tokens left"                 [ "$(tokens "$Q")" = 0 ]
    check "…child's data intact"            bash -c "cd '$(mnt "$Q/c")' 2>/dev/null && sha256sum -c --quiet '$WORK/rq_sums'"
fi

T forget
if [ $SKIP = 0 ]; then
    run forget "$DS"
    check "forget succeeds"                 rc_is 0
    check "…releases local holds"           [ -z "$(held "$DS")" ]
    check "…releases remote holds"          [ -z "$(held "$RP")" ]
    check "…data kept"                      [ "$(nsnaps "$DS")" -gt 0 ]
    run status
    check "…no longer listed"               out_lacks "$DS "
fi

echo
echo "$PASS passed, $FAIL failed"
for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "  - $f"; done
[ "$FAIL" = 0 ]
