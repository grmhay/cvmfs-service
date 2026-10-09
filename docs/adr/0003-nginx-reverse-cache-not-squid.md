# Clients read the repository through an nginx reverse cache, not a Squid forward proxy

CernVM-FS deployments conventionally put a Squid forward proxy between clients and a Stratum 1, with
`CVMFS_HTTP_PROXY` naming the Squid. The owner already runs nginx-shaped infrastructure and no Squid;
and with S3 upstream storage the Origin bucket itself serves every object, so there is no Stratum 1
to proxy to either.

A dedicated VM, `cache1.hayweb.org`, runs nginx as a **reverse cache** in front of the Origin bucket.
Clients set `CVMFS_SERVER_URL=http://cache1.hayweb.org/cvmfs/@fqrn@` and `CVMFS_HTTP_PROXY=DIRECT`.
Everything under `data/` is content-addressed and immutable and is cached for 90 days; the three
mutable manifests (`.cvmfspublished`, `.cvmfswhitelist`, `.cvmfsreflog`) are cached for 30 seconds.
The bucket is never exposed to clients; nginx is the only reader of MinIO. Cloud hosts use the same
URL over OpenVPN with internal DNS pushed through the tunnel.

## Considered Options

- **Squid forward proxy** — the documented default, but a second proxy technology to run for one
  consumer, and it only adds value when there are several Stratum 1s to choose between. Rejected.
- **nginx as a forward proxy** — nginx can be coerced into proxying absolute-URI requests for plain
  HTTP, but it is a hack with no upstream support. Rejected.
- **Clients hit MinIO directly** — works (CVMFS supports pointing clients at an S3 bucket) but puts
  every cache miss on TrueNAS and gives no shared cache; MinIO also then needs anonymous access from
  every host. Rejected.
- **A CVMFS Stratum 1** — a full replica of the repository on another host. Overkill for one site;
  the S3 Origin already is the durable copy.
- **Running the cache as a compose stack on skyline** — fits the ops repo pattern, but skyline is the
  public-facing Docker host and the owner wanted the cache on its own VM.

## Consequences

- Failover is a second `CVMFS_SERVER_URL` entry; a second cache (or a per-cloud one when a cloud
  region gains more than one host) is an inventory change, not a design change.
- The cache must strip S3's cache-defeating headers (`proxy_ignore_headers`) and must not cache a
  404 for long: a client may ask for an object moments before the publish that creates it.
- A stale manifest can be served for up to 30 s plus the repository TTL (4 min); publish visibility
  is therefore bounded at roughly five minutes, matching the Publisher's reconciler interval.
- nginx verifies the Origin's Let's Encrypt certificate; the MinIO cert work is a prerequisite.
- `$upstream_cache_status` is logged per request and shipped to Loki for a hit-ratio dashboard.
