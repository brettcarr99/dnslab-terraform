provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "dns_lab" {
  zone_id = var.cloudflare_zone_id
}

locals {
  cf_records = {
    rootdns  = aws_instance.root_server.public_ip
    tlddns   = aws_instance.tld_server.public_ip
    "2lddns" = aws_instance.sld_server.public_ip
    resolver = aws_instance.resolver.public_ip
    client   = aws_instance.client.public_ip
  }
}

resource "cloudflare_record" "dns_lab" {
  for_each = local.cf_records

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = each.value
  type    = "A"
  ttl     = 60
  proxied = false
}
