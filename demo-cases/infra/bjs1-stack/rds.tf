# ----------------------------------------------------------------------------
# RDS PostgreSQL `bjs-todo-db`
#
# DELIBERATE FAULT (L1): single-AZ on purpose. Case C6 (predictive evaluation)
# expects this to surface as a 30-day risk finding. DO NOT switch to multi-AZ.
# ----------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "bjs-todo-db-sg"
  description = "Allow Postgres from inside VPC only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Postgres from VPC CIDR (default VPC 172.31.0.0/16)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bjs-todo-db-sg"
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "bjs-todo-db-subnets"
  subnet_ids = local.one_subnet_per_az

  tags = {
    Name = "bjs-todo-db-subnets"
  }
}

resource "aws_db_instance" "todo" {
  identifier        = "bjs-todo-db"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # === DELIBERATE FAULT L1: single-AZ on purpose. ===
  multi_az = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  apply_immediately       = true
  deletion_protection     = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = {
    Name = "bjs-todo-db"
    Risk = "L1-single-az"
  }
}

# Stash the password in Secrets Manager so apps / agent can pull it later.
resource "aws_secretsmanager_secret" "db" {
  name                    = "bjs-todo-db/master"
  description             = "Master credentials for bjs-todo-db Postgres instance"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = aws_db_instance.todo.username
    password = random_password.db_password.result
    host     = aws_db_instance.todo.address
    port     = aws_db_instance.todo.port
    dbname   = aws_db_instance.todo.db_name
    engine   = "postgres"
  })
}
