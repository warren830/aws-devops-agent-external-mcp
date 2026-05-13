###############################################################################
# DynamoDB table that stores ETL state.
# BASE state: PAY_PER_REQUEST (on-demand). Fault-inject script L5 will switch
# this to PROVISIONED with WCU=5 to drive throttle for case C3.
#
# We use ignore_changes on billing_mode + provisioned_throughput so that
# terraform doesn't fight the inject script.
###############################################################################
resource "aws_dynamodb_table" "etl_state" {
  name         = "etl-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = false
  }

  lifecycle {
    ignore_changes = [
      billing_mode,
      read_capacity,
      write_capacity,
    ]
  }

  tags = {
    Name = "etl-state"
  }
}
