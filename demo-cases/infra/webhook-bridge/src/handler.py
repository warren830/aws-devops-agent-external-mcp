"""
CloudWatch Alarm -> AWS DevOps Agent Webhook Bridge.

Architecture role
-----------------
AWS DevOps Agent's webhook endpoint lives in a non-China partition (us-east-1
or another global region). CloudWatch alarms in China (cn-north-1 / cn-northwest-1)
cannot directly invoke an HTTPS endpoint outside the cn-* partition via the
DevOps Agent SDK because DevOps Agent has no cn-* presence. This Lambda is the
bridge:

  CloudWatch Alarm  ->  SNS Topic  ->  THIS LAMBDA  ->  HTTPS POST (HMAC-signed)
                                                          ->  DevOps Agent webhook

Inputs
------
- SNS event with a CloudWatch alarm payload nested inside ``Sns.Message`` (JSON string).
- Webhook URL + secret read at cold start from SSM Parameter Store:
    /devops-agent/webhook-url    (String)
    /devops-agent/webhook-secret (SecureString)

Output
------
A signed POST to the DevOps Agent webhook URL with payload schema documented in
``aws-docs/03-building-end-to-end-agentic-sre.md``.

Design notes
------------
- Uses ``urllib3`` (bundled in AWS Lambda Python 3.12 base image via ``botocore``).
  No external deps needed -> faster cold start, simpler deployment.
- SSM parameters are fetched once per cold start and cached in module-level
  globals. This is safe because the bridge is single-tenant per Lambda.
- On webhook 4xx/5xx we LOG the error but do not raise: SNS is fire-and-forget
  for incident notifications; we'd rather lose one alert than have SNS retry-storm.
- Structured JSON logging so CloudWatch Logs Insights can query reliably.
"""
from __future__ import annotations

import base64
import datetime as _dt
import hashlib
import hmac
import json
import logging
import os
from typing import Any

import boto3
import urllib3

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Lambda's default log handler already exists; we just set the level and
# emit JSON-formatted records ourselves via _log().
logging.getLogger().setLevel(logging.INFO)
_LOG = logging.getLogger(__name__)


def _log(level: str, event: str, **fields: Any) -> None:
    """Emit a single-line JSON log record."""
    record = {"level": level, "event": event, **fields}
    try:
        msg = json.dumps(record, default=str)
    except Exception:  # pragma: no cover - defensive
        msg = json.dumps({"level": level, "event": event, "_serialize_error": True})
    getattr(_LOG, level.lower(), _LOG.info)(msg)


# ---------------------------------------------------------------------------
# Module-level configuration. Read once per cold start.
# ---------------------------------------------------------------------------
SSM_PREFIX = os.environ.get("SSM_PARAMETER_PREFIX", "/devops-agent")
WEBHOOK_URL_PARAM = f"{SSM_PREFIX}/webhook-url"
WEBHOOK_SECRET_PARAM = f"{SSM_PREFIX}/webhook-secret"

_HTTP = urllib3.PoolManager(
    num_pools=2,
    timeout=urllib3.Timeout(connect=5.0, read=10.0),
    retries=False,  # We do NOT want urllib3 to retry; one shot only.
)
_SSM = boto3.client("ssm")

# Cached SSM values. None means "not loaded yet". Use _load_config() to populate.
_WEBHOOK_URL: str | None = None
_WEBHOOK_SECRET: str | None = None


def _load_config() -> tuple[str, str]:
    """Lazy-load webhook URL + secret from SSM. Cached for the life of the container."""
    global _WEBHOOK_URL, _WEBHOOK_SECRET
    if _WEBHOOK_URL is not None and _WEBHOOK_SECRET is not None:
        return _WEBHOOK_URL, _WEBHOOK_SECRET

    resp = _SSM.get_parameters(
        Names=[WEBHOOK_URL_PARAM, WEBHOOK_SECRET_PARAM],
        WithDecryption=True,
    )
    by_name = {p["Name"]: p["Value"] for p in resp.get("Parameters", [])}
    missing = [n for n in (WEBHOOK_URL_PARAM, WEBHOOK_SECRET_PARAM) if n not in by_name]
    if missing:
        raise RuntimeError(f"Missing SSM parameters: {missing}")

    _WEBHOOK_URL = by_name[WEBHOOK_URL_PARAM]
    _WEBHOOK_SECRET = by_name[WEBHOOK_SECRET_PARAM]
    return _WEBHOOK_URL, _WEBHOOK_SECRET


# ---------------------------------------------------------------------------
# Mappings
# ---------------------------------------------------------------------------
# CloudWatch alarm state -> DevOps Agent action.
_STATE_TO_ACTION = {
    "ALARM": "created",
    "OK": "resolved",
    "INSUFFICIENT_DATA": "updated",
}

# CloudWatch namespace -> short service token used in payload.
# Extend as new alarm sources appear.
_NAMESPACE_TO_SERVICE = {
    "AWS/ApplicationELB": "ALB",
    "AWS/NetworkELB": "NLB",
    "AWS/ELB": "ELB",
    "AWS/EC2": "EC2",
    "AWS/Lambda": "Lambda",
    "AWS/RDS": "RDS",
    "AWS/DynamoDB": "DynamoDB",
    "AWS/ECS": "ECS",
    "AWS/EKS": "EKS",
    "AWS/ApiGateway": "ApiGateway",
    "AWS/CloudFront": "CloudFront",
    "AWS/S3": "S3",
    "AWS/SQS": "SQS",
    "AWS/SNS": "SNS",
    "AWS/Logs": "CloudWatchLogs",
    "AWS/States": "StepFunctions",
    "AWS/Kinesis": "Kinesis",
    "AWS/CloudWatch": "CloudWatch",
}

# Heuristic priority fallback by namespace if the alarm has no Priority tag
# AND we couldn't resolve one another way. Tweak as ops experience accumulates.
_NAMESPACE_PRIORITY_HEURISTIC = {
    "AWS/Logs": "LOW",        # Log-based alarms tend to be noisier / lower urgency.
    "AWS/Billing": "LOW",
    "AWS/CloudWatch": "LOW",
    "AWS/ApplicationELB": "HIGH",
    "AWS/RDS": "HIGH",
    "AWS/Lambda": "MEDIUM",
}

_VALID_PRIORITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW", "MINIMAL"}


def _namespace_to_service(namespace: str | None) -> str:
    if not namespace:
        return "Unknown"
    if namespace in _NAMESPACE_TO_SERVICE:
        return _NAMESPACE_TO_SERVICE[namespace]
    # Best-effort: strip "AWS/" prefix if present.
    return namespace.split("/", 1)[1] if namespace.startswith("AWS/") else namespace


# Lazily-built CloudWatch client (only when we need to fetch alarm tags).
_CW_CLIENT_CACHE: dict[str, Any] = {}


def _cloudwatch_client(region: str | None):
    if not region:
        return None
    if region not in _CW_CLIENT_CACHE:
        _CW_CLIENT_CACHE[region] = boto3.client("cloudwatch", region_name=region)
    return _CW_CLIENT_CACHE[region]


def _resolve_priority(alarm_arn: str | None, alarm_region: str | None, namespace: str | None) -> str:
    """Read alarm Priority tag if available, else fall back to namespace heuristic, else HIGH."""
    if alarm_arn and alarm_region:
        try:
            cw = _cloudwatch_client(alarm_region)
            if cw is not None:
                resp = cw.list_tags_for_resource(ResourceARN=alarm_arn)
                for tag in resp.get("Tags", []):
                    if tag.get("Key") == "Priority":
                        candidate = (tag.get("Value") or "").upper().strip()
                        if candidate in _VALID_PRIORITIES:
                            return candidate
        except Exception as exc:  # noqa: BLE001 - tag fetch is best-effort
            _log("warning", "priority_tag_fetch_failed",
                 alarm_arn=alarm_arn, error=str(exc))

    # Heuristic fallback by namespace.
    if namespace and namespace in _NAMESPACE_PRIORITY_HEURISTIC:
        return _NAMESPACE_PRIORITY_HEURISTIC[namespace]

    return "HIGH"


# ---------------------------------------------------------------------------
# Payload construction
# ---------------------------------------------------------------------------
def _build_payload(alarm: dict[str, Any]) -> dict[str, Any]:
    """Convert a CloudWatch alarm SNS message dict to the DevOps Agent webhook schema."""
    alarm_name: str = alarm.get("AlarmName", "unknown-alarm")
    alarm_description: str = alarm.get("AlarmDescription") or ""
    new_state: str = alarm.get("NewStateValue", "ALARM")
    new_state_reason: str = alarm.get("NewStateReason") or ""
    state_change_time: str = alarm.get("StateChangeTime") or ""
    region: str = alarm.get("Region") or alarm.get("AWSRegion") or ""
    account_id: str = alarm.get("AWSAccountId") or ""
    alarm_arn: str | None = alarm.get("AlarmArn")
    resources = alarm.get("Resources") or []

    trigger = alarm.get("Trigger") or {}
    namespace = trigger.get("Namespace")
    metric_name = trigger.get("MetricName")
    statistic = trigger.get("Statistic") or trigger.get("ExtendedStatistic")

    action = _STATE_TO_ACTION.get(new_state, "updated")
    service = _namespace_to_service(namespace)

    # AlarmArn region is more reliable than the human-readable Region field.
    alarm_region = None
    if isinstance(alarm_arn, str) and alarm_arn.startswith("arn:"):
        try:
            alarm_region = alarm_arn.split(":")[3]
        except IndexError:
            alarm_region = None

    priority = _resolve_priority(alarm_arn, alarm_region, namespace)

    timestamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    # IncidentId: stable per-alarm-event so DevOps Agent can group updates.
    # Use stateChangeTime if available; falls back to current timestamp.
    id_suffix = state_change_time or timestamp
    # Replace characters that look funky in identifiers.
    id_suffix = id_suffix.replace(" ", "T").replace(":", "").replace(".", "")
    incident_id = f"{alarm_name}-{id_suffix}"

    return {
        "eventType": "incident",
        "incidentId": incident_id,
        "action": action,
        "priority": priority,
        "title": alarm_name,
        "description": alarm_description or new_state_reason,
        "timestamp": timestamp,
        "service": service,
        "data": {
            "alarmName": alarm_name,
            "alarmDescription": alarm_description,
            "newStateValue": new_state,
            "newStateReason": new_state_reason,
            "stateChangeTime": state_change_time,
            "region": region or alarm_region or "",
            "accountId": account_id,
            "resources": resources,
            "trigger": {
                "metricName": metric_name,
                "namespace": namespace,
                "statistic": statistic,
            },
        },
    }


# ---------------------------------------------------------------------------
# HMAC signing
# ---------------------------------------------------------------------------
def _sign(secret: str, timestamp: str, body: str) -> str:
    """HMAC-SHA256 over '<timestamp>:<body>', base64-encoded."""
    string_to_sign = f"{timestamp}:{body}".encode("utf-8")
    digest = hmac.new(secret.encode("utf-8"), string_to_sign, hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


# ---------------------------------------------------------------------------
# Webhook POST
# ---------------------------------------------------------------------------
def _post_webhook(url: str, secret: str, payload: dict[str, Any]) -> tuple[int, str]:
    """Send the signed POST. Returns (status_code, body_excerpt). Never raises."""
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    timestamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    signature = _sign(secret, timestamp, body)
    headers = {
        "Content-Type": "application/json",
        "x-amzn-event-timestamp": timestamp,
        "x-amzn-event-signature": signature,
    }
    try:
        resp = _HTTP.request(
            "POST",
            url,
            body=body.encode("utf-8"),
            headers=headers,
        )
        excerpt = resp.data[:500].decode("utf-8", errors="replace") if resp.data else ""
        return resp.status, excerpt
    except Exception as exc:  # noqa: BLE001 - we deliberately swallow
        _log("error", "webhook_post_failed", error=str(exc), url_host=_extract_host(url))
        return 0, str(exc)


def _extract_host(url: str) -> str:
    try:
        # Avoid logging full URL since it may include identifying tokens.
        from urllib.parse import urlparse

        return urlparse(url).hostname or "unknown"
    except Exception:  # pragma: no cover
        return "unknown"


# ---------------------------------------------------------------------------
# SNS event parsing
# ---------------------------------------------------------------------------
def _extract_alarms(event: dict[str, Any]) -> list[dict[str, Any]]:
    """Pull CloudWatch alarm dicts out of an SNS Lambda event.

    SNS-from-CloudWatch packs the alarm JSON into ``Records[*].Sns.Message`` as
    a string. This helper handles both that shape and a direct alarm dict (for
    convenience when invoking the function manually).
    """
    if "Records" in event:
        alarms: list[dict[str, Any]] = []
        for record in event["Records"]:
            sns = record.get("Sns") or {}
            raw_msg = sns.get("Message")
            if not raw_msg:
                continue
            if isinstance(raw_msg, dict):
                alarms.append(raw_msg)
                continue
            try:
                parsed = json.loads(raw_msg)
            except json.JSONDecodeError:
                _log("warning", "sns_message_not_json", excerpt=raw_msg[:200])
                continue
            if isinstance(parsed, dict):
                alarms.append(parsed)
        return alarms

    # Direct invocation with a raw alarm dict (for tests).
    if "AlarmName" in event:
        return [event]

    return []


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """SNS-triggered Lambda entrypoint."""
    alarms = _extract_alarms(event)
    if not alarms:
        _log("warning", "no_alarms_in_event")
        return {"processed": 0}

    try:
        webhook_url, webhook_secret = _load_config()
    except Exception as exc:  # noqa: BLE001
        _log("error", "config_load_failed", error=str(exc))
        # Re-raise here: missing config is an operator error, not a runtime issue.
        raise

    results: list[dict[str, Any]] = []
    for alarm in alarms:
        payload = _build_payload(alarm)
        status, excerpt = _post_webhook(webhook_url, webhook_secret, payload)
        ok = 200 <= status < 300
        log_fn = "info" if ok else "error"
        _log(
            log_fn,
            "webhook_post_result",
            status=status,
            ok=ok,
            incident_id=payload["incidentId"],
            action=payload["action"],
            priority=payload["priority"],
            service=payload["service"],
            response_excerpt=excerpt if not ok else None,
        )
        results.append({"incidentId": payload["incidentId"], "status": status, "ok": ok})

    return {"processed": len(alarms), "results": results}
