# Runbook: weekly GC on a host in union Mode (#50)

`nix-gc.timer` runs `nix-collect-garbage --delete-older-than {{ nix_gc_older_than }}` (default `30d`) weekly:
Sunday at 04:00, plus up to 2 hours of random delay (`nix-gc.timer.j2`). It does collect the RW Branch.
Its log, though, looks alarming, and most of it is noise from Nix's `local-overlay://` store. This runbook
says which lines to ignore and how to check that GC really works. This is not the Repository's GC; see
`gc.md` for that.

## Symptoms (expected, ignore)

An example run (pi5, 2026-11-15):

```
deleting '/nix/store/…'                         ×643   (all 643 still in the Lower Store afterwards)
BUG: error: cannot delete path '/nix/store/A' because it is in use by '/nix/store/B'   ×134
warning: '/nix/store' needs remounting, set remount-hook to do this automatically      (sometimes)
643 store paths deleted, 72343110759.15 MiB freed
```

- **`deleting '…'` for Lower Store paths.** Almost every path is a no-op. The same Lower Store paths come back every week.
- **`BUG: error: cannot delete path … in use by …`.** The path it cannot delete is a Lower Store path: every target checked on two hosts was. GC carries on, and the unit still ends `Result=success`.
- **The deleted and freed totals.** They mean nothing. Don't graph them or alert on them.
- **`needs remounting`.** A path was in both the RW Branch and the Lower Store, and GC deleted its RW-Branch copy. mergerfs (ADR 0002) shows the Lower Store copy straight away, so no remount is needed.

Act on a failed unit (`systemctl show nix-gc.service -p Result` is not `success`), not on these lines.

## Why (Nix 2.30.0, upstream)

Read from the 2.30.0 source. Nothing in our roles causes it. Re-check these lines when `nix_installer_version`
is bumped.

1. GC lists the merged `/nix/store` (`readdir`) and asks whether each entry is valid. For a Lower Store path,
   `LocalOverlayStore::isValidPathUncached` copies its metadata and references into the RW Branch's database
   ([local-overlay-store.cc#L135-L150](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/local-overlay-store.cc#L135-L150)).
2. GC therefore sees those paths as valid local paths with no GC root, so it treats them as garbage. It
   invalidates each one in the RW Branch's database and calls `deleteStorePath`. For a path with no RW-Branch
   copy, the overlay store's `deleteStorePath` does nothing
   ([#L212-L237](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/local-overlay-store.cc#L212-L237)),
   but GC has already printed `deleting` and counted the path. Every run registers the same paths again and
   "deletes" them again.
3. Nothing sets `bytesFreed` in that case. GC declares it without a value
   (`uint64_t bytesFreed;`, [gc.cc#L656-L659](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/gc.cc#L656-L659))
   and adds whatever was in it to the total, hence figures like 7×10¹⁰ MiB. Fixed upstream in Nix 2.36.0
   ([NixOS/nix#16269](https://github.com/NixOS/nix/issues/16269)); the deleted count stays wrong.
4. When GC tries to invalidate a path whose referrer is still registered, `invalidatePathChecked` throws
   `PathInUse`. GC catches it and prints `BUG: …`
   ([gc.cc#L779-L780](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/gc.cc#L779-L780)), which points
   at [NixOS/nix#11923](https://github.com/NixOS/nix/issues/11923).

Upstream report for point 2: not filed yet (see #50). It reproduces on plain overlayfs too, so it is not
mergerfs-specific.

## Check that the RW Branch is really collected

As root on the host. Listing dead paths also registers Lower Store paths in the RW Branch's database, the same
harmless side effect as point 1.

```sh
( # subshell: an `exit` below leaves your shell open
NIX=/nix/var/nix/profiles/default/bin
RW=/nix/.rw-store/store
DEAD=$(mktemp)
# Dead paths that have an RW-Branch copy (the only garbage GC can really free):
"$NIX/nix-store" --gc --print-dead > "$DEAD.all" || { echo "print-dead failed"; exit 1; }
while read -r p; do [ -e "$RW/${p#/nix/store/}" ] && echo "$p"; done < "$DEAD.all" > "$DEAD"
wc -l < "$DEAD"
# The last GC run's start (oneshot units log "Starting"):
START=$(journalctl -u nix-gc.service -o short-iso | awk '/Starting/ {t=$1} END {print t}')
[ -n "$START" ] || { echo "no GC run in the journal"; exit 1; }
LAST=$(date -d "$START" +%s)
# How many of those were registered before that run started?
xargs -r "$NIX/nix" --extra-experimental-features nix-command path-info --json < "$DEAD" |
  python3 -c "import json,sys; d=json.load(sys.stdin); v=d.values() if isinstance(d,dict) else d; print(sum(1 for i in v if i and i['registrationTime']<$LAST))"
rm -f "$DEAD" "$DEAD.all"
)
```

Expect 0. A path registered before the last run may still have been live then, for example held by a
profile generation younger than `nix_gc_older_than`, a GC root or a `result` link removed since. Above 0,
check those paths' roots as of the last run (`nix-store --query --roots`, the profile generations' dates)
before deciding garbage survived. If it did, reopen #50 with the paths.
