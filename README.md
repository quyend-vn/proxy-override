# Proxy Override

A small macOS menu bar app that does two things from Proxyman, with nothing else:

- **External proxy**: send selected hosts through an upstream HTTP, HTTPS (TLS to the proxy) or SOCKS5 proxy, with optional authentication, an include list and a bypass list.
- **Override macOS Proxy**: point the system proxy at the app. Quitting the app puts the previous settings back exactly.

There's no TLS interception and no certificate to install.

## Download

Get `ProxyOverride.zip` from the [Releases](../../releases) page. Requires macOS 15 or later on Apple silicon (M1 or newer).

```bash
unzip ProxyOverride.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/ProxyOverride.app
open /Applications/ProxyOverride.app
```

The app is ad-hoc signed, not notarized by Apple. That's why you need the `xattr` step. Without it, macOS says the app "can't be opened"; you can also allow it in System Settings → Privacy & Security → **Open Anyway**.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). Swift 6 toolchain, no third-party dependencies.

```bash
git clone git@github.com:quyend-vn/proxy-override.git
cd proxy-override/ProxyOverride
./build.sh             # builds build/ProxyOverride.app
./build.sh --install   # also quits the running copy and installs to /Applications
```

An app built on the same Mac isn't quarantined, so it opens without a Gatekeeper warning.

To package a release zip:

```bash
cd ProxyOverride && ./build.sh
ditto -c -k --keepParent build/ProxyOverride.app ../dist/ProxyOverride.zip
```

## First run

1. Click the menu bar icon, then **Settings…**.
2. In **External Proxy**, enter the proxy host, port, username and password. If Proxyman is installed, **General → Import from Proxyman** fills in hosts and lists, but not credentials.
3. In **Rules**, set the include and bypass lists.
4. Turn on **Override macOS Proxy**.

The two switches in the menu:

| Switch | What it does |
|---|---|
| **Proxy Running** | Starts the local proxy on `127.0.0.1:9090`. Only apps you point at it use it. |
| **Override macOS Proxy** | Also points the macOS system proxy at it, so browsers and most apps use it. Turning it on starts the proxy if needed. |

### Rules

- **Include**: only these hosts go through the external proxy; everything else connects directly. An empty list sends every host through the proxy.
- **Bypass**: these hosts always connect directly, even if they're in Include.
- Wildcards: `*.example.com` matches `example.com` and every subdomain. `?` matches one character.
- **Bypass localhost** keeps `localhost`, `*.local` and private-network addresses (`10.*`, `192.168.*`, …) direct.

### Moving to another Mac

Settings are in `~/Library/Application Support/ProxyOverride/settings.json`. Copy that file to the same place on the other Mac, then enter the passwords again: they're in each Mac's Keychain (service `ProxyOverride`) and never in the file or this repo.

## How it works

```
 app / browser ──► macOS proxy ──► 127.0.0.1:9090 (ProxyOverride) ──┬─► upstream proxy ─► included hosts
                  (PAC or fixed)                                     └─► direct ───────────► everything else
```

### Local listener

One port, bound to `127.0.0.1` only, accepts three protocols, detected from the first bytes:

- **HTTP `CONNECT`** (HTTPS and other TLS traffic): a byte tunnel; TLS stays end-to-end.
- **Plain HTTP** (`GET http://…`): forwarded with `Connection: close`.
- **SOCKS5** inbound, for apps that only speak SOCKS.

For every connection the host is checked against the rules, then it's either tunnelled through the upstream proxy or connected directly.

### Upstream proxy

| Type | How it connects |
|---|---|
| HTTP | `CONNECT host:port` to the proxy, `Proxy-Authorization: Basic …` when auth is on |
| HTTPS | Same, but the connection to the proxy itself is TLS. **Insecure TLS** skips certificate checks for proxies with self-signed certificates. |
| SOCKS5 | SOCKS5 handshake, username/password auth (RFC 1929) when auth is on; the hostname is sent to the proxy, so DNS resolves there |

If a SOCKS slot is enabled, it's used for both HTTP and HTTPS traffic. Outgoing connections are made with `preferNoProxies`, so the app never loops back through the system proxy it set.

### Override methods

The method is chosen in **General → Override macOS Proxy**.

| Method | What macOS gets | What happens if the app crashes |
|---|---|---|
| **Auto-config (PAC)**, the default | `http://127.0.0.1:9090/proxy.pac`, served by the app: `PROXY 127.0.0.1:9090; DIRECT` for matching hosts | macOS can't load the PAC and connects directly. The Mac keeps internet; included hosts also go direct. |
| **Fixed proxy**, like Proxyman | Web and Secure Web proxy = `127.0.0.1:9090` | Web traffic goes to a dead port until the app is opened again. |

### Restoring the system proxy

Before overriding, the app saves the exact values of the 8 proxy keys it changes (HTTP, HTTPS, auto-config: enable, host, port, URL) for every enabled network service, read from SystemConfiguration, to `system-proxy-backup.json`. SOCKS, bypass domains and other settings are never touched.

On quit it writes back only the keys that differ, using `networksetup` (no admin password), reads the settings again to verify, and deletes the backup. This runs on:

- a normal quit, logout or shutdown;
- `SIGTERM`, `SIGINT`, `SIGHUP` (`kill`, Ctrl-C);
- the next launch, if the app was killed with `kill -9` or crashed (the backup file is still there).

Without an admin password macOS can't delete a field that didn't exist before. In that case the field stays, switched off, and the Logs tab lists it.

### Source layout

| File | Purpose |
|---|---|
| `ProxyOverride/Sources/ProxyOverride/ProxyEngine.swift` | Listener, protocol detection, routing rules, PAC serving |
| `Conn.swift` | async/await wrapper around `NWConnection`, two-way relay |
| `Settings.swift` | Settings model, JSON storage, PAC generation, Keychain |
| `SystemProxy.swift` | Snapshot, override and restore of the macOS proxy |
| `AppModel.swift` | App state, start/stop, crash recovery |
| `MenuPanel.swift`, `Views.swift` | Menu bar panel and Settings window (SwiftUI) |
| `ProxymanImport.swift` | Reads Proxyman's External Proxy settings (no credentials) |
| `main.swift` | App entry point, signal handlers, `--headless` mode |
| `ProxyOverride/build.sh` | Builds, signs and installs the `.app` |

## Troubleshooting

| Symptom | Cause |
|---|---|
| `407` in Logs | Upstream needs a username/password, or it's wrong. |
| `upstream refused CONNECT: … 502` | The upstream proxy itself can't reach that host (for example an IPv6-only proxy and an IPv4-only site). |
| Port 9090 already in use | Change **General → Local proxy → Port**, or quit the other app (Proxyman uses 9090 too). |
| Mac has no internet after a crash in Fixed mode | Open the app again and quit it, or turn off the Web proxies in System Settings → Network → Details → Proxies. |

Check a host's route from the terminal:

```bash
curl -x http://127.0.0.1:9090 -sI https://example.com    # goes through the app
scutil --proxy                                           # current macOS proxy settings
```

## Other files

- `proxy_override.py` is the original command-line version (Python 3, no dependencies). `config.example.json` is its config example: `python3 proxy_override.py -c config.json [--system]`.
- `/Applications/ProxyOverride.app/Contents/MacOS/ProxyOverride --headless --config settings.json` runs only the proxy engine in a terminal, without the menu bar app.
