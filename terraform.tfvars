ami_id        = ""
key_name      = ""
aws_region    = "eu-west-2"
instance_type = "t3.micro"

# Restrict SSH to your IP for better security, e.g. "203.0.113.0/32"
ssh_allowed_cidr = "0.0.0.0/0"

notification_email = ""

# Cloudflare - find both values in the Cloudflare dashboard under your domain
cloudflare_api_token = ""
cloudflare_zone_id   = ""
