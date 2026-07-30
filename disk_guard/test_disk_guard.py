import json
import tempfile
import unittest
import urllib.error
from pathlib import Path

from disk_guard.guard import (
    GIB,
    LOW_SPACE_BYTES,
    RECOVERY_BYTES,
    DiskGuard,
    GuardError,
    HttpTransport,
    QBittorrentClient,
    StateStore,
    incident_phase,
    select_stoppable_hashes,
)


class FakeQBittorrent:
    def __init__(self, stopped_count=2):
        self.calls = 0
        self.stopped_count = stopped_count

    def stop_active_incomplete(self):
        self.calls += 1
        return self.stopped_count


class FakeNotifier:
    RECIPIENT_DIGEST = "a" * 64

    def __init__(self):
        self.messages = []

    def send_all(self, message, sent_recipient_digests, on_recipient_sent):
        self.messages.append(message)
        newly_sent = 0
        if self.RECIPIENT_DIGEST not in sent_recipient_digests:
            sent_recipient_digests.add(self.RECIPIENT_DIGEST)
            on_recipient_sent(set(sent_recipient_digests))
            newly_sent = 1
        return 1, newly_sent


class RecoveryFailingNotifier(FakeNotifier):
    def __init__(self):
        super().__init__()
        self.failures_remaining = 1

    def send_all(self, message, sent_recipient_digests, on_recipient_sent):
        if message.startswith("RECOVERY:") and self.failures_remaining:
            self.failures_remaining -= 1
            raise GuardError("Telegram recovery notification failed")
        return super().send_all(
            message, sent_recipient_digests, on_recipient_sent
        )


class RecordingTransport:
    def __init__(self, torrent_payload):
        self.torrent_payload = torrent_payload
        self.calls = []

    def request(self, **kwargs):
        self.calls.append(kwargs)
        if kwargs["method"] == "GET":
            return json.dumps(self.torrent_payload).encode("utf-8")
        return b""


class DiskGuardTests(unittest.TestCase):
    def test_threshold_and_recovery_hysteresis(self):
        self.assertEqual(
            incident_phase(LOW_SPACE_BYTES - 1, False), "enter"
        )
        self.assertEqual(incident_phase(LOW_SPACE_BYTES, False), "normal")
        self.assertEqual(incident_phase(LOW_SPACE_BYTES, True), "active")
        self.assertEqual(
            incident_phase(RECOVERY_BYTES - 1, True), "active"
        )
        self.assertEqual(incident_phase(RECOVERY_BYTES, True), "recover")

    def test_selects_only_active_incomplete_torrents(self):
        downloading_hash = "a" * 40
        queued_hash = "b" * 40
        forced_metadata_hash = "1" * 40
        torrents = [
            {
                "hash": downloading_hash,
                "state": "downloading",
                "progress": 0.5,
                "amount_left": 100,
            },
            {
                "hash": queued_hash,
                "state": "queuedDL",
                "progress": 0,
                "amount_left": 200,
            },
            {
                "hash": "c" * 40,
                "state": "stalledUP",
                "progress": 1,
                "amount_left": 0,
            },
            {
                "hash": "d" * 40,
                "state": "downloading",
                "progress": 1,
                "amount_left": 0,
            },
            {
                "hash": "e" * 40,
                "state": "stoppedDL",
                "progress": 0.25,
                "amount_left": 300,
            },
            {
                "hash": "f" * 40,
                "state": "pausedDL",
                "progress": 0.25,
                "amount_left": 300,
            },
            {
                "hash": "0" * 40,
                "state": "error",
                "progress": 0.25,
                "amount_left": 300,
            },
            {
                "hash": forced_metadata_hash,
                "state": "forcedMetaDL",
                "progress": 0,
                "amount_left": 0,
            },
        ]

        self.assertEqual(
            select_stoppable_hashes(torrents),
            [downloading_hash, queued_hash, forced_metadata_hash],
        )

    def test_qbittorrent_uses_v5_stop_endpoint(self):
        torrent_hash = "a" * 40
        transport = RecordingTransport(
            [
                {
                    "hash": torrent_hash,
                    "state": "downloading",
                    "progress": 0.25,
                    "amount_left": 100,
                }
            ]
        )
        client = QBittorrentClient(
            ["http://gluetun:8080"], transport
        )

        self.assertEqual(client.stop_active_incomplete(), 1)
        self.assertEqual(len(transport.calls), 2)
        self.assertEqual(
            transport.calls[1]["url"],
            "http://gluetun:8080/api/v2/torrents/stop",
        )
        self.assertEqual(
            transport.calls[0]["url"],
            "http://gluetun:8080/api/v2/torrents/info?filter=downloading",
        )
        self.assertEqual(
            transport.calls[1]["form"], {"hashes": torrent_hash}
        )

    def test_incident_state_throttles_alerts_and_resets_after_recovery(self):
        free_bytes = [19 * GIB]
        qbittorrent = FakeQBittorrent()
        notifier = FakeNotifier()

        with tempfile.TemporaryDirectory() as temporary_directory:
            state_store = StateStore(
                Path(temporary_directory) / "incident-state.json"
            )
            guard = DiskGuard(
                data_path=Path("/unused"),
                state_store=state_store,
                qbittorrent=qbittorrent,
                notifier=notifier,
                free_space_reader=lambda: free_bytes[0],
                clock=lambda: 1000,
            )

            self.assertEqual(guard.run_once(), "enter")
            self.assertEqual(guard.run_once(), "active")
            self.assertEqual(len(notifier.messages), 1)
            self.assertEqual(qbittorrent.calls, 2)
            active_state = state_store.load()
            self.assertTrue(active_state.active)
            self.assertTrue(active_state.warning_complete)

            free_bytes[0] = 25 * GIB
            self.assertEqual(guard.run_once(), "recover")
            self.assertEqual(len(notifier.messages), 2)
            self.assertIn("require manual resume", notifier.messages[1])
            recovered_state = state_store.load()
            self.assertFalse(recovered_state.active)
            self.assertFalse(recovered_state.warning_complete)
            self.assertEqual(recovered_state.warning_recipients, set())

            free_bytes[0] = 19 * GIB
            self.assertEqual(guard.run_once(), "enter")
            self.assertEqual(len(notifier.messages), 3)
            self.assertEqual(qbittorrent.calls, 3)

    def test_recovery_notification_retries_without_reopening_incident(self):
        free_bytes = [19 * GIB]
        with tempfile.TemporaryDirectory() as temporary_directory:
            state_store = StateStore(
                Path(temporary_directory) / "incident-state.json"
            )
            guard = DiskGuard(
                data_path=Path("/unused"),
                state_store=state_store,
                qbittorrent=FakeQBittorrent(),
                notifier=RecoveryFailingNotifier(),
                free_space_reader=lambda: free_bytes[0],
                clock=lambda: 1000,
            )

            self.assertEqual(guard.run_once(), "enter")
            free_bytes[0] = 25 * GIB
            with self.assertRaisesRegex(
                GuardError, "recovery notification failed"
            ):
                guard.run_once()

            pending_state = state_store.load()
            self.assertFalse(pending_state.active)
            self.assertTrue(pending_state.recovery_pending)
            self.assertEqual(pending_state.last_success_at, 1000)

            self.assertEqual(guard.run_once(), "recover")
            recovered_state = state_store.load()
            self.assertFalse(recovered_state.active)
            self.assertFalse(recovered_state.recovery_pending)

    def test_http_retries_transient_failures_without_exposing_url(self):
        calls = []
        sleeps = []
        secret_url = (
            "https://api.telegram.org/botSUPERSECRET/sendMessage"
        )

        def opener(request, timeout):
            calls.append((request, timeout))
            raise urllib.error.HTTPError(
                request.full_url, 503, "unavailable", {}, None
            )

        transport = HttpTransport(
            attempts=3, opener=opener, sleeper=sleeps.append
        )
        with self.assertLogs("disk-guard", level="WARNING") as logs:
            with self.assertRaises(GuardError) as raised:
                transport.request(
                    method="POST",
                    url=secret_url,
                    operation="Telegram sendMessage",
                    form={"chat_id": "12345", "text": "test"},
                )

        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [1, 2])
        combined_output = "\n".join(logs.output) + str(raised.exception)
        self.assertNotIn("SUPERSECRET", combined_output)
        self.assertNotIn("12345", combined_output)
        self.assertIn("HTTP 503", str(raised.exception))

    def test_http_does_not_retry_explicit_client_error(self):
        calls = []
        sleeps = []

        def opener(request, timeout):
            calls.append((request, timeout))
            raise urllib.error.HTTPError(
                request.full_url, 403, "forbidden", {}, None
            )

        transport = HttpTransport(
            attempts=3, opener=opener, sleeper=sleeps.append
        )
        with self.assertRaisesRegex(GuardError, "HTTP 403"):
            transport.request(
                method="GET",
                url="http://gluetun:8080/api/v2/torrents/info",
                operation="qBittorrent incomplete-torrent query",
            )

        self.assertEqual(len(calls), 1)
        self.assertEqual(sleeps, [])

    def test_http_construction_error_does_not_expose_secret_url(self):
        secret_url = (
            "https://api.telegram.org/botSUPERSECRET\n/sendMessage"
        )
        transport = HttpTransport(attempts=1)

        with self.assertRaises(GuardError) as raised:
            transport.request(
                method="POST",
                url=secret_url,
                operation="Telegram sendMessage",
            )

        self.assertNotIn("SUPERSECRET", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
