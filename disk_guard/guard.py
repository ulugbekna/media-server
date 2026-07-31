#!/usr/bin/env python3
"""Guard media storage by stopping active incomplete qBittorrent downloads."""

import argparse
import ast
import dataclasses
import hashlib
import http.client
import json
import logging
import os
import re
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple


GIB = 1024**3
LOW_SPACE_BYTES = 5 * GIB
RECOVERY_BYTES = 10 * GIB
DEFAULT_POLL_SECONDS = 60
DEFAULT_HEALTH_MAX_AGE_SECONDS = 300
DEFAULT_HTTP_TIMEOUT_SECONDS = 10
DEFAULT_HTTP_ATTEMPTS = 3
MAX_HTTP_RESPONSE_BYTES = 16 * 1024 * 1024
STATE_VERSION = 1

ACTIVE_INCOMPLETE_STATES = frozenset(
    {
        "checkingDL",
        "downloading",
        "forcedDL",
        "forcedMetaDL",
        "metaDL",
        "queuedDL",
        "stalledDL",
    }
)
TORRENT_HASH_RE = re.compile(r"^[0-9a-fA-F]{40,64}$")
RECIPIENT_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
RETRYABLE_HTTP_STATUSES = frozenset({408, 425, 429})

LOGGER = logging.getLogger("disk-guard")


class GuardError(RuntimeError):
    """An operational error safe to emit in logs."""


def format_gib(byte_count: int) -> str:
    return f"{byte_count / GIB:.1f} GiB"


def incident_phase(free_bytes: int, incident_active: bool) -> str:
    if incident_active:
        return "recover" if free_bytes >= RECOVERY_BYTES else "active"
    return "enter" if free_bytes < LOW_SPACE_BYTES else "normal"


def _number_field(torrent: Dict[str, object], field: str) -> Optional[float]:
    value = torrent.get(field)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GuardError(f"qBittorrent returned a non-numeric {field} field")
    return float(value)


def select_stoppable_hashes(torrents: Iterable[object]) -> List[str]:
    """Select active download-side torrents while excluding complete/seed states."""
    selected: List[str] = []
    seen: Set[str] = set()

    for torrent in torrents:
        if not isinstance(torrent, dict):
            raise GuardError("qBittorrent returned a malformed torrent entry")

        state = torrent.get("state")
        if not isinstance(state, str):
            raise GuardError("qBittorrent returned a torrent without a valid state")

        amount_left = _number_field(torrent, "amount_left")
        progress = _number_field(torrent, "progress")
        if amount_left is None and progress is None:
            raise GuardError(
                "qBittorrent returned a torrent without completion information"
            )
        if amount_left is not None and amount_left < 0:
            raise GuardError("qBittorrent returned a negative amount_left value")
        if progress is not None and not 0 <= progress <= 1:
            raise GuardError("qBittorrent returned a progress value outside 0..1")

        incomplete = (amount_left is not None and amount_left > 0) or (
            progress is not None and progress < 1
        )
        if not incomplete or state not in ACTIVE_INCOMPLETE_STATES:
            continue

        torrent_hash = torrent.get("hash")
        if not isinstance(torrent_hash, str) or not TORRENT_HASH_RE.fullmatch(
            torrent_hash
        ):
            raise GuardError(
                "qBittorrent returned an invalid hash for an active torrent"
            )
        normalized_hash = torrent_hash.lower()
        if normalized_hash not in seen:
            selected.append(normalized_hash)
            seen.add(normalized_hash)

    return selected


class HttpTransport:
    def __init__(
        self,
        *,
        timeout_seconds: int = DEFAULT_HTTP_TIMEOUT_SECONDS,
        attempts: int = DEFAULT_HTTP_ATTEMPTS,
        opener: Callable[..., object] = urllib.request.urlopen,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if attempts <= 0:
            raise ValueError("attempts must be positive")
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
        form: Optional[Dict[str, str]] = None,
    ) -> bytes:
        data = None
        headers = {"User-Agent": "media-disk-guard/1"}
        if form is not None:
            data = urllib.parse.urlencode(form).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"

        last_error: Optional[GuardError] = None
        for attempt in range(1, self.attempts + 1):
            retryable = True
            try:
                request = urllib.request.Request(
                    url=url, data=data, headers=headers, method=method
                )
                with self.opener(
                    request, timeout=self.timeout_seconds
                ) as response:
                    status = getattr(response, "status", response.getcode())
                    if not 200 <= status < 300:
                        raise GuardError(f"{operation} returned HTTP {status}")
                    body = response.read(MAX_HTTP_RESPONSE_BYTES + 1)
                    if len(body) > MAX_HTTP_RESPONSE_BYTES:
                        raise GuardError(f"{operation} response was too large")
                    return body
            except urllib.error.HTTPError as error:
                last_error = GuardError(
                    f"{operation} returned HTTP {error.code}"
                )
                retryable = (
                    error.code in RETRYABLE_HTTP_STATUSES or error.code >= 500
                )
                if error.fp is not None:
                    error.close()
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                last_error = GuardError(
                    f"{operation} failed ({self._network_error_name(error)})"
                )
                if isinstance(error, urllib.error.URLError) and isinstance(
                    error.reason, socket.gaierror
                ):
                    retryable = False
            except GuardError as error:
                last_error = error
                retryable = False
            except ValueError:
                last_error = GuardError(
                    f"{operation} request could not be constructed"
                )
                retryable = False
            except http.client.InvalidURL:
                last_error = GuardError(
                    f"{operation} request could not be constructed"
                )
                retryable = False
            except http.client.HTTPException as error:
                last_error = GuardError(
                    f"{operation} failed ({type(error).__name__})"
                )

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
            raise GuardError(f"{operation} failed without an error response")
        raise last_error


def parse_qbittorrent_urls(raw_urls: str) -> Tuple[str, ...]:
    urls: List[str] = []
    for raw_url in raw_urls.split(","):
        candidate = raw_url.strip().rstrip("/")
        if not candidate:
            continue
        parsed = urllib.parse.urlsplit(candidate)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise GuardError(
                "DISK_GUARD_QBITTORRENT_URLS contains an invalid base URL"
            )
        urls.append(candidate)

    if not urls:
        raise GuardError("DISK_GUARD_QBITTORRENT_URLS has no usable base URL")
    return tuple(dict.fromkeys(urls))


class QBittorrentClient:
    def __init__(
        self, base_urls: Sequence[str], transport: HttpTransport
    ) -> None:
        if not base_urls:
            raise ValueError("base_urls cannot be empty")
        self.base_urls = tuple(base_urls)
        self.transport = transport
        self.active_base_url: Optional[str] = None

    def _ordered_base_urls(self) -> Tuple[str, ...]:
        if self.active_base_url is None:
            return self.base_urls
        return (self.active_base_url,) + tuple(
            url for url in self.base_urls if url != self.active_base_url
        )

    def _request(
        self,
        *,
        method: str,
        path: str,
        operation: str,
        form: Optional[Dict[str, str]] = None,
    ) -> bytes:
        last_error: Optional[GuardError] = None
        for base_url in self._ordered_base_urls():
            try:
                body = self.transport.request(
                    method=method,
                    url=f"{base_url}{path}",
                    operation=operation,
                    form=form,
                )
                self.active_base_url = base_url
                return body
            except GuardError as error:
                last_error = error

        endpoint_count = len(self.base_urls)
        if last_error is None:
            raise GuardError(
                f"{operation} failed across {endpoint_count} endpoint(s)"
            )
        raise GuardError(
            f"{operation} failed across {endpoint_count} endpoint(s): "
            f"{last_error}"
        )

    def list_incomplete(self) -> List[object]:
        body = self._request(
            method="GET",
            path="/api/v2/torrents/info?filter=downloading",
            operation="qBittorrent download-side torrent query",
        )
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise GuardError(
                "qBittorrent returned invalid JSON for the incomplete-torrent query"
            ) from error
        if not isinstance(payload, list):
            raise GuardError(
                "qBittorrent returned a non-list incomplete-torrent response"
            )
        return payload

    def stop(self, torrent_hashes: Sequence[str]) -> None:
        if not torrent_hashes:
            return
        self._request(
            method="POST",
            path="/api/v2/torrents/stop",
            operation="qBittorrent v5 stop request",
            form={"hashes": "|".join(torrent_hashes)},
        )

    def stop_active_incomplete(self) -> int:
        torrent_hashes = select_stoppable_hashes(self.list_incomplete())
        self.stop(torrent_hashes)
        return len(torrent_hashes)


def read_telegram_token(settings_path: Path) -> str:
    try:
        settings_text = settings_path.read_text(encoding="utf-8")
    except OSError as error:
        raise GuardError("could not read Searcharr settings.py") from error
    try:
        settings_tree = ast.parse(settings_text, filename="settings.py")
    except SyntaxError as error:
        raise GuardError("Searcharr settings.py is not valid Python") from error

    token: Optional[str] = None
    for statement in settings_tree.body:
        targets: List[ast.expr] = []
        value: Optional[ast.expr] = None
        if isinstance(statement, ast.Assign):
            targets = statement.targets
            value = statement.value
        elif isinstance(statement, ast.AnnAssign):
            targets = [statement.target]
            value = statement.value

        if value is None or not any(
            isinstance(target, ast.Name) and target.id == "tgram_token"
            for target in targets
        ):
            continue
        if not isinstance(value, ast.Constant) or not isinstance(value.value, str):
            raise GuardError(
                "Searcharr tgram_token must be a literal string"
            )
        token = value.value.strip()

    if not token:
        raise GuardError("Searcharr tgram_token is missing or empty")
    return token


def read_authorized_chat_ids(database_path: Path) -> List[str]:
    encoded_path = urllib.parse.quote(str(database_path), safe="/:")
    database_uri = f"file:{encoded_path}?mode=ro"
    try:
        with sqlite3.connect(
            database_uri, uri=True, timeout=5
        ) as connection:
            connection.execute("PRAGMA query_only = ON")
            columns = {
                row[1] for row in connection.execute("PRAGMA table_info(users)")
            }
            if "id" not in columns:
                raise GuardError(
                    "Searcharr users table does not contain the expected id column"
                )
            rows = connection.execute("SELECT id FROM users").fetchall()
    except sqlite3.Error as error:
        raise GuardError(
            f"could not read Searcharr users database ({type(error).__name__})"
        ) from error

    chat_ids: Set[str] = set()
    for row in rows:
        value = row[0]
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            raise GuardError("Searcharr users table contains an invalid user id")
        chat_id = str(value).strip()
        if not chat_id or not re.fullmatch(r"-?[0-9]+", chat_id):
            raise GuardError("Searcharr users table contains an invalid user id")
        chat_ids.add(chat_id)

    if not chat_ids:
        raise GuardError(
            "Searcharr has no authorized users; Telegram alert was not sent"
        )
    return sorted(chat_ids, key=lambda value: int(value))


def recipient_digest(chat_id: str) -> str:
    return hashlib.sha256(
        f"media-disk-guard:{chat_id}".encode("utf-8")
    ).hexdigest()


class TelegramNotifier:
    def __init__(
        self,
        *,
        settings_path: Path,
        database_path: Path,
        transport: HttpTransport,
    ) -> None:
        self.settings_path = settings_path
        self.database_path = database_path
        self.transport = transport

    def validate(self) -> int:
        read_telegram_token(self.settings_path)
        return len(read_authorized_chat_ids(self.database_path))

    def send_all(
        self,
        message: str,
        sent_recipient_digests: Set[str],
        on_recipient_sent: Callable[[Set[str]], None],
    ) -> Tuple[int, int]:
        token = read_telegram_token(self.settings_path)
        chat_ids = read_authorized_chat_ids(self.database_path)
        newly_sent = 0

        for chat_id in chat_ids:
            digest = recipient_digest(chat_id)
            if digest in sent_recipient_digests:
                continue
            body = self.transport.request(
                method="POST",
                url=f"https://api.telegram.org/bot{token}/sendMessage",
                operation="Telegram sendMessage",
                form={"chat_id": chat_id, "text": message},
            )
            try:
                response = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise GuardError(
                    "Telegram sendMessage returned invalid JSON"
                ) from error
            if not isinstance(response, dict) or response.get("ok") is not True:
                raise GuardError(
                    "Telegram sendMessage response was not successful"
                )

            sent_recipient_digests.add(digest)
            on_recipient_sent(set(sent_recipient_digests))
            newly_sent += 1

        return len(chat_ids), newly_sent


@dataclasses.dataclass
class IncidentState:
    active: bool = False
    warning_complete: bool = False
    warning_recipients: Set[str] = dataclasses.field(default_factory=set)
    recovery_pending: bool = False
    recovery_recipients: Set[str] = dataclasses.field(default_factory=set)
    recovery_free_bytes: int = 0
    last_success_at: float = 0
    last_free_bytes: int = 0

    def to_json(self) -> Dict[str, object]:
        return {
            "version": STATE_VERSION,
            "active": self.active,
            "warning_complete": self.warning_complete,
            "warning_recipients": sorted(self.warning_recipients),
            "recovery_pending": self.recovery_pending,
            "recovery_recipients": sorted(self.recovery_recipients),
            "recovery_free_bytes": self.recovery_free_bytes,
            "last_success_at": self.last_success_at,
            "last_free_bytes": self.last_free_bytes,
        }

    @classmethod
    def from_json(cls, payload: object) -> "IncidentState":
        if not isinstance(payload, dict) or payload.get("version") != STATE_VERSION:
            raise GuardError("disk guard state file has an unsupported format")

        active = payload.get("active")
        warning_complete = payload.get("warning_complete")
        recovery_pending = payload.get("recovery_pending")
        recovery_free_bytes = payload.get("recovery_free_bytes")
        last_success_at = payload.get("last_success_at")
        last_free_bytes = payload.get("last_free_bytes")
        if not isinstance(active, bool) or not isinstance(
            warning_complete, bool
        ) or not isinstance(recovery_pending, bool):
            raise GuardError("disk guard state file has invalid flags")
        if (
            isinstance(recovery_free_bytes, bool)
            or not isinstance(recovery_free_bytes, int)
            or recovery_free_bytes < 0
        ):
            raise GuardError(
                "disk guard state file has invalid recovery free-space data"
            )
        if (
            isinstance(last_success_at, bool)
            or not isinstance(last_success_at, (int, float))
            or last_success_at < 0
        ):
            raise GuardError("disk guard state file has an invalid heartbeat")
        if (
            isinstance(last_free_bytes, bool)
            or not isinstance(last_free_bytes, int)
            or last_free_bytes < 0
        ):
            raise GuardError("disk guard state file has invalid free-space data")

        warning_recipients = cls._recipient_set(
            payload.get("warning_recipients"), "warning"
        )
        recovery_recipients = cls._recipient_set(
            payload.get("recovery_recipients"), "recovery"
        )
        if active and (recovery_pending or recovery_recipients):
            raise GuardError(
                "disk guard state file mixes active and recovery incidents"
            )
        if not active and (warning_complete or warning_recipients):
            raise GuardError(
                "disk guard state file has incident data while inactive"
            )
        if recovery_pending and recovery_free_bytes < RECOVERY_BYTES:
            raise GuardError(
                "disk guard state file has an invalid pending recovery"
            )
        if not recovery_pending and (
            recovery_recipients or recovery_free_bytes
        ):
            raise GuardError(
                "disk guard state file has stale recovery data"
            )

        return cls(
            active=active,
            warning_complete=warning_complete,
            warning_recipients=warning_recipients,
            recovery_pending=recovery_pending,
            recovery_recipients=recovery_recipients,
            recovery_free_bytes=recovery_free_bytes,
            last_success_at=float(last_success_at),
            last_free_bytes=last_free_bytes,
        )

    @staticmethod
    def _recipient_set(value: object, label: str) -> Set[str]:
        if not isinstance(value, list) or not all(
            isinstance(item, str) and RECIPIENT_DIGEST_RE.fullmatch(item)
            for item in value
        ):
            raise GuardError(
                f"disk guard state file has invalid {label} recipients"
            )
        if len(value) != len(set(value)):
            raise GuardError(
                f"disk guard state file has duplicate {label} recipients"
            )
        return set(value)


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> IncidentState:
        if not self.path.exists():
            return IncidentState()
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise GuardError("could not read disk guard state file") from error
        return IncidentState.from_json(payload)

    def save(self, state: IncidentState) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary_path = self.path.with_name(
                f".{self.path.name}.{os.getpid()}.tmp"
            )
            with temporary_path.open("w", encoding="utf-8") as state_file:
                json.dump(
                    state.to_json(),
                    state_file,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                state_file.write("\n")
                state_file.flush()
                os.fsync(state_file.fileno())
            os.replace(temporary_path, self.path)
        except OSError as error:
            raise GuardError("could not persist disk guard state file") from error


class DiskGuard:
    def __init__(
        self,
        *,
        data_path: Path,
        state_store: StateStore,
        qbittorrent: QBittorrentClient,
        notifier: TelegramNotifier,
        free_space_reader: Optional[Callable[[], int]] = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.data_path = data_path
        self.state_store = state_store
        self.qbittorrent = qbittorrent
        self.notifier = notifier
        self.free_space_reader = free_space_reader or self._read_free_space
        self.clock = clock

    def _read_free_space(self) -> int:
        try:
            stats = os.statvfs(self.data_path)
        except OSError as error:
            raise GuardError("could not inspect free space for /data") from error
        return stats.f_bavail * stats.f_frsize

    def _mark_success(
        self, state: IncidentState, free_bytes: int
    ) -> None:
        state.last_success_at = self.clock()
        state.last_free_bytes = free_bytes
        self.state_store.save(state)

    @staticmethod
    def _warning_message(
        free_bytes: int,
        stopped_count: int,
        stop_error: Optional[GuardError],
    ) -> str:
        prefix = (
            "WARNING: Media storage is critically low. "
            f"/data has {format_gib(free_bytes)} free, below the "
            f"{format_gib(LOW_SPACE_BYTES)} safety threshold. "
        )
        if stop_error is not None:
            action = (
                "The disk guard could not confirm that incomplete "
                "qBittorrent downloads were stopped; check qBittorrent "
                "immediately. "
            )
        elif stopped_count:
            action = (
                f"Stopped {stopped_count} active incomplete qBittorrent "
                "torrent(s). "
            )
        else:
            action = (
                "No active incomplete qBittorrent torrents needed stopping. "
            )
        return (
            prefix
            + action
            + "Completed and seeding torrents were not targeted. Downloads "
            "will not auto-resume; resume them manually only after freeing "
            "space."
        )

    @staticmethod
    def _recovery_message(
        recovery_free_bytes: int, current_free_bytes: int
    ) -> str:
        return (
            "RECOVERY: Media storage has recovered. "
            f"/data reached {format_gib(recovery_free_bytes)} free, meeting "
            f"the {format_gib(RECOVERY_BYTES)} recovery threshold, and "
            "currently has "
            f"{format_gib(current_free_bytes)} free. qBittorrent downloads "
            "remain stopped and require manual resume."
        )

    @staticmethod
    def _combined_error(
        *errors: Optional[GuardError],
    ) -> Optional[GuardError]:
        messages = [str(error) for error in errors if error is not None]
        if not messages:
            return None
        return GuardError("; ".join(messages))

    def _persist_warning_recipients(
        self, state: IncidentState, recipients: Set[str]
    ) -> None:
        state.warning_recipients = recipients
        self.state_store.save(state)

    def _persist_recovery_recipients(
        self, state: IncidentState, recipients: Set[str]
    ) -> None:
        state.recovery_recipients = recipients
        self.state_store.save(state)

    def _handle_low_space(
        self, state: IncidentState, free_bytes: int, entering: bool
    ) -> None:
        stopped_count = 0
        stop_error: Optional[GuardError] = None
        try:
            stopped_count = self.qbittorrent.stop_active_incomplete()
        except GuardError as error:
            stop_error = error

        state_error: Optional[GuardError] = None
        if entering:
            state.active = True
            state.warning_complete = False
            state.warning_recipients.clear()
            state.recovery_pending = False
            state.recovery_recipients.clear()
            state.recovery_free_bytes = 0
            try:
                self.state_store.save(state)
            except GuardError as error:
                state_error = error

        alert_error: Optional[GuardError] = None
        if state_error is None and not state.warning_complete:
            message = self._warning_message(
                free_bytes, stopped_count, stop_error
            )
            try:
                recipient_count, _ = self.notifier.send_all(
                    message,
                    state.warning_recipients,
                    lambda recipients: self._persist_warning_recipients(
                        state, recipients
                    ),
                )
                state.warning_complete = True
                self.state_store.save(state)
                LOGGER.warning(
                    "sent low-space warning to %d authorized user(s)",
                    recipient_count,
                )
            except GuardError as error:
                alert_error = error

        combined_error = self._combined_error(
            stop_error, state_error, alert_error
        )
        if combined_error is not None:
            raise combined_error

        self._mark_success(state, free_bytes)
        if entering or stopped_count:
            LOGGER.warning(
                "low-space guard active at %s free; stopped %d active "
                "incomplete torrent(s)",
                format_gib(free_bytes),
                stopped_count,
            )

    def _handle_recovery(
        self, state: IncidentState, free_bytes: int
    ) -> None:
        if not state.recovery_pending:
            state.active = False
            state.warning_complete = False
            state.warning_recipients.clear()
            state.recovery_pending = True
            state.recovery_recipients.clear()
            state.recovery_free_bytes = free_bytes
            self.state_store.save(state)

        recipient_count, _ = self.notifier.send_all(
            self._recovery_message(
                state.recovery_free_bytes, free_bytes
            ),
            state.recovery_recipients,
            lambda recipients: self._persist_recovery_recipients(
                state, recipients
            ),
        )

        state.recovery_pending = False
        state.recovery_recipients.clear()
        state.recovery_free_bytes = 0
        self._mark_success(state, free_bytes)
        LOGGER.info(
            "disk-space incident recovered at %s free; notified %d "
            "authorized user(s); downloads remain stopped",
            format_gib(free_bytes),
            recipient_count,
        )

    def run_once(self) -> str:
        state = self.state_store.load()
        free_bytes = self.free_space_reader()
        if free_bytes < 0:
            raise GuardError("free-space reader returned a negative value")

        if state.recovery_pending:
            if free_bytes < LOW_SPACE_BYTES:
                state.recovery_pending = False
                state.recovery_recipients.clear()
                state.recovery_free_bytes = 0
                self.state_store.save(state)
            else:
                self._handle_recovery(state, free_bytes)
                return "recover"

        phase = incident_phase(free_bytes, state.active)

        if phase == "normal":
            self._mark_success(state, free_bytes)
        elif phase == "enter":
            self._handle_low_space(state, free_bytes, entering=True)
        elif phase == "active":
            self._handle_low_space(state, free_bytes, entering=False)
        elif phase == "recover":
            self._handle_recovery(state, free_bytes)
        else:
            raise AssertionError(f"unhandled incident phase: {phase}")
        return phase

    def dry_run(self) -> None:
        free_bytes = self.free_space_reader()
        torrents = self.qbittorrent.list_incomplete()
        stoppable_count = len(select_stoppable_hashes(torrents))
        recipient_count = self.notifier.validate()
        LOGGER.info(
            "dry run: %s free on /data; %d active incomplete torrent(s) "
            "would be stopped during a low-space incident; %d authorized "
            "user(s) would be notified; no actions or state changes made",
            format_gib(free_bytes),
            stoppable_count,
            recipient_count,
        )


def check_health(
    state_store: StateStore,
    *,
    max_age_seconds: int,
    clock: Callable[[], float] = time.time,
) -> None:
    state = state_store.load()
    age_seconds = clock() - state.last_success_at
    if state.last_success_at <= 0 or age_seconds < 0:
        raise GuardError("disk guard heartbeat is missing")
    if age_seconds > max_age_seconds:
        raise GuardError(
            f"disk guard heartbeat is stale ({int(age_seconds)} seconds old)"
        )


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="validate integrations and report actions without changing anything",
    )
    mode.add_argument(
        "--test-alert",
        action="store_true",
        help="send a one-shot Telegram test alert without touching torrents/state",
    )
    mode.add_argument(
        "--healthcheck",
        action="store_true",
        help="fail if the persisted successful-check heartbeat is stale",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="run one real disk check instead of polling",
    )
    parser.add_argument(
        "--poll-seconds",
        type=_positive_int,
        default=_positive_int(
            os.environ.get(
                "DISK_GUARD_POLL_SECONDS", str(DEFAULT_POLL_SECONDS)
            )
        ),
    )
    parser.add_argument(
        "--health-max-age-seconds",
        type=_positive_int,
        default=_positive_int(
            os.environ.get(
                "DISK_GUARD_HEALTH_MAX_AGE_SECONDS",
                str(DEFAULT_HEALTH_MAX_AGE_SECONDS),
            )
        ),
    )
    return parser


def build_components() -> Tuple[DiskGuard, StateStore, TelegramNotifier]:
    data_path = Path(os.environ.get("DISK_GUARD_DATA_PATH", "/data"))
    state_path = Path(
        os.environ.get(
            "DISK_GUARD_STATE_PATH", "/state/incident-state.json"
        )
    )
    settings_path = Path(
        os.environ.get(
            "DISK_GUARD_SEARCHARR_SETTINGS",
            "/searcharr/settings.py",
        )
    )
    database_path = Path(
        os.environ.get(
            "DISK_GUARD_SEARCHARR_DATABASE",
            "/searcharr/searcharr.db",
        )
    )
    base_urls = parse_qbittorrent_urls(
        os.environ.get(
            "DISK_GUARD_QBITTORRENT_URLS",
            "http://gluetun:8080,http://qbittorrent:8080",
        )
    )

    transport = HttpTransport()
    state_store = StateStore(state_path)
    notifier = TelegramNotifier(
        settings_path=settings_path,
        database_path=database_path,
        transport=transport,
    )
    guard = DiskGuard(
        data_path=data_path,
        state_store=state_store,
        qbittorrent=QBittorrentClient(base_urls, transport),
        notifier=notifier,
    )
    return guard, state_store, notifier


def run_test_alert(notifier: TelegramNotifier) -> None:
    message = (
        "TEST: Media disk guard Telegram notifications are working. "
        "No torrents were stopped and incident state was not changed."
    )
    recipient_count, _ = notifier.send_all(message, set(), lambda _: None)
    LOGGER.info(
        "sent disk guard test alert to %d authorized user(s)",
        recipient_count,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    args = build_parser().parse_args(argv)

    try:
        guard, state_store, notifier = build_components()
        if args.healthcheck:
            check_health(
                state_store,
                max_age_seconds=args.health_max_age_seconds,
            )
            return 0
        if args.test_alert:
            run_test_alert(notifier)
            return 0
        if args.dry_run:
            guard.dry_run()
            return 0
        if args.once:
            guard.run_once()
            return 0

        LOGGER.info(
            "starting disk guard: stop below %s, recover at %s, "
            "poll every %d seconds",
            format_gib(LOW_SPACE_BYTES),
            format_gib(RECOVERY_BYTES),
            args.poll_seconds,
        )
        while True:
            try:
                guard.run_once()
            except GuardError as error:
                LOGGER.error("disk guard check failed: %s", error)
            except Exception:
                LOGGER.exception("unexpected disk guard check failure")
            time.sleep(args.poll_seconds)
    except GuardError as error:
        LOGGER.error("%s", error)
        return 1
    except Exception:
        LOGGER.exception("unexpected disk guard failure")
        return 1


if __name__ == "__main__":
    sys.exit(main())
