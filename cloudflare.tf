provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  cf_records = {
    root     = aws_instance.root_server.public_ip
    tld      = aws_instance.tld_server.public_ip
    sld      = aws_instance.sld_server.public_ip
    resolver = aws_instance.resolver.public_ip
  }
}

resource "cloudflare_record" "dns_lab" {
  for_each = local.cf_records

  zone_id = var.cloudflare_zone_id
  name    = "${var.cloudflare_subdomain_prefix}-${each.key}"
  content = each.value
  type    = "A"
  ttl     = 60
  proxied = false
}
