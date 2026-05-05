# redis: Provisions an ElastiCache Redis replication group in a private subnet.
# https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.html

# Define the Redis security group
resource "aws_security_group" "redis_sg" {
  name        = "${var.name}-sg"
  description = "Allow inbound traffic from EKS to Redis"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr_block]
  }
}

resource "aws_elasticache_subnet_group" "elasticache_subnet_group" {
  name       = "${var.name}-subnet-group"
  subnet_ids = var.subnet_ids
}

# The actual Redis instance
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = var.name
  description          = "LangSmith Redis"
  node_type            = var.instance_type
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  security_group_ids   = [aws_security_group.redis_sg.id]
  subnet_group_name    = aws_elasticache_subnet_group.elasticache_subnet_group.name
  apply_immediately    = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.auth_token
}
