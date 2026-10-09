from __future__ import annotations

import asyncio
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from androidtvremote2 import AndroidTVRemote, CannotConnect, ConnectionClosed, InvalidAuth
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from zeroconf import ServiceStateChange
from zeroconf.asyncio import AsyncServiceBrowser, AsyncServiceInfo, AsyncZeroconf

BASE_DIR = Path(__file__).resolve().parent
TV_HOST = os.getenv("TV_HOST", "").strip()
CLIENT_NAME = os.getenv("TV_CLIENT_NAME", "HomeTV Remote")
CERT_FILE = os.getenv("TV_CERT_FILE", str(BASE_DIR / "data" / "cert.pem"))
KEY_FILE = os.getenv("TV_KEY_FILE", str(BASE_DIR / "data" / "key.pem"))

remote: AndroidTVRemote | None = None
pairing_started = False


class TextRequest(BaseModel):
    text: str = Field(min_length=1, max_length=500)


class AppRequest(BaseModel):
    uri: str = Field(min_length=1, max_length=500)


class PairingCode(BaseModel):
    code: str = Field(min_length=1, max_length=20)


def require_remote() -> AndroidTVRemote:
    if remote is None:
        raise HTTPException(status_code=503, detail="TV_HOST is not configured")
    return remote


def remote_status(tv: AndroidTVRemote) -> dict[str, Any]:
    volume = tv.volume_info
    return {
        # androidtvremote2 exposes availability through callbacks, but not as
        # a property in all released versions.
        "available": getattr(tv, "is_available", tv.device_info is not None),
        "on": tv.is_on,
        "host": tv.host,
        "current_app": tv.current_app,
        "volume": {
            "level": getattr(volume, "level", None),
            "maximum": getattr(volume, "maximum", None),
            "muted": getattr(volume, "muted", None),
        } if volume else None,
    }


@asynccontextmanager
async def lifespan(_: FastAPI):
    global remote
    if TV_HOST:
        Path(CERT_FILE).parent.mkdir(parents=True, exist_ok=True)
        remote = AndroidTVRemote(CLIENT_NAME, CERT_FILE, KEY_FILE, TV_HOST)
        await remote.async_generate_cert_if_missing()
        if Path(CERT_FILE).exists() and Path(KEY_FILE).exists():
            try:
                await remote.async_connect()
                remote.keep_reconnecting()
            except (CannotConnect, ConnectionClosed, InvalidAuth):
                # Pairing can be completed through the API after startup.
                pass
    yield
    if remote is not None:
        remote.disconnect()


app = FastAPI(title="HomeTV Android TV API", version="0.1.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")


@app.get("/", include_in_schema=False)
async def root():
    return FileResponse(BASE_DIR / "static" / "index.html")


@app.get("/api/tv/discover")
async def discover(timeout: float = 3.0):
    """Discover Android TVs advertising the Android TV Remote service."""
    timeout = max(1.0, min(timeout, 10.0))
    found: dict[str, dict[str, Any]] = {}
    pending: set[asyncio.Task[None]] = set()
    zc = AsyncZeroconf()

    async def read_service(service_type: str, name: str) -> None:
        info = AsyncServiceInfo(service_type, name)
        if await info.async_request(zc.zeroconf, int(timeout * 1000)):
            addresses = info.parsed_scoped_addresses()
            if addresses:
                found[name] = {
                    "name": name,
                    "host": addresses[0],
                    "port": info.port,
                }

    def on_service_change(
        zeroconf: Any, service_type: str, name: str, state_change: ServiceStateChange
    ) -> None:
        if state_change is ServiceStateChange.Added:
            task = asyncio.create_task(read_service(service_type, name))
            pending.add(task)
            task.add_done_callback(pending.discard)

    browser = AsyncServiceBrowser(
        zc.zeroconf,
        ["_androidtvremote2._tcp.local."],
        handlers=[on_service_change],
    )
    try:
        await asyncio.sleep(timeout)
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        return {"devices": list(found.values())}
    finally:
        await browser.async_cancel()
        await zc.async_close()


@app.get("/api/tv/status")
async def status():
    return remote_status(require_remote())


@app.post("/api/tv/pair/start")
async def pair_start():
    global pairing_started
    tv = require_remote()
    try:
        name, mac = await tv.async_get_name_and_mac()
        await tv.async_start_pairing()
        pairing_started = True
        return {"pairing_started": True, "name": name, "mac": mac, "message": "請查看電視畫面上的配對碼"}
    except (CannotConnect, ConnectionClosed) as exc:
        raise HTTPException(status_code=502, detail=f"無法連線到電視：{exc}") from exc


@app.post("/api/tv/pair/finish")
async def pair_finish(request: PairingCode):
    global pairing_started
    tv = require_remote()
    if not pairing_started:
        raise HTTPException(status_code=409, detail="請先呼叫 /api/tv/pair/start")
    try:
        await tv.async_finish_pairing(request.code)
        pairing_started = False
        await tv.async_connect()
        tv.keep_reconnecting()
        return {"paired": True, "status": remote_status(tv)}
    except InvalidAuth as exc:
        raise HTTPException(status_code=401, detail="配對碼錯誤") from exc
    except (CannotConnect, ConnectionClosed) as exc:
        raise HTTPException(status_code=502, detail=f"配對後連線失敗：{exc}") from exc


@app.post("/api/tv/keys/{key}")
async def key(key: str):
    tv = require_remote()
    allowed = {
        "home": "HOME", "back": "BACK", "up": "DPAD_UP", "down": "DPAD_DOWN",
        "left": "DPAD_LEFT", "right": "DPAD_RIGHT", "enter": "DPAD_CENTER",
        "play_pause": "MEDIA_PLAY_PAUSE", "rewind": "MEDIA_REWIND",
        "fast_forward": "MEDIA_FAST_FORWARD", "power": "POWER", "mute": "MUTE",
        "volume_up": "VOLUME_UP", "volume_down": "VOLUME_DOWN",
    }
    if key.isdigit() and len(key) == 1:
        # androidtvremote2 prefixes commands with KEYCODE_. The protocol's
        # numeric enum is KEYCODE_NUMPAD_0..KEYCODE_NUMPAD_9.
        command = f"NUMPAD_{key}"
    else:
        command = allowed.get(key.lower())
    if command is None:
        raise HTTPException(status_code=400, detail=f"不支援的按鍵：{key}")
    tv.send_key_command(command)
    return {"success": True, "key": key}


@app.post("/api/tv/text")
async def text(request: TextRequest):
    require_remote().send_text(request.text)
    return {"success": True}


@app.post("/api/tv/apps/launch")
async def launch_app(request: AppRequest):
    require_remote().send_launch_app_command(request.uri)
    return {"success": True, "uri": request.uri}
