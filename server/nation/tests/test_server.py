"""Тесты серверной логики GhostNation: геометрия, экономика, валидация, WS-IP."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("GC_JWT_SECRET", "x" * 48)
os.environ.setdefault("NATION_DB", os.path.join(tempfile.mkdtemp(), "nation_test.db"))

import server as srv  # noqa: E402


class FakeWS:
    def __init__(self, host, headers=None):
        self.client = type("C", (), {"host": host})()
        self.headers = headers or {}


class AreaTests(unittest.TestCase):
    def test_square_one_km(self):
        # 0.01° по широте ≈ 1113 м; на экваторе столько же по долготе
        square = [[0.0, 0.0], [0.0, 0.01], [0.01, 0.01], [0.01, 0.0]]
        self.assertAlmostEqual(srv._area_km2(square), 1.239, delta=0.01)

    def test_degenerate(self):
        self.assertEqual(srv._area_km2([[0, 0], [0, 1]]), 0.0)

    def test_bbox(self):
        bb = srv._bbox([[10, 20], [-5, 30], [0, -1]])
        self.assertEqual(bb, (-5, -1, 10, 30))


class PolyTests(unittest.TestCase):
    sq = [[0, 0], [0, 2], [2, 2], [2, 0]]

    def test_inside_outside(self):
        self.assertTrue(srv._in_poly([1, 1], self.sq))
        self.assertFalse(srv._in_poly([3, 3], self.sq))

    def test_overlap(self):
        near = [[1, 1], [1, 3], [3, 3], [3, 1]]
        far = [[10, 10], [10, 12], [12, 12], [12, 10]]
        self.assertTrue(srv._overlap(self.sq, near))
        self.assertFalse(srv._overlap(self.sq, far))
        inside = [[0.5, 0.5], [0.5, 1], [1, 1], [1, 0.5]]
        self.assertTrue(srv._overlap(self.sq, inside))


class LengthTests(unittest.TestCase):
    def test_road_len_one_km(self):
        line = [[0.0, 0.0], [0.008993, 0.0]]  # ≈ 1000 м по широте
        self.assertAlmostEqual(srv._road_len_m([line]), 1000, delta=5)


class EconomyTests(unittest.TestCase):
    def test_value_counts_every_line_kind(self):
        st = {"buildings": [{"type": "house", "lat": 0, "lng": 0}],
              "roads": [[[0.0, 0.0], [0.007, 0.0]]],
              "rails": [[[0.0, 1.0], [0.007, 1.0]]],
              "paths": [[[0.0, 2.0], [0.007, 2.0]]],
              "lights": [{"lat": 0, "lng": 0}],
              "crosswalks": [{"lat": 0, "lng": 0}],
              "parking": [{"lat": 0, "lng": 0}],
              "stations": [{"lat": 0, "lng": 0}]}
        val = srv._state_value(st)
        line_m = 0.007 * 111320
        self.assertAlmostEqual(val, 40 + 0.6 * 3 * line_m + 30 + 10 + 120 + 250, places=3)

    def test_population_is_residents(self):
        houses = [{"type": "house", "lat": 0, "lng": 0}] * 3
        self.assertEqual(srv._population({"buildings": houses}), 12)

    def test_economy_employment(self):
        st = {"buildings": [{"type": "house", "lat": 0, "lng": 0}] * 2
                           + [{"type": "shop", "lat": 0, "lng": 0}]}
        e = srv._economy(st)
        self.assertEqual((e["residents"], e["jobs"], e["employed"], e["unemployed"]), (8, 12, 8, 0))
        self.assertAlmostEqual(e["income"], 8 * srv.TAX_EMPLOYED_HR, places=3)

    def test_economy_unemployed_paid_less(self):
        st = {"buildings": [{"type": "house", "lat": 0, "lng": 0}] * 2}
        e = srv._economy(st)
        self.assertEqual((e["employed"], e["unemployed"]), (0, 8))
        self.assertAlmostEqual(e["income"], 8 * srv.TAX_UNEMPLOYED_HR, places=3)

    def test_upkeep_counts_all_lines(self):
        km = [[0.0, 0.0], [0.008993, 0.0]]
        e = srv._economy({"roads": [km], "paths": [km], "lights": [{"lat": 0, "lng": 0}]})
        self.assertAlmostEqual(e["upkeep"], 2 * srv.UPKEEP_ROAD_KM_HR + srv.UPKEEP_LIGHT_HR, delta=0.02)
        self.assertLess(e["net"], 0)

    def test_offline_cap_constant(self):
        self.assertEqual(srv._MAX_OFFLINE_HOURS, 72.0)


class ValidationTests(unittest.TestCase):
    def line(self, n=2):
        return [[0.0, i * 0.001] for i in range(n)]

    def test_rejects_too_many_rails(self):
        st = {"rails": [self.line() for _ in range(srv.MAX_ROADS + 1)]}
        with self.assertRaises(Exception) as ctx:
            srv._validate_state(st)
        self.assertIn("Too many rails", str(ctx.exception))

    def test_rejects_bad_point(self):
        with self.assertRaises(Exception):
            srv._validate_state({"paths": [[[91.0, 0.0], [0.0, 0.0]]]})

    def test_rejects_huge_linemeta(self):
        st = {"lineMeta": {str(i): {} for i in range(8193)}}
        with self.assertRaises(Exception):
            srv._validate_state(st)

    def test_accepts_normal_state(self):
        st = {"buildings": [{"type": "house", "lat": 0.0, "lng": 0.0}],
              "roads": [self.line()], "rails": [self.line()], "paths": [self.line()],
              "lineMeta": {"a": {"surface": "dirt"}}, "roadWalk": {"a": "both"}}
        srv._validate_state(st)


class BboxTests(unittest.TestCase):
    def test_norm_bbox(self):
        ok = srv._norm_bbox({"minlat": 0, "minlng": 0, "maxlat": 1, "maxlng": 1})
        self.assertEqual(ok, (0.0, 0.0, 1.0, 1.0))
        self.assertIsNone(srv._norm_bbox({"minlat": 2, "minlng": 0, "maxlat": 1, "maxlng": 1}))
        self.assertIsNone(srv._norm_bbox({"minlat": float("nan"), "minlng": 0, "maxlat": 1, "maxlng": 1}))
        self.assertIsNone(srv._norm_bbox({}))

    def test_bbox_hits(self):
        self.assertTrue(srv._bbox_hits((0, 0, 1, 1), (0.5, 0.5, 2, 2)))
        self.assertFalse(srv._bbox_hits((0, 0, 1, 1), (5, 5, 6, 6)))


class WSIPTests(unittest.TestCase):
    def test_forwarded_used_for_loopback_peer(self):
        ws = FakeWS("127.0.0.1", {"x-real-ip": "203.0.113.5"})
        self.assertEqual(srv._ws_ip(ws), "203.0.113.5")

    def test_forwarded_ignored_for_direct_peer(self):
        ws = FakeWS("198.51.100.7", {"x-real-ip": "203.0.113.5"})
        self.assertEqual(srv._ws_ip(ws), "198.51.100.7")

    def test_forwarded_list_uses_first(self):
        ws = FakeWS("127.0.0.1", {"x-forwarded-for": "203.0.113.5, 10.0.0.1"})
        self.assertEqual(srv._ws_ip(ws), "203.0.113.5")

    def test_garbage_forwarded_falls_back(self):
        ws = FakeWS("127.0.0.1", {"x-real-ip": "not-an-ip"})
        self.assertEqual(srv._ws_ip(ws), "127.0.0.1")


class PartialSaveTests(unittest.TestCase):
    """Частичное сохранение: клиент присылает только изменившиеся коллекции."""

    def setUp(self):
        import asyncio, json as _json, time as _time, jwt as _jwt
        self.asyncio, self.json, self.jwt = asyncio, _json, _jwt
        srv.DB_PATH = os.path.join(tempfile.mkdtemp(), "partial.db")
        con = srv._db()
        border = [[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]]
        con.execute(
            "INSERT INTO country(owner,name,color,border,state,balance,built_value,"
            "cx,cy,minlat,minlng,maxlat,maxlng,created,updated,last_income) "
            "VALUES(?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?)",
            ("tester", "T", "#fff", _json.dumps(border),
             _json.dumps({"buildings": [{"type": "house", "lat": 0.5, "lng": 0.5}],
                          "lights": []}),
             1000, 0.5, 0.5, 0.0, 0.0, 1.0, 1.0, 0, 0, 0),
        )
        con.commit(); con.close()
        now = int(_time.time())
        self.token = "Bearer " + _jwt.encode(
            {"sub": "tester", "iat": now, "exp": now + 600},
            os.environ["GC_JWT_SECRET"], algorithm="HS256")

    def saved_state(self):
        con = srv._db()
        st = self.json.loads(con.execute(
            "SELECT state FROM country WHERE owner='tester'").fetchone()["state"])
        con.close()
        return st

    def test_partial_merges_and_keeps_old_collections(self):
        body = srv.SaveReq(state={"lights": [{"lat": 0.4, "lng": 0.4}]}, keys=["lights"])
        res = self.asyncio.run(srv.save_mine(body, self.token))
        self.assertTrue(res["ok"])
        st = self.saved_state()
        self.assertEqual(len(st["buildings"]), 1)      # старая коллекция сохранилась
        self.assertEqual(len(st["lights"]), 1)         # новая применилась

    def test_partial_charges_only_new_value(self):
        self.asyncio.run(srv.save_mine(
            srv.SaveReq(state={"lights": [{"lat": 0.4, "lng": 0.4}]}, keys=["lights"]), self.token))
        spent_first = 1000 - self.balance()
        self.assertAlmostEqual(spent_first, 40 + srv.COST_LIGHT, places=3)
        # повтор с тем же набором ничего не списывает
        self.asyncio.run(srv.save_mine(
            srv.SaveReq(state={"lights": [{"lat": 0.4, "lng": 0.4}]}, keys=["lights"]), self.token))
        self.assertAlmostEqual(self.balance(), 1000 - spent_first, places=3)

    def test_unknown_key_rejected(self):
        with self.assertRaises(Exception) as ctx:
            self.asyncio.run(srv.save_mine(
                srv.SaveReq(state={"hacked": 1}, keys=["hacked"]), self.token))
        self.assertIn("keys", str(ctx.exception))

    def balance(self):
        con = srv._db()
        bal = con.execute("SELECT balance FROM country WHERE owner='tester'").fetchone()["balance"]
        con.close()
        return bal


if __name__ == "__main__":
    unittest.main()
