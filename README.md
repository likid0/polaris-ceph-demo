# Polaris-Ceph Terraform Demo

A proof-of-concept showing how to use Terraform to fully automate a Polaris data catalog deployment on Ceph Object Gateway (RGW). This includes:

- Provisioning Ceph RGW S3 buckets, IAM roles, and policies
- Deploying the Polaris control plane and Jupyter Notebook via Docker Compose
- Configuring Polaris resources (principals, roles, grants, tables)
- Demonstrating credential vending and fine-grained table RBAC in an interactive notebook

---

## Repository Structure

```
.
├── ceph
│   ├── ceph-resources.tf      # RGW S3 & IAM Terraform module
│   ├── envfile.tf             # Terraform environment provider setup
│   └── terraform.tfvars       # User-supplied Ceph variables
├── demo.sh                    # Orchestrates the full demo (up/destroy)
├── docker-compose.yml         # Brings up Polaris & Jupyter services
├── LICENSE
├── notebooks                  # Interactive demo notebooks & assets
│   ├── demo.ipynb
│   ├── SparkPolaris.ipynb
│   ├── products.csv
│   ├── rbac_workflow.png
│   └── tokens.json
├── polaris                    # Polaris Terraform module & helper scripts
│   ├── main.tf               
│   ├── variables.tf           # User-supplied Polaris variables
│   └── scripts
│       ├── fetch_token.sh     # Helper to get Polaris API token
│       └── log-reader.sh      # Tail Polaris logs
├── spark
│   └── conf
│       └── spark-defaults.conf
```

---

## Prerequisites

1. **Ceph RGW Account**: Create an RGW account and IAM root user for the account:



   ```bash
   radosgw-admin account create \
   --uid=polaris-account \
   --display-name="Polaris Account"

   radosgw-admin user create \
   --uid=polaris-account \
   --display-name="Polaris Root" \
   --email=polaris@example.com \
   --access-key=POLARIS_ROOT_KEY \
   --secret=POLARIS_ROOT_SECRET
   ```

   Note the generated **Account ID** (e.g. `RGW9470590896XXXX`).

2. **AWS Credentials File**: Add your Ceph S3 keys to `~/.aws/credentials` under a profile:

   ```ini
   [polaris-root]
   aws_access_key_id = POLARIS_ROOT_KEY
   aws_secret_access_key = POLARIS_ROOT_SECRET
   ```

3. **Install**: Terraform >= 1.0, Podman, and Podman Compose.

---

## Configuration

### `ceph/terraform.tfvars`

Edit these values to match your RGW setup:

```hcl
ceph_endpoint       = "https://s3.example.com"
credentials_profile = "polaris-root"
bucket_name         = "polarisdemo"
account_arn         = "RGW9470590896XXXX"
location            = "s3://polarisdemo"
```

### `polaris/variables.tf`

Override only if you changed defaults:

```hcl
auth_token  = "principal:root;realm:default-realm"
s3_role_arn = "arn:aws:iam::RGW9470590896XXXX:role/polaris/catalog/client"
```

---

## Running the Demo

From the repository root, run:

```bash
# Bring up all resources
./demo.sh up

# When finished, destroy everything
./demo.sh destroy
```

This will:
1. Provision RGW S3 bucket, IAM roles & policies via Terraform
2. Deploy Polaris control plane & Jupyter Notebook via Docker Compose
3. Configure Polaris catalog principals, roles, grants, and tables
4. Launch an interactive notebook demonstrating credential vending & RBAC

Once complete, you will get the jupyter URL to login with your browser and run `notebooks/demo.ipynb`.

---

