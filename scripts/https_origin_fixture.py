#!/usr/bin/env python3
"""Serve generated media from two TLS origins for the dedicated iPhone tests.

All keys and certificates are generated into the required temporary directory.
Only the dedicated test Simulator receives the one-day synthetic trust anchor.
Stop with Ctrl-C; the fixture descriptor is removed on exit.
"""

import argparse
import base64
import hashlib
import json
import plistlib
import re
import signal
import shutil
import socket
import ssl
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def command(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL)


def certificates(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    ca = directory / "ca.conf"
    ca.write_text("""[req]
prompt = no
distinguished_name = dn
x509_extensions = ca_extensions
[dn]
CN = rustyView Synthetic Test CA
[ca_extensions]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
""")
    leaf = directory / "leaf.conf"
    leaf.write_text("""[req]
prompt = no
distinguished_name = dn
req_extensions = server_extensions
[dn]
CN = localhost
[server_extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
""")
    command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-config", str(ca), "-keyout", str(directory / "ca.key"), "-out", str(directory / "ca.crt"))
    command("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-config", str(leaf),
            "-keyout", str(directory / "server.key"), "-out", str(directory / "server.csr"))
    command("openssl", "x509", "-req", "-in", str(directory / "server.csr"), "-days", "1",
            "-CA", str(directory / "ca.crt"), "-CAkey", str(directory / "ca.key"), "-CAcreateserial",
            "-extfile", str(leaf), "-extensions", "server_extensions", "-out", str(directory / "server.crt"))
    for path in directory.glob("*.key"):
        path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "--json"))["devices"]
    device = next((device for runtime in devices.values() for device in runtime
                   if device["udid"] == args.simulator), None)
    if not device or device["name"] != "rustyView Test iPhone" or device["state"] != "Booted":
        parser.error("Use the booted, dedicated rustyView Test iPhone Simulator.")
    directory = args.directory.resolve()
    if not str(directory).startswith(("/tmp/", "/private/tmp/")):
        parser.error("Generated TLS material must be kept in a temporary directory.")
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    container = Path(command("xcrun", "simctl", "get_app_container", args.simulator, bundle_id, "data").decode().strip())
    descriptor = container / "Library/Caches/HTTPSOriginFixture.json"
    descriptor.parent.mkdir(parents=True, exist_ok=True)
    certificates(directory)
    command("xcrun", "simctl", "keychain", args.simulator, "add-root-cert", str(directory / "ca.crt"))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(directory / "server.crt", directory / "server.key")
    media = (args.repository / "rustyViewTests/Fixtures/synthetic-offline-valid.mp4").read_bytes()
    av_media = (args.repository / "rustyViewTests/Fixtures/synthetic-native-tracks.mp4").read_bytes()
    segments = [(args.repository / f"rustyViewUITests/Fixtures/synthetic-stall-{i}.ts").read_bytes() for i in range(3)]
    encrypted_segments = []
    for index in range(3):
        destination = directory / f"encrypted-{index}.ts"
        command("openssl", "enc", "-aes-128-cbc", "-K", bytes(range(16)).hex(), "-iv", "0" * 32,
                "-in", str(args.repository / f"rustyViewUITests/Fixtures/synthetic-stall-{index}.ts"), "-out", str(destination))
        encrypted_segments.append(destination.read_bytes())
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        parser.error("FFmpeg is required to generate the synthetic fMP4/map fixture.")
    fragmented = directory / "synthetic-fragmented.mp4"
    command(ffmpeg, "-v", "error", "-y", "-i", str(args.repository / "rustyViewTests/Fixtures/synthetic-native-tracks.mp4"),
            "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-movflags", "empty_moov+frag_keyframe+default_base_moof", str(fragmented))
    fragmented_data = fragmented.read_bytes()
    boundary = 0
    while boundary + 8 <= len(fragmented_data):
        size = int.from_bytes(fragmented_data[boundary:boundary + 4], "big")
        box = fragmented_data[boundary + 4:boundary + 8]
        if box == b"moof":
            break
        if size < 8:
            parser.error("Generated fMP4 has an invalid box boundary.")
        boundary += size
    if not 0 < boundary < len(fragmented_data):
        parser.error("Generated fMP4 has no media fragment.")
    fragment_init, fragment_body = fragmented_data[:boundary], fragmented_data[boundary:]
    padding_size = 32 * 1024 * 1024 - len(av_media)
    large_media = av_media + padding_size.to_bytes(4, "big") + b"free" + bytes(padding_size - 8)
    large_metadata = {"byteCount": len(large_media), "sha256": hashlib.sha256(large_media).hexdigest()}
    expected_auth = "Basic " + base64.b64encode(b"tls-viewer:synthetic-tls-secret").decode()
    second_auth = "Basic " + base64.b64encode(b"second-tls-viewer:second-synthetic-tls-secret").decode()
    observations = {}
    holds = {}
    event_phases = {}
    lock = threading.Lock()
    origins = {}

    def make_handler(role):
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass  # Never print URLs, authentication headers, or metadata.

            def increment(self, case, key, amount=1):
                with lock:
                    counts = observations.setdefault(case, {})
                    counts[key] = counts.get(key, 0) + amount

            def respond(self, status, body=b"", headers=None):
                self.send_response(status)
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                if body and self.command != "HEAD":
                    try:
                        self.wfile.write(body)
                    except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                        self.close_connection = True

            def ranged(self, case, body, content_type, slow=False):
                headers = {"Content-Type": content_type, "Accept-Ranges": "bytes"}
                value = self.headers.get("Range")
                status = 200
                if value:
                    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
                    if not match or not any(match.groups()):
                        self.respond(416, headers={"Content-Range": f"bytes */{len(body)}"})
                        return
                    left, right = match.groups()
                    start = int(left) if left else max(0, len(body) - int(right))
                    end = min(int(right) if left and right else len(body) - 1, len(body) - 1)
                    if start > end or start >= len(body):
                        self.respond(416, headers={"Content-Range": f"bytes */{len(body)}"})
                        return
                    headers["Content-Range"] = f"bytes {start}-{end}/{len(body)}"
                    body = body[start:end + 1]
                    status = 206
                    self.increment(case, role + "RangeRequests")
                if slow:
                    self.send_response(status)
                    for key, value in headers.items():
                        self.send_header(key, value)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Connection", "keep-alive")
                    self.end_headers()
                    if self.command != "HEAD":
                        try:
                            for offset in range(0, len(body), 65536):
                                chunk = body[offset:offset + 65536]
                                self.wfile.write(chunk)
                                self.wfile.flush()
                                self.increment(case, role + "MediaResponseBytes", len(chunk))
                                time.sleep(0.003)
                        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                            self.increment(case, role + "LargeCancelled")
                            self.close_connection = True
                    return
                self.respond(status, body, headers)
                if not self.close_connection:
                    self.increment(case, role + "MediaResponseBytes", len(body))

            def av(self, parsed, case):
                query = parse_qs(parsed.query)
                path = parsed.path
                authorization = self.headers.get("Authorization")
                key = role + "Path" + path.removeprefix("/av/").replace("/", "_").replace(".", "_").replace("-", "_")
                self.increment(case, key)
                if query.get("request") == ["37"] and query.get("session") == ["41"]:
                    self.increment(case, role + "Generation37Session41Requests")
                if authorization == expected_auth:
                    self.increment(case, key + "FirstCredentials")
                elif authorization == second_auth:
                    self.increment(case, key + "SecondCredentials")

                if path == "/av/held.mp4":
                    with lock:
                        gate = holds.setdefault(case, threading.Event())
                    self.increment(case, role + "HeldRequests")
                    old_timeout = self.connection.gettimeout()
                    self.connection.settimeout(0.1)
                    deadline = time.monotonic() + 30
                    try:
                        while not gate.is_set() and time.monotonic() < deadline:
                            try:
                                if not self.connection.recv(1):
                                    self.increment(case, role + "HeldClosed")
                                    self.close_connection = True
                                    return
                            except (socket.timeout, ssl.SSLWantReadError):
                                continue
                            except (ConnectionResetError, ssl.SSLError):
                                self.increment(case, role + "HeldClosed")
                                self.close_connection = True
                                return
                    finally:
                        self.connection.settimeout(old_timeout)

                if role == "trusted" and authorization not in (expected_auth, second_auth):
                    self.respond(401, headers={"WWW-Authenticate": 'Basic realm="synthetic-av-origin"'})
                    return
                if path == "/av/redirect.mp4":
                    self.respond(302, headers={"Location": origins["hostile"] + "/av/media.mp4?case=" + case})
                    return
                if path == "/av/same-redirect.mp4":
                    hop = int(query.get("hop", ["0"])[0])
                    target = "/av/media.mp4" if hop >= 2 else "/av/same-redirect.mp4"
                    self.respond(302, headers={"Location": origins[role] + target + f"?case={case}&hop={hop + 1}"})
                    return
                if path == "/av/loop.mp4":
                    self.respond(302, headers={"Location": origins[role] + "/av/loop.mp4?case=" + case})
                    return
                if path == "/av/segment-redirect.ts":
                    self.respond(302, headers={"Location": origins["hostile"] + "/av/segment-0.ts?case=" + case})
                    return
                if path in ("/av/disguised.mp4", "/av/disguised-segment.ts"):
                    body = ("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n"
                            "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2.000000,\n"
                            + origins["hostile"] + "/av/segment-0.ts?case=" + case + "\n#EXT-X-ENDLIST\n")
                    self.respond(200, body.encode(), {"Content-Type": "video/mp4" if path.endswith(".mp4") else "video/mp2t"})
                    return
                if path in ("/av/media.mp4", "/av/held.mp4"):
                    self.ranged(case, av_media, "video/mp4")
                    return
                if path == "/av/large.mp4":
                    self.ranged(case, large_media, "video/mp4", slow=True)
                    return
                if path == "/av/init.mp4":
                    self.ranged(case, fragment_init, "video/mp4")
                    return
                if path == "/av/fragment.m4s":
                    self.ranged(case, fragment_body, "video/mp4")
                    return
                encrypted = re.fullmatch(r"/av/encrypted-([0-2])\.ts", path)
                if encrypted:
                    self.ranged(case, encrypted_segments[int(encrypted[1])], "video/mp2t")
                    return
                match = re.fullmatch(r"/av/segment-([0-2])\.ts", path)
                if match:
                    self.ranged(case, segments[int(match[1])], "video/mp2t")
                    return
                if path in ("/av/master.m3u8", "/av/master-foreign.m3u8", "/av/media-attribute-foreign.m3u8"):
                    target_role = "hostile" if path.endswith("master-foreign.m3u8") else role
                    body = "#EXTM3U\n#EXT-X-VERSION:3\n"
                    if path.endswith("media-attribute-foreign.m3u8"):
                        body += '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="Synthetic Audio",DEFAULT=YES,AUTOSELECT=YES,URI="' + origins["hostile"] + "/av/same.m3u8?case=" + case + '"\n'
                    body += '#EXT-X-STREAM-INF:BANDWIDTH=1000000' + (',AUDIO="sound"' if path.endswith("media-attribute-foreign.m3u8") else '') + "\n"
                    body += origins[target_role] + "/av/same.m3u8?case=" + case + "\n"
                    self.respond(200, body.encode(), {"Content-Type": "application/vnd.apple.mpegurl"})
                    return
                if path.endswith(".m3u8"):
                    body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
                    if path == "/av/long-event.m3u8":
                        with lock:
                            advanced = event_phases.get(case, False)
                        body = body.replace("#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-PLAYLIST-TYPE:EVENT")
                        for index in range(7200 if advanced else 6000):
                            body += f"#EXTINF:2.000000,\n{origins[role]}/av/segment-{index % 3}.ts?case={case}&fragment={index}&request=37&session=41\n"
                        self.respond(200, body.encode(), {"Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store"})
                        return
                    if path == "/av/event.m3u8":
                        with lock:
                            advanced = event_phases.get(case, False)
                        body = body.replace("#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-PLAYLIST-TYPE:EVENT")
                        # A full initial startup window with contiguous video
                        # timestamps: 1.483333, 3.483333 and 5.483333 seconds.
                        for index in range(3):
                            body += f"#EXTINF:2.000000,\n{origins[role]}/av/segment-{index}.ts?case={case}\n"
                        if advanced:
                            body += "#EXTINF:2.000000,\n" + origins["hostile"] + "/av/segment-0.ts?case=" + case + "\n"
                        self.increment(case, role + "EventResponses")
                        self.respond(200, body.encode(), {"Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store"})
                        return
                    if path == "/av/unknown-uri.m3u8":
                        body += '#EXT-X-CONTENT-STEERING:SERVER-URI="' + origins["hostile"] + "/av/steering.json?case=" + case + '"\n'
                    if path == "/av/duplicate-uri.m3u8":
                        body += '#EXT-X-MAP:URI="' + origins[role] + "/av/init.mp4?case=" + case + '",URI="' + origins["hostile"] + "/av/init.mp4?case=" + case + '"\n'
                    if path == "/av/malformed-uri.m3u8":
                        body += '#EXT-X-KEY:METHOD=AES-128,URI="' + origins["hostile"] + "/av/key.bin?case=" + case + "\n"
                    if path in ("/av/key-foreign.m3u8", "/av/encrypted.m3u8"):
                        key_role = "hostile" if path == "/av/key-foreign.m3u8" else role
                        body += '#EXT-X-KEY:METHOD=AES-128,URI="' + origins[key_role] + "/av/key.bin?case=" + case + '",IV=0x00000000000000000000000000000000\n'
                    if path in ("/av/map-foreign.m3u8", "/av/fmp4.m3u8"):
                        map_role = "hostile" if path == "/av/map-foreign.m3u8" else role
                        body = body.replace("#EXT-X-VERSION:3", "#EXT-X-VERSION:7").replace("#EXT-X-TARGETDURATION:2", "#EXT-X-TARGETDURATION:6")
                        body += '#EXT-X-MAP:URI="' + origins[map_role] + "/av/init.mp4?case=" + case + '"\n'
                        body += "#EXTINF:6.000000,\n" + origins[role] + "/av/fragment.m4s?case=" + case + "\n#EXT-X-ENDLIST\n"
                        self.respond(200, body.encode(), {"Content-Type": "application/vnd.apple.mpegurl"})
                        return
                    for index in range(3):
                        target_role = "hostile" if path == "/av/media-foreign.m3u8" else role
                        segment_path = "/av/segment-redirect.ts" if path == "/av/segment-redirect.m3u8" else f"/av/segment-{index}.ts"
                        if path == "/av/disguised-segment.m3u8":
                            segment_path = "/av/disguised-segment.ts"
                        if path in ("/av/key-foreign.m3u8", "/av/encrypted.m3u8"):
                            segment_path = f"/av/encrypted-{index}.ts"
                        body += "#EXTINF:2.000000,\n" + origins[target_role] + segment_path + "?case=" + case + "\n"
                    body += "#EXT-X-ENDLIST\n"
                    self.respond(200, body.encode(), {"Content-Type": "application/vnd.apple.mpegurl"})
                    return
                if path == "/av/key.bin":
                    self.respond(200, bytes(range(16)), {"Content-Type": "application/octet-stream"})
                    return
                self.respond(404)

            def do_GET(self):
                parsed = urlparse(self.path)
                case = parse_qs(parsed.query).get("case", [""])[0]
                if not re.fullmatch(r"[0-9a-fA-F-]{36}", case):
                    self.respond(400)
                    return
                if parsed.path == "/observations" and role == "trusted":
                    with lock:
                        counts = observations.get(case, {})
                        body = json.dumps(counts).encode()
                    self.respond(200, body, {"Content-Type": "application/json"})
                    return
                if parsed.path == "/av/release" and role == "trusted":
                    with lock:
                        gate = holds.setdefault(case, threading.Event())
                    gate.set()
                    self.respond(200, b"{}", {"Content-Type": "application/json"})
                    return
                if parsed.path == "/av/advance" and role == "trusted":
                    with lock:
                        event_phases[case] = True
                    self.respond(200, b"{}", {"Content-Type": "application/json"})
                    return
                if parsed.path == "/av/large-metadata" and role == "trusted":
                    self.respond(200, json.dumps(large_metadata).encode(), {"Content-Type": "application/json"})
                    return
                with lock:
                    counts = observations.setdefault(case, {})
                    counts[role + "Requests"] = counts.get(role + "Requests", 0) + 1
                    if self.headers.get("Authorization"):
                        counts[role + "Credentials"] = counts.get(role + "Credentials", 0) + 1
                    if self.headers.get("Authorization") == expected_auth:
                        counts[role + "FirstCredentials"] = counts.get(role + "FirstCredentials", 0) + 1
                    elif self.headers.get("Authorization") == second_auth:
                        counts[role + "SecondCredentials"] = counts.get(role + "SecondCredentials", 0) + 1
                if parsed.path.startswith("/av/"):
                    self.av(parsed, case)
                    return
                if role == "hostile":
                    # The contract rejects the request itself, even if the OS
                    # strips the initial Basic header before following it.
                    self.respond(200, media, {"Content-Type": "video/mp4"})
                elif self.headers.get("Authorization") != expected_auth:
                    self.respond(401, headers={"WWW-Authenticate": 'Basic realm="synthetic-origin"'})
                elif parsed.path == "/redirect":
                    self.respond(302, headers={"Location": origins["hostile"] + "/received?case=" + case})
                elif parsed.path == "/media":
                    self.respond(200, media, {"Content-Type": "video/mp4"})
                else:
                    self.respond(404)

            def do_HEAD(self):
                self.do_GET()
        return Handler

    servers = []
    for role in ("trusted", "hostile"):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(role))
        server.daemon_threads = True
        server.socket = context.wrap_socket(server.socket, server_side=True)
        origins[role] = "https://127.0.0.1:" + str(server.server_port)
        servers.append(server)
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    descriptor.write_text(json.dumps(origins))
    print("Synthetic HTTPS origins ready for the dedicated iPhone tests.", flush=True)
    stopped = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    try:
        stopped.wait()
    finally:
        with lock:
            for gate in holds.values():
                gate.set()
        descriptor.unlink(missing_ok=True)
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
