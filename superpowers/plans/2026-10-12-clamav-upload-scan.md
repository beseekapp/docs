# Virus Scanning (ClamAV) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scan every file that enters transformer with ClamAV before it is transformed or indexed. Quarantine infected or unscannable files, and block their download in webapp.

**Architecture:** A new first activity, `scan_file_activity`, runs in transformer's existing Dapr workflow. It streams the file to a `clamav/clamav` daemon over TCP (clamd `INSTREAM`, stdlib `socket`, no new dependency). A clean file continues through the existing steps. A dirty file is copied to an admin-only quarantine bucket, deleted from the main bucket, flagged in `file_metadata.scan_status`, and announced on `file.quarantined`; the workflow then ends without `file.transformed`. Webapp reads `scan_status` to show badges and to refuse downloads and previews.

**Tech Stack:** Python 3.11, FastAPI, dapr-ext-workflow, Appwrite SDK 15.3.0, pydantic v2, Dash Mantine Components, `clamav/clamav:stable` image, pytest.

**Spec:** `docs/superpowers/specs/2026-10-12-clamav-upload-scan-design.md` (Vikunja Epic V, cards #78–#81)

## Global Constraints

- Scan statuses, exact strings: `pending`, `clean`, `infected`, `unscannable`. An empty or missing status means "existed before scanning" and is treated as clean.
- The clamd stream limit equals Appwrite's upload limit: `StreamMaxLength 30M` (`_APP_STORAGE_LIMIT=30000000`).
- Transformer env vars: `CLAMAV_HOST` (default `clamav`), `CLAMAV_PORT` (default `3310`), `SCAN_ENABLED` (default `true`, parsed with `.lower() == "true"`), `QUARANTINE_BUCKET_ID`.
- New topic `file.quarantined`. Payload: `{workspace_id, file_metadata_id, appwrite_file_id, reason, signature, quarantined_at}`.
- No producer (webapp, courier, backoffice, pixelcraft, wordcraft) changes how it uploads or publishes.
- Never delete the original unless the quarantine copy succeeded.
- No new Python dependencies.

## Decisions refined while planning (deviations from the first spec draft; spec updated to match)

1. **Duplicate rule.** The spec said "skip the scan if `scan_status` is final". Revisions re-publish `file.uploaded` for the same `file_metadata_id` with a new `appwrite_file_id` (webapp `router.py:688`, `file_details.py:2439`), so that rule would leave new revisions unscanned. Instead, the activity sets `pending` and then always scans the `appwrite_file_id` in the event. Duplicate deliveries are already deduplicated by the workflow instance id `transform-{file_metadata_id}`.
2. **`pending` is written by transformer** at the start of the scan, not by webapp. Courier, backoffice and the other producers are covered without changes. The few seconds between upload and scan start show no badge.
3. **Scope gap.** `file.uploaded` is only published for workspace-scope files, so user- and worker-scope files are not scanned. This is recorded in the spec's Known gaps.
4. **Quarantine bucket** is created by hand in the Appwrite Console, like the main bucket; provisioning code has no bucket support. `scan_status` is a `StringAttribute` because provisioning has no enum type.
5. **Retry.** Transformer has no retry policy today. The scan call gets `RetryPolicy(10 s first, ×2, max 5 min, 6 attempts)`. If it's still failing after that, the workflow takes the existing failure path and the status stays `pending`.

## File map

| Repo | File | Responsibility |
|---|---|---|
| platform40-appwrite | `provisioning/domain/collections/knowledge.py` | `scan_status` attribute |
| platform40-transformer | `src/adapters/clamd_scanner.py` (new) | clamd INSTREAM client and reply parser |
| | `src/ports/scanner.py` (new) | `ScannerPort`, `ScanResult`, `ScannerUnavailableError` |
| | `src/ports/storage_client.py`, `src/adapters/appwrite_storage.py` | `delete_file`, optional `file_id` on `upload_file` |
| | `src/ports/database_client.py`, `src/adapters/appwrite_database.py` | `set_scan_status` |
| | `src/domain/events.py`, `src/ports/pubsub.py`, `src/adapters/pubsub/dapr_pubsub_client.py` | `FileQuarantined`, `publish_file_quarantined` |
| | `src/application/activities.py`, `src/main.py`, `src/application/api/dependencies.py` | `scan_file_activity`, registration, wiring |
| | `src/application/workflow.py` | step 0 |
| | `docker-compose.yml`, `clamav/clamd.conf` (new), `deployment.yaml`, `.env.example` | runtime |
| platform40-webapp | `src/shared/domain/knowledge.py` | `FileMetadata.scan_status` |
| | `src/shared/application/vfs_guards.py` | `is_scan_cleared()` |
| | `src/components/files/application/file_details_content.py` | `scan_status_badge()` |
| | `file_table.py`, `file_preview_drawer.py`, pages (download/preview sites) | badges and gating |
| | `src/shared/adapters/collection_adapters.py` | `copy_file` carries `scan_status` |

---

### Task 1: `scan_status` attribute (V1, card #78)

**Files:**
- Modify: `platform40-appwrite/provisioning/domain/collections/knowledge.py:95` (after `thumbnail_appwrite_file_id`)
- Test: `platform40-appwrite/provisioning/tests/unit/test_collection_specs.py`

**Interfaces:**
- Produces: the optional string attribute `file_metadata.scan_status` (size 20). Later tasks read and write it by this key.

- [ ] **Step 1: Write the failing test.** Append to `tests/unit/test_collection_specs.py`:

```python
def test_file_metadata_has_optional_scan_status():
    from domain.collections.knowledge import get_file_metadata_spec

    attr = next(a for a in get_file_metadata_spec().attributes if a.key == "scan_status")
    assert attr.required is False
    assert attr.size == 20
    assert getattr(attr, "default", None) is None
```

(Match the import style already used at the top of this test file. If it imports `from provisioning.domain...`, use that.)

- [ ] **Step 2: Run it and confirm it fails.** `cd platform40-appwrite/provisioning && pytest tests/unit/test_collection_specs.py::test_file_metadata_has_optional_scan_status -v` should fail with `StopIteration`.

- [ ] **Step 3: Implement.** After line 95 in `get_file_metadata_spec()`, add:

```python
            StringAttribute(key='scan_status', size=20, required=False),                  # pending|clean|infected|unscannable — set by transformer (ClamAV); empty = pre-scan legacy
```

- [ ] **Step 4: Run the whole unit suite.** `pytest tests/unit -v`; everything passes and the collection count is still 60.

- [ ] **Step 5: Commit.**

```bash
git add domain/collections/knowledge.py tests/unit/test_collection_specs.py
git commit -m "feat(provisioning): file_metadata.scan_status for ClamAV scanning"
```

---

### Task 2: clamd client (transformer)

**Files:**
- Create: `platform40-transformer/src/ports/scanner.py`
- Create: `platform40-transformer/src/adapters/clamd_scanner.py`
- Test: `platform40-transformer/tests/test_clamd_scanner.py`

**Interfaces:**
- Produces:
  - `ScanResult(status: str, signature: Optional[str])`, where `status` is one of `clean | infected | unscannable`.
  - `ScannerPort.scan_bytes(data: bytes) -> ScanResult`.
  - `ScannerUnavailableError(Exception)`, raised when clamd can't be reached or replies with something unexpected. That counts as a retryable failure and is never treated as clean.
  - `ClamdScanner(host: str, port: int, timeout: float = 120.0)`.
  - `parse_reply(reply: str) -> ScanResult`.

- [ ] **Step 1: Write the failing tests.** `tests/test_clamd_scanner.py`:

```python
import socket
import struct
import threading

import pytest

from src.adapters.clamd_scanner import ClamdScanner, parse_reply
from src.ports.scanner import ScannerUnavailableError


@pytest.mark.parametrize("reply,status,signature", [
    ("stream: OK", "clean", None),
    ("stream: Win.Test.EICAR_HDB-1 FOUND", "infected", "Win.Test.EICAR_HDB-1"),
    ("stream: Heuristics.Limits.Exceeded.MaxFileSize FOUND", "unscannable", "Heuristics.Limits.Exceeded.MaxFileSize"),
    ("INSTREAM size limit exceeded. ERROR", "unscannable", "INSTREAM size limit exceeded"),
])
def test_parse_reply(reply, status, signature):
    result = parse_reply(reply)
    assert (result.status, result.signature) == (status, signature)


def test_parse_reply_unknown_error_is_unavailable():
    with pytest.raises(ScannerUnavailableError):
        parse_reply("stream: lstat() failed. ERROR")


def _fake_clamd(reply: bytes):
    """One-shot TCP server that reads one INSTREAM request and answers `reply`."""
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    received = {}

    def serve():
        conn, _ = server.accept()
        with conn:
            buf = b""
            while not buf.endswith(b"\0\0\0\0"):
                buf += conn.recv(65536)
            received["raw"] = buf
            conn.sendall(reply + b"\0")
        server.close()

    threading.Thread(target=serve, daemon=True).start()
    return server.getsockname()[1], received


def test_scan_bytes_streams_instream_chunks():
    port, received = _fake_clamd(b"stream: OK")
    result = ClamdScanner("127.0.0.1", port).scan_bytes(b"hello")

    assert result.status == "clean"
    assert received["raw"] == b"zINSTREAM\0" + struct.pack("!L", 5) + b"hello" + struct.pack("!L", 0)


def test_scan_bytes_unreachable_raises_unavailable():
    with pytest.raises(ScannerUnavailableError):
        ClamdScanner("127.0.0.1", 1, timeout=1).scan_bytes(b"x")
```

- [ ] **Step 2: Run and confirm they fail.** `PYTHONPATH=. pytest tests/test_clamd_scanner.py -v` fails with `ModuleNotFoundError: src.adapters.clamd_scanner`.

- [ ] **Step 3: Implement the port.** `src/ports/scanner.py`:

```python
"""Scanner port — antivirus scanning of file bytes."""
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class ScanResult:
    status: str                      # "clean" | "infected" | "unscannable"
    signature: Optional[str] = None  # ClamAV signature or limit reason


class ScannerUnavailableError(Exception):
    """clamd unreachable or answered unexpectedly — retryable, never 'clean'."""


class ScannerPort(ABC):
    @abstractmethod
    def scan_bytes(self, data: bytes) -> ScanResult: ...
```

- [ ] **Step 4: Implement the adapter.** `src/adapters/clamd_scanner.py`:

```python
"""clamd INSTREAM client over TCP (stdlib only).

Protocol: send b"zINSTREAM\\0", then <4-byte big-endian length><chunk>... and a
zero-length chunk; clamd answers "stream: OK", "stream: <sig> FOUND" or "<msg> ERROR",
terminated by NUL.
"""
import logging
import socket
import struct

from ..ports.scanner import ScannerPort, ScanResult, ScannerUnavailableError

logger = logging.getLogger(__name__)

CHUNK_SIZE = 64 * 1024
LIMIT_PREFIX = "Heuristics.Limits.Exceeded"   # emitted because clamd.conf sets AlertExceedsMax yes


def parse_reply(reply: str) -> ScanResult:
    reply = reply.strip()
    if reply.endswith(" FOUND"):
        signature = reply.removeprefix("stream: ").removesuffix(" FOUND")
        status = "unscannable" if signature.startswith(LIMIT_PREFIX) else "infected"
        return ScanResult(status, signature)
    if reply == "stream: OK":
        return ScanResult("clean")
    if "size limit exceeded" in reply.lower():
        return ScanResult("unscannable", reply.removesuffix(". ERROR"))
    raise ScannerUnavailableError(f"unexpected clamd reply: {reply!r}")


class ClamdScanner(ScannerPort):
    def __init__(self, host: str, port: int, timeout: float = 120.0) -> None:
        self._address = (host, port)
        self._timeout = timeout

    def scan_bytes(self, data: bytes) -> ScanResult:
        try:
            with socket.create_connection(self._address, timeout=self._timeout) as sock:
                try:
                    sock.sendall(b"zINSTREAM\0")
                    for i in range(0, len(data), CHUNK_SIZE):
                        chunk = data[i:i + CHUNK_SIZE]
                        sock.sendall(struct.pack("!L", len(chunk)) + chunk)
                    sock.sendall(struct.pack("!L", 0))
                except (BrokenPipeError, ConnectionResetError):
                    pass  # clamd closes early on size limit; its reply is still readable
                reply = b""
                while not reply.endswith(b"\0"):
                    part = sock.recv(4096)
                    if not part:
                        break
                    reply += part
        except OSError as e:
            raise ScannerUnavailableError(f"clamd at {self._address} unreachable: {e}") from e

        if not reply:
            raise ScannerUnavailableError("clamd closed the connection without a reply")
        result = parse_reply(reply.rstrip(b"\0").decode(errors="replace"))
        logger.info(f"clamd scan: status={result.status} signature={result.signature}")
        return result
```

- [ ] **Step 5: Run the tests and confirm they pass.** `PYTHONPATH=. pytest tests/test_clamd_scanner.py -v`

- [ ] **Step 6: Commit.**

```bash
git add src/ports/scanner.py src/adapters/clamd_scanner.py tests/test_clamd_scanner.py
git commit -m "feat(transformer): stdlib clamd INSTREAM scanner adapter"
```

---

### Task 3: Storage, database and pub/sub capabilities for quarantine (transformer)

**Files:**
- Modify: `src/ports/storage_client.py`, `src/adapters/appwrite_storage.py`
- Modify: `src/ports/database_client.py`, `src/adapters/appwrite_database.py`
- Modify: `src/domain/events.py`, `src/ports/pubsub.py`, `src/adapters/pubsub/dapr_pubsub_client.py`
- Test: `tests/test_quarantine_adapters.py` (new)

**Interfaces:**
- Produces:
  - `StorageClientPort.delete_file(file_id: str) -> None` (async). Raises `StorageDeleteError(file_id, reason)`.
  - `StorageClientPort.upload_file(file_bytes, filename, mime_type, file_id: Optional[str] = None) -> str` (async). If `file_id` is given and Appwrite answers 409 (already exists), it returns `file_id`, so a retried quarantine copy is idempotent.
  - `DatabaseClientPort.set_scan_status(file_metadata_id: str, status: str) -> None` (async). Raises `DatabaseUpdateError`.
  - `FileQuarantined` pydantic event, and `PubSubPort.publish_file_quarantined(event: FileQuarantined) -> None` (async) on topic `file.quarantined`.

- [ ] **Step 1: Write the failing tests.** `tests/test_quarantine_adapters.py`:

```python
from unittest.mock import MagicMock, patch

import pytest
from appwrite.exception import AppwriteException

from src.adapters.appwrite_database import AppwriteDatabaseAdapter
from src.adapters.appwrite_storage import AppwriteStorageAdapter
from src.domain.events import FileQuarantined


def _storage():
    adapter = AppwriteStorageAdapter(client=MagicMock(), bucket_id="quarantine")
    adapter._storage = MagicMock()
    return adapter


async def test_upload_with_explicit_id_is_idempotent_on_409():
    adapter = _storage()
    adapter._storage.create_file.side_effect = AppwriteException("exists", 409)

    assert await adapter.upload_file(b"x", "a.pdf", "application/pdf", file_id="orig_1") == "orig_1"
    assert adapter._storage.create_file.call_args.kwargs["file_id"] == "orig_1"


async def test_delete_file_calls_sdk():
    adapter = _storage()
    await adapter.delete_file("orig_1")
    adapter._storage.delete_file.assert_called_once_with(bucket_id="quarantine", file_id="orig_1")


async def test_set_scan_status_updates_document():
    db = AppwriteDatabaseAdapter(client=MagicMock(), database_id="db1")
    db._databases = MagicMock()
    await db.set_scan_status("meta_001", "infected")
    db._databases.update_document.assert_called_once_with(
        database_id="db1", collection_id="file_metadata",
        document_id="meta_001", data={"scan_status": "infected"},
    )


def test_publish_file_quarantined_topic():
    from src.adapters.pubsub import dapr_pubsub_client as mod

    client = MagicMock()
    with patch.object(mod, "DaprClient") as dapr:
        dapr.return_value.__enter__.return_value = client
        import asyncio
        asyncio.run(mod.DaprPubSubClient().publish_file_quarantined(FileQuarantined(
            workspace_id="w", file_metadata_id="m", appwrite_file_id="f",
            reason="infected", signature="Eicar",
        )))
    assert client.publish_event.call_args.kwargs["topic_name"] == "file.quarantined"
```

- [ ] **Step 2: Run and confirm they fail.** `PYTHONPATH=. pytest tests/test_quarantine_adapters.py -v` fails on the `FileQuarantined` import.

- [ ] **Step 3: Add the event.** Append to `src/domain/events.py`, and add `- FileQuarantined: ...` to the Outbound list in its docstring:

```python
class FileQuarantined(BaseModel):
    """Published on topic 'file.quarantined' when ClamAV flags a file (infected or unscannable)."""

    workspace_id: str = Field(..., description="Workspace ID")
    file_metadata_id: str = Field(..., description="Appwrite DB file_metadata document ID")
    appwrite_file_id: str = Field(..., description="Storage $id (same id in the quarantine bucket)")
    reason: str = Field(..., description="infected | unscannable")
    signature: Optional[str] = Field(None, description="ClamAV signature or limit reason")
    quarantined_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat(),
        description="ISO 8601 timestamp",
    )
```

- [ ] **Step 4: Pub/sub.** In `src/ports/pubsub.py`, import `FileQuarantined` and add:

```python
    @abstractmethod
    async def publish_file_quarantined(self, event: FileQuarantined) -> None: ...
```

In `src/adapters/pubsub/dapr_pubsub_client.py`, add `TOPIC_FILE_QUARANTINED = "file.quarantined"` next to the other topic constants, import `FileQuarantined`, and add:

```python
    async def publish_file_quarantined(self, event: FileQuarantined) -> None:
        try:
            with DaprClient() as client:
                client.publish_event(
                    pubsub_name=PUBSUB_NAME,
                    topic_name=TOPIC_FILE_QUARANTINED,
                    data=event.model_dump_json(),
                    data_content_type="application/json",
                )
            logger.info(f"Published file.quarantined: file_metadata_id={event.file_metadata_id} reason={event.reason}")
        except Exception as e:
            logger.error(f"Failed to publish file.quarantined for {event.file_metadata_id}: {e}", exc_info=True)
            raise
```

- [ ] **Step 5: Storage.** In `src/ports/storage_client.py`, add the exception and abstract method, and add an optional `file_id` to the abstract `upload_file` signature:

```python
class StorageDeleteError(Exception):
    def __init__(self, file_id: str, reason: str) -> None:
        self.file_id = file_id
        self.reason = reason
        super().__init__(f"Failed to delete {file_id}: {reason}")
```

```python
    @abstractmethod
    async def upload_file(self, file_bytes: bytes, filename: str, mime_type: str,
                          file_id: Optional[str] = None) -> str: ...

    @abstractmethod
    async def delete_file(self, file_id: str) -> None: ...
```

In `src/adapters/appwrite_storage.py`, import `StorageDeleteError`. Change `upload_file` to accept `file_id: Optional[str] = None`, pass `file_id=file_id or ID.unique()` to `create_file`, and add this as the **first** clause of its `except AppwriteSDKException as e:` block:

```python
            if file_id and e.code == 409:
                logger.info(f"File {file_id} already in bucket {self.bucket_id}; treating upload as done")
                return file_id
```

Add the delete method:

```python
    async def delete_file(self, file_id: str) -> None:
        try:
            self._storage.delete_file(bucket_id=self.bucket_id, file_id=file_id)
            logger.info(f"Deleted {file_id} from bucket {self.bucket_id}")
        except AppwriteSDKException as e:
            raise StorageDeleteError(file_id=file_id, reason=f"Appwrite error [{e.code}]: {e.message}")
```

- [ ] **Step 6: Database.** Add `async def set_scan_status(self, file_metadata_id: str, status: str) -> None: ...` as an abstract method in `src/ports/database_client.py`. Implement it in `src/adapters/appwrite_database.py`:

```python
    async def set_scan_status(self, file_metadata_id: str, status: str) -> None:
        try:
            self._databases.update_document(
                database_id=self._database_id,
                collection_id=COLLECTION_FILE_METADATA,
                document_id=file_metadata_id,
                data={"scan_status": status},
            )
            logger.info(f"file_metadata {file_metadata_id} scan_status={status}")
        except AppwriteSDKException as e:
            raise DatabaseUpdateError(document_id=file_metadata_id, reason=f"Appwrite error [{e.code}]: {e.message}")
```

- [ ] **Step 7: Run the new tests and the full suite.** `PYTHONPATH=. pytest -q`; everything passes. The existing `upload_file` callers pass positional arguments only, so they are unaffected.

- [ ] **Step 8: Commit.**

```bash
git add src/ports src/adapters src/domain/events.py tests/test_quarantine_adapters.py
git commit -m "feat(transformer): quarantine primitives — delete, idempotent upload, scan_status, file.quarantined"
```

---

### Task 4: `scan_file_activity` and wiring (transformer)

**Files:**
- Modify: `src/application/activities.py` (registry and new activity)
- Modify: `src/application/api/dependencies.py` (build scanner and quarantine storage)
- Modify: `src/main.py:48-56,92-102` and the `register_adapters(...)` call in `lifespan`
- Test: `tests/test_scan_activity.py` (new)

**Interfaces:**
- Consumes: Task 2 `ClamdScanner`, `ScanResult` and `ScannerUnavailableError`; Task 3 `delete_file`, `upload_file(file_id=)`, `set_scan_status`, `publish_file_quarantined` and `FileQuarantined`.
- Produces: `scan_file_activity(ctx, input_data: dict) -> dict`, returning `{"status": "clean"|"infected"|"unscannable"|"skipped", "signature": str|None}`. It raises on infrastructure errors so the workflow retries them. `register_adapters(..., scanner=None, quarantine_storage=None)`.

- [ ] **Step 1: Write the failing tests.** `tests/test_scan_activity.py`:

```python
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.application import activities as activities_module
from src.ports.scanner import ScanResult, ScannerUnavailableError
from src.ports.storage_client import StorageUploadError

INPUT = {
    "workspace_id": "team_ws1", "file_metadata_id": "meta_001", "appwrite_file_id": "orig_file_001",
    "file_name": "a.pdf", "mime_type": "application/pdf", "file_type": "pdf", "uploaded_by": "user_abc",
}


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setattr(activities_module, "restore_trace_context", lambda _d: None)
    monkeypatch.setattr(activities_module, "detach_trace_context", lambda _t: None)
    monkeypatch.setenv("SCAN_ENABLED", "true")
    activities_module._registry.clear()
    reg = activities_module._registry
    reg["storage_client"] = AsyncMock(download_file=AsyncMock(return_value=b"bytes"))
    reg["quarantine_storage"] = AsyncMock(upload_file=AsyncMock(return_value="orig_file_001"))
    reg["database_client"] = AsyncMock()
    reg["pubsub_client"] = AsyncMock()
    reg["scanner"] = MagicMock()
    yield reg
    activities_module._registry.clear()


def _run():
    loop = asyncio.new_event_loop()
    with patch("src.application.activities.asyncio.run", side_effect=loop.run_until_complete):
        return activities_module.scan_file_activity(MagicMock(), dict(INPUT))


def test_clean_marks_clean_and_does_not_quarantine(_env):
    _env["scanner"].scan_bytes.return_value = ScanResult("clean")
    assert _run()["status"] == "clean"
    statuses = [c.args[1] for c in _env["database_client"].set_scan_status.await_args_list]
    assert statuses == ["pending", "clean"]
    _env["quarantine_storage"].upload_file.assert_not_awaited()
    _env["storage_client"].delete_file.assert_not_awaited()


@pytest.mark.parametrize("status", ["infected", "unscannable"])
def test_dirty_copies_then_deletes_flags_and_publishes(_env, status):
    _env["scanner"].scan_bytes.return_value = ScanResult(status, "Sig")
    assert _run() == {"status": status, "signature": "Sig"}
    _env["quarantine_storage"].upload_file.assert_awaited_once_with(
        b"bytes", "a.pdf", "application/pdf", file_id="orig_file_001")
    _env["storage_client"].delete_file.assert_awaited_once_with("orig_file_001")
    assert _env["database_client"].set_scan_status.await_args_list[-1].args == ("meta_001", status)
    event = _env["pubsub_client"].publish_file_quarantined.await_args.args[0]
    assert (event.reason, event.signature) == (status, "Sig")


def test_quarantine_copy_failure_keeps_original(_env):
    _env["scanner"].scan_bytes.return_value = ScanResult("infected", "Sig")
    _env["quarantine_storage"].upload_file.side_effect = StorageUploadError("a.pdf", "boom")
    assert _run()["status"] == "infected"
    _env["storage_client"].delete_file.assert_not_awaited()
    assert _env["database_client"].set_scan_status.await_args_list[-1].args == ("meta_001", "infected")


def test_scanner_unavailable_raises_and_leaves_pending(_env):
    _env["scanner"].scan_bytes.side_effect = ScannerUnavailableError("down")
    with pytest.raises(ScannerUnavailableError):
        _run()
    statuses = [c.args[1] for c in _env["database_client"].set_scan_status.await_args_list]
    assert statuses == ["pending"]


def test_scan_disabled_is_noop(_env, monkeypatch):
    monkeypatch.setenv("SCAN_ENABLED", "false")
    assert _run()["status"] == "skipped"
    _env["storage_client"].download_file.assert_not_awaited()
    _env["database_client"].set_scan_status.assert_not_awaited()
```

- [ ] **Step 2: Run and confirm they fail.** `PYTHONPATH=. pytest tests/test_scan_activity.py -v` fails with `AttributeError: ... scan_file_activity`.

- [ ] **Step 3: Extend the registry.** In `src/application/activities.py`, add `import os` and `from ..ports.storage_client import StorageUploadError`, and change `register_adapters`:

```python
def register_adapters(
    storage_client: StorageClientPort,
    converter: ConverterPort,
    thumbnail_generator: ThumbnailGeneratorPort,
    database_client: DatabaseClientPort,
    pubsub_client: PubSubPort,
    scanner=None,
    quarantine_storage=None,
) -> None:
    """..."""
    _registry["storage_client"] = storage_client
    _registry["converter"] = converter
    _registry["thumbnail_generator"] = thumbnail_generator
    _registry["database_client"] = database_client
    _registry["pubsub_client"] = pubsub_client
    _registry["scanner"] = scanner
    _registry["quarantine_storage"] = quarantine_storage
    logger.info("Workflow activity adapters registered")
```

- [ ] **Step 4: Add the activity** (place it before `transform_document_activity`):

```python
def scan_file_activity(ctx: WorkflowActivityContext, input_data: dict) -> dict:
    """
    Step 0: ClamAV scan. clean → workflow continues; infected/unscannable → quarantined.

    Raises on infrastructure errors (clamd down, download/DB failure) so the workflow
    retry policy re-runs it; the file then stays scan_status=pending (download blocked).
    """
    if os.environ.get("SCAN_ENABLED", "true").lower() != "true":
        return {"status": "skipped", "signature": None}

    token = restore_trace_context(input_data)
    try:
        meta_id = input_data["file_metadata_id"]
        file_id = input_data["appwrite_file_id"]
        storage = _registry["storage_client"]
        db = _registry["database_client"]

        asyncio.run(db.set_scan_status(meta_id, "pending"))
        data = asyncio.run(storage.download_file(file_id))
        result = _registry["scanner"].scan_bytes(data)
        logger.info(f"Activity: scan_file_activity file_metadata_id={meta_id} status={result.status}")

        if result.status == "clean":
            asyncio.run(db.set_scan_status(meta_id, "clean"))
            return {"status": "clean", "signature": None}

        quarantine = _registry["quarantine_storage"]
        if quarantine is None:
            raise RuntimeError("QUARANTINE_BUCKET_ID not set — cannot quarantine flagged file")
        try:
            asyncio.run(quarantine.upload_file(
                data, input_data["file_name"], input_data["mime_type"], file_id=file_id))
            asyncio.run(storage.delete_file(file_id))
        except StorageUploadError as e:
            logger.error(f"Quarantine copy failed for {file_id}; original kept, downloads blocked: {e}")

        asyncio.run(db.set_scan_status(meta_id, result.status))
        from ..domain.events import FileQuarantined
        pubsub = _registry.get("pubsub_client")
        if pubsub:
            asyncio.run(pubsub.publish_file_quarantined(FileQuarantined(
                workspace_id=input_data["workspace_id"], file_metadata_id=meta_id,
                appwrite_file_id=file_id, reason=result.status, signature=result.signature,
            )))
        return {"status": result.status, "signature": result.signature}
    finally:
        detach_trace_context(token)
```

- [ ] **Step 5: Wire it up.** In `src/application/api/dependencies.py` `get_all_adapters()`, after `pubsub_client`:

```python
    from ...adapters.clamd_scanner import ClamdScanner

    scanner = ClamdScanner(
        host=os.environ.get("CLAMAV_HOST", "clamav"),
        port=int(os.environ.get("CLAMAV_PORT", "3310")),
    )
    quarantine_bucket_id = os.environ.get("QUARANTINE_BUCKET_ID", "")
    if not quarantine_bucket_id:
        logger.warning("QUARANTINE_BUCKET_ID not set — flagged files cannot be quarantined")
    quarantine_storage = (
        AppwriteStorageAdapter(client=appwrite_client, bucket_id=quarantine_bucket_id)
        if quarantine_bucket_id else None
    )
```

Add `"scanner": scanner` and `"quarantine_storage": quarantine_storage` to `_adapters`. In `src/main.py`, add `scan_file_activity` to the activities import, call `workflow_runtime.register_activity(scan_file_activity)` before the transform registration, and extend the lifespan call:

```python
    register_adapters(
        storage_client=adapters["storage_client"],
        converter=adapters["converter"],
        thumbnail_generator=adapters["thumbnail_generator"],
        database_client=adapters["database_client"],
        pubsub_client=adapters["pubsub_client"],
        scanner=adapters["scanner"],
        quarantine_storage=adapters["quarantine_storage"],
    )
```

- [ ] **Step 6: Run everything.** `PYTHONPATH=. pytest -q`; everything passes, including `test_register_adapters_populates_registry`, because the new parameters have defaults.

- [ ] **Step 7: Commit.**

```bash
git add src/application src/main.py tests/test_scan_activity.py
git commit -m "feat(transformer): scan_file_activity — ClamAV scan + quarantine"
```

---

### Task 5: Workflow step 0 (transformer)

**Files:**
- Modify: `src/application/workflow.py` (imports L34-45, body L65)
- Modify: `tests/test_workflow.py` (drivers and index asserts)

**Interfaces:**
- Consumes: Task 4 `scan_file_activity`.
- Produces: the workflow result `{"status": "quarantined", "reason": "infected"|"unscannable"}` for dirty files. Clean and `skipped` files produce the existing results unchanged.

- [ ] **Step 1: Update the existing tests first.** In `tests/test_workflow.py`:
  - Change `_make_ctx` to `ctx.call_activity = MagicMock(side_effect=lambda fn, input, **kw: MagicMock(name=fn.__name__))`.
  - Import `scan_file_activity`.
  - In every driver and test that starts with `next(gen)`, insert `gen.send({"status": "clean", "signature": None})` right after `next(gen)`. Every result that was sent to the transform yield now goes one yield later.
  - Shift every `call_args_list[i]` index by +1.
  - Rename `test_workflow_calls_transform_activity_first` to `test_workflow_calls_transform_after_scan` and assert `call_args_list[0].args[0] is scan_file_activity` and `call_args_list[1].args[0] is transform_document_activity`.

  Then add:

```python
@pytest.mark.parametrize("status", ["infected", "unscannable"])
def test_workflow_stops_after_quarantine(status):
    ctx = _make_ctx()
    gen = transformer_workflow(ctx, _make_workflow_input())
    next(gen)  # yield 0: scan
    try:
        gen.send({"status": status, "signature": "Sig"})
    except StopIteration as exc:
        result = exc.value
    else:
        raise AssertionError("workflow must end after quarantine")
    assert result == {"status": "quarantined", "reason": status}
    called = [c.args[0] for c in ctx.call_activity.call_args_list]
    assert transform_document_activity not in called
    assert publish_transformed_event_activity not in called


def test_scan_uses_retry_policy():
    ctx = _make_ctx()
    gen = transformer_workflow(ctx, _make_workflow_input())
    next(gen)
    assert ctx.call_activity.call_args_list[0].kwargs["retry_policy"].max_number_of_attempts == 6


def test_scan_failure_takes_failure_path():
    ctx = _make_ctx()
    gen = transformer_workflow(ctx, _make_workflow_input())
    next(gen)
    gen.throw(RuntimeError("clamd down"))  # retries exhausted
    assert ctx.call_activity.call_args_list[-1].args[0] is publish_failure_activity
```

(Add `import pytest` if the file doesn't import it yet.)

- [ ] **Step 2: Run and confirm they fail.** `PYTHONPATH=. pytest tests/test_workflow.py -v` fails, because step 0 doesn't exist yet.

- [ ] **Step 3: Implement.** In `workflow.py`, add `from datetime import timedelta`, extend the dapr import to `from dapr.ext.workflow import DaprWorkflowContext, RetryPolicy`, add `scan_file_activity` to the activities import, and add this at module level:

```python
# clamd may be restarting or reloading signatures: ~10s, 20s, 40s, 80s, 160s (+cap) before giving up.
SCAN_RETRY_POLICY = RetryPolicy(
    first_retry_interval=timedelta(seconds=10),
    max_number_of_attempts=6,
    backoff_coefficient=2,
    max_retry_interval=timedelta(minutes=5),
)
```

At the top of the `try:` block, before `# Step 1`:

```python
        # Step 0: ClamAV scan — nothing is transformed or indexed until the file is clean
        scan_result = yield ctx.call_activity(
            scan_file_activity,
            input=input_data,
            retry_policy=SCAN_RETRY_POLICY,
        )
        if scan_result.get("status") in ("infected", "unscannable"):
            if not ctx.is_replaying:
                logger.warning(
                    f"Workflow stopped: file_metadata_id={file_metadata_id} "
                    f"quarantined ({scan_result.get('status')}: {scan_result.get('signature')})"
                )
            return {"status": "quarantined", "reason": scan_result["status"]}
```

Update the module docstring's step list to begin with `0. scan_file_activity`.

- [ ] **Step 4: Run the full suite.** `PYTHONPATH=. pytest -q`; everything passes.

- [ ] **Step 5: Commit.**

```bash
git add src/application/workflow.py tests/test_workflow.py
git commit -m "feat(transformer): scan step 0 gates transformation; quarantined files stop the workflow"
```

---

### Task 6: Run clamav alongside transformer

**Files:**
- Create: `platform40-transformer/clamav/clamd.conf`
- Modify: `docker-compose.yml`, `deployment.yaml`, `.env.example`, `README.md` (env table)

**Interfaces:**
- Consumes: the env names from Global Constraints.
- Produces: clamd reachable at `clamav:3310` (compose) or `localhost:3310` (GKE sidecar).

- [ ] **Step 1: Write `clamav/clamd.conf`.**

```
# Mounted over the image default. Limits match Appwrite's 30 MB upload cap.
Foreground yes
LocalSocket /tmp/clamd.sock
TCPSocket 3310
TCPAddr 0.0.0.0
StreamMaxLength 30M
MaxFileSize 30M
MaxScanSize 120M
AlertExceedsMax yes
LogTime yes
```

- [ ] **Step 2: Compose.** In `docker-compose.yml`, add this service before `transformer`:

```yaml
  # ─── ClamAV daemon (virus scanning, step 0) ───────────────────────────────
  # Loads signatures on start (~1 min) and runs freshclam itself.
  clamav:
    image: clamav/clamav:stable
    restart: unless-stopped
    volumes:
      - ./clamav/clamd.conf:/etc/clamav/clamd.conf:ro
      - clamav-db:/var/lib/clamav
    healthcheck:
      test: ["CMD", "clamdcheck.sh"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
    deploy:
      resources:
        limits:
          memory: 2G
    networks:
      - platform40_default
```

Add this under transformer's `depends_on:`:

```yaml
      clamav:
        condition: service_healthy
```

Add a top-level `volumes:` block with `clamav-db: {}`.

- [ ] **Step 3: Check the container is healthy.** Run `docker compose up -d clamav && sleep 150 && docker compose ps clamav`; expected `healthy`. If the image has no `clamdcheck.sh`, change the test to `["CMD-SHELL", "echo PING | nc -w 2 127.0.0.1 3310 | grep -q PONG"]` and re-check.

- [ ] **Step 4: Check EICAR is detected.** Run:

```bash
docker compose exec clamav sh -c 'printf "X5O!P%%@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*" | clamdscan --stream -'
```

Expected: `stream: Win.Test.EICAR_HDB-1 FOUND`.

- [ ] **Step 5: GKE.** In `deployment.yaml`, under `spec.template.spec.containers:`, add a second container:

```yaml
      - name: clamav
        image: clamav/clamav:stable
        ports:
        - containerPort: 3310
        resources:
          limits:
            memory: 2Gi
          requests:
            memory: 1Gi
        volumeMounts:
        - name: clamd-conf
          mountPath: /etc/clamav/clamd.conf
          subPath: clamd.conf
```

Add the following:
- Under `spec.template.spec.volumes`: `- name: clamd-conf` with `configMap: {name: transformer-clamd-conf}`.
- A ConfigMap document `transformer-clamd-conf` (separated by `---`) with key `clamd.conf` holding the content from Step 1.
- These env entries on the transformer container:

```yaml
        - name: CLAMAV_HOST
          value: "localhost"
        - name: CLAMAV_PORT
          value: "3310"
        - name: SCAN_ENABLED
          value: "false"   # flipped to "true" in rollout task
        - name: QUARANTINE_BUCKET_ID
          valueFrom:
            secretKeyRef:
              name: appwrite-config
              key: quarantine-bucket-id
```

- [ ] **Step 6: `.env.example` and README.** Add this section to `.env.example`:

```
# ClamAV virus scanning (step 0)
CLAMAV_HOST=clamav
CLAMAV_PORT=3310
SCAN_ENABLED=true
QUARANTINE_BUCKET_ID=your-quarantine-bucket-id
```

Add the same four variables to the README env table, and add one line to the README pipeline description: "Step 0 scans with ClamAV; flagged files are quarantined and never transformed."

- [ ] **Step 7: Commit.**

```bash
git add clamav/clamd.conf docker-compose.yml deployment.yaml .env.example README.md
git commit -m "feat(transformer): run clamav/clamav alongside transformer (compose + GKE sidecar)"
```

---

### Task 7: Webapp: model, gating, badges, copy (V3, card #80)

**Files:**
- Modify: `src/shared/domain/knowledge.py` (`FileMetadata`, in the artifacts block)
- Modify: `src/shared/application/vfs_guards.py` (new helper after `require_file_read_access`)
- Modify: `src/components/files/application/file_details_content.py` (new `scan_status_badge`, after `_access_badge`, used in the header badge group L304-325)
- Modify: `src/components/files/application/file_table.py:381-413` (name cell)
- Modify: `src/components/files/application/file_preview_drawer.py:399-407` (badge group)
- Modify: `src/shared/adapters/collection_adapters.py:675` (`copy_file`)
- Modify: the original-file download and preview sites (table below)
- Test: `tests/test_scan_gate.py` (new)

**Interfaces:**
- Consumes: the `file_metadata.scan_status` values written by transformer.
- Produces: `is_scan_cleared(file: FileMetadata) -> bool` and `scan_status_badge(scan_status: Optional[str]) -> Optional[dmc.Badge]`.

- [ ] **Step 1: Write the failing tests.** `tests/test_scan_gate.py`:

```python
import pytest

from src.shared.domain.knowledge import FileMetadata
from src.shared.application.vfs_guards import is_scan_cleared
from src.components.files.application.file_details_content import scan_status_badge


def _meta(**kw):
    base = dict(workspace_id="w", name="a.pdf", file_type="pdf", mime_type="application/pdf",
                size_bytes=1, uploaded_by="u", appwrite_file_id="f")
    return FileMetadata(**{**base, **kw})


@pytest.mark.parametrize("status,cleared", [
    (None, True), ("clean", True), ("pending", False), ("infected", False), ("unscannable", False),
])
def test_is_scan_cleared(status, cleared):
    assert is_scan_cleared(_meta(scan_status=status)) is cleared


def test_scan_status_survives_appwrite_roundtrip():
    doc = {"$id": "m1", "workspace_id": "w", "name": "a.pdf", "file_type": "pdf",
           "mime_type": "application/pdf", "size_bytes": 1, "uploaded_by": "u",
           "appwrite_file_id": "f", "scan_status": "infected"}
    assert FileMetadata.from_appwrite(doc).scan_status == "infected"


@pytest.mark.parametrize("status,label", [
    ("pending", "Scanning…"), ("infected", "Removed: virus detected"), ("unscannable", "Could not be scanned"),
])
def test_badge_labels(status, label):
    assert scan_status_badge(status).children == label


@pytest.mark.parametrize("status", [None, "clean"])
def test_no_badge_for_cleared(status):
    assert scan_status_badge(status) is None
```

(If `FileMetadata` has other required fields, add them to `_meta` and `doc`, copying the minimal set used by existing tests or `copy_file`.)

- [ ] **Step 2: Run and confirm they fail.** `cd platform40-webapp && python -m pytest tests/test_scan_gate.py -q` fails with `ImportError: is_scan_cleared`.

- [ ] **Step 3: Model.** In `FileMetadata`, after `thumbnail_appwrite_file_id`:

```python
    scan_status: Optional[str] = Field(
        None,
        description="ClamAV result written by transformer: pending | clean | infected | unscannable. "
                    "None = file predates scanning (treated as clean)."
    )
```

- [ ] **Step 4: Guard.** In `vfs_guards.py`, after `require_file_read_access`:

```python
SCAN_BLOCKED_STATUSES = frozenset({"pending", "infected", "unscannable"})


def is_scan_cleared(file: FileMetadata) -> bool:
    """True when the file's bytes may be served (scanned clean, or predates scanning)."""
    return file.scan_status not in SCAN_BLOCKED_STATUSES
```

- [ ] **Step 5: Badge helper.** In `file_details_content.py`, after `_access_badge`:

```python
def scan_status_badge(scan_status: Optional[str]) -> Optional[dmc.Badge]:
    """Badge for files not cleared by the virus scan; None when clean or pre-scan."""
    config = {
        "pending": ("Scanning…", "blue", "mingcute:loading-line"),
        "infected": ("Removed: virus detected", "red", "mingcute:virus-line"),
        "unscannable": ("Could not be scanned", "orange", "mingcute:warning-line"),
    }
    if scan_status not in config:
        return None
    label, color, icon = config[scan_status]
    return dmc.Badge(label, color=color, variant="light", size="sm",
                     leftSection=DashIconify(icon=icon, width=12))
```

In `render_file_header_card`'s badge group (L304-325), append `scan_status_badge(file.scan_status)` to the children list. Dash skips `None` children. Add `Optional` to the typing import if it's missing.

- [ ] **Step 6: Run the tests and confirm they pass.** `python -m pytest tests/test_scan_gate.py -q`

- [ ] **Step 7: Table and drawer badges.** Import `scan_status_badge` from `.file_details_content` in both files.
  - `file_table.py`, name cell (L381-413): append `scan_status_badge(file.scan_status)` to the `dmc.Group([...])` children, after the `dmc.Tooltip(...)`.
  - `file_preview_drawer.py` L399-407: append it to the format/scope badge group:

```python
        dmc.Group(
            [
                dmc.Badge(format_label, variant="light", size="sm", color="gray"),
                dmc.Badge(scope_label, variant="light", size="sm", color=scope_color),
                scan_status_badge(file.scan_status),
            ],
            gap="xs",
        ),
```

- [ ] **Step 8: Gate the original-file download and preview sites.** Import `is_scan_cleared` next to `require_file_read_access` in each page. Find every site with `git grep -n "download_file(file_meta.appwrite_file_id\|get_file_preview(file_meta.appwrite_file_id" src/pages`. At the time of planning these were:

| Site | Kind |
|---|---|
| `src/pages/files.py:1605` (`handle_aside_download`) | download |
| `src/pages/files.py:2653` (`handle_bulk_download`) | download (skip the file in the ZIP) |
| `src/pages/file_details.py:841` | download |
| `src/pages/task_details.py:772` (`handle_td_download`) | download |
| `src/pages/channels_emails.py:914` (`handle_ce_download`) | download |
| `src/pages/files.py:1260`, `file_details.py:556,1016,1223,2462`, `task_details.py:605`, `channels_emails.py:779` | preview |

For a **download**, place this right after the existing `require_file_read_access` deny branch at that site, returning the same tuple shape that branch returns:

```python
        if not is_scan_cleared(file_meta):
            return dash.no_update, error_alert("Download blocked", "This file has not passed the virus scan.")
```

In the **bulk ZIP** loop, skip the file instead: `if not is_scan_cleared(file_meta): continue`.

For a **preview**, add the guard to the condition in front of the `get_file_preview` call, for example at files.py:1260:

```python
        if file_meta.appwrite_file_id and mime.startswith("image/") and is_scan_cleared(file_meta):
```

In `handle_file_row_click` (files.py ~L1310), pass `can_download=is_scan_cleared(file_meta)` to `render_file_actions`.

Revision downloads (`file_details.py:1144`, `file_revision.py:418`) are not gated. Only the head revision is scanned; older revisions are tracked separately in the spec's Known gaps.

- [ ] **Step 9: `copy_file`.** In `collection_adapters.py`, inside `copy = FileMetadata(` (L675), add `scan_status=source.scan_status,` after `appwrite_file_id=source.appwrite_file_id,`.

- [ ] **Step 10: Run the suite and lint.** Run `python -m pytest tests/ -q && flake8 src --select=E9,F63,F7,F82`; both pass.

- [ ] **Step 11: Commit.**

```bash
git add src tests/test_scan_gate.py
git commit -m "feat(webapp): scan_status badges and download/preview block for unscanned files"
```

---

### Task 8: Rollout and EICAR smoke test on the test server (V4, card #81)

**Files:**
- None (operational task; spec already records the refined decisions)

**Interfaces:**
- Consumes: Tasks 1–7 merged or available as refs; SSH access to `ubuntu@3.90.155.157`.

- [ ] **Step 1: Provision the field.** Run `cd platform40-appwrite && docker compose -f docker-compose.provisioning.yml up database` against the test server's Appwrite (use the existing provisioning `.env`). Expect `scan_status` to be created and everything else skipped.
- [ ] **Step 2: Create the quarantine bucket.** In the Appwrite Console (`:9080`), go to Storage → Create bucket, name it `quarantine`, give it **no permissions**, and set the max file size to 30 MB. Note its ID.
- [ ] **Step 3: Configure transformer on the server.** In the server `.env` at `platform40/microservices/transformer/.env`, set `CLAMAV_HOST=clamav`, `CLAMAV_PORT=3310`, `SCAN_ENABLED=false` and `QUARANTINE_BUCKET_ID=<id>`.
- [ ] **Step 4: Deploy transformer.** Run `bash docs/scripts/deploy-to-remote.sh --ref <transformer-branch> transformer`. Expect transformer, the dapr sidecar and clamav all running, with clamav healthy. Check memory with `ssh ubuntu@3.90.155.157 "sudo docker stats --no-stream | grep clamav"`; it should be under 2 GiB.
- [ ] **Step 5: Deploy webapp.** Run `bash docs/scripts/deploy-to-remote.sh --ref <webapp-branch> webapp`.
- [ ] **Step 6: Enable scanning.** Set `SCAN_ENABLED=true` in the server `.env`, then run `ssh ubuntu@3.90.155.157 "cd platform40/microservices/transformer && sudo docker compose up -d transformer"`.
- [ ] **Step 7: EICAR smoke test.** Upload a file `eicar.txt` with the content `X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*` to a workspace through webapp. Expected within about 30 s:
  - transformer logs show `status=infected` and `Workflow stopped ... quarantined`;
  - the file is in the `quarantine` bucket and gone from the main bucket;
  - `file_metadata.scan_status = infected`;
  - webapp shows "Removed: virus detected" and the Download button is hidden;
  - searching "EICAR" in seeker returns nothing.
- [ ] **Step 8: Clean-file smoke test.** Upload a normal PDF. Expect `scan_status = clean`, a thumbnail to appear, and the PDF to be searchable as before.
- [ ] **Step 9: Board.** Move cards #78–#81 to Done, with a comment on each linking the PRs and the smoke-test results.
