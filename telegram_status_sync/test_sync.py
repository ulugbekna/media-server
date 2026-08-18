import sqlite3
import tempfile
import unittest
from pathlib import Path

from telegram_status_sync.sync import (
    Delivery,
    EVENT_SETTINGS,
    EventStore,
    MANAGED_NOTIFICATION_NAME,
    PermanentDeliveryError,
    RadarrClient,
    SyncConfig,
    SyncError,
    TelegramNotifier,
    build_webhook_payload,
    deliver_due,
    event_dedupe_key,
    format_event,
    load_config,
    read_authorized_chat_ids,
    recipient_digest,
    recover_radarr_state,
    synchronize_webhook,
    webhook_matches,
)


def webhook_schema():
    return {
        **{key: False for key in EVENT_SETTINGS},
        "name": "",
        "implementationName": "Webhook",
        "implementation": "Webhook",
        "configContract": "WebhookSettings",
        "fields": [
            {"name": "url", "value": None},
            {"name": "method", "value": 1},
            {"name": "username", "value": None},
            {"name": "password", "value": None},
            {"name": "headers", "value": []},
        ],
        "tags": [],
    }


class FakeRadarrClient:
    def __init__(self, notifications=None):
        self.existing = notifications or []
        self.created = []
        self.updated = []
        self.deleted = []

    def webhook_schema(self):
        return webhook_schema()

    def notifications(self):
        return self.existing

    def create(self, payload):
        self.created.append(payload)

    def update(self, notification_id, payload):
        self.updated.append((notification_id, payload))

    def delete(self, notification_id):
        self.deleted.append(notification_id)


class FakeNotifier:
    def __init__(self, failing_chat_id=None, unavailable_chat_id=None):
        self.failing_chat_id = failing_chat_id
        self.unavailable_chat_id = unavailable_chat_id
        self.messages = []

    def send(self, bot_token, chat_id, message):
        if chat_id == self.unavailable_chat_id:
            raise PermanentDeliveryError("blocked")
        if chat_id == self.failing_chat_id:
            raise SyncError("blocked")
        self.messages.append((chat_id, message))


class PagedTransport:
    def __init__(self):
        self.urls = []

    def request_json(self, **kwargs):
        self.urls.append(kwargs["url"])
        page = int(kwargs["url"].split("page=")[1].split("&")[0])
        if page == 1:
            ids = range(500, 250, -1)
        else:
            ids = range(250, 0, -1)
        return {"records": [{"id": history_id} for history_id in ids]}


class TelegramStatusSyncTests(unittest.TestCase):
    def _temporary_path(self, name):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        return Path(temporary_directory.name) / name

    def _settings_file(self):
        path = self._temporary_path("settings.py")
        path.write_text(
            "\n".join(
                [
                    'tgram_token = "bot-secret"',
                    "radarr_enabled = True",
                    'radarr_url = "http://radarr:7878/"',
                    'radarr_api_key = "radarr-secret"',
                ]
            ),
            encoding="utf-8",
        )
        return path

    def _database_file(self, users):
        path = self._temporary_path("searcharr.db")
        with sqlite3.connect(path) as connection:
            connection.execute(
                "CREATE TABLE users (id INTEGER, username TEXT, admin TEXT)"
            )
            connection.executemany(
                "INSERT INTO users VALUES (?, ?, ?)",
                [(user_id, "user", "") for user_id in users],
            )
        return path

    def test_loads_settings_and_unique_authorized_users(self):
        config = load_config(self._settings_file())
        self.assertEqual(config.bot_token, "bot-secret")
        self.assertEqual(config.radarr_url, "http://radarr:7878")
        self.assertEqual(
            read_authorized_chat_ids(self._database_file([20, 10, 20])),
            ["10", "20"],
        )

    def test_builds_untagged_internal_lifecycle_webhook(self):
        payload = build_webhook_payload(webhook_schema())
        fields = {field["name"]: field["value"] for field in payload["fields"]}
        self.assertEqual(payload["name"], MANAGED_NOTIFICATION_NAME)
        self.assertEqual(payload["tags"], [])
        self.assertTrue(payload["onMovieAdded"])
        self.assertTrue(payload["onGrab"])
        self.assertTrue(payload["onDownload"])
        self.assertTrue(payload["onUpgrade"])
        self.assertTrue(payload["onManualInteractionRequired"])
        self.assertEqual(
            fields["url"],
            "http://telegram-status-sync:8081/radarr",
        )

    def test_tagged_or_duplicate_managed_webhooks_are_reconciled(self):
        desired = build_webhook_payload(webhook_schema())
        desired["id"] = 3
        tagged = {**desired, "tags": [99]}
        duplicate = {**desired, "id": 7, "name": "Renamed by user"}
        client = FakeRadarrClient([tagged, duplicate])

        result = synchronize_webhook(client)

        self.assertEqual(result.removed, 1)
        self.assertEqual(result.updated, 1)
        self.assertEqual(client.deleted, [7])
        self.assertFalse(webhook_matches(tagged, desired))

    def test_formats_grab_import_and_manual_action(self):
        movie = {"title": "WALL-E", "year": 2008, "tmdbId": 10681}
        self.assertIn(
            "Download started: WALL-E (2008)",
            format_event(
                {
                    "eventType": "Grab",
                    "movie": movie,
                    "release": {"quality": "Remux-2160p"},
                }
            ),
        )
        self.assertIn(
            "Ready to watch: WALL-E (2008)",
            format_event(
                {
                    "eventType": "Download",
                    "movie": movie,
                    "movieFile": {"quality": "Remux-2160p"},
                    "isUpgrade": False,
                }
            ),
        )
        self.assertIn(
            "Reason: Not enough free space",
            format_event(
                {
                    "eventType": "ManualInteractionRequired",
                    "movie": movie,
                    "downloadStatusMessages": [
                        {"messages": ["Not enough free space"]}
                    ],
                }
            ),
        )

    def test_manual_webhook_and_queue_messages_share_dedupe_key(self):
        webhook_payload = {
            "eventType": "ManualInteractionRequired",
            "downloadId": "ABC",
            "downloadStatusMessages": [
                {"title": "empty", "messages": []},
                {"title": "problem", "messages": ["Needs import"]},
            ],
        }
        queue_payload = {
            "eventType": "ManualInteractionRequired",
            "downloadId": "ABC",
            "downloadStatusMessages": [
                {"title": "problem", "messages": ["Needs import"]}
            ],
        }

        self.assertEqual(
            event_dedupe_key(webhook_payload),
            event_dedupe_key(queue_payload),
        )

    def test_event_is_durable_until_each_recipient_succeeds(self):
        state_path = self._temporary_path("events.sqlite")
        store = EventStore(state_path)
        digest_10 = recipient_digest("10")
        digest_20 = recipient_digest("20")
        store.enqueue(
            "Ready",
            [digest_10, digest_20],
            "download:abc",
            clock=lambda: 100,
        )

        first = deliver_due(
            store,
            SyncConfig("token", "http://radarr:7878", "key"),
            ["10", "20"],
            FakeNotifier(failing_chat_id="10"),
            clock=lambda: 100,
        )
        self.assertEqual(first.delivered, 1)
        self.assertEqual(first.failed, 1)
        self.assertEqual(store.pending_count(), 1)

        second = deliver_due(
            EventStore(state_path),
            SyncConfig("token", "http://radarr:7878", "key"),
            ["10", "20"],
            FakeNotifier(),
            clock=lambda: 103,
        )
        self.assertEqual(second.delivered, 1)
        self.assertEqual(store.pending_count(), 0)

    def test_revoked_recipient_is_removed_from_pending_event(self):
        store = EventStore(self._temporary_path("events.sqlite"))
        store.enqueue(
            "Ready",
            [recipient_digest("10"), recipient_digest("20")],
            "download:abc",
            clock=lambda: 100,
        )

        result = deliver_due(
            store,
            SyncConfig("token", "http://radarr:7878", "key"),
            ["20"],
            FakeNotifier(),
            clock=lambda: 100,
        )

        self.assertEqual(result.revoked, 1)
        self.assertEqual(result.delivered, 1)
        self.assertEqual(store.pending_count(), 0)

    def test_pending_delivery_is_atomically_claimed(self):
        state_path = self._temporary_path("events.sqlite")
        first_store = EventStore(state_path)
        first_store.enqueue(
            "Ready",
            [recipient_digest("10")],
            "download:abc",
            clock=lambda: 100,
        )

        self.assertEqual(len(first_store.due(100)), 1)
        self.assertEqual(len(EventStore(state_path).due(100)), 0)

    def test_unavailable_recipient_is_abandoned_without_sticking_health(self):
        store = EventStore(self._temporary_path("events.sqlite"))
        store.enqueue(
            "Ready",
            [recipient_digest("10")],
            "download:abc",
            clock=lambda: 100,
        )

        result = deliver_due(
            store,
            SyncConfig("token", "http://radarr:7878", "key"),
            ["10"],
            FakeNotifier(unavailable_chat_id="10"),
            clock=lambda: 100,
        )

        self.assertEqual(result.abandoned, 1)
        self.assertEqual(store.pending_count(), 0)

    def test_recipient_cache_survives_live_database_outage(self):
        state_path = self._temporary_path("events.sqlite")
        store = EventStore(state_path)
        expected = [recipient_digest("10"), recipient_digest("20")]
        store.cache_recipients(expected)

        self.assertEqual(EventStore(state_path).cached_recipients(), expected)

    def test_history_recovery_is_baselined_then_deduplicated(self):
        class HistoryClient:
            def __init__(self):
                self.records = [
                    {
                        "id": 1,
                        "eventType": "grabbed",
                        "downloadId": "ABC",
                        "movie": {
                            "id": 9,
                            "title": "WALL-E",
                            "year": 2008,
                            "tmdbId": 10681,
                        },
                        "quality": {"quality": {"name": "Remux-2160p"}},
                    }
                ]

            def history_since(self, last_history_id):
                if last_history_id is None:
                    return self.records
                return [
                    record
                    for record in self.records
                    if record["id"] > last_history_id
                ]

            def queue(self):
                return []

        store = EventStore(self._temporary_path("events.sqlite"))
        client = HistoryClient()
        recipients = [recipient_digest("10")]

        self.assertEqual(
            recover_radarr_state(client, store, recipients),
            0,
        )
        client.records.append(
            {
                "id": 2,
                "eventType": "downloadFolderImported",
                "downloadId": "ABC",
                "movie": {
                    "id": 9,
                    "title": "WALL-E",
                    "year": 2008,
                    "tmdbId": 10681,
                },
                "quality": {"quality": {"name": "Remux-2160p"}},
            }
        )

        self.assertEqual(
            recover_radarr_state(client, store, recipients),
            1,
        )
        self.assertEqual(
            recover_radarr_state(client, store, recipients),
            0,
        )
        self.assertEqual(store.pending_count(), 1)

    def test_history_paginates_until_persisted_cursor(self):
        transport = PagedTransport()
        client = RadarrClient(
            SyncConfig("token", "http://radarr:7878", "key"),
            transport,
        )

        records = client.history_since(100)

        self.assertEqual(len(records), 400)
        self.assertEqual(records[0]["id"], 500)
        self.assertEqual(records[-1]["id"], 101)
        self.assertEqual(len(transport.urls), 2)


if __name__ == "__main__":
    unittest.main()
