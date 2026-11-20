# Runbook: weekly GC on a union host (#50)

`nix-gc.timer` runs `nix-collect-garbage --delete-older-than 30d` every Sunday at 04:00 (plus up to 2 hours of
random delay) on every host in union Mode.
It does collect the RW Branch. Its log, though, looks alarming, and most of it is noise from Nix's
`local-overlay://` store. This runbook says which lines to ignore and how to check that GC really works.

## Expected, ignore

A typical run (pi5, 2026-11-15):

```
deleting '/nix/store/…'                         ×643   (all 643 still in the Lower Store afterwards)
BUG: error: cannot delete path '/nix/store/A' because it is in use by '/nix/store/B'   ×134
warning: '/nix/store' needs remounting, set remount-hook to do this automatically      (sometimes)
643 store paths deleted, 72343110759.15 MiB freed
```

- **`deleting '…'` for Lower Store paths.** Almost every path is a no-op. The same Lower Store paths come back every week.
- **`BUG: error: cannot delete path … in use by …`.** Each one names two Lower Store paths. GC carries on, and the unit still ends `Result=success`.
- **The deleted and freed totals.** They mean nothing. Don't graph them or alert on them.
- **`needs remounting`.** A path was in both the RW Branch and the Lower Store, and GC deleted the RW copy. mergerfs (ADR 0002) shows the Lower Store copy straight away, so no remount is needed.

Act on a failed unit (`systemctl show nix-gc.service -p Result` is not `success`), not on these lines.

## Why (Nix 2.30.0, upstream)

Read from the 2.30.0 source. Nothing in our roles causes it.

1. When anything asks whether a Lower Store path is valid, `LocalOverlayStore::isValidPathUncached` copies its
   metadata and references into the RW Branch's database:
   ([local-overlay-store.cc#L135-L150](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/local-overlay-store.cc#L135-L150)).
2. GC therefore sees those paths as valid local paths with no GC root, so it treats them as garbage. It
   invalidates each one in the RW Branch's database and calls `deleteStorePath`. For a path with no RW-Branch
   copy, the overlay store's `deleteStorePath` does nothing
   ([#L212-L237](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/local-overlay-store.cc#L212-L237)),
   but GC has already printed `deleting` and counted the path. The next lookup registers the path again, so
   the same paths come back the next week.
3. Nothing sets `bytesFreed` in that case. GC declares it without a value
   (`uint64_t bytesFreed;`, [gc.cc#L656-L659](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/gc.cc#L656-L659))
   and adds whatever was in it to the total, hence figures like 7×10¹⁰ MiB.
4. When GC tries to invalidate a path whose referrer is still registered, `invalidatePathChecked` throws
   `PathInUse`. GC catches it and prints `BUG: …`
   ([gc.cc#L779-L780](https://github.com/NixOS/nix/blob/2.30.0/src/libstore/gc.cc#L779-L780)), which points
   at [NixOS/nix#11923](https://github.com/NixOS/nix/issues/11923).

## Check that the RW Branch is really collected

As root on the host:

```sh
NIX=/nix/var/nix/profiles/default/bin; rw=/nix/.rw-store/store
# Dead paths that have an RW-Branch copy (the only garbage GC can really free):
for p in $($NIX/nix-store --gc --print-dead 2>/dev/null); do
  [ -e "$rw/${p#/nix/store/}" ] && echo "$p"; done > /tmp/rw-dead
wc -l < /tmp/rw-dead
# How many of those were registered before the last GC run started? Expect 0:
last=$(date -d "$(journalctl -u nix-gc.service -o short-iso | grep -E 'Start(ed|ing)' | tail -1 | awk '{print $1}')" +%s)
xargs -r $NIX/nix --extra-experimental-features nix-command path-info --json < /tmp/rw-dead |
  python3 -c "import json,sys; d=json.load(sys.stdin); v=d.values() if isinstance(d,dict) else d; print(sum(1 for i in v if i and i['registrationTime']<$last))"
```

A count above 0 means garbage survived a run. That would be a real bug; reopen #50 with the paths.
On 2026-11-20 pi5 had 312 dead RW-Branch paths, all registered after the 11-15 run (count 0), and
nixcanary-deb1 had 2 of 1132.
