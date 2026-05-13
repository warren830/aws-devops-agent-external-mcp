###############################################################################
# RDS MySQL — multi-AZ db.t3.micro.
# This is the GOOD one: multi-AZ ON. Used for cross-account compare in
# case C4 / C8 with bjs1's deliberately single-AZ Postgres.
###############################################################################

# Subnet group across all default-VPC subnets
resource "aws_db_subnet_group" "china_data" {
  name        = "${var.name_prefix}-mysql"
  description = "Subnet group for china-data MySQL"
  subnet_ids  = data.aws_subnets.default.ids

  tags = {
    Name = "${var.name_prefix}-mysql"
  }
}

# Security group: allow MySQL only from ECS tasks SG
resource "aws_security_group" "rds_mysql" {
  name        = "${var.name_prefix}-rds-mysql"
  description = "Allow MySQL from ECS tasks only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from ECS tasks"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-rds-mysql"
  }
}

resource "aws_db_instance" "china_data" {
  identifier     = "china-data-db"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.rds_db_name
  username = var.rds_master_username
  password = var.rds_master_password

  multi_az = true # ✅ deliberately good — for cross-account compare in C4/C8

  db_subnet_group_name   = aws_db_subnet_group.china_data.name
  vpc_security_group_ids = [aws_security_group.rds_mysql.id]
  publicly_accessible    = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  performance_insights_enabled = false # save cost; enable on demand for C9

  tags = {
    Name = "china-data-db"
    Tier = "data"
  }
}
