# FIPS Nostr Relay Sidecar with Optional Nym Mixnet Transport

Runs a [strfry](https://github.com/hoytech/strfry) Nostr relay reachable
exclusively over the FIPS mesh, with an **optional Nym mixnet sidecar**
that lets the FIPS peer link route through the
[Nym mixnet](https://nymtech.net/) via a local
[`nym-socks5-client`](https://nymtech.net/docs/clients/socks5-client.html).
The relay container shares the FIPS sidecar's network namespace and is
isolated from the host network by iptables — it can only be reached via
the node's `.fips` name.

A single switch in `.env` (`FIPS_PEER_TRANSPORT`) controls everything:
when it is `udp` or `tcp`, only the FIPS daemon and the relay run; when
it is `nym`, the `nym-socks5-client` sidecar is also started and the
FIPS daemon is configured to dial its peer through the mixnet.

## How to Run

### 1. Set your node identity

The relay needs a unique FIPS identity. Generate one with:

```bash
fipsctl keygen
```

If you do not have FIPS installed locally, generate the key directly
inside the (already built) sidecar image:

```bash
docker run --rm --entrypoint fipsctl \
    sidecar-nostr-mixnet-relay-fips:latest keygen
```

Then set it in `.env`:

```bash
# .env
FIPS_NSEC=nsec1...   # paste your nsec here
```

`FIPS_NSEC` is required — the container will refuse to start without it.

### 2. Choose the peer transport

`.env` ships with `FIPS_PEER_TRANSPORT=udp` and a public peer
configured. Three modes are supported:

| `FIPS_PEER_TRANSPORT` | Peer-link path | Sidecars started |
|---|---|---|
| `udp`  | direct UDP/IP                           | `fips`, `app` |
| `tcp`  | direct TCP/IP                           | `fips`, `app` |
| `nym`  | TCP tunnelled through the Nym mixnet    | `fips`, `app`, `nym` |

The `nym` row is enabled by a Compose profile that is auto-activated
from `.env`:

```ini
COMPOSE_PROFILES=${FIPS_PEER_TRANSPORT}
```

Compose interpolates that line, so simply setting
`FIPS_PEER_TRANSPORT=nym` is enough to add the `nym-socks5-client`
sidecar to the next `docker compose up`. No `--profile` flag is needed.

To enable Nym, additionally set:

```ini
FIPS_PEER_TRANSPORT=nym
NYM_SERVICE_PROVIDER=<nym-network-requester-address>
```

A working network-requester address is required — pick one from
[harbourmaster.nymtech.net](https://harbourmaster.nymtech.net/) or
run your own.

### 3. Start the stack

FIPS is compiled from source inside the Docker build stage — no local
Rust toolchain, Zig, or cargo-zigbuild needed.

```bash
cd examples/sidecar-nostr-mixnet-relay
docker compose up -d --build
```

Confirm what was actually started:

```bash
docker compose config --services
# fips, app          → udp/tcp transport
# fips, app, nym     → nym mixnet transport
docker compose ps
```

### 4. Verify

```bash
# FIPS node is up and has a mesh address:
docker exec sidecar-nostr-mixnet-relay-fips-1 fipsctl show status

# Relay is listening (should show nginx on :80 and strfry on :7777):
docker exec sidecar-nostr-mixnet-relay-fips-1 ss -tlnp

# Peer link is established:
docker exec sidecar-nostr-mixnet-relay-fips-1 fipsctl show peers

# Active transports — should include `nym` when the mixnet is enabled:
docker exec sidecar-nostr-mixnet-relay-fips-1 fipsctl show transports

# Live logs:
docker compose logs -f
```

When Nym is enabled, the `nym` sidecar takes 30–60 s to bootstrap
through the mixnet on first start. Watch its progress with:

```bash
docker compose logs -f nym
```

The FIPS daemon will print
`Waiting for Nym SOCKS5 client to become ready...` and probe
`127.0.0.1:1080` with exponential backoff (1 s → 2 s → 4 s …) until the
sidecar is ready, then complete the handshake to the peer over the
mixnet automatically.

### 5. Connect to the relay

Your node's npub (and therefore its `.fips` name) is derived from its
keypair:

```bash
docker exec sidecar-nostr-mixnet-relay-fips-1 fipsctl show status
```

Connect from any FIPS-peered client using the node's npub:

```
ws://npub1xxxx.fips:80
```

### 6. Switching transport modes

To switch back to plain UDP after running with Nym:

```bash
# Edit .env: FIPS_PEER_TRANSPORT=udp  (and optionally clear NYM_SERVICE_PROVIDER)
docker compose down
docker compose up -d
```

`docker compose ps` will then show only `fips` + `app`; the `nym`
sidecar is no longer started.

## How the Nym mixnet sidecar works

The `nym` service runs the official `nym-socks5-client` binary in the
FIPS network namespace. It listens on `127.0.0.1:1080` and provides a
SOCKS5 proxy whose outbound traffic is routed through the Nym mixnet
(Sphinx packet routing through three mix nodes, with timing
obfuscation).

The FIPS daemon's Nym transport — implemented in
[`src/transport/nym/`](../../src/transport/nym/) — opens TCP
connections to peers via this SOCKS5 proxy, frames them with the
existing FIPS multiplexing protocol, and otherwise behaves like the
TCP transport. Because the Nym transport is connection-oriented and
FMP-framed, **the peer must accept FIPS over a TCP endpoint**;
`FIPS_PEER_ADDR` must therefore point at a TCP listener.

### How `nym-socks5-client` is obtained

`nym-socks5-client` is **not built from source**. The
[`Dockerfile.nym`](Dockerfile.nym) downloads the official pre-built
binary published by Nym Technologies on GitHub Releases at
`docker compose build` time:

```
https://github.com/nymtech/nym/releases/download/nym-binaries-v2026.6-stilton/nym-socks5-client
```

Currently pinned to release tag **`nym-binaries-v2026.6-stilton`**
(binary version 1.1.73). The build prints the version after download,
and `nym-socks5-client --version` inside the running container will
show it again at startup.

To upgrade or downgrade, edit the `curl` URL in `Dockerfile.nym` to a
different tag from
[github.com/nymtech/nym/releases](https://github.com/nymtech/nym/releases)
and run `docker compose build nym` again. New tags appear roughly
every few weeks.

The downloaded binary is `linux/amd64` only. The `nym` service
declares `platform: linux/amd64`; on Apple Silicon Docker runs it
under Rosetta. That is expected and not a bug.

## Run with Peers

To connect the sidecar to an existing mesh, provide the peer's npub
and transport address:

```bash
FIPS_PEER_NPUB=npub1... \
FIPS_PEER_ADDR=203.0.113.10:8443 \
FIPS_PEER_ALIAS=gateway \
FIPS_PEER_TRANSPORT=nym \
docker compose up -d
```

Verify the peer link:

```bash
docker exec sidecar-nostr-mixnet-relay-fips-1 fipsctl show peers
docker exec sidecar-nostr-mixnet-relay-fips-1 fipsctl show links
```

## Architecture

```
┌──── Docker network namespace (shared) ────────────┐
│                                                   │
│ ┌── fips container ──┐  ┌── nym container ─────┐  │
│ │ fips daemon        │  │ nym-socks5-client    │  │
│ │ fipsctl            │  │ → Nym mixnet via     │  │
│ │ dnsmasq            │  │   eth0 (TCP)         │  │
│ └────────────────────┘  └──────────────────────┘  │
│                                                   │
│ ┌── app container ───────────────────────────┐    │
│ │ strfry (Nostr relay) + nginx               │    │
│ └────────────────────────────────────────────┘    │
│                                                   │
│ Interfaces:                                       │
│   lo    — loopback (unrestricted)                 │
│   eth0  — Docker bridge (iptables: FIPS only)     │
│   fips0 — FIPS TUN (fd::/8, unrestricted)         │
└───────────────────────────────────────────────────┘
```

The FIPS sidecar owns the network namespace and creates the `fips0`
TUN interface. The `app` and (optionally) `nym` containers join via
`network_mode: service:fips` and see the same interfaces. The
entrypoint script applies iptables rules before launching the FIPS
daemon:

**IPv4 rules** (iptables):

- ACCEPT on `lo` (both directions)
- ACCEPT UDP sport/dport 2121 on `eth0` (FIPS UDP transport)
- ACCEPT TCP dport 443 / sport 443 on `eth0` (FIPS TCP transport)
- When `FIPS_PEER_TRANSPORT=nym`, additionally ACCEPT outbound TCP on
  `eth0` (the Nym SOCKS5 client needs to reach Nym gateways)
- DROP everything else on `eth0`

**IPv6 rules** (ip6tables):

- ACCEPT on `lo` (both directions)
- ACCEPT on `fips0` (both directions)
- DROP everything on `eth0`

### DNS Resolution

DNS inside the container is handled by dnsmasq (127.0.0.1:53):

- `.fips` queries are forwarded to the FIPS daemon's built-in DNS
  resolver (127.0.0.1:5354), which resolves npub-based names to
  `fd::/8` addresses
- All other queries are forwarded to Docker's embedded DNS
  (127.0.0.11)

The `resolv.conf` mount points the container's resolver at
127.0.0.1, where dnsmasq handles the routing.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `FIPS_NSEC` | *(required)* | Node secret key (hex or nsec1 bech32) |
| `FIPS_PEER_NPUB` | *(empty)* | Peer's npub to connect to |
| `FIPS_PEER_ADDR` | *(empty)* | Peer's transport address (e.g. `203.0.113.10:2121`) |
| `FIPS_PEER_ALIAS` | `peer` | Human-readable peer name |
| `FIPS_PEER_TRANSPORT` | `udp` | Peer transport type — `udp`, `tcp`, or `nym` |
| `FIPS_UDP_BIND` | `0.0.0.0:2121` | UDP transport bind address |
| `FIPS_TCP_BIND` | `0.0.0.0:8443` | TCP transport bind address |
| `FIPS_TUN_MTU` | `1280` | TUN interface MTU |
| `FIPS_NYM_SOCKS5_ADDR` | `127.0.0.1:1080` | Address of the Nym SOCKS5 client (used only when `FIPS_PEER_TRANSPORT=nym`) |
| `NYM_SERVICE_PROVIDER` | *(required for nym)* | Nym network-requester address |
| `NYM_CLIENT_ID` | `fips-nym-client` | `nym-socks5-client` instance ID |
| `NYM_SOCKS5_PORT` | `1080` | Port the Nym client listens on |
| `NYM_SOCKS5_BIND` | `0.0.0.0` | Bind address for the Nym client |
| `COMPOSE_PROFILES` | `${FIPS_PEER_TRANSPORT}` | Auto-activates the `nym` Compose profile when transport is `nym` |
| `FIPS_NETWORK` | `fips-sidecar-net` | Docker network name |
| `FIPS_SUBNET` | `172.20.1.0/24` | Docker network subnet |
| `FIPS_IPV4` | `172.20.1.20` | Sidecar's IPv4 address on the Docker network |
| `RUST_LOG` | `info` | FIPS log level |

## Troubleshooting

**`FIPS_NSEC is required`** — The `FIPS_NSEC` environment variable is
not set. Either add it to `.env` or pass it on the command line.
Generate a random key with `fipsctl keygen` (locally or via
`docker run --rm --entrypoint fipsctl <image> keygen`).

**`nym` service is not started even though I set `FIPS_PEER_TRANSPORT=nym`** —
Check that `.env` still contains
`COMPOSE_PROFILES=${FIPS_PEER_TRANSPORT}` and that you did not export
`COMPOSE_PROFILES` in your shell to a different value (shell
environment overrides `.env`). Run `docker compose config --services`
to see what Compose will start.

**FIPS daemon prints `Connection refused` repeatedly on the SOCKS5
probe** — The `nym-socks5-client` is not running, or is not yet ready.
Either you forgot to set `FIPS_PEER_TRANSPORT=nym` (so the sidecar
was never started — check `docker compose ps`), or the mixnet
bootstrap is still in progress (give it 30–60 s and check
`docker compose logs -f nym`).

**Nym client exits immediately with `error: NYM_SERVICE_PROVIDER is
required`** — Set `NYM_SERVICE_PROVIDER` in `.env` to a working
network-requester address from harbourmaster.nymtech.net.

**Peer never connects when using Nym** — `FIPS_PEER_ADDR` must point
to a **TCP** listener on the peer (typically the peer's
`FIPS_TCP_BIND`, default `0.0.0.0:8443`). The Nym transport tunnels
TCP, so a `udp` peer endpoint will not work.

**`fips0` interface not appearing** — The FIPS daemon needs
`/dev/net/tun` and `NET_ADMIN` capability. Check that the compose
file includes both:

```yaml
cap_add:
  - NET_ADMIN
devices:
  - /dev/net/tun:/dev/net/tun
```

**No peer connection established** — Verify the peer address is
reachable from the sidecar container
(`docker exec sidecar-nostr-mixnet-relay-fips-1 ping -c1 <peer-ip>`).
If joining an external Docker network, ensure `FIPS_NETWORK`,
`FIPS_SUBNET`, and `FIPS_IPV4` match the target network. Check logs
with `docker logs sidecar-nostr-mixnet-relay-fips-1`.

**DNS not resolving `.fips` names** — Verify dnsmasq is running:
`docker exec sidecar-nostr-mixnet-relay-fips-1 pgrep dnsmasq`. Check
that `resolv.conf` is mounted (should contain
`nameserver 127.0.0.1`). Verify the FIPS DNS resolver is listening:
`docker exec sidecar-nostr-mixnet-relay-fips-1 dig @127.0.0.1 -p 5354 <npub>.fips AAAA`.

**iptables errors in entrypoint** — The sidecar container requires
`NET_ADMIN` capability for iptables. Without it, the isolation rules
cannot be applied and the entrypoint will fail.

**`nym` image fails to run on Apple Silicon** — Ensure Rosetta is
installed (`softwareupdate --install-rosetta --agree-to-license`) or
enabled under Docker Desktop → Settings → General → "Use Rosetta for
x86_64/amd64 emulation on Apple Silicon".

## Production Considerations

**Secrets management**: The default `.env` contains placeholder
values. In production, use Docker secrets, a vault, or inject the key
via a secure CI/CD pipeline. Never commit production keys to version
control.

**Logging**: Set `RUST_LOG` to control log verbosity (`debug`,
`info`, `warn`, `error`). For production, configure the Docker
logging driver with size limits:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

**Resource limits**: Add memory and CPU constraints in the compose
file:

```yaml
deploy:
  resources:
    limits:
      memory: 256M
      cpus: "0.5"
```

**Multiple peers**: The entrypoint supports a single peer via
environment variables. For multiple peers, mount a custom
`fips.yaml` directly:

```yaml
volumes:
  - ./my-fips.yaml:/etc/fips/fips.yaml:ro
```

**Health checks**: Add a Docker health check using `fipsctl`:

```yaml
healthcheck:
  test: ["CMD", "fipsctl", "show", "status"]
  interval: 30s
  timeout: 5s
  retries: 3
```
