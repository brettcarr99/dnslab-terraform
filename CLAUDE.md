# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Terraform-managed DNS lab in AWS that simulates a full recursive DNS resolution chain. Four EC2 instances are deployed into a single VPC, each running a different role in the DNS hierarchy:

- **root server** (`10.0.1.10`) — BIND, authoritative for `.`, delegates `lab.` to the TLD
- **TLD server** (`10.0.1.11`) — BIND, authoritative for `lab.`, delegates `example.lab.` to the 2LD
- **2LD/SLD server** (`10.0.1.12`) — BIND, authoritative for `example.lab.`, answers `www.example.lab A`
- **resolver** (`10.0.1.13`) — Unbound, configured with a custom root hints file pointing at the lab root server instead of the real internet roots

Private IPs are statically assigned (computed via `cidrhost` in `locals`) so they can be safely templated into user-data scripts at plan time.

Cloudflare DNS records (A records for `rootdns`, `tlddns`, `2lddns`, `resolver` on `pwei.uk`) are managed alongside the AWS infrastructure so public hostnames track the elastic IPs.

## Common commands

```bash
terraform init          # first time or after provider changes
terraform plan          # preview changes
terraform apply         # deploy / update
terraform destroy       # tear down everything
```

Validate user-data scripts locally (syntax only — they require a running EC2 instance for full execution):

```bash
bash -n user_data/root.sh
bash -n user_data/tld.sh
bash -n user_data/sld.sh
bash -n user_data/resolver.sh
```

After apply, use the `test_commands` output to verify the DNS chain is working (~2 min for user-data to complete):

```bash
terraform output test_commands
```

## Key architecture notes

**User-data templating**: Each `user_data/*.sh` script is a Terraform `templatefile`. Variables are injected at `terraform apply` time (e.g., `${root_ip}`, `${tld_ip}`). Changing any variable causes `user_data_replace_on_change = true` to trigger instance replacement, not just a reboot.

**Static private IPs**: All four IPs are fixed in `locals` in `main.tf` so they can be referenced before instances exist. The subnet is `10.0.1.0/24`; hosts `.10`–`.13` are reserved for the lab servers.

**S3 script bucket**: `chronicled-install.sh` (AWS Chronicle security agent installer) is uploaded to an account-scoped S3 bucket and pulled down by each instance at boot via `aws s3 cp`. IAM permissions for S3 read and SNS publish are in `iam.tf`.

**SNS notifications**: Each server publishes to `dns-lab-notifications` when setup completes and before rebooting. Subscribe `notification_email` in `terraform.tfvars` to receive these.

**Required tfvars** (`terraform.tfvars`, gitignored): `ami_id`, `key_name`, `cloudflare_api_token`, `cloudflare_zone_id`, `notification_email`. Optional overrides: `aws_region`, `instance_type`, `vpc_cidr`, `subnet_cidr`, `ssh_allowed_cidr`.
