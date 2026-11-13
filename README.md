# Proxy Override

A small macOS menu bar app that does two things from Proxyman, with nothing else:

- **External proxy**: send selected hosts through an upstream HTTP, HTTPS (TLS to the proxy) or SOCKS5 proxy, with optional authentication, an include list and a bypass list.
- **Override macOS Proxy**: point the system proxy at the app. Quitting the app puts the previous settings back exactly.

There's no TLS interception and no certificate to install.

## Install on another Mac

Requires macOS 15 or later on Apple silicon.

### Option A: build from source (recommended)

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo> proxyman
cd proxyman/ProxyOverride
./build.sh --install
open /Applications/ProxyOverride.app
```

Building locally means macOS doesn't quarantine the app, so it opens without a Gatekeeper warning.

### Option B: copy the built app

On the build machine:

```bash
cd ProxyOverride && ./build.sh
ditto -c -k --keepParent build/ProxyOverride.app ../dist/ProxyOverride.zip
```

Copy `dist/ProxyOverride.zip` to the other Mac, then:

```bash
unzip ProxyOverride.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/ProxyOverride.app
open /Applications/ProxyOverride.app
```

The app is ad-hoc signed, not notarized. That's why you need the `xattr` step, or System Settings → Privacy & Security → "Open Anyway".

### First run

1. Click the menu bar icon, then **Settings…**.
2. In **External Proxy**, enter the proxy host, port, username and password. Passwords are stored in the Keychain on each Mac. If Proxyman is installed, **General → Import from Proxyman** fills in hosts and lists, but not credentials.
3. In **Rules**, set the include and bypass lists.
4. Turn on **Override macOS Proxy**.

Settings are stored in `~/Library/Application Support/ProxyOverride/settings.json`. To move them to another Mac, copy that file, then enter the passwords again.

## Override methods

| Method | What happens if the app crashes |
|---|---|
| **Auto-config (PAC)**, the default | macOS can't load the PAC and connects directly. The Mac keeps internet; included hosts also go direct. |
| **Fixed proxy**, like Proxyman | Web traffic goes to a dead port until the app is opened again. |

When it quits, the app restores the exact proxy values it saved before overriding: normal quit, `kill`, logout, or on the next launch after a crash. Without an admin password macOS can't delete a field that didn't exist before. In that case the field stays switched off, and the app's Logs tab lists it.

## Other files

- `proxy_override.py` is the original command-line version (Python 3, no dependencies). `config.example.json` is its config example.
- `ProxyOverride --headless --config settings.json` runs only the proxy engine in a terminal.
