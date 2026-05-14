brew install terraform

cd /Users/brettcarr/dns-lab

terraform init      # download AWS provider, first time only
terraform plan      # preview what will be created
terraform apply     # deploy — type 'yes' when prompted

Tear it down

terraform destroy
