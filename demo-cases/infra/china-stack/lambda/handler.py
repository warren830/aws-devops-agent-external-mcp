"""
etl-trigger Lambda — stub.

Pushes 100 stub items into the etl-jobs SQS queue, then logs a summary.

This is intentionally a placeholder. Real ETL trigger logic will be filled
in later — for now we just want a callable function for EventBridge to
schedule and for case C3's manual invoke step.
"""

import json
import logging
import os
import time
import uuid

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

QUEUE_URL = os.environ.get("ETL_QUEUE_URL", "")
ITEMS_PER_RUN = int(os.environ.get("ITEMS_PER_RUN", "100"))

sqs = boto3.client("sqs")


def _build_messages(n: int):
    now = int(time.time())
    for i in range(n):
        yield {
            "Id": str(i),
            "MessageBody": json.dumps(
                {
                    "job_id": str(uuid.uuid4()),
                    "seq": i,
                    "batch_ts": now,
                    "payload": {"sku": f"sku-{i:05d}", "qty": 1},
                }
            ),
        }


def lambda_handler(event, context):
    logger.info("etl-trigger invoked", extra={"event": event})

    if not QUEUE_URL:
        logger.error("ETL_QUEUE_URL not set; nothing to do")
        return {"status": "skipped", "reason": "no-queue-url"}

    sent = 0
    failed = 0
    batch = []
    for msg in _build_messages(ITEMS_PER_RUN):
        batch.append(msg)
        if len(batch) == 10:  # SQS SendMessageBatch max is 10
            resp = sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=batch)
            sent += len(resp.get("Successful", []))
            failed += len(resp.get("Failed", []))
            batch = []
    if batch:
        resp = sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=batch)
        sent += len(resp.get("Successful", []))
        failed += len(resp.get("Failed", []))

    logger.info(
        "etl-trigger done", extra={"sent": sent, "failed": failed, "queue": QUEUE_URL}
    )
    return {"status": "ok", "sent": sent, "failed": failed}
