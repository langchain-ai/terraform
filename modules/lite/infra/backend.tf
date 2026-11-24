# Local state: terraform.tfstate in this directory (gitignored).
#
# State holds every generated credential (secrets.tf), so treat the file as a secret: keep it out of
# git and back it up beside infra/.secrets.env and the box's data (OPERATE.md, Keeping its data). To
# move state elsewhere later, replace this block and run `terraform init -migrate-state`.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
