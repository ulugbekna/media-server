#!/usr/bin/env python3
"""Durably forward Radarr movie webhooks to authorized Searcharr users."""

import argparse
import ast
import copy
import dataclasses
import hashlib
import http.client
import json
import logging
import os
import queue
import re
import signal
import socket
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set


DEFAULT_SETTINGS_PATH = Path("/searcharr/settings.py")
DEFAULT_DATABASE_PATH = Path("/searcharr/searcharr.db")
DEFAULT_STATE_PATH = Path("/state/events.sqlite")
DEFAULT_SYNC_HEARTBEAT_PATH = Path("/tmp/status-sync-heartbeat")
DEFAULT_WORKER_HEARTBEAT_PATH = Path("/tmp/status-worker-heartbeat")
DEFAULT_LISTEN_PORT = 8081
DEFAULT_POLL_SECONDS = 60
DEFAULT_HTTP_TIMEOUT_SECONDS = 10
DEFAULT_HTTP_ATTEMPTS = 3
DEFAULT_HEALTH_MAX_AGE_SECONDS = 300
MAX_WEBHOOK_BYTES = 1024 * 1024
MAX_TELEGRAM_MESSAGE_BYTES = 4000
MAX_DELIVERY_ATTEMPTS_BEFORE_UNHEALTHY = 3
MANAGED_NOTIFICATION_NAME = "Searcharr Movie Status Webhook"
WEBHOOK_URL = "http://telegram-status-sync:8081/radarr"
RETRYABLE_HTTP_STATUSES = frozenset({408, 425, 429})
LOGGER = logging.getLogger("telegram-status-sync")

EVENT_SETTINGS = {
    "onGrab": True,
    "onDownload": True,
    "onUpgrade": True,
    "onRename": False,
    "onMovieAdded": True,
    "onMovieDelete": False,
    "onMovieFileDelete": False,
    "onMovieFileDeleteForUpgrade": False,
    "onHealthIssue": False,
    "includeHealthWarnings": False,
    "onHealthRestored": False,
    "onApplicationUpdate": False,
    "onManualInteractionRequired": True,
}


class SyncError(RuntimeError):
    """An operational error safe to write to container logs."""


class PermanentDeliveryError(SyncError):
    """A recipient-specific failure that retrying cannot repair."""


@dataclasses.dataclass(frozen=True)
class SyncConfig:
    bot_token: str
    radarr_url: str
    radarr_api_key: str


@dataclasses.dataclass(frozen=True)
class SyncResult:
    created: int
    updated: int
    removed: int


@dataclasses.dataclass(frozen=True)
class Delivery:
    event_id: int
    recipient_digest: str
    message: str
    attempts: int


@dataclasses.dataclass(frozen=True)
class DeliveryResult:
    delivered: int
    failed: int
    revoked: int
    abandoned: int


def _literal_settings(settings_path: Path) -> Dict[str, object]:
    try:
        source = settings_path.read_text(encoding="utf-8")
    except OSError as error:
        raise SyncError("Searcharr settings.py is not readable") from error
    try:
        tree = ast.parse(source, filename=str(settings_path))
    except SyntaxError as error:
        raise SyncError("Searcharr settings.py is not valid Python") from error

    settings: Dict[str, object] = {}
    for statement in tree.body:
        targets: Iterable[ast.expr]
        value: Optional[ast.expr]
        if isinstance(statement, ast.Assign):
            targets = statement.targets
            value = statement.value
        elif isinstance(statement, ast.AnnAssign):
            targets = (statement.target,)
            value = statement.value
        else:
            continue
        if value is None:
            continue
        for target in targets:
            if not isinstance(target, ast.Name):
                continue
            try:
                settings[target.id] = ast.literal_eval(value)
            except (ValueError, TypeError):
                continue
    return settings


def _radarr_url(value: object) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SyncError("Radarr URL is missing from Searcharr settings")
    candidate = value.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(candidate)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise SyncError("Radarr URL is invalid in Searcharr settings")
    return candidate


def load_config(settings_path: Path) -> SyncConfig:
    settings = _literal_settings(settings_path)
    if settings.get("radarr_enabled") is not True:
        raise SyncError("Radarr is not enabled in Searcharr settings")
    bot_token = settings.get("tgram_token")
    api_key = settings.get("radarr_api_key")
    if not isinstance(bot_token, str) or not bot_token.strip():
        raise SyncError("Telegram bot token is missing from Searcharr settings")
    if not isinstance(api_key, str) or not api_key.strip():
        raise SyncError("Radarr API key is missing from Searcharr settings")
    return SyncConfig(
        bot_token=bot_token.strip(),
        radarr_url=_radarr_url(settings.get("radarr_url")),
        radarr_api_key=api_key.strip(),
    )


def read_authorized_chat_ids(database_path: Path) -> List[str]:
    encoded_path = urllib.parse.quote(str(database_path), safe="/:")
    database_uri = f"file:{encoded_path}?mode=ro"
    try:
        with sqlite3.connect(database_uri, uri=True, timeout=5) as connection:
            connection.execute("PRAGMA query_only = ON")
            columns = {
                row[1] for row in connection.execute("PRAGMA table_info(users)")
            }
            if "id" not in columns:
                raise SyncError(
                    "Searcharr users table does not contain the expected id column"
                )
            rows = connection.execute("SELECT id FROM users").fetchall()
    except sqlite3.Error as error:
        raise SyncError(
            f"could not read Searcharr users database ({type(error).__name__})"
        ) from error

    chat_ids: Set[str] = set()
    for row in rows:
        value = row[0]
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            raise SyncError("Searcharr users table contains an invalid user id")
        chat_id = str(value).strip()
        if not chat_id or not re.fullmatch(r"-?[0-9]+", chat_id):
            raise SyncError("Searcharr users table contains an invalid user id")
        chat_ids.add(chat_id)
    return sorted(chat_ids, key=int)


def recipient_digest(chat_id: str) -> str:
    return hashlib.sha256(
        f"searcharr-movie-status:{chat_id}".encode("utf-8")
    ).hexdigest()


class EventStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with sqlite3.connect(path, timeout=10) as connection:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        message TEXT NOT NULL,
                        created_at REAL NOT NULL
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS seen_events (
                        dedupe_key TEXT PRIMARY KEY,
                        seen_at REAL NOT NULL
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS recipient_cache (
                        recipient_digest TEXT PRIMARY KEY
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS metadata (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS deliveries (
                        event_id INTEGER NOT NULL,
                        recipient_digest TEXT NOT NULL,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        next_attempt_at REAL NOT NULL DEFAULT 0,
                        claimed_until REAL NOT NULL DEFAULT 0,
                        PRIMARY KEY (event_id, recipient_digest),
                        FOREIGN KEY (event_id) REFERENCES events(id)
                            ON DELETE CASCADE
                    )
                    """
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not initialize status event store ({type(error).__name__})"
            ) from error

    def enqueue(
        self,
        message: str,
        recipient_digests: Sequence[str],
        dedupe_key: str,
        *,
        clock: Callable[[], float] = time.time,
    ) -> int:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                inserted = connection.execute(
                    """
                    INSERT OR IGNORE INTO seen_events (dedupe_key, seen_at)
                    VALUES (?, ?)
                    """,
                    (dedupe_key, clock()),
                ).rowcount
                if inserted == 0 or not recipient_digests:
                    return 0
                cursor = connection.execute(
                    "INSERT INTO events (message, created_at) VALUES (?, ?)",
                    (message, clock()),
                )
                event_id = int(cursor.lastrowid)
                connection.executemany(
                    """
                    INSERT INTO deliveries
                        (
                            event_id, recipient_digest, attempts,
                            next_attempt_at, claimed_until
                        )
                    VALUES (?, ?, 0, 0, 0)
                    """,
                    [(event_id, digest) for digest in recipient_digests],
                )
                return event_id
        except sqlite3.Error as error:
            raise SyncError(
                f"could not persist status event ({type(error).__name__})"
            ) from error

    def mark_seen(
        self,
        dedupe_keys: Sequence[str],
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                connection.executemany(
                    """
                    INSERT OR IGNORE INTO seen_events (dedupe_key, seen_at)
                    VALUES (?, ?)
                    """,
                    [(key, clock()) for key in dedupe_keys],
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not baseline status history ({type(error).__name__})"
            ) from error

    def cache_recipients(self, recipient_digests: Sequence[str]) -> None:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                connection.execute("DELETE FROM recipient_cache")
                connection.executemany(
                    """
                    INSERT INTO recipient_cache (recipient_digest)
                    VALUES (?)
                    """,
                    [(digest,) for digest in recipient_digests],
                )
                connection.execute(
                    """
                    INSERT INTO metadata (key, value)
                    VALUES ('recipient_cache_initialized', '1')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not cache status recipients ({type(error).__name__})"
            ) from error

    def cached_recipients(self) -> List[str]:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                initialized = connection.execute(
                    """
                    SELECT value FROM metadata
                    WHERE key = 'recipient_cache_initialized'
                    """
                ).fetchone()
                if initialized is None:
                    raise SyncError("status recipient cache is not initialized")
                return [
                    str(row[0])
                    for row in connection.execute(
                        """
                        SELECT recipient_digest FROM recipient_cache
                        ORDER BY recipient_digest
                        """
                    ).fetchall()
                ]
        except sqlite3.Error as error:
            raise SyncError(
                f"could not read cached status recipients ({type(error).__name__})"
            ) from error

    def metadata(self, key: str) -> Optional[str]:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                row = connection.execute(
                    "SELECT value FROM metadata WHERE key = ?",
                    (key,),
                ).fetchone()
                return None if row is None else str(row[0])
        except sqlite3.Error as error:
            raise SyncError(
                f"could not read status metadata ({type(error).__name__})"
            ) from error

    def set_metadata(self, key: str, value: str) -> None:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                connection.execute(
                    """
                    INSERT INTO metadata (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    (key, value),
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not write status metadata ({type(error).__name__})"
            ) from error

    def revoke_missing(self, valid_digests: Set[str]) -> int:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                rows = connection.execute(
                    "SELECT DISTINCT recipient_digest FROM deliveries"
                ).fetchall()
                missing = [
                    str(row[0])
                    for row in rows
                    if str(row[0]) not in valid_digests
                ]
                for digest in missing:
                    connection.execute(
                        "DELETE FROM deliveries WHERE recipient_digest = ?",
                        (digest,),
                    )
                self._delete_completed_events(connection)
                return len(missing)
        except sqlite3.Error as error:
            raise SyncError(
                f"could not reconcile revoked recipients ({type(error).__name__})"
            ) from error

    def due(self, now: float, limit: int = 100) -> List[Delivery]:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                connection.execute("BEGIN IMMEDIATE")
                rows = connection.execute(
                    """
                    SELECT d.event_id, d.recipient_digest, e.message, d.attempts
                    FROM deliveries d
                    JOIN events e ON e.id = d.event_id
                    WHERE d.next_attempt_at <= ? AND d.claimed_until <= ?
                    ORDER BY e.created_at, d.event_id, d.recipient_digest
                    LIMIT ?
                    """,
                    (now, now, limit),
                ).fetchall()
                connection.executemany(
                    """
                    UPDATE deliveries SET claimed_until = ?
                    WHERE event_id = ? AND recipient_digest = ?
                    """,
                    [
                        (now + 60, int(row[0]), str(row[1]))
                        for row in rows
                    ],
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not read pending status events ({type(error).__name__})"
            ) from error
        return [
            Delivery(
                event_id=int(row[0]),
                recipient_digest=str(row[1]),
                message=str(row[2]),
                attempts=int(row[3]),
            )
            for row in rows
        ]

    def mark_delivered(self, delivery: Delivery) -> None:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                connection.execute(
                    """
                    DELETE FROM deliveries
                    WHERE event_id = ? AND recipient_digest = ?
                    """,
                    (delivery.event_id, delivery.recipient_digest),
                )
                self._delete_completed_events(connection)
        except sqlite3.Error as error:
            raise SyncError(
                f"could not complete status delivery ({type(error).__name__})"
            ) from error

    def mark_retry(
        self,
        delivery: Delivery,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        attempts = delivery.attempts + 1
        delay = min(300, 2 ** min(attempts, 8))
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                connection.execute(
                    """
                    UPDATE deliveries
                    SET attempts = ?, next_attempt_at = ?, claimed_until = 0
                    WHERE event_id = ? AND recipient_digest = ?
                    """,
                    (
                        attempts,
                        clock() + delay,
                        delivery.event_id,
                        delivery.recipient_digest,
                    ),
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not schedule status retry ({type(error).__name__})"
            ) from error

    def pending_count(self) -> int:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                return int(
                    connection.execute(
                        "SELECT COUNT(*) FROM deliveries"
                    ).fetchone()[0]
                )
        except sqlite3.Error as error:
            raise SyncError(
                f"could not count pending status events ({type(error).__name__})"
            ) from error

    def stuck_count(self, minimum_attempts: int) -> int:
        try:
            with sqlite3.connect(self.path, timeout=10) as connection:
                return int(
                    connection.execute(
                        "SELECT COUNT(*) FROM deliveries WHERE attempts >= ?",
                        (minimum_attempts,),
                    ).fetchone()[0]
                )
        except sqlite3.Error:
            return minimum_attempts

    @staticmethod
    def _delete_completed_events(connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            DELETE FROM events
            WHERE NOT EXISTS (
                SELECT 1 FROM deliveries WHERE deliveries.event_id = events.id
            )
            """
        )


class HttpTransport:
    def __init__(
        self,
        *,
        timeout_seconds: int = DEFAULT_HTTP_TIMEOUT_SECONDS,
        attempts: int = DEFAULT_HTTP_ATTEMPTS,
        opener: Callable[..., object] = urllib.request.urlopen,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        if timeout_seconds <= 0 or attempts <= 0:
            raise ValueError("HTTP timeout and attempts must be positive")
        self.timeout_seconds = timeout_seconds
        self.attempts = attempts
        self.opener = opener
        self.sleeper = sleeper

    @staticmethod
    def _network_error_name(error: BaseException) -> str:
        if isinstance(error, urllib.error.URLError):
            return type(error.reason).__name__
        return type(error).__name__

    def request(
        self,
        *,
        method: str,
        url: str,
        operation: str,
        headers: Optional[Dict[str, str]] = None,
        body: Optional[bytes] = None,
        allow_retries: bool = True,
    ) -> bytes:
        last_error: Optional[SyncError] = None
        for attempt in range(1, self.attempts + 1):
            retryable = allow_retries
            try:
                request = urllib.request.Request(
                    url=url,
                    data=body,
                    headers=headers or {},
                    method=method,
                )
                with self.opener(
                    request, timeout=self.timeout_seconds
                ) as response:
                    status = getattr(response, "status", response.getcode())
                    response_body = response.read()
                    if not 200 <= status < 300:
                        raise SyncError(f"{operation} returned HTTP {status}")
                    return response_body
            except urllib.error.HTTPError as error:
                if (
                    operation == "Telegram movie-status sendMessage"
                    and error.code in {400, 403}
                ):
                    last_error = PermanentDeliveryError(
                        "Telegram movie-status recipient is unavailable"
                    )
                else:
                    last_error = SyncError(
                        f"{operation} returned HTTP {error.code}"
                    )
                retryable = allow_retries and (
                    error.code in RETRYABLE_HTTP_STATUSES or error.code >= 500
                )
                if error.fp is not None:
                    error.close()
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                last_error = SyncError(
                    f"{operation} failed ({self._network_error_name(error)})"
                )
                if isinstance(error, urllib.error.URLError) and isinstance(
                    error.reason, socket.gaierror
                ):
                    retryable = False
            except (ValueError, http.client.HTTPException, SyncError) as error:
                last_error = (
                    error
                    if isinstance(error, SyncError)
                    else SyncError(
                        f"{operation} failed ({type(error).__name__})"
                    )
                )
                retryable = False
            if not retryable or attempt == self.attempts:
                break
            delay_seconds = 2 ** (attempt - 1)
            LOGGER.warning(
                "%s attempt %d/%d failed; retrying in %d second(s)",
                operation,
                attempt,
                self.attempts,
                delay_seconds,
            )
            self.sleeper(delay_seconds)
        if last_error is None:
            raise SyncError(f"{operation} failed without an error response")
        raise last_error

    def request_json(
        self,
        *,
        method: str,
        url: str,
        operation: str,
        api_key: str,
        payload: Optional[object] = None,
        allow_retries: bool = True,
    ) -> object:
        headers = {
            "X-Api-Key": api_key,
            "User-Agent": "telegram-status-sync/1",
        }
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload).encode("utf-8")
        response_body = self.request(
            method=method,
            url=url,
            operation=operation,
            headers=headers,
            body=body,
            allow_retries=allow_retries,
        )
        if not response_body:
            return None
        try:
            return json.loads(response_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SyncError(f"{operation} returned invalid JSON") from error

    def post_form(
        self,
        *,
        url: str,
        operation: str,
        fields: Dict[str, str],
    ) -> object:
        response_body = self.request(
            method="POST",
            url=url,
            operation=operation,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "telegram-status-sync/1",
            },
            body=urllib.parse.urlencode(fields).encode("utf-8"),
        )
        try:
            return json.loads(response_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SyncError(f"{operation} returned invalid JSON") from error


class RadarrClient:
    def __init__(self, config: SyncConfig, transport: HttpTransport) -> None:
        self.config = config
        self.transport = transport

    def _request(
        self,
        method: str,
        path: str,
        operation: str,
        payload: Optional[object] = None,
        *,
        allow_retries: bool = True,
    ) -> object:
        return self.transport.request_json(
            method=method,
            url=f"{self.config.radarr_url}/api/v3{path}",
            operation=operation,
            api_key=self.config.radarr_api_key,
            payload=payload,
            allow_retries=allow_retries,
        )

    def webhook_schema(self) -> Dict[str, object]:
        schemas = self._request(
            "GET",
            "/notification/schema",
            "Radarr notification schema query",
        )
        if not isinstance(schemas, list):
            raise SyncError("Radarr returned malformed notification schemas")
        for schema in schemas:
            if (
                isinstance(schema, dict)
                and schema.get("implementation") == "Webhook"
            ):
                return schema
        raise SyncError("Radarr did not return a webhook notification schema")

    def notifications(self) -> List[Dict[str, object]]:
        notifications = self._request(
            "GET",
            "/notification",
            "Radarr notification query",
        )
        if not isinstance(notifications, list) or not all(
            isinstance(item, dict) for item in notifications
        ):
            raise SyncError("Radarr returned malformed notifications")
        return notifications

    @staticmethod
    def _records(response: object, operation: str) -> List[Dict[str, object]]:
        if not isinstance(response, dict):
            raise SyncError(f"Radarr returned malformed {operation}")
        records = response.get("records")
        if not isinstance(records, list) or not all(
            isinstance(item, dict) for item in records
        ):
            raise SyncError(f"Radarr returned malformed {operation} records")
        return records

    def history_since(
        self,
        last_history_id: Optional[int],
    ) -> List[Dict[str, object]]:
        page = 1
        page_size = 250
        recovered: List[Dict[str, object]] = []
        while True:
            response = self._request(
                "GET",
                (
                    f"/history?page={page}&pageSize={page_size}&sortKey=date"
                    "&sortDirection=descending&includeMovie=true"
                ),
                "Radarr history query",
            )
            records = self._records(response, "history")
            if last_history_id is None:
                return records
            stop = False
            for record in records:
                history_id = record.get("id")
                if isinstance(history_id, int) and history_id > last_history_id:
                    recovered.append(record)
                else:
                    stop = True
            if stop or len(records) < page_size:
                return recovered
            page += 1

    def queue(self) -> List[Dict[str, object]]:
        page = 1
        page_size = 250
        records: List[Dict[str, object]] = []
        while True:
            response = self._request(
                "GET",
                (
                    f"/queue?page={page}&pageSize={page_size}"
                    "&includeUnknownMovieItems=true&includeMovie=true"
                ),
                "Radarr queue query",
            )
            page_records = self._records(response, "queue")
            records.extend(page_records)
            if len(page_records) < page_size:
                return records
            page += 1

    def create(self, payload: Dict[str, object]) -> None:
        self._request(
            "POST",
            "/notification",
            "Radarr status webhook creation",
            payload,
            allow_retries=False,
        )

    def update(self, notification_id: int, payload: Dict[str, object]) -> None:
        self._request(
            "PUT",
            f"/notification/{notification_id}",
            "Radarr status webhook update",
            payload,
        )

    def delete(self, notification_id: int) -> None:
        self._request(
            "DELETE",
            f"/notification/{notification_id}",
            "Radarr status webhook deletion",
        )


def _set_field(fields: object, field_name: str, value: object) -> None:
    if not isinstance(fields, list):
        raise SyncError("Radarr webhook schema has malformed fields")
    for field in fields:
        if isinstance(field, dict) and field.get("name") == field_name:
            field["value"] = value
            return
    raise SyncError(f"Radarr webhook schema is missing {field_name}")


def build_webhook_payload(schema: Dict[str, object]) -> Dict[str, object]:
    payload = copy.deepcopy(schema)
    payload["name"] = MANAGED_NOTIFICATION_NAME
    payload["enable"] = True
    payload["tags"] = []
    payload.update(EVENT_SETTINGS)
    fields = payload.get("fields")
    _set_field(fields, "url", WEBHOOK_URL)
    _set_field(fields, "method", 1)
    _set_field(fields, "username", None)
    _set_field(fields, "password", None)
    _set_field(fields, "headers", [])
    return payload


def _field_values(notification: Dict[str, object]) -> Dict[str, object]:
    fields = notification.get("fields")
    if not isinstance(fields, list):
        return {}
    return {
        str(field.get("name")): field.get("value")
        for field in fields
        if isinstance(field, dict) and isinstance(field.get("name"), str)
    }


def webhook_matches(
    existing: Dict[str, object],
    desired: Dict[str, object],
) -> bool:
    if (
        existing.get("name") != MANAGED_NOTIFICATION_NAME
        or existing.get("implementation") != "Webhook"
        or existing.get("enable") is False
        or sorted(existing.get("tags") or []) != []
    ):
        return False
    for key, value in EVENT_SETTINGS.items():
        if existing.get(key) != value:
            return False
    existing_fields = _field_values(existing)
    desired_fields = _field_values(desired)
    for field_name in ("url", "method", "username", "password", "headers"):
        if existing_fields.get(field_name) != desired_fields.get(field_name):
            return False
    return True


def _notification_id(notification: Dict[str, object]) -> int:
    notification_id = notification.get("id")
    if isinstance(notification_id, bool) or not isinstance(notification_id, int):
        raise SyncError("managed Radarr notification has an invalid id")
    return notification_id


def _is_managed_webhook(notification: Dict[str, object]) -> bool:
    return (
        notification.get("name") == MANAGED_NOTIFICATION_NAME
        or (
            notification.get("implementation") == "Webhook"
            and _field_values(notification).get("url") == WEBHOOK_URL
        )
    )


def synchronize_webhook(client: RadarrClient) -> SyncResult:
    desired = build_webhook_payload(client.webhook_schema())
    managed = [
        notification
        for notification in client.notifications()
        if _is_managed_webhook(notification)
    ]
    managed.sort(key=_notification_id)
    removed = 0
    for duplicate in managed[1:]:
        client.delete(_notification_id(duplicate))
        removed += 1
    if not managed:
        client.create(desired)
        return SyncResult(created=1, updated=0, removed=removed)
    primary = managed[0]
    if not webhook_matches(primary, desired):
        notification_id = _notification_id(primary)
        desired["id"] = notification_id
        client.update(notification_id, desired)
        return SyncResult(created=0, updated=1, removed=removed)
    return SyncResult(created=0, updated=0, removed=removed)


def _movie(payload: Dict[str, object]) -> Dict[str, object]:
    for key in ("movie", "remoteMovie"):
        value = payload.get(key)
        if isinstance(value, dict):
            return value
    return {}


def _title(payload: Dict[str, object]) -> str:
    movie = _movie(payload)
    title = movie.get("title")
    year = movie.get("year")
    if isinstance(title, str) and title.strip():
        if isinstance(year, int) and year > 0:
            return f"{title.strip()} ({year})"
        return title.strip()
    return "Unknown movie"


def _metadata_link(payload: Dict[str, object]) -> Optional[str]:
    tmdb_id = _movie(payload).get("tmdbId")
    if isinstance(tmdb_id, int) and tmdb_id > 0:
        return f"https://www.themoviedb.org/movie/{tmdb_id}"
    return None


def _quality(payload: Dict[str, object]) -> Optional[str]:
    for parent in ("release", "movieFile", "downloadInfo"):
        value = payload.get(parent)
        if isinstance(value, dict):
            quality = value.get("quality")
            if isinstance(quality, str) and quality:
                return quality
    return None


def _normalized_status_messages(value: object) -> List[str]:
    details = []
    if isinstance(value, list):
        for item in value:
            if not isinstance(item, dict):
                continue
            messages = item.get("messages")
            if isinstance(messages, list):
                details.extend(
                    message.strip()
                    for message in messages
                    if isinstance(message, str) and message.strip()
                )
    return sorted(set(details))


def format_event(payload: Dict[str, object]) -> str:
    event_type = str(payload.get("eventType", "")).lower()
    title = _title(payload)
    quality = _quality(payload)
    if event_type == "test":
        return "Radarr movie status notifications are connected."
    if event_type == "movieadded":
        headline = f"Added to Radarr: {title}"
    elif event_type == "grab":
        headline = f"Download started: {title}"
    elif event_type == "download":
        action = "Upgrade ready" if payload.get("isUpgrade") is True else "Ready to watch"
        headline = f"{action}: {title}"
    elif event_type == "manualinteractionrequired":
        headline = f"Action needed: {title}"
    else:
        raise SyncError("unsupported Radarr webhook event")
    lines = [headline]
    if quality:
        lines.append(f"Quality: {quality}")
    if event_type == "manualinteractionrequired":
        details = _normalized_status_messages(
            payload.get("downloadStatusMessages")
        )
        if details:
            lines.append("Reason: " + "; ".join(details))
    metadata_link = _metadata_link(payload)
    if metadata_link:
        lines.append(metadata_link)
    return "\n".join(lines)[:MAX_TELEGRAM_MESSAGE_BYTES]


def event_dedupe_key(payload: Dict[str, object]) -> str:
    event_type = str(payload.get("eventType", "")).lower()
    download_id = payload.get("downloadId")
    if isinstance(download_id, str) and download_id:
        if event_type == "grab":
            return f"grab:{download_id.upper()}"
        if event_type == "download":
            return f"download:{download_id.upper()}"
        if event_type == "manualinteractionrequired":
            detail_hash = hashlib.sha256(
                json.dumps(
                    _normalized_status_messages(
                        payload.get("downloadStatusMessages")
                    ),
                    sort_keys=True,
                ).encode("utf-8")
            ).hexdigest()[:16]
            return f"manual:{download_id.upper()}:{detail_hash}"
    queue_id = payload.get("queueId")
    if event_type == "manualinteractionrequired" and isinstance(queue_id, int):
        return f"manualqueue:{queue_id}"
    movie_id = _movie(payload).get("id")
    if event_type == "movieadded" and isinstance(movie_id, int):
        return f"movieadded:{movie_id}"
    if event_type == "test":
        return "test:connector"
    payload_hash = hashlib.sha256(
        json.dumps(payload, sort_keys=True).encode("utf-8")
    ).hexdigest()
    return f"{event_type}:{payload_hash}"


def _history_payload(record: Dict[str, object]) -> Optional[Dict[str, object]]:
    event_type = str(record.get("eventType", "")).lower()
    quality = record.get("quality")
    quality_name = None
    if isinstance(quality, dict):
        quality_value = quality.get("quality")
        if isinstance(quality_value, dict):
            quality_name = quality_value.get("name")
    common = {
        "movie": record.get("movie"),
        "downloadId": record.get("downloadId"),
    }
    if event_type == "grabbed":
        return {
            **common,
            "eventType": "Grab",
            "release": {"quality": quality_name},
        }
    if event_type == "downloadfolderimported":
        return {
            **common,
            "eventType": "Download",
            "movieFile": {"quality": quality_name},
            "isUpgrade": False,
        }
    return None


def _queue_payload(record: Dict[str, object]) -> Optional[Dict[str, object]]:
    status_messages = record.get("statusMessages")
    messages = []
    if isinstance(status_messages, list):
        messages = [
            item
            for item in status_messages
            if isinstance(item, dict) and item.get("messages")
        ]
    tracked_status = str(record.get("trackedDownloadStatus", "")).lower()
    if not messages and tracked_status not in {"warning", "error"}:
        return None
    quality_name = None
    quality = record.get("quality")
    if isinstance(quality, dict):
        quality_value = quality.get("quality")
        if isinstance(quality_value, dict):
            quality_name = quality_value.get("name")
    return {
        "eventType": "ManualInteractionRequired",
        "movie": record.get("movie"),
        "downloadId": record.get("downloadId"),
        "queueId": record.get("id"),
        "downloadInfo": {"quality": quality_name},
        "downloadStatusMessages": messages,
    }


def _recover_records(
    store: EventStore,
    records: Sequence[Dict[str, object]],
    recipient_digests: Sequence[str],
    *,
    metadata_key: str,
    payload_builder: Callable[
        [Dict[str, object]], Optional[Dict[str, object]]
    ],
) -> int:
    candidates = []
    for record in records:
        payload = payload_builder(record)
        if payload is not None:
            candidates.append(
                (
                    event_dedupe_key(payload),
                    format_event(payload),
                )
            )
    if store.metadata(metadata_key) is None:
        store.mark_seen([key for key, _ in candidates])
        store.set_metadata(metadata_key, "1")
        return 0
    recovered = 0
    for dedupe_key, message in reversed(candidates):
        if store.enqueue(message, recipient_digests, dedupe_key):
            recovered += 1
    return recovered


def recover_radarr_state(
    client: RadarrClient,
    store: EventStore,
    recipient_digests: Sequence[str],
) -> int:
    raw_history_id = store.metadata("history_max_id")
    try:
        last_history_id = (
            None if raw_history_id is None else int(raw_history_id)
        )
    except ValueError as error:
        raise SyncError("status history cursor is invalid") from error
    history_records = client.history_since(last_history_id)
    history_candidates = []
    history_ids = []
    for record in history_records:
        history_id = record.get("id")
        if isinstance(history_id, int):
            history_ids.append(history_id)
        payload = _history_payload(record)
        if payload is not None:
            history_candidates.append(
                (event_dedupe_key(payload), format_event(payload))
            )
    recovered = 0
    if last_history_id is None:
        store.mark_seen([key for key, _ in history_candidates])
    else:
        for dedupe_key, message in reversed(history_candidates):
            if store.enqueue(message, recipient_digests, dedupe_key):
                recovered += 1
    if history_ids:
        store.set_metadata("history_max_id", str(max(history_ids)))
    elif last_history_id is None:
        store.set_metadata("history_max_id", "0")

    recovered += _recover_records(
        store,
        client.queue(),
        recipient_digests,
        metadata_key="queue_initialized",
        payload_builder=_queue_payload,
    )
    return recovered


class TelegramNotifier:
    def __init__(self, transport: HttpTransport) -> None:
        self.transport = transport

    def send(self, bot_token: str, chat_id: str, message: str) -> None:
        response = self.transport.post_form(
            url=f"https://api.telegram.org/bot{bot_token}/sendMessage",
            operation="Telegram movie-status sendMessage",
            fields={"chat_id": chat_id, "text": message},
        )
        if not isinstance(response, dict) or response.get("ok") is not True:
            if (
                isinstance(response, dict)
                and response.get("error_code") in {400, 403}
            ):
                raise PermanentDeliveryError(
                    "Telegram movie-status recipient is unavailable"
                )
            raise SyncError("Telegram movie-status response was not successful")


def deliver_due(
    store: EventStore,
    config: SyncConfig,
    chat_ids: Sequence[str],
    notifier: TelegramNotifier,
    *,
    clock: Callable[[], float] = time.time,
) -> DeliveryResult:
    chat_by_digest = {
        recipient_digest(chat_id): chat_id for chat_id in chat_ids
    }
    revoked = store.revoke_missing(set(chat_by_digest))
    delivered = 0
    failed = 0
    abandoned = 0
    for delivery in store.due(clock()):
        chat_id = chat_by_digest.get(delivery.recipient_digest)
        if chat_id is None:
            continue
        try:
            notifier.send(config.bot_token, chat_id, delivery.message)
            store.mark_delivered(delivery)
            delivered += 1
        except PermanentDeliveryError:
            store.mark_delivered(delivery)
            abandoned += 1
        except SyncError:
            store.mark_retry(delivery, clock=clock)
            failed += 1
    return DeliveryResult(
        delivered=delivered,
        failed=failed,
        revoked=revoked,
        abandoned=abandoned,
    )


class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "telegram-status-sync"

    def log_message(self, format_string: str, *args: object) -> None:
        return

    def _respond(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self) -> None:
        self._respond(200, b"ok\n") if self.path == "/health" else self._respond(404)

    def do_POST(self) -> None:
        if self.path != "/radarr":
            self._respond(404)
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._respond(400)
            return
        if content_length <= 0 or content_length > MAX_WEBHOOK_BYTES:
            self._respond(413)
            return
        try:
            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
            if not isinstance(payload, dict) or not payload.get("eventType"):
                raise ValueError
            message = format_event(payload)
            recipient_digests = self.server.store.cached_recipients()
            self.server.store.enqueue(
                message,
                recipient_digests,
                event_dedupe_key(payload),
            )
            self.server.wake_worker.set()
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, SyncError):
            self._respond(503)
            return
        self._respond(200, b"accepted\n")


class StatusServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple,
        store: EventStore,
        wake_worker: threading.Event,
    ) -> None:
        super().__init__(server_address, WebhookHandler)
        self.store = store
        self.wake_worker = wake_worker


def _write_heartbeat(path: Path, clock: Callable[[], float] = time.time) -> None:
    temporary_path = path.with_suffix(".tmp")
    try:
        temporary_path.write_text(f"{clock():.6f}\n", encoding="ascii")
        os.replace(temporary_path, path)
    except OSError as error:
        raise SyncError("could not write status heartbeat") from error


def _event_worker(
    store: EventStore,
    settings_path: Path,
    database_path: Path,
    notifier: TelegramNotifier,
    heartbeat_path: Path,
    wake_worker: threading.Event,
) -> None:
    while True:
        try:
            config = load_config(settings_path)
            chat_ids = read_authorized_chat_ids(database_path)
            store.cache_recipients(
                [recipient_digest(chat_id) for chat_id in chat_ids]
            )
            result = deliver_due(store, config, chat_ids, notifier)
            _write_heartbeat(heartbeat_path)
            if (
                result.delivered
                or result.failed
                or result.revoked
                or result.abandoned
            ):
                LOGGER.info(
                    "processed status deliveries: delivered=%d failed=%d "
                    "revoked=%d unavailable=%d",
                    result.delivered,
                    result.failed,
                    result.revoked,
                    result.abandoned,
                )
        except SyncError as error:
            LOGGER.error("status delivery worker failed: %s", error)
        wake_worker.wait(timeout=1)
        wake_worker.clear()


def _heartbeat_is_fresh(path: Path, max_age: int, now: float) -> bool:
    try:
        heartbeat = float(path.read_text(encoding="ascii").strip())
    except (OSError, UnicodeError, ValueError):
        return False
    return 0 <= now - heartbeat <= max_age


def healthcheck(
    sync_heartbeat_path: Path,
    worker_heartbeat_path: Path,
    settings_path: Path,
    database_path: Path,
    state_path: Path,
    *,
    listen_port: int,
    max_age_seconds: int,
    proc_cmdline_path: Path = Path("/proc/1/cmdline"),
    clock: Callable[[], float] = time.time,
    opener: Callable[..., object] = urllib.request.urlopen,
) -> bool:
    try:
        cmdline = proc_cmdline_path.read_bytes()
        now = clock()
        if (
            b"telegram-status-sync" not in cmdline
            or not _heartbeat_is_fresh(
                sync_heartbeat_path, max_age_seconds, now
            )
            or not _heartbeat_is_fresh(
                worker_heartbeat_path, max_age_seconds, now
            )
        ):
            return False
        load_config(settings_path)
        read_authorized_chat_ids(database_path)
        if (
            EventStore(state_path).stuck_count(
                MAX_DELIVERY_ATTEMPTS_BEFORE_UNHEALTHY
            )
            > 0
        ):
            return False
        with opener(
            f"http://127.0.0.1:{listen_port}/health", timeout=3
        ) as response:
            return 200 <= response.getcode() < 300
    except (OSError, SyncError, urllib.error.URLError, TimeoutError):
        return False


def _exit_on_signal(signum: int, frame: object) -> None:
    LOGGER.info("received shutdown signal; exiting")
    raise SystemExit(0)


def _install_signal_handlers() -> None:
    signal.signal(signal.SIGTERM, _exit_on_signal)
    signal.signal(signal.SIGINT, _exit_on_signal)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings-path", type=Path, default=DEFAULT_SETTINGS_PATH)
    parser.add_argument("--database-path", type=Path, default=DEFAULT_DATABASE_PATH)
    parser.add_argument("--state-path", type=Path, default=DEFAULT_STATE_PATH)
    parser.add_argument(
        "--sync-heartbeat-path",
        type=Path,
        default=DEFAULT_SYNC_HEARTBEAT_PATH,
    )
    parser.add_argument(
        "--worker-heartbeat-path",
        type=Path,
        default=DEFAULT_WORKER_HEARTBEAT_PATH,
    )
    parser.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    parser.add_argument("--poll-seconds", type=int, default=DEFAULT_POLL_SECONDS)
    parser.add_argument(
        "--health-max-age-seconds",
        type=int,
        default=DEFAULT_HEALTH_MAX_AGE_SECONDS,
    )
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--healthcheck", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s telegram-status-sync: %(message)s",
    )
    args = _parser().parse_args(argv)
    if (
        args.listen_port <= 0
        or args.poll_seconds <= 0
        or args.health_max_age_seconds <= 0
    ):
        LOGGER.error("port, poll, and health values must be positive")
        return 2
    if args.healthcheck:
        return (
            0
            if healthcheck(
                args.sync_heartbeat_path,
                args.worker_heartbeat_path,
                args.settings_path,
                args.database_path,
                args.state_path,
                listen_port=args.listen_port,
                max_age_seconds=args.health_max_age_seconds,
            )
            else 1
        )

    _install_signal_handlers()
    transport = HttpTransport()
    notifier = TelegramNotifier(transport)
    store = EventStore(args.state_path)
    while True:
        try:
            initial_chat_ids = read_authorized_chat_ids(args.database_path)
            store.cache_recipients(
                [recipient_digest(chat_id) for chat_id in initial_chat_ids]
            )
            break
        except SyncError as live_error:
            try:
                # A persisted cache keeps ingestion available during a
                # host-restart race where Searcharr is not readable yet.
                store.cached_recipients()
                break
            except SyncError:
                LOGGER.warning(
                    "waiting for Searcharr users before accepting webhooks: %s",
                    live_error,
                )
                time.sleep(1)
    wake_worker = threading.Event()
    server = StatusServer(
        ("0.0.0.0", args.listen_port),
        store,
        wake_worker,
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(
        target=_event_worker,
        args=(
            store,
            args.settings_path,
            args.database_path,
            notifier,
            args.worker_heartbeat_path,
            wake_worker,
        ),
        daemon=True,
    ).start()

    while True:
        try:
            config = load_config(args.settings_path)
            chat_ids = read_authorized_chat_ids(args.database_path)
            recipient_digests = [
                recipient_digest(chat_id) for chat_id in chat_ids
            ]
            store.cache_recipients(recipient_digests)
            client = RadarrClient(config, transport)
            recovered = recover_radarr_state(
                client,
                store,
                recipient_digests,
            )
            result = synchronize_webhook(client)
            _write_heartbeat(args.sync_heartbeat_path)
            if (
                args.once
                or recovered
                or result.created
                or result.updated
                or result.removed
            ):
                LOGGER.info(
                    "synchronized Radarr status: recovered=%d created=%d "
                    "updated=%d removed=%d",
                    recovered,
                    result.created,
                    result.updated,
                    result.removed,
                )
        except SyncError as error:
            LOGGER.error("status synchronization failed: %s", error)
            if args.once:
                return 1

        if args.once:
            deadline = time.time() + 15
            while store.pending_count() and time.time() < deadline:
                wake_worker.set()
                time.sleep(0.1)
            return 0 if store.pending_count() == 0 else 1
        time.sleep(args.poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
