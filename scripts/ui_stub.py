#!/usr/bin/env python3
"""Synthetic rustyDLNA HTTP surface for simulator and UI verification."""

from __future__ import annotations

import argparse
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


USER = "viewer"
PASSWORD = "test-only-password"
AUTHORIZATION = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()

TITLES = [
    "The Clockwork Orchard",
    "Lanterns Beyond Europa",
    "A Map of Quiet Stars",
    "Midnight at Copper Harbor",
    "The Paper Astronaut",
    "Echoes of the Glass Sea",
    "Seven Days in Ember City",
    "The Last Library Train",
]


def media_item(index: int) -> dict:
    media_id = str(42001 + index)
    title = TITLES[index]
    return {
        "entry_type": "media",
        "id": media_id,
        "title": title,
        "file_name": f"synthetic-{index + 1}.mkv",
        "kind": "video",
        "mime": "video/x-matroska",
        "ext": "mkv",
        "duration": f"1:{32 + index:02d}:08",
        "duration_seconds": 5528 + index * 137,
        "resolution": "3840x2160" if index % 3 == 0 else "1920x1080",
        "width": 3840 if index % 3 == 0 else 1920,
        "height": 2160 if index % 3 == 0 else 1080,
        "about": "An entirely invented story used to verify the app interface.",
        "plot": "Synthetic plot text with no relationship to any real production library.",
        "genre": "Science Fiction" if index % 2 == 0 else "Adventure",
        "size_bytes": 8_200_000_000 + index * 100_000_000,
        "container": "matroska",
        "video_codec": "hevc" if index % 2 == 0 else "h264",
        "video_profile": "Main 10" if index % 2 == 0 else "High",
        "bit_depth": 10 if index % 2 == 0 else 8,
        "frame_rate": "24000/1001",
        "video_repair_required": False,
        "audio_codec": "dts,aac",
        "audio_layout": "5.1",
        "codec_string": "hvc1.2.4.L153.B0,mp4a.40.2",
        "hdr": "hdr10" if index % 2 == 0 else "sdr",
        "audio_tracks": [
            {
                "index": 0,
                "codec": "aac",
                "content_type": "audio/mp4; codecs=\"mp4a.40.2\"",
                "channels": 2,
                "language": "fra",
                "title": "French dub",
                "default": False,
            },
            {
                "index": 1,
                "codec": "dts",
                "content_type": None,
                "channels": 6,
                "language": "eng",
                "title": "Original English",
                "default": True,
            },
        ],
        "default_audio_index": 1,
        "captions": [
            {
                "index": 0,
                "label": "English",
                "language": "eng",
                "default": False,
                "source_format": "srt",
                "browser_supported": True,
                "url": f"/Captions/{media_id}/0.vtt",
            }
        ],
        "chapters": [
            {"index": 0, "title": "Lantern Engine Ignition", "start_seconds": 0, "end_seconds": 1800},
            {"index": 1, "title": "Glasswater Transit", "start_seconds": 1800, "end_seconds": 3600},
            {"index": 2, "title": "Copper Harbor Docking", "start_seconds": 3600, "end_seconds": 5528 + index * 137},
        ],
        "art_url": None,
        "download_url": f"/web/download/{media_id}",
        "source_url": f"/web/media/{media_id}.mp4?mode=direct",
        "fallback_url": f"/web/media/{media_id}.mp4",
        "transcode_likely": True,
    }


CAPABILITIES = {
    "transcoding": True,
    "captions": True,
    "quality_profiles": [
        {
            "id": "auto",
            "label": "Auto · Best for this connection",
            "max_width": 3840,
            "max_height": 2160,
            "expected_bandwidth_kbps": 12000,
            "automatic_fallback": False,
        },
        {
            "id": "full_hd",
            "label": "1080p · 8 Mbps",
            "max_width": 1920,
            "max_height": 1080,
            "expected_bandwidth_kbps": 8448,
            "automatic_fallback": False,
        },
        {
            "id": "data_saver",
            "label": "720p · Save data",
            "max_width": 1280,
            "max_height": 720,
            "expected_bandwidth_kbps": 3384,
            "automatic_fallback": True,
        },
    ],
}


class Handler(BaseHTTPRequestHandler):
    server_version = "rustyViewSynthetic/1"

    def do_GET(self) -> None:
        if self.headers.get("Authorization") != AUTHORIZATION:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="synthetic"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        parsed = urlparse(self.path)
        if parsed.path == "/api/web/library":
            entries = [media_item(index) for index in range(len(TITLES))]
            self.send_json(
                {
                    "schema_version": 2,
                    "generation": 1,
                    "server_name": "Synthetic Media Server",
                    "root_folder_id": "0",
                    "capabilities": CAPABILITIES,
                    "library_state": "ready",
                    "view": "library",
                    "folder": None,
                    "breadcrumbs": [],
                    "offset": 0,
                    "limit": 60,
                    "total": len(entries),
                    "has_more": False,
                    "query": "",
                    "sort": "title",
                    "entries": entries,
                }
            )
            return
        if parsed.path.startswith("/api/web/item/"):
            try:
                index = int(parsed.path.rsplit("/", 1)[1]) - 42001
                item = media_item(index)
            except (ValueError, IndexError):
                self.send_json(
                    {"schema_version": 2, "error": {"code": "media_missing", "message": "Synthetic title is missing.", "recoverable": True, "action": "return_to_library"}},
                    status=404,
                )
                return
            item.pop("entry_type", None)
            self.send_json(
                {
                    "schema_version": 2,
                    "id": item["id"],
                    "item": item,
                    "audio_tracks": item["audio_tracks"],
                    "chapters": item["chapters"],
                }
            )
            return
        if parsed.path.startswith("/Captions/"):
            self.send_bytes(
                b"WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nSynthetic subtitle for interface verification.\n",
                "text/vtt; charset=utf-8",
            )
            return
        self.send_json(
            {"schema_version": 2, "error": {"code": "not_found", "message": "Synthetic route not found.", "recoverable": False, "action": None}},
            status=404,
        )

    def send_json(self, payload: dict, status: int = 200) -> None:
        self.send_bytes(json.dumps(payload).encode(), "application/json", status)

    def send_bytes(self, data: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, _format: str, *_args: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
