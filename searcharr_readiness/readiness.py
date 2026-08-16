#!/usr/bin/env python3
"""Wait for Searcharr's authenticated Arr APIs before launching the bot."""

import argparse
import ast
import dataclasses
import hashlib
import http.client
import logging
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Dict, Iterable, Optional, Sequence, Tuple


DEFAULT_SETTINGS_PATH = Path("/app/data/settings.py")
DEFAULT_SEARCHARR_PATH = Path("/app/searcharr.py")
DEFAULT_READY_MARKER_PATH = Path("/tmp/searcharr-readiness.sha256")
DEFAULT_POLL_SECONDS = 5
DEFAULT_REQUEST_TIMEOUT_SECONDS = 3
LOGGER = logging.getLogger("searcharr-readiness")


class ReadinessError(RuntimeError):
    """A startup error that is safe to write to container logs."""


@dataclasses.dataclass(frozen=True)
class Dependency:
    name: str
    status_url: str
    api_key: str


def _literal_settings(settings_path: Path) -> Dict[str, object]:
    try:
        source = settings_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ReadinessError("Searcharr settings.py is not readable") from error

    try:
        tree = ast.parse(source, filename=str(settings_path))
    except SyntaxError as error:
        raise ReadinessError("Searcharr settings.py is not valid Python") from error

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


def _status_url(service_name: str, base_url: object) -> str:
    if not isinstance(base_url, str) or not base_url.strip():
        raise ReadinessError(f"{service_name} URL is missing from settings.py")

    candidate = base_url.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(candidate)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ReadinessError(f"{service_name} URL is invalid in settings.py")

    return f"{candidate}/api/v3/system/status"


def load_dependencies(settings_path: Path) -> Tuple[Dependency, ...]:
    settings = _literal_settings(settings_path)
    dependencies = []

    for prefix, display_name in (("sonarr", "Sonarr"), ("radarr", "Radarr")):
        enabled = settings.get(f"{prefix}_enabled", False)
        if not isinstance(enabled, bool):
            raise ReadinessError(
                f"{display_name} enabled setting must be true or false"
            )
        if not enabled:
            continue

        api_key = settings.get(f"{prefix}_api_key")
        if not isinstance(api_key, str) or not api_key.strip():
            raise ReadinessError(
                f"{display_name} API key is missing from settings.py"
            )

        dependencies.append(
            Dependency(
                name=display_name,
                status_url=_status_url(
                    display_name, settings.get(f"{prefix}_url")
                ),
                api_key=api_key.strip(),
            )
        )

    if not dependencies:
        raise ReadinessError("no enabled Arr services were found in settings.py")

    return tuple(dependencies)


def settings_digest(settings_path: Path) -> str:
    try:
        content = settings_path.read_bytes()
    except OSError as error:
        raise ReadinessError("Searcharr settings.py is not readable") from error
    return hashlib.sha256(content).hexdigest()


def _clear_ready_marker(marker_path: Path) -> None:
    try:
        marker_path.unlink()
    except FileNotFoundError:
        return
    except OSError as error:
        raise ReadinessError("could not clear Searcharr readiness marker") from error


def _write_ready_marker(settings_path: Path, marker_path: Path) -> None:
    digest = settings_digest(settings_path)
    try:
        marker_path.write_text(f"{digest}\n", encoding="ascii")
    except OSError as error:
        raise ReadinessError("could not write Searcharr readiness marker") from error


def _ready_marker_matches(settings_path: Path, marker_path: Path) -> bool:
    try:
        recorded_digest = marker_path.read_text(encoding="ascii").strip()
        return recorded_digest == settings_digest(settings_path)
    except (OSError, UnicodeError, ReadinessError):
        return False


def dependency_is_ready(
    dependency: Dependency,
    *,
    timeout_seconds: int,
    opener: Callable[..., object] = urllib.request.urlopen,
) -> bool:
    request = urllib.request.Request(
        dependency.status_url,
        headers={
            "X-Api-Key": dependency.api_key,
            "User-Agent": "searcharr-readiness/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=timeout_seconds) as response:
            status = getattr(response, "status", response.getcode())
            return 200 <= status < 300
    except (
        urllib.error.URLError,
        TimeoutError,
        OSError,
        ValueError,
        http.client.HTTPException,
    ):
        return False


def dependencies_are_ready(
    dependencies: Sequence[Dependency],
    *,
    timeout_seconds: int,
    probe: Callable[..., bool] = dependency_is_ready,
) -> bool:
    return all(
        probe(dependency, timeout_seconds=timeout_seconds)
        for dependency in dependencies
    )


def wait_for_dependencies(
    settings_path: Path,
    *,
    poll_seconds: int,
    timeout_seconds: int,
    loader: Callable[[Path], Tuple[Dependency, ...]] = load_dependencies,
    probe: Callable[..., bool] = dependency_is_ready,
    sleeper: Callable[[float], None] = time.sleep,
) -> Tuple[Dependency, ...]:
    last_states: Dict[str, bool] = {}
    last_configuration_error: Optional[str] = None

    while True:
        try:
            dependencies = loader(settings_path)
            last_configuration_error = None
        except ReadinessError as error:
            message = str(error)
            if message != last_configuration_error:
                LOGGER.warning("waiting for configuration: %s", message)
                last_configuration_error = message
            sleeper(poll_seconds)
            continue

        all_ready = True
        for dependency in dependencies:
            ready = probe(dependency, timeout_seconds=timeout_seconds)
            if last_states.get(dependency.name) != ready:
                if ready:
                    LOGGER.info("%s authenticated API is ready", dependency.name)
                else:
                    LOGGER.warning(
                        "waiting for %s authenticated API", dependency.name
                    )
                last_states[dependency.name] = ready
            all_ready = all_ready and ready

        if all_ready:
            LOGGER.info("all enabled Arr dependencies are ready")
            return dependencies

        sleeper(poll_seconds)


def _searcharr_is_pid_one(proc_cmdline_path: Path) -> bool:
    try:
        cmdline = proc_cmdline_path.read_bytes()
    except OSError:
        return False
    return b"searcharr.py" in cmdline


def healthcheck(
    settings_path: Path,
    *,
    timeout_seconds: int,
    proc_cmdline_path: Path = Path("/proc/1/cmdline"),
    ready_marker_path: Path = DEFAULT_READY_MARKER_PATH,
    loader: Callable[[Path], Tuple[Dependency, ...]] = load_dependencies,
    probe: Callable[..., bool] = dependency_is_ready,
) -> bool:
    if not _searcharr_is_pid_one(proc_cmdline_path):
        return False
    if not _ready_marker_matches(settings_path, ready_marker_path):
        return False
    try:
        dependencies = loader(settings_path)
    except ReadinessError:
        return False
    return dependencies_are_ready(
        dependencies,
        timeout_seconds=timeout_seconds,
        probe=probe,
    )


def _exit_on_signal(signum: int, frame: object) -> None:
    LOGGER.info("received shutdown signal; exiting")
    raise SystemExit(0)


def _install_signal_handlers() -> None:
    signal.signal(signal.SIGTERM, _exit_on_signal)
    signal.signal(signal.SIGINT, _exit_on_signal)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--settings-path",
        type=Path,
        default=DEFAULT_SETTINGS_PATH,
    )
    parser.add_argument(
        "--searcharr-path",
        type=Path,
        default=DEFAULT_SEARCHARR_PATH,
    )
    parser.add_argument(
        "--ready-marker-path",
        type=Path,
        default=DEFAULT_READY_MARKER_PATH,
    )
    parser.add_argument(
        "--poll-seconds",
        type=int,
        default=DEFAULT_POLL_SECONDS,
    )
    parser.add_argument(
        "--request-timeout-seconds",
        type=int,
        default=DEFAULT_REQUEST_TIMEOUT_SECONDS,
    )
    parser.add_argument("--check-once", action="store_true")
    parser.add_argument("--healthcheck", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s searcharr-readiness: %(message)s",
    )
    args = _parser().parse_args(argv)

    if args.poll_seconds <= 0 or args.request_timeout_seconds <= 0:
        LOGGER.error("poll and request timeouts must be positive")
        return 2

    if args.healthcheck:
        return (
            0
            if healthcheck(
                args.settings_path,
                timeout_seconds=args.request_timeout_seconds,
                ready_marker_path=args.ready_marker_path,
            )
            else 1
        )

    if args.check_once:
        try:
            dependencies = load_dependencies(args.settings_path)
        except ReadinessError as error:
            LOGGER.error("%s", error)
            return 1
        return (
            0
            if dependencies_are_ready(
                dependencies,
                timeout_seconds=args.request_timeout_seconds,
            )
            else 1
        )

    _install_signal_handlers()
    try:
        _clear_ready_marker(args.ready_marker_path)
        wait_for_dependencies(
            args.settings_path,
            poll_seconds=args.poll_seconds,
            timeout_seconds=args.request_timeout_seconds,
        )
        _write_ready_marker(args.settings_path, args.ready_marker_path)
    except ReadinessError as error:
        LOGGER.error("%s", error)
        return 1

    if not args.searcharr_path.is_file():
        LOGGER.error("Searcharr application is missing")
        return 1

    LOGGER.info("launching Searcharr")
    os.execv(
        sys.executable,
        [sys.executable, str(args.searcharr_path)],
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
