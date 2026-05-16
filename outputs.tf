locals {
  zone = data.cloudflare_zone.dns_lab.name
}

output "servers" {
  description = "Full DNS names and IPs for all lab servers"
  value = {
    root_server = {
      dns_name   = "rootdns.${local.zone}"
      public_ip  = aws_instance.root_server.public_ip
      private_ip = aws_instance.root_server.private_ip
    }
    tld_server = {
      dns_name   = "tlddns.${local.zone}"
      public_ip  = aws_instance.tld_server.public_ip
      private_ip = aws_instance.tld_server.private_ip
    }
    sld_server = {
      dns_name   = "2lddns.${local.zone}"
      public_ip  = aws_instance.sld_server.public_ip
      private_ip = aws_instance.sld_server.private_ip
    }
    resolver = {
      dns_name   = "resolver.${local.zone}"
      public_ip  = aws_instance.resolver.public_ip
      private_ip = aws_instance.resolver.private_ip
    }
    client = {
      dns_name   = "client.${local.zone}"
      public_ip  = aws_instance.client.public_ip
      private_ip = aws_instance.client.private_ip
    }
    dnsmaster = {
      dns_name   = "dnsmaster.${local.zone}"
      public_ip  = aws_instance.dnsmaster.public_ip
      private_ip = aws_instance.dnsmaster.private_ip
    }
  }
}

output "test_commands" {
  description = "Commands to verify DNS resolution (run after user-data completes, ~2 min)"
  value = <<-EOT
    # SSH into resolver:
    ssh brettcarr@${aws_instance.resolver.public_ip}

    # From the resolver, test full recursive chain:
    dig @127.0.0.1 www.example.lab A          # full recursive lookup
    dig @${local.root_ip} lab. NS              # root -> TLD delegation
    dig @${local.tld_ip} example.lab. NS      # TLD -> 2LD delegation
    dig @${local.sld_ip} www.example.lab. A   # 2LD authoritative answer

    # Check user-data progress on any node:
    sudo tail -f /var/log/user-data.log

    # SSH into client and run the traffic generator:
    ssh brettcarr@${aws_instance.client.public_ip}
    dns-traffic-gen                            # 100 queries at 100ms intervals
    dns-traffic-gen -n 0 -i 50 -v             # infinite, 50ms interval, verbose
    dns-traffic-gen -n 1000 -i 10             # burst: 1000 queries at 10ms
  EOT
}
