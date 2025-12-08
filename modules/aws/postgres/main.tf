resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.identifier}-sg"
  description = "Allow PostgreSQL access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres ingress"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "this" {
  identifier            = var.identifier
  db_name               = var.db_name
  engine                = "postgres"
  engine_version        = var.engine_version
  instance_class        = var.instance_type
  allocated_storage     = var.storage_gb
  max_allocated_storage = var.max_storage_gb
  username              = var.username
  password              = var.password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  deletion_protection    = true

  iam_database_authentication_enabled = var.iam_database_authentication_enabled

  # Prevents terraform from trying to downsize a database that scaled up automatically.
  # To manually increase the storage, you can use the AWS console.
  lifecycle {
    ignore_changes = [allocated_storage]
  }
}

# IAM policy for RDS IAM authentication
# This policy allows connecting to the database using IAM credentials
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_policy" "rds_iam_auth" {
  count = var.iam_database_authentication_enabled && var.iam_database_user != null ? 1 : 0

  name        = "${var.identifier}-rds-iam-auth"
  description = "Allows IAM authentication to RDS PostgreSQL instance ${var.identifier}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "rds-db:connect"
        Resource = "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.this.resource_id}/${var.iam_database_user}"
      }
    ]
  })
}

# NOTE: The IAM database user must be created manually in PostgreSQL.
# Connect as the admin user and run:
#
#   CREATE USER <iam_database_user>;
#   GRANT rds_iam TO <iam_database_user>;
#   GRANT ALL PRIVILEGES ON DATABASE <db_name> TO <iam_database_user>;
#   GRANT USAGE ON SCHEMA public TO <iam_database_user>;
#   GRANT ALL PRIVILEGES ON SCHEMA public TO <iam_database_user>;
#   GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO <iam_database_user>;
#   GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO <iam_database_user>;
#   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO <iam_database_user>;
#   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO <iam_database_user>;
