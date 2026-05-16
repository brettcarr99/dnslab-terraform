#!/bin/bash
# Terraform template vars: root_ip=${root_ip}  tld_ip=${tld_ip}  sld_ip=${sld_ip}
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s) 2>&1

echo "==> Setting hostname"
hostnamectl set-hostname dns-lab-dnsmaster

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
    notify          yes;
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
    category xfer-out  { xfer_log; };
    category notify    { xfer_log; };
    category queries   { queries_log; };
};

key "dns-lab-transfer" {
    algorithm hmac-sha256;
    secret "${tsig_secret}";
};

server ${root_ip} { keys { dns-lab-transfer; }; };
server ${tld_ip}  { keys { dns-lab-transfer; }; };
server ${sld_ip}  { keys { dns-lab-transfer; }; };

zone "." {
    type master;
    file "root.zone";
    allow-transfer { key dns-lab-transfer; };
    also-notify    { ${root_ip}; };
};

zone "lab." {
    type master;
    file "lab.zone";
    allow-transfer { key dns-lab-transfer; };
    also-notify    { ${tld_ip}; };
};

zone "example.lab." {
    type master;
    file "example.lab.zone";
    allow-transfer { key dns-lab-transfer; };
    also-notify    { ${sld_ip}; };
};
NAMED_CONF

echo "==> Writing root zone"
cat > /var/named/root.zone << 'ZONE'
$TTL 86400
.   IN  SOA ns.root. hostmaster.root. (
            2024010101 ; serial
            300        ; refresh
            60         ; retry
            604800     ; expire
            86400 )    ; minimum

.           IN  NS  ns.root.
ns.root.    IN  A   ${root_ip}

lab.        IN  NS  ns.lab.
ns.lab.     IN  A   ${tld_ip}
ZONE

echo "==> Writing lab. zone"
cat > /var/named/lab.zone << 'ZONE'
$TTL 86400
lab.    IN  SOA ns.lab. hostmaster.lab. (
                2024010101 ; serial
                300        ; refresh
                60         ; retry
                604800     ; expire
                86400 )    ; minimum

lab.            IN  NS  ns.lab.
ns.lab.         IN  A   ${tld_ip}

example.lab.    IN  NS  ns.example.lab.
ns.example.lab. IN  A   ${sld_ip}
ZONE

echo "==> Writing example.lab. zone"
cat > /var/named/example.lab.zone << 'ZONE'
$TTL 86400
example.lab.    IN  SOA ns.example.lab. hostmaster.example.lab. (
                        2024010101 ; serial
                        300        ; refresh
                        60         ; retry
                        604800     ; expire
                        86400 )    ; minimum

example.lab.        IN  NS  ns.example.lab.
ns.example.lab.     IN  A   ${sld_ip}

www.example.lab.    IN  A   192.0.2.1
mail.example.lab.   IN  A   192.0.2.2
test.example.lab.   IN  A   192.0.2.3
example.lab.        IN  MX  10 mail.example.lab.
ZONE

chown named:named /var/named/root.zone /var/named/lab.zone /var/named/example.lab.zone
chmod 640 /var/named/root.zone /var/named/lab.zone /var/named/example.lab.zone

echo "==> Validating named configuration"
named-checkconf
named-checkzone . /var/named/root.zone
named-checkzone lab. /var/named/lab.zone
named-checkzone example.lab. /var/named/example.lab.zone

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
