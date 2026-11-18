import unittest

from helpers import CITED, P, blend
from langsmith_sizing.model import stores

NODES = {m: CITED["scale.clickhouse_setup"][m] for m in ("single", "replicated")}


class Retention(unittest.TestCase):
    def test_extended_share_only_when_longer_than_base(self) -> None:
        self.assertEqual(stores.effective_extended_share(0, 14, 400), 0)
        self.assertEqual(stores.effective_extended_share(20, 14, 400), 0.2)
        self.assertEqual(stores.effective_extended_share(20, 14, 14), 0)

    def test_days_in_each_bucket(self) -> None:
        lag = P["retention.smithdb_delete_lag_days"]
        self.assertEqual(stores.smithdb_retention_days(14, 0, 400, lag), 19)
        self.assertAlmostEqual(stores.blob_retention_days(14, 0.2, 400), 94)
        self.assertEqual(stores.smithdb_steady_state_days(14, 0.05, 400, lag), 405)
        self.assertEqual(stores.smithdb_steady_state_days(14, 0, 400, lag), 19)


class ObjectStorage(unittest.TestCase):
    KW = {"base_days": 14, "extended_share_pct": 5, "extended_days": 400, "lag_days": 5, "headroom": 1.2, "blob": True}

    def test_defaults_ten_users_fifty_traces_a_second(self) -> None:
        s = stores.object_storage(43_200_000, blend(), **self.KW)
        self.assertAlmostEqual(s["smithdb"]["tb"], 23.78, places=2)
        self.assertAlmostEqual(s["langsmith"]["tb"], 24.15, places=2)
        self.assertAlmostEqual(s["total_tb"], 47.9, places=1)

    def test_written_a_day_for_ten_billion_traces_a_year(self) -> None:
        per_day = 1e10 / P["time.seconds_per_year"] * 10 * 86_400
        b = blend()
        self.assertAlmostEqual(stores.written_tb_per_day(per_day, b["smithdb_kb"]) + stores.written_tb_per_day(per_day, b["blob_kb"]), 7.03, places=2)

    def test_no_langsmith_bucket_without_blob_storage(self) -> None:
        self.assertIsNone(stores.object_storage(43_200_000, blend(blob=False), **self.KW | {"blob": False})["langsmith"])

    def test_log_log_is_not_linear(self) -> None:
        # 10 + 10 KiB at 10 billion traces a year, SmithDB bucket: the log-log reading is 87.0 TB, a linear one 77.6 TB
        from helpers import coeffs

        per_day = 1e10 / P["time.seconds_per_year"] * 10 * 86_400
        days = stores.smithdb_retention_days(14, 0.05, 400, 5)
        self.assertAlmostEqual(stores.storage_tb(per_day, coeffs(10, 10)["smithdb_kb"], days, 1.2), 87.0, places=1)
        linear = 3.75 + (20 - 8) / (64 - 8) * (15 - 3.75)
        self.assertAlmostEqual(stores.storage_tb(per_day, linear, days, 1.2), 77.6, places=1)


class Redis(unittest.TestCase):
    def test_headroom(self) -> None:
        self.assertAlmostEqual(stores.redis_headroom(1.3, True, 1.3), 1.3)
        self.assertAlmostEqual(stores.redis_headroom(1.3, False, 1.3), 1.69)

    def test_memory_at_the_defaults(self) -> None:
        b = stores.redis_bytes(1500, 8.115, 21600, 1.3)
        self.assertAlmostEqual(stores.bytes_to_gb(b), 341.8, places=1)
        self.assertAlmostEqual(stores.bytes_to_gib(b), 318.3, places=1)
        self.assertEqual(stores.redis_sizing(10, stores.bytes_to_gib(b))["gi"], 319)

    def test_the_guide_is_a_floor(self) -> None:
        self.assertEqual(stores.redis_sizing(26, 5.2), {"gi": 26, "basis": "load", "payload_gi": 6, "profile_gi": 26})

    def test_backlog_tolerance_and_alarm(self) -> None:
        self.assertEqual(stores.redis_backlog_tolerance_hours(21600, P["redis.expiry_retry_hours"]), 2.5)
        self.assertEqual(stores.redis_backlog_tolerance_hours(3600, P["redis.expiry_retry_hours"]), 0)
        self.assertEqual(round(stores.redis_alarm_gib(319, P["redis.alarm_pct"])), 223)

    def test_shards_and_cluster(self) -> None:
        self.assertEqual(stores.redis_shards_for_cpu(1500, 0.7, P["redis.runs_per_shard"]), 2)
        self.assertEqual(stores.redis_shards_for_cpu(1, 1, P["redis.runs_per_shard"]), 1)
        self.assertTrue(stores.redis_needs_cluster(319, 1, P["redis.single_node_max_gb"]))
        self.assertTrue(stores.redis_needs_cluster(64, 2, P["redis.single_node_max_gb"]))
        self.assertFalse(stores.redis_needs_cluster(64, 1, P["redis.single_node_max_gb"]))

    def test_queue_partitions(self) -> None:
        q = P["redis.queue_partitions"]
        self.assertEqual(stores.ingest_queue_partitions(1500, True, **q), 2)
        self.assertEqual(stores.ingest_queue_partitions(150_000, True, **q), 13)
        self.assertEqual(stores.ingest_queue_partitions(150_000, False, **q), 1)


class Postgres(unittest.TestCase):
    def test_connections_at_the_defaults(self) -> None:
        self.assertEqual(stores.postgres_connections(5, 28, 50, 3), 334)

    def test_assumed_max_connections(self) -> None:
        kw = {"in_cluster": P["postgres.max_connections_in_cluster"], "bytes_per_connection": P["postgres.bytes_per_connection"], "cap": P["postgres.max_connections_cap"]}
        self.assertEqual([stores.postgres_max_connections(m, **kw) for m in (32, 8, None)], [3604, 901, 100])
        self.assertEqual(stores.postgres_max_connections(4096, **kw), 5000)


class ClickHouse(unittest.TestCase):
    SLOPE = CITED["scale.clickhouse_disk.high"]["gi_per_day"] / CITED["scale.clickhouse_disk.high"]["traces_per_second"]
    FLOOR = (P["clickhouse.floor_gi_per_day"], P["clickhouse.floor_up_to_traces_per_second"])

    def test_the_guides_two_points_are_on_one_slope(self) -> None:
        m = CITED["scale.clickhouse_disk.medium"]
        self.assertEqual(m["gi_per_day"] / m["traces_per_second"], self.SLOPE)

    def test_disk_a_day(self) -> None:
        self.assertEqual([stores.clickhouse_gi_per_day(t, self.SLOPE, *self.FLOOR) for t in (50, 100, 1000, 10)], [30, 60, 600, 5])

    def test_disk_a_node_and_in_total(self) -> None:
        kw = {"min_volume_gi": 50, "inline_factor": P["clickhouse.inline_payload_factor"]}
        self.assertEqual(stores.clickhouse_storage_gi(True, "single", 30, 14, True, **kw), 420)
        self.assertEqual(stores.clickhouse_storage_gi(True, "single", 30, 14, False, **kw), 2100)
        self.assertEqual(stores.clickhouse_storage_gi(True, "single", 5, 1, True, **kw), 50)
        self.assertEqual(stores.clickhouse_storage_gi(False, "single", 30, 14, True, **kw), 0)
        self.assertEqual(stores.clickhouse_total_storage_gi("replicated", 420, NODES), 1260)

    def test_node_count(self) -> None:
        self.assertEqual([stores.clickhouse_node_count(on, m, NODES) for on, m in ((False, "single"), (True, "external"), (True, "single"), (True, "replicated"))], [0, 0, 1, 3])


if __name__ == "__main__":
    unittest.main()
