"""ETL worker stub.

Polls the etl-jobs SQS queue, "processes" each message by writing a row to
the etl-state DynamoDB table. Designed for the L5 / C3 demo cases where:

- Container memory limit (set to 256 MB at the container level by the
  task definition) intentionally allows OOM under high concurrency
- DynamoDB table is on PAY_PER_REQUEST in the base state; the L5 inject
  script switches to PROVISIONED 5 WCU to drive throttling

This script is deliberately minimal — just enough to consume messages and
produce real CloudWatch metrics for the agent to investigate.
"""
import json
import os
import time
import uuid

import boto3

QUEUE_URL = os.environ["SQS_QUEUE_URL"]
TABLE_NAME = os.environ.get("DDB_TABLE_NAME", "etl-state")
REGION = os.environ.get("AWS_REGION", "cn-northwest-1")

sqs = boto3.client("sqs", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)


def process_message(body: str) -> None:
    """Write a single row to DynamoDB. Failures bubble up to caller."""
    payload = json.loads(body) if body else {"raw": ""}
    item = {
        "job_id": {"S": payload.get("job_id", str(uuid.uuid4()))},
        "processed_at": {"N": str(int(time.time()))},
        "status": {"S": "processed"},
        "size_kb": {"N": str(payload.get("size_kb", 1))},
    }
    ddb.put_item(TableName=TABLE_NAME, Item=item)


def main() -> None:
    print(f"etl-worker starting. queue={QUEUE_URL} table={TABLE_NAME}", flush=True)
    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                VisibilityTimeout=60,
            )
        except Exception as exc:
            print(f"SQS receive failed: {exc}", flush=True)
            time.sleep(5)
            continue

        messages = resp.get("Messages", [])
        if not messages:
            continue

        for m in messages:
            try:
                process_message(m.get("Body", ""))
                sqs.delete_message(
                    QueueUrl=QUEUE_URL, ReceiptHandle=m["ReceiptHandle"]
                )
            except Exception as exc:
                # Don't delete on error — visibility timeout will requeue.
                print(f"process_message failed: {exc}", flush=True)


if __name__ == "__main__":
    main()
