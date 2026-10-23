# Interface VPC endpoints for a cluster with no internet egress. Each one has
# private DNS on, so the AWS SDKs and the kubelet reach the regional service
# name through the endpoint with no client configuration. The S3 gateway
# endpoint lives in the storage module.
resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "HTTPS from the VPC to its interface endpoints"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

resource "aws_vpc_endpoint" "this" {
  for_each = toset(var.services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.this.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name}-${each.value}"
  }
}
