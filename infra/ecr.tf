resource "aws_ecr_repository" "demo_crm" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_destroy # allows cleanup workflow to delete repo with images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    project = "CloudOps_CRM"
  }

  # prevent_destroy removed — use ecr_force_destroy=false (default) for safety;
  # the cleanup workflow passes ecr_force_destroy=true to allow full teardown.
}
