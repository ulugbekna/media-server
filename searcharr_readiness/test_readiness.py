import tempfile
import unittest
import urllib.error
from pathlib import Path

from searcharr_readiness.readiness import (
    Dependency,
    ReadinessError,
    _exit_on_signal,
    _write_ready_marker,
    dependency_is_ready,
    healthcheck,
    load_dependencies,
    wait_for_dependencies,
)


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def getcode(self):
        return self.status


class SearcharrReadinessTests(unittest.TestCase):
    def _settings_file(self, content):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        path = Path(temporary_directory.name) / "settings.py"
        path.write_text(content, encoding="utf-8")
        return path

    def test_loads_enabled_dependencies_from_literal_settings(self):
        path = self._settings_file(
            "\n".join(
                [
                    "sonarr_enabled = True",
                    'sonarr_url = "http://sonarr:8989"',
                    'sonarr_api_key = "sonarr-secret"',
                    "radarr_enabled = True",
                    'radarr_url = "http://radarr:7878/"',
                    'radarr_api_key = "radarr-secret"',
                ]
            )
        )

        dependencies = load_dependencies(path)

        self.assertEqual(
            [(dependency.name, dependency.status_url) for dependency in dependencies],
            [
                ("Sonarr", "http://sonarr:8989/api/v3/system/status"),
                ("Radarr", "http://radarr:7878/api/v3/system/status"),
            ],
        )

    def test_rejects_missing_enabled_service_credentials_without_exposing_them(self):
        path = self._settings_file(
            "\n".join(
                [
                    "sonarr_enabled = True",
                    'sonarr_url = "http://sonarr:8989"',
                    'sonarr_api_key = ""',
                    "radarr_enabled = False",
                ]
            )
        )

        with self.assertRaisesRegex(ReadinessError, "Sonarr API key is missing"):
            load_dependencies(path)

    def test_probe_uses_api_key_header(self):
        dependency = Dependency(
            "Radarr",
            "http://radarr:7878/api/v3/system/status",
            "top-secret",
        )
        requests = []

        def opener(request, timeout):
            requests.append((request, timeout))
            return FakeResponse(200)

        self.assertTrue(
            dependency_is_ready(
                dependency,
                timeout_seconds=3,
                opener=opener,
            )
        )
        request, timeout = requests[0]
        self.assertEqual(timeout, 3)
        self.assertEqual(request.get_header("X-api-key"), "top-secret")
        self.assertNotIn("top-secret", request.full_url)

    def test_probe_returns_false_for_network_failures(self):
        dependency = Dependency(
            "Sonarr",
            "http://sonarr:8989/api/v3/system/status",
            "secret",
        )

        def opener(request, timeout):
            raise urllib.error.URLError("offline")

        self.assertFalse(
            dependency_is_ready(
                dependency,
                timeout_seconds=3,
                opener=opener,
            )
        )

    def test_wait_retries_until_every_dependency_is_ready(self):
        dependencies = (
            Dependency("Sonarr", "http://sonarr/status", "one"),
            Dependency("Radarr", "http://radarr/status", "two"),
        )
        attempts = {"Radarr": 0}
        sleeps = []

        def loader(settings_path):
            return dependencies

        def probe(dependency, timeout_seconds):
            if dependency.name == "Radarr":
                attempts["Radarr"] += 1
                return attempts["Radarr"] >= 2
            return True

        result = wait_for_dependencies(
            Path("/unused"),
            poll_seconds=5,
            timeout_seconds=3,
            loader=loader,
            probe=probe,
            sleeper=sleeps.append,
        )

        self.assertEqual(result, dependencies)
        self.assertEqual(sleeps, [5])

    def test_healthcheck_requires_searcharr_as_pid_one(self):
        settings_path = self._settings_file(
            "\n".join(
                [
                    "sonarr_enabled = True",
                    'sonarr_url = "http://sonarr:8989"',
                    'sonarr_api_key = "secret"',
                    "radarr_enabled = False",
                ]
            )
        )
        proc_directory = tempfile.TemporaryDirectory()
        self.addCleanup(proc_directory.cleanup)
        cmdline_path = Path(proc_directory.name) / "cmdline"
        cmdline_path.write_bytes(b"python3\x00readiness.py\x00")

        self.assertFalse(
            healthcheck(
                settings_path,
                timeout_seconds=1,
                proc_cmdline_path=cmdline_path,
            )
        )

    def test_healthcheck_rejects_settings_changed_after_startup(self):
        settings_path = self._settings_file(
            "\n".join(
                [
                    "sonarr_enabled = True",
                    'sonarr_url = "http://sonarr:8989"',
                    'sonarr_api_key = "old-secret"',
                    "radarr_enabled = False",
                ]
            )
        )
        proc_directory = tempfile.TemporaryDirectory()
        self.addCleanup(proc_directory.cleanup)
        cmdline_path = Path(proc_directory.name) / "cmdline"
        marker_path = Path(proc_directory.name) / "ready-marker"
        cmdline_path.write_bytes(b"python3\x00/app/searcharr.py\x00")
        _write_ready_marker(settings_path, marker_path)

        self.assertTrue(
            healthcheck(
                settings_path,
                timeout_seconds=1,
                proc_cmdline_path=cmdline_path,
                ready_marker_path=marker_path,
                probe=lambda dependency, timeout_seconds: True,
            )
        )

        settings_path.write_text(
            settings_path.read_text(encoding="utf-8").replace(
                "old-secret", "new-secret"
            ),
            encoding="utf-8",
        )

        self.assertFalse(
            healthcheck(
                settings_path,
                timeout_seconds=1,
                proc_cmdline_path=cmdline_path,
                ready_marker_path=marker_path,
                probe=lambda dependency, timeout_seconds: True,
            )
        )

    def test_shutdown_signal_exits_waiting_pid_one(self):
        with self.assertRaises(SystemExit) as raised:
            _exit_on_signal(15, None)

        self.assertEqual(raised.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
