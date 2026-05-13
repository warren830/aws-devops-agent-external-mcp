"""
Standalone tests for handler.py.

Avoids extra deps: no moto, no pytest fixtures - just stdlib unittest with
hand-built monkeypatches over boto3 + urllib3. Run with:

    cd demo-cases/infra/webhook-bridge
    python -m unittest tests.test_handler -v
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock

# Make src importable.
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

# Sample event lives next to this file.
SAMPLE_EVENT_PATH = Path(__file__).parent / "sample_event.json"


def _ensure_boto3_stub() -> None:
    """If boto3 isn't installed locally, install a minimal stub.

    The Lambda runtime ships boto3 by default, so production never uses this.
    """
    try:
        import boto3  # noqa: F401
        return
    except ModuleNotFoundError:
        pass

    fake = types.ModuleType("boto3")

    def _client(_name, **_kwargs):  # noqa: D401, ANN001 - simple stub
        return MagicMock(name=f"boto3.client({_name})")

    fake.client = _client  # type: ignore[attr-defined]
    sys.modules["boto3"] = fake


_ensure_boto3_stub()


def _fresh_handler_module():
    """Force re-import of handler so module-level caches are reset between tests."""
    if "handler" in sys.modules:
        del sys.modules["handler"]
    import handler  # noqa: WPS433 - intentional fresh import
    return handler


class HandlerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        with SAMPLE_EVENT_PATH.open("r", encoding="utf-8") as f:
            self.sample_event = json.load(f)

    # ----- payload construction --------------------------------------------------
    def test_build_payload_alb_alarm_state_alarm_maps_to_created(self) -> None:
        handler = _fresh_handler_module()
        alarm = json.loads(self.sample_event["Records"][0]["Sns"]["Message"])
        payload = handler._build_payload(alarm)

        self.assertEqual(payload["eventType"], "incident")
        self.assertEqual(payload["action"], "created")
        self.assertEqual(payload["service"], "ALB")
        self.assertIn("demo-alb-5xx", payload["incidentId"])
        self.assertEqual(payload["title"], "demo-alb-5xx")
        self.assertEqual(payload["data"]["newStateValue"], "ALARM")
        self.assertEqual(payload["data"]["trigger"]["namespace"], "AWS/ApplicationELB")
        self.assertEqual(payload["data"]["accountId"], "111122223333")
        # Priority: tag fetch will fail in test (no real AWS) -> heuristic for
        # AWS/ApplicationELB is HIGH.
        self.assertEqual(payload["priority"], "HIGH")

    def test_build_payload_state_ok_maps_to_resolved(self) -> None:
        handler = _fresh_handler_module()
        alarm = json.loads(self.sample_event["Records"][0]["Sns"]["Message"])
        alarm["NewStateValue"] = "OK"
        payload = handler._build_payload(alarm)
        self.assertEqual(payload["action"], "resolved")

    def test_build_payload_state_insufficient_maps_to_updated(self) -> None:
        handler = _fresh_handler_module()
        alarm = json.loads(self.sample_event["Records"][0]["Sns"]["Message"])
        alarm["NewStateValue"] = "INSUFFICIENT_DATA"
        payload = handler._build_payload(alarm)
        self.assertEqual(payload["action"], "updated")

    def test_build_payload_logs_namespace_uses_low_priority_heuristic(self) -> None:
        handler = _fresh_handler_module()
        alarm = json.loads(self.sample_event["Records"][0]["Sns"]["Message"])
        alarm["Trigger"]["Namespace"] = "AWS/Logs"
        # Wipe the alarm ARN so tag fetch is short-circuited; otherwise heuristic kicks in.
        alarm["AlarmArn"] = None
        payload = handler._build_payload(alarm)
        self.assertEqual(payload["priority"], "LOW")
        self.assertEqual(payload["service"], "CloudWatchLogs")

    # ----- HMAC signing ----------------------------------------------------------
    def test_sign_matches_reference_implementation(self) -> None:
        handler = _fresh_handler_module()
        secret = "super-secret"
        timestamp = "2026-05-13T10:01:24.000000Z"
        body = '{"hello":"world"}'
        expected = base64.b64encode(
            hmac.new(secret.encode(), f"{timestamp}:{body}".encode(), hashlib.sha256).digest()
        ).decode()
        self.assertEqual(handler._sign(secret, timestamp, body), expected)

    # ----- end-to-end: lambda_handler with mocked SSM + HTTP --------------------
    def test_lambda_handler_signs_and_posts_to_webhook(self) -> None:
        handler = _fresh_handler_module()

        # Mock SSM get_parameters
        ssm_mock = MagicMock()
        ssm_mock.get_parameters.return_value = {
            "Parameters": [
                {"Name": "/devops-agent/webhook-url", "Value": "https://webhook.example.com/x"},
                {"Name": "/devops-agent/webhook-secret", "Value": "topsecret"},
            ]
        }
        handler._SSM = ssm_mock

        # Mock urllib3 PoolManager
        http_mock = MagicMock()
        fake_response = MagicMock()
        fake_response.status = 202
        fake_response.data = b'{"ok":true}'
        http_mock.request.return_value = fake_response
        handler._HTTP = http_mock

        # Reset cached config
        handler._WEBHOOK_URL = None
        handler._WEBHOOK_SECRET = None

        result = handler.lambda_handler(self.sample_event, context=None)

        self.assertEqual(result["processed"], 1)
        self.assertEqual(result["results"][0]["status"], 202)
        self.assertTrue(result["results"][0]["ok"])

        # Inspect the HTTP request that was made.
        call_args = http_mock.request.call_args
        self.assertEqual(call_args.args[0], "POST")
        self.assertEqual(call_args.args[1], "https://webhook.example.com/x")
        sent_body = call_args.kwargs["body"].decode("utf-8")
        sent_payload = json.loads(sent_body)
        self.assertEqual(sent_payload["eventType"], "incident")
        self.assertEqual(sent_payload["action"], "created")

        headers = call_args.kwargs["headers"]
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertIn("x-amzn-event-timestamp", headers)
        self.assertIn("x-amzn-event-signature", headers)

        # Verify the signature with the timestamp we sent.
        ts = headers["x-amzn-event-timestamp"]
        expected_sig = base64.b64encode(
            hmac.new(b"topsecret", f"{ts}:{sent_body}".encode(), hashlib.sha256).digest()
        ).decode()
        self.assertEqual(headers["x-amzn-event-signature"], expected_sig)

    def test_lambda_handler_swallows_webhook_5xx(self) -> None:
        handler = _fresh_handler_module()
        ssm_mock = MagicMock()
        ssm_mock.get_parameters.return_value = {
            "Parameters": [
                {"Name": "/devops-agent/webhook-url", "Value": "https://webhook.example.com/x"},
                {"Name": "/devops-agent/webhook-secret", "Value": "topsecret"},
            ]
        }
        handler._SSM = ssm_mock

        http_mock = MagicMock()
        fake_response = MagicMock()
        fake_response.status = 503
        fake_response.data = b"upstream blew up"
        http_mock.request.return_value = fake_response
        handler._HTTP = http_mock
        handler._WEBHOOK_URL = None
        handler._WEBHOOK_SECRET = None

        result = handler.lambda_handler(self.sample_event, context=None)
        self.assertEqual(result["results"][0]["status"], 503)
        self.assertFalse(result["results"][0]["ok"])
        # Crucially: did NOT raise.

    def test_lambda_handler_swallows_network_failure(self) -> None:
        handler = _fresh_handler_module()
        ssm_mock = MagicMock()
        ssm_mock.get_parameters.return_value = {
            "Parameters": [
                {"Name": "/devops-agent/webhook-url", "Value": "https://webhook.example.com/x"},
                {"Name": "/devops-agent/webhook-secret", "Value": "topsecret"},
            ]
        }
        handler._SSM = ssm_mock

        http_mock = MagicMock()
        http_mock.request.side_effect = ConnectionError("dns blackhole")
        handler._HTTP = http_mock
        handler._WEBHOOK_URL = None
        handler._WEBHOOK_SECRET = None

        result = handler.lambda_handler(self.sample_event, context=None)
        self.assertEqual(result["results"][0]["status"], 0)
        self.assertFalse(result["results"][0]["ok"])

    def test_no_alarms_returns_zero(self) -> None:
        handler = _fresh_handler_module()
        result = handler.lambda_handler({"Records": []}, context=None)
        self.assertEqual(result["processed"], 0)


if __name__ == "__main__":
    unittest.main()
