# LangSmith Azure modules
This folder containers helpful starting terraform modules to get a self-hosted version of LangSmith up and running in Azure. Keep in mind that these are meant to be starting points. You may want to modify some of these Terraform modules depending on any internal standards (example: adding certain tags to resources).

We provide the following modules here:
- LangSmith (uses the other modules under the hood)
- Virtual Network (VNet) module
- AKS (Managed Kubernetes) module
- Redis cache module (with optional Redis cluster)
- PostgreSQL Flexible DB module
- Azure blob module

You can use an existing VNet instead of creating one by setting the `create_vnet` variable to false. If you bring your own vertual network, you will need to provide a couple of variables mentioned in `langsmith/variables.tf`

## LangSmith Quick Start
You can clone or fork this repo. Decide where you want to keep your terraform state:
- (Recommended) If you want to keep your terraform state in an Azure container, comment out backend.tf and update as needed.
- If you want to keep your terraform state locally, then no changes are needed.

Provide the `subscription_id` variable for your Azure subscription. Determine if you want to create a new VPC or use an existing one. If you want to use an existing VPC, set the `create_vnet` variable to false and you will need to provide `vnet_id`, `aks_subnet_id`, `postgres_subnet_id`, and `redis_subnet_id` as variables.

Note that the default region for this module is `eastus`. You can change that variable as needed.

Make sure you have valid Azure credentials locally that have the permissions to create the resources, or you can add relevant fields to the `provider "azurerm"` block. See the [official Terraform provider page](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) for more information. You may just need to simply run an `az login` command to get credentials locally.

Then run the following commands from the `langsmith` folder:

```
$ terraform init
$ terraform apply
```

You will be prompted to enter your desired postgres_password and postgres_username for the database that will be created. Check out the terraform plan and confirm to create the resources.

Afterwards, you may want to fetch the kubeconfig locally with a command like this:
```
az aks get-credentials --resource-group <resource-group> --name <cluster-name>
```

Once everything is created, fill out the values_azure.yaml file with your [desired configuration](https://docs.smith.langchain.com/self_hosting/configuration) and follow our [helm installation instructions](https://docs.smith.langchain.com/self_hosting/installation/kubernetes#deploying-to-kubernetes). You can use the terraform output from the LangSmith module to fill in things like the redis and postgres connection URL and blob storage authentication.
