#!/bin/bash
# Terraform template vars: tld_ip=${tld_ip}  sld_ip=${sld_ip}  dnsmaster_ip=${dnsmaster_ip}
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s) 2>&1

echo "==> Setting hostname"
hostnamectl set-hostname dns-lab-tld

echo "==> Updating packages"
yum update -y

echo "==> Creating brettcarr user"
id brettcarr &>/dev/null || useradd -m -s /bin/bash brettcarr
usermod -aG wheel brettcarr
mkdir -p /home/brettcarr/.ssh
chmod 700 /home/brettcarr/.ssh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDApxGXORrEC+6MOnNhcr0ZkO4G9A5LvLkBEWHtge3jAh8B/Z84blJ/RnHjhAjBlHXW+YC7VJF24x9a+HlARBtBvCxdsyo9smxHI2MMLtpKD5Wrh8X4a66nhkiTupnSb+9M58ZHG2EGGEAtPMYH4X0eYQXYCjVoIdajP9JRs72WnMjatf/D8PoHTj+hWCY+9+MVjjIl8RkVSZkhJvXKowzP+n6zEEk9v/Fb2yNo92uV+zF4c0jP1uhyXsN5w+drQdUqY7G30g6a7T2RbH3A9pYFf2BV3dZmfNIdrnjWQSHmbsj+xdBDCMVEz0G4DhrE7FQ3/BTgAZmFt8ou1Zyx8ZKanttd/ekqnX+KoaxN9KRSgSIAw7Q8oIIKQ3nTmDoDpj+Bg6VQ4uxa0jkQgdt5pGfadbbzup5bcGKpvIV2E7GJOSuhJzuiUjIHx0lguFd0ggDCzk0sEoyV+awlyjqD/4slwQG/HQNx7uEEInJGsHOrOvwtOszPZ0s6yH/fdXTo7IE= brett@Mac0441.local" \
    > /home/brettcarr/.ssh/authorized_keys
chmod 600 /home/brettcarr/.ssh/authorized_keys
chown -R brettcarr:brettcarr /home/brettcarr/.ssh

echo "==> Installing BIND"
yum install -y bind bind-utils

echo "==> Writing named.conf"
mkdir -p /var/log/named
chown named:named /var/log/named

cat > /etc/named.conf << 'NAMED_CONF'
options {
    listen-on port 53 { any; };
    listen-on-v6    { none; };
    directory       "/var/named";
    allow-query     { any; };
    allow-transfer  { none; };
    recursion       no;
    dnssec-validation no;
};

logging {
    channel xfer_log {
        file "/var/log/named/xfer.log" versions 3 size 5m;
        severity info;
        print-time yes;
    };
    channel queries_log {
        file "/var/log/named/queries.log" versions 3 size 5m;
        severity info;
        print-time yes;
    };
    category xfer-in   { xfer_log; };
    category notify    { xfer_log; };
    category queries   { queries_log; };
};

key "dns-lab-transfer" {
    algorithm hmac-sha256;
    secret "${tsig_secret}";
};

server ${dnsmaster_ip} { keys { dns-lab-transfer; }; };

zone "lab." {
    type slave;
    masters { ${dnsmaster_ip}; };
    file "slaves/lab.zone";
    allow-notify { ${dnsmaster_ip}; };
};
NAMED_CONF

echo "==> Creating slaves directory"
mkdir -p /var/named/slaves
chown named:named /var/named/slaves
chmod 770 /var/named/slaves

echo "==> Validating named configuration"
named-checkconf

echo "==> Waiting for dnsmaster to be reachable on port 53 (up to 5 min)..."
count=0
until nc -zw3 ${dnsmaster_ip} 53 2>/dev/null; do
  count=$(( count + 1 ))
  if [ "$count" -ge 30 ]; then
    echo "  dnsmaster not yet reachable; starting named anyway (AXFR will retry)"
    break
  fi
  echo "  attempt $count/30, retrying in 10s..."
  sleep 10
done

echo "==> Starting named"
systemctl enable named
systemctl start named

echo "==> Running chronicled-install.sh"
aws s3 cp s3://${scripts_bucket}/chronicled-install.sh /tmp/chronicled-install.sh
chmod +x /tmp/chronicled-install.sh
/tmp/chronicled-install.sh

echo "==> Installing maintenance cron jobs"
cat > /etc/cron.d/dns-lab-maintenance << 'CRON'
0 2 * * *   root  yum update -y >> /var/log/yum-update.log 2>&1
0 3 * * 1   root  /sbin/reboot
CRON
chmod 644 /etc/cron.d/dns-lab-maintenance

echo "==> Sending reboot notification"
aws sns publish \
  --region "${aws_region}" \
  --topic-arn "${sns_topic_arn}" \
  --message "$(hostname): setup complete, rebooting now"

echo "==> Rebooting"
reboot
