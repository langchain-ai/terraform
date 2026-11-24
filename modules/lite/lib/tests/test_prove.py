"""make verify and make soak's driver: the admin's login makes a key, the key is revoked pass or fail, and
the right load test command runs with it. LangSmith is a local stub; the load test is not run."""

import base64
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

import prove

CALLS: list[tuple[str, str]] = []
# The test admin's Basic auth header, built here so the expected login reads as what it is.
GOOD_LOGIN = "Basic " + base64.b64encode(b"a@b.co:pw").decode()


class Stub(BaseHTTPRequestHandler):
    """LangSmith's login, tenants and API key endpoints, as lsb/client.py found them."""

    def _send(self, body: object, code: int = 200) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:  # noqa: N802 - the handler's name is http.server's
        CALLS.append(("POST", self.path))
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/api/v1/login":
            ok = self.headers["Authorization"] == GOOD_LOGIN
            self._send({"access_token": "t"} if ok else {}, 200 if ok else 401)
        else:
            self._send({"id": "k1", "key": "lsv2_test"})

    def do_GET(self) -> None:  # noqa: N802
        CALLS.append(("GET", self.path))
        self._send([{"id": "ws1"}])

    def do_DELETE(self) -> None:  # noqa: N802
        CALLS.append(("DELETE", self.path))
        self._send({})

    def log_message(self, *args: object) -> None:
        pass


class Driver(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.endpoint = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        CALLS.clear()
        self.out = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.out.cleanup()

    def run_main(self, *args: str, password: str = "pw") -> tuple[int, list[tuple[str, ...]]]:
        ran: list[tuple[str, ...]] = []
        argv = ["prove.py", *args, "--endpoint", self.endpoint, "--namespace", "a", "--data-namespace", "a-data", "--loadtest", "/lt", "--out", self.out.name]
        env = {"LITE_ADMIN_EMAIL": "a@b.co", "LITE_ADMIN_PASSWORD": password}
        with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, env), \
                mock.patch.object(prove, "load_test", lambda a, e, cmd, *rest: ran.append((cmd, e["LANGSMITH_API_KEY"], *rest)) or 0), \
                mock.patch.object(prove, "runs_per_trace", lambda a: 10.0), redirect_stderr(io.StringIO()):
            return prove.main(), ran

    def test_verify_makes_a_key_runs_verify_and_revokes_it(self) -> None:
        code, ran = self.run_main("verify")
        self.assertEqual(code, 0)
        self.assertEqual(ran[0][:2], ("load-test-verify", "lsv2_test"))
        self.assertIn(("DELETE", "/api/v1/api-key/k1"), CALLS)

    def test_soak_sends_traces_at_the_rate_over_runs_a_trace_then_judges(self) -> None:
        code, ran = self.run_main("soak", "--runs-per-second", "25")
        self.assertEqual(code, 0)
        self.assertEqual([r[0] for r in ran], ["load-test", "load-test-judge"])
        self.assertIn("2.5000", ran[0])

    def test_step_runs_the_step_command(self) -> None:
        _, ran = self.run_main("soak", "--runs-per-second", "25", "--step")
        self.assertEqual([r[0] for r in ran], ["load-test-step"])

    def test_a_failed_login_stops_before_any_load(self) -> None:
        code, ran = self.run_main("verify", password="wrong")
        self.assertEqual((code, ran), (1, []))

    def test_a_key_that_cannot_be_revoked_says_so(self) -> None:
        ls = prove.LangSmith("http://127.0.0.1:9")
        ls.key_id = "k9"
        err = io.StringIO()
        with redirect_stderr(err):
            ls.revoke()
        self.assertIn("was not revoked", err.getvalue())
        self.assertIsNone(ls.key_id)


if __name__ == "__main__":
    unittest.main()
