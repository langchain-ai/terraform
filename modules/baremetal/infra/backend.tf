# Local state: terraform.tfstate in this directory (gitignored).
#
# State holds every generated datastore password, so treat the file as a
# secret: keep it out of git and back it up with infra/.secrets.env. To move
# state elsewhere later, replace this block and run `terraform init -migrate-state`.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
