# Dedicated RDS PostgreSQL metastore for SmithDB.
# All SmithDB pods except the cluster manager connect to this instance.
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html

resource "aws_db_subnet_group" "metastore" {
  count = local.create_rds ? 1 : 0

  name       = "${local.rds_identifier}-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}

resource "aws_security_group" "metastore" {
  count = local.create_rds ? 1 : 0

  name        = "${local.rds_identifier}-sg"
  description = "SmithDB metastore Postgres access for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

# Only the EKS worker nodes (where the SmithDB pods run) may reach the metastore.
resource "aws_vpc_security_group_ingress_rule" "metastore_from_nodes" {
  count = local.create_rds ? 1 : 0

  security_group_id            = aws_security_group.metastore[0].id
  description                  = "Postgres from EKS worker nodes"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.eks_node_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "metastore_egress" {
  count = local.create_rds ? 1 : 0

  security_group_id = aws_security_group.metastore[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "random_password" "metastore" {
  count = local.create_rds && var.metastore_master_password == null ? 1 : 0

  length  = 32
  special = false
}

resource "aws_db_instance" "metastore" {
  count = local.create_rds ? 1 : 0

  identifier                = local.rds_identifier
  engine                    = "postgres"
  engine_version            = var.metastore_engine_version
  instance_class            = var.metastore_instance_class
  allocated_storage         = var.metastore_allocated_storage
  storage_type              = "gp3"
  storage_encrypted         = true
  db_name                   = local.rds_db_name
  username                  = var.metastore_master_username
  password                  = local.rds_master_password
  vpc_security_group_ids    = [aws_security_group.metastore[0].id]
  db_subnet_group_name      = aws_db_subnet_group.metastore[0].name
  publicly_accessible       = false
  multi_az                  = var.metastore_multi_az
  deletion_protection       = var.metastore_deletion_protection
  backup_retention_period   = var.metastore_backup_retention_period
  skip_final_snapshot       = var.metastore_skip_final_snapshot
  final_snapshot_identifier = var.metastore_skip_final_snapshot ? null : "${local.rds_identifier}-final"
  tags                      = local.tags

  lifecycle {
    ignore_changes = [allocated_storage]
  }
}
