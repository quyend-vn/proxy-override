#!/usr/bin/env python3
"""
proxy_override.py - Minimal replacement for Proxyman's "Override macOS Proxy"
+ "External Proxy" features. No third-party dependencies.

  * Local listener (default 127.0.0.1:9090) accepting HTTP proxy requests,
    HTTPS CONNECT tunnels and SOCKS5 - all on the same port.
  * Each connection is routed either DIRECT or through an upstream proxy
    (http://, https:// (TLS to the proxy), socks5://), with optional auth.
  * Include list / bypass list with wildcards (same semantics as Proxyman):
    if the include list is non-empty only matching hosts use the upstream.
  * --system: points the macOS system HTTP/HTTPS proxy at the local listener
    for every enabled network service, and restores the previous values on exit
    (or with --restore after a crash).

No MITM / TLS decryption is done: HTTPS is tunnelled as-is.
"""

import argparse
import asyncio
import base64
import fnmatch
import ipaddress
import json
import os
import signal
import socket
import ssl
import struct
import subprocess
import sys
from urllib.parse import urlsplit, unquote

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "config.json")
STATE_FILE = os.path.join(HERE, ".system_proxy_backup.json")
PROXYMAN_DIR = os.path.expanduser("~/Library/Application Support/com.proxyman.NSProxy")

VERBOSE = False


def log(*a):
    print(*a, flush=True)


def vlog(*a):
    if VERBOSE:
        print(*a, flush=True)


# --------------------------------------------------------------------------- config

class Upstream:
    def __init__(self, url, insecure=False):
        u = urlsplit(url)
        self.scheme = u.scheme.lower()
        if self.scheme in ("socks5h", "socks"):
            self.scheme = "socks5"
        if self.scheme not in ("http", "https", "socks5"):
            raise ValueError(f"unsupported upstream scheme: {url}")
        self.host = u.hostname
        self.port = u.port or {"http": 8080, "https": 443, "socks5": 1080}[self.scheme]
        self.user = unquote(u.username) if u.username else None
        self.password = unquote(u.password) if u.password else ""
        self.insecure = insecure

    def proxy_auth_header(self):
        if not self.user:
            return b""
        token = base64.b64encode(f"{self.user}:{self.password}".encode()).decode()
        return f"Proxy-Authorization: Basic {token}\r\n".encode()

    def __str__(self):
        return f"{self.scheme}://{self.host}:{self.port}"


class Config:
    def __init__(self, d):
        self.listen_host = d.get("listen_host", "127.0.0.1")
        self.listen_port = int(d.get("listen_port", 9090))
        insecure = bool(d.get("insecure_tls_to_proxy", False))
        ups = d.get("upstream", {})
        if isinstance(ups, str):
            ups = {"all": ups}
        # "http" is used for plain-HTTP requests, "https" for CONNECT tunnels and
        # SOCKS clients; "all" is the fallback for both (mirrors Proxyman's
        # separate HTTP / HTTPS / SOCKS external proxy entries).
        mk = lambda k: Upstream(ups[k], insecure) if ups.get(k) else None
        fallback = mk("all")
        self.up_http = mk("http") or fallback
        self.up_https = mk("https") or fallback
        self.include = [p.strip().lower() for p in d.get("include", []) if p.strip()]
        self.bypass = [p.strip().lower() for p in d.get("bypass", []) if p.strip()]
        self.bypass_localhost = bool(d.get("bypass_localhost", True))

    def route(self, host, plain_http):
        """Return the Upstream to use for host, or None for DIRECT."""
        up = self.up_http if plain_http else self.up_https
        if up is None:
            return None
        h = host.lower().strip("[]")
        if self.bypass_localhost and is_local(h):
            return None
        if any(match(p, h) for p in self.bypass):
            return None
        if self.include and not any(match(p, h) for p in self.include):
            return None
        return up


def match(pattern, host):
    if fnmatch.fnmatchcase(host, pattern):
        return True
    # "*.example.com" also matches "example.com"
    return pattern.startswith("*.") and host == pattern[2:]


def is_local(h):
    if h == "localhost" or h.endswith(".localhost") or h.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_loopback or ip.is_private or ip.is_link_local
    except ValueError:
        return False


# --------------------------------------------------------------------------- upstream dialing

async def read_http_head(reader, limit=65536):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(4096)
        if not chunk:
            raise ConnectionError("connection closed while reading headers")
        data += chunk
        if len(data) > limit:
            raise ConnectionError("header too large")
    head, rest = data.split(b"\r\n\r\n", 1)
    return head, rest


async def open_to_proxy(up):
    if up.scheme == "https":
        ctx = ssl.create_default_context()
        if up.insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        return await asyncio.open_connection(up.host, up.port, ssl=ctx, server_hostname=up.host)
    return await asyncio.open_connection(up.host, up.port)


async def open_tunnel(host, port, up):
    """TCP stream to host:port, direct or through the upstream proxy."""
    if up is None:
        return await asyncio.open_connection(host, port)
    r, w = await open_to_proxy(up)
    try:
        if up.scheme in ("http", "https"):
            hp = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
            w.write(f"CONNECT {hp} HTTP/1.1\r\nHost: {hp}\r\n".encode()
                    + up.proxy_auth_header() + b"\r\n")
            await w.drain()
            head, rest = await read_http_head(r)
            status = head.split(b"\r\n", 1)[0].decode(errors="replace")
            if status.split(" ")[1:2] != ["200"]:
                raise ConnectionError(f"upstream refused CONNECT: {status}")
            if rest:  # bytes the proxy sent right after its 200 belong to the tunnel
                r.feed_data(rest)
        else:
            await socks5_handshake(r, w, host, port, up)
        return r, w
    except Exception:
        w.close()
        raise


async def socks5_handshake(r, w, host, port, up):
    methods = b"\x00\x02" if up.user else b"\x00"
    w.write(b"\x05" + bytes([len(methods)]) + methods)
    await w.drain()
    ver, method = await r.readexactly(2)
    if method == 0x02:
        u, p = up.user.encode(), up.password.encode()
        w.write(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        await w.drain()
        if (await r.readexactly(2))[1] != 0:
            raise ConnectionError("SOCKS5 authentication failed")
    elif method != 0x00:
        raise ConnectionError("SOCKS5 proxy rejected auth methods")
    try:
        addr = b"\x01" + socket.inet_aton(host)
    except OSError:
        try:
            addr = b"\x04" + socket.inet_pton(socket.AF_INET6, host)
        except OSError:
            hb = host.encode()  # remote DNS (socks5h behaviour)
            addr = b"\x03" + bytes([len(hb)]) + hb
    w.write(b"\x05\x01\x00" + addr + struct.pack(">H", port))
    await w.drain()
    rep = await r.readexactly(4)
    if rep[1] != 0:
        raise ConnectionError(f"SOCKS5 connect failed, code {rep[1]}")
    atyp = rep[3]
    n = 4 if atyp == 1 else 16 if atyp == 4 else (await r.readexactly(1))[0]
    await r.readexactly(n + 2)


# --------------------------------------------------------------------------- piping

async def pipe(src, dst):
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except (ConnectionError, OSError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            if dst.can_write_eof():
                dst.write_eof()
            else:
                dst.close()
        except (OSError, RuntimeError):
            pass


async def relay(cr, cw, ur, uw):
    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
    for w in (cw, uw):
        try:
            w.close()
        except Exception:
            pass


# --------------------------------------------------------------------------- inbound

class Server:
    def __init__(self, cfg):
        self.cfg = cfg

    async def handle(self, cr, cw):
        try:
            first = await cr.readexactly(1)
            if first == b"\x05":
                await self.handle_socks(cr, cw)
            else:
                await self.handle_http(first, cr, cw)
        except (ConnectionError, OSError, asyncio.IncompleteReadError, ValueError) as e:
            vlog(f"  ! {e}")
            try:
                cw.close()
            except Exception:
                pass

    def describe(self, kind, host, port, up):
        vlog(f"{kind:7} {host}:{port} -> {up or 'DIRECT'}")

    async def handle_socks(self, cr, cw):
        n = (await cr.readexactly(1))[0]
        await cr.readexactly(n)
        cw.write(b"\x05\x00")
        await cw.drain()
        ver, cmd, _, atyp = await cr.readexactly(4)
        if atyp == 1:
            host = socket.inet_ntoa(await cr.readexactly(4))
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, await cr.readexactly(16))
        else:
            host = (await cr.readexactly((await cr.readexactly(1))[0])).decode()
        port = struct.unpack(">H", await cr.readexactly(2))[0]
        if cmd != 1:
            cw.write(b"\x05\x07\x00\x01" + b"\x00" * 6)
            cw.close()
            return
        up = self.cfg.route(host, plain_http=False)
        self.describe("SOCKS", host, port, up)
        try:
            ur, uw = await open_tunnel(host, port, up)
        except Exception as e:
            vlog(f"  ! {host}:{port}: {e}")
            cw.write(b"\x05\x05\x00\x01" + b"\x00" * 6)
            cw.close()
            return
        cw.write(b"\x05\x00\x00\x01" + b"\x00" * 6)
        await cw.drain()
        await relay(cr, cw, ur, uw)

    async def handle_http(self, first, cr, cw):
        head, rest = await read_http_head(cr)
        head = first + head
        lines = head.split(b"\r\n")
        method, target, version = lines[0].decode("latin-1").split(" ", 2)

        if method.upper() == "CONNECT":
            host, port = split_hostport(target, 443)
            up = self.cfg.route(host, plain_http=False)
            self.describe("CONNECT", host, port, up)
            try:
                ur, uw = await open_tunnel(host, port, up)
            except Exception as e:
                vlog(f"  ! {host}:{port}: {e}")
                cw.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                cw.close()
                return
            cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await cw.drain()
            if rest:
                uw.write(rest)
            await relay(cr, cw, ur, uw)
            return

        u = urlsplit(target)
        if u.scheme.lower() != "http" or not u.hostname:
            cw.write(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
                     b"proxy_override: absolute http:// URL expected\n")
            cw.close()
            return
        host, port = u.hostname, u.port or 80
        up = self.cfg.route(host, plain_http=True)
        self.describe(method, host, port, up)

        # One request per connection keeps per-request routing correct.
        headers = [l for l in lines[1:]
                   if not l.lower().startswith((b"proxy-connection:", b"connection:",
                                                b"keep-alive:", b"proxy-authorization:"))]
        headers.append(b"Connection: close")
        if up is not None and up.scheme in ("http", "https"):
            req_target = target
            ur, uw = await open_to_proxy(up)
            auth = up.proxy_auth_header()
            if auth:
                headers.append(auth.rstrip(b"\r\n"))
        else:
            req_target = (u.path or "/") + (f"?{u.query}" if u.query else "")
            try:
                ur, uw = await open_tunnel(host, port, up)
            except Exception as e:
                vlog(f"  ! {host}:{port}: {e}")
                cw.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                cw.close()
                return
        uw.write(f"{method} {req_target} {version}\r\n".encode("latin-1")
                 + b"\r\n".join(headers) + b"\r\n\r\n" + rest)
        await uw.drain()
        await relay(cr, cw, ur, uw)


def split_hostport(s, default_port):
    if s.startswith("["):
        host, _, p = s[1:].partition("]")
        p = p.lstrip(":")
    else:
        host, _, p = s.rpartition(":") if ":" in s else (s, "", "")
    return host, int(p) if p else default_port


# --------------------------------------------------------------------------- macOS system proxy

def ns(*args):
    return subprocess.run(["networksetup", *args], capture_output=True, text=True)


def network_services():
    out = ns("-listallnetworkservices").stdout.splitlines()[1:]
    return [s for s in out if s and not s.startswith("*")]


def get_proxy(kind, svc):
    info = {}
    for line in ns(f"-get{kind}", svc).stdout.splitlines():
        k, _, v = line.partition(":")
        info[k.strip()] = v.strip()
    return {"enabled": info.get("Enabled") == "Yes",
            "server": info.get("Server", ""), "port": info.get("Port", "0")}


def system_proxy_on(host, port):
    if not os.path.exists(STATE_FILE):
        backup = {svc: {k: get_proxy(k, svc) for k in ("webproxy", "securewebproxy")}
                  for svc in network_services()}
        with open(STATE_FILE, "w") as f:
            json.dump(backup, f, indent=2)
    for svc in network_services():
        for k in ("webproxy", "securewebproxy"):
            r = ns(f"-set{k}", svc, host, str(port))
            if r.returncode != 0:
                log(f"networksetup failed for {svc}: {r.stderr.strip() or r.stdout.strip()}")
            ns(f"-set{k}state", svc, "on")
    log(f"macOS system HTTP/HTTPS proxy -> {host}:{port} ({', '.join(network_services())})")


def system_proxy_restore():
    if not os.path.exists(STATE_FILE):
        log("no saved system proxy state; nothing to restore")
        return
    with open(STATE_FILE) as f:
        backup = json.load(f)
    for svc, kinds in backup.items():
        for k, v in kinds.items():
            if v["server"]:
                ns(f"-set{k}", svc, v["server"], v["port"])
            ns(f"-set{k}state", svc, "on" if v["enabled"] else "off")
    os.remove(STATE_FILE)
    log("macOS system proxy restored")


# --------------------------------------------------------------------------- Proxyman import

def import_proxyman(path):
    """Build a config skeleton from Proxyman's saved External Proxy settings.
    Proxyman stores the credentials encrypted, so they are left as placeholders."""
    with open(os.path.join(PROXYMAN_DIR, "user-data", "ExternalProxySetting")) as f:
        entries = json.load(f)
    defaults = lambda key: subprocess.run(["defaults", "read", "com.proxyman.NSProxy", key],
                                          capture_output=True, text=True).stdout.strip()
    upstream = {}
    for e in entries:
        if not e.get("isEnabled") or e.get("kind") == "pac":
            continue
        scheme = {"http": "http", "https": "http", "socks": "socks5"}[e["kind"]]
        auth = "USER:PASS@" if e.get("isRequireAuth") else ""
        url = f"{scheme}://{auth}{e['host']}:{e['port']}"
        if e["kind"] == "socks":
            upstream["all"] = url
        else:  # Proxyman's "HTTPS" entry is the proxy used for HTTPS traffic (CONNECT)
            upstream[e["kind"]] = url
    split = lambda s: [x for x in s.split(",") if x]
    cfg = {
        "listen_host": "127.0.0.1",
        "listen_port": 9090,
        "upstream": upstream,
        "include": split(defaults("ExternalProxy-IncludeList")),
        "bypass": split(defaults("ByPassProxy-externalProxy")),
        "bypass_localhost": defaults("isBypassLocalhostExternalProxy") != "0",
        "insecure_tls_to_proxy": False,
    }
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(path, 0o600)
    log(f"wrote {path} - replace USER:PASS with your proxy credentials")


# --------------------------------------------------------------------------- main

async def amain(cfg, system):
    server = await asyncio.start_server(Server(cfg).handle, cfg.listen_host, cfg.listen_port)
    log(f"listening on {cfg.listen_host}:{cfg.listen_port} (HTTP / HTTPS CONNECT / SOCKS5)")
    log(f"  upstream http : {cfg.up_http or 'DIRECT'}")
    log(f"  upstream https: {cfg.up_https or 'DIRECT'}")
    log(f"  include: {', '.join(cfg.include) or '(all hosts)'}")
    if cfg.bypass:
        log(f"  bypass : {', '.join(cfg.bypass)}")
    if system:
        system_proxy_on("127.0.0.1" if cfg.listen_host in ("0.0.0.0", "::") else cfg.listen_host,
                        cfg.listen_port)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()
    for t in asyncio.all_tasks() - {asyncio.current_task()}:
        t.cancel()
    if system:
        system_proxy_restore()


def main():
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", default=DEFAULT_CONFIG)
    ap.add_argument("--system", action="store_true", help="override macOS system proxy while running")
    ap.add_argument("--restore", action="store_true", help="restore macOS system proxy and exit")
    ap.add_argument("--import-proxyman", action="store_true", help="create config from Proxyman settings and exit")
    ap.add_argument("-v", "--verbose", action="store_true", help="log every connection and its route")
    a = ap.parse_args()
    VERBOSE = a.verbose
    if a.restore:
        return system_proxy_restore()
    if a.import_proxyman:
        return import_proxyman(a.config)
    if not os.path.exists(a.config):
        sys.exit(f"config not found: {a.config} (see config.example.json or use --import-proxyman)")
    with open(a.config) as f:
        cfg = Config(json.load(f))
    asyncio.run(amain(cfg, a.system))


if __name__ == "__main__":
    main()
