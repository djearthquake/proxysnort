# ProxySnort v4

Proxy check for AMX Mod X that runs over **async HTTPS** instead of raw sockets.
Checks each connecting player's IP against **proxycheck.io**, then applies a
configurable policy (reserved-slot kick, or the "discombobulate" effects).

> **Linux 32-bit server only for now.** Windows / 64-bit builds are **not**
> supported yet — the bundled `.so` is i386 and the module source is
> intentionally Linux-only. Plugins cannot load the module on Windows.

Requires **AMX Mod X 1.10+ (Linux, 32-bit)** and the bundled **HTTP module** —
without it the plugin fails to load:
`unknown function (name "http_get")`.

### Dependencies

| Dependency | Why | Install (Debian / Mint) |
|---|---|---|
| `libcurl` (runtime) | The `.so` links against it | `sudo apt install libcurl4` |
| `libcurl4-openssl-dev` + `pkg-config` | Only if building the *module* yourself from source | `sudo apt install libcurl4-openssl-dev pkg-config` |
| 32-bit libs | HLDS / AMXX are 32-bit | `sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install lib32gcc1 lib32stdc++6` (example) |

Verify the `.so` sees libcurl before starting the server:

```bash
ldd addons/amxmodx/modules/http_amxx_i386.so | grep curl
# -> libcurl.so.4 => /usr/lib/x86_64-linux-gnu/libcurl.so.4 (or i386 path)
```

> Mint is Ubuntu-based, so the same `apt` commands work there. On Debian
> with the `contrib`/`non-free` split, make sure your sources include them if
> your mirror needs them for curl deps.

## How the HTTPS async works

```
GAME THREAD                          WORKER THREADS (2)
client_authorized → http_get() ──►  queue ──► curl (DNS + TLS + HTTP)
                                      game keeps ticking, never blocks
StartFrame() ──► Http_OnComplete() ──► JSON parse → policy / log / HUD
```

- Protocols: `http` / `https` only, verified TLS certificates
- 2 pthreads, 16-deep queue, 32 KiB response cap, 10 s timeout (30 s max)
- Callbacks fire on the game thread, so up to 16 lookups can be in flight
  without a frame hitch, and a slow endpoint only costs one queued request

## Install

1. Drop `addons/amxmodx/modules/http_amxx_i386.so` into your `modules/` folder
2. In `addons/amxmodx/configs/modules.ini` add (must load **before** the plugin):
   ```
   http_amxx_i386.so
   ```
3. Compile `proxysnort4.sma` with `amxxpc` and enable in `plugins.ini`:
   ```
   proxysnort4.amxx
   ```
4. In `server.cfg`:
   ```c
   sv_proxycheckio-key   "YOUR_KEY"   // never commit a real key
   ps_risk_kick          "55"         // risk >= 55 = flagged
   ps_discombobulate     "1"          // 1 = effects, 0 = slots only
   ps_log_prune_days     "7"
   ```

## Verify

```
amxx_http_test https://example.com   // module sanity test
amx_proxytest 8.8.8.8                // one-off IP lookup
say /proxies                          // (admin) recent-blocks HUD
amx_proxy_whitelist <name|#userid>    // exempt an account
```

## Effects on flagged players

Name-rename to `PROXY: <name>`, alert sound, recent-blocks HUD, JSON logs
in `configs/` (`proxy_logs.json`, `proxyfree_logs.json`). With
`ps_discombobulate 1`, one random spawn effect: screen shake, 50 HP, half
damage dealt, or frozen + red glow. When fewer than 6 slots free, the proxy
user is kicked: `Security Risk: <reason> (<risk>%)`.

## License

GPLv3 (AMX Mod X derivative-work exceptions apply). No compiled `.amxx` is
shipped — compile it yourself for your target.
