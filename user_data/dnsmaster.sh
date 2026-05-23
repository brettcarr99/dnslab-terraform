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
    allow-update   { key dns-lab-transfer; };
};

zone "lab." {
    type master;
    file "lab.zone";
    allow-transfer { key dns-lab-transfer; };
    also-notify    { ${tld_ip}; };
    allow-update   { key dns-lab-transfer; };
};

zone "example.lab." {
    type master;
    file "example.lab.zone";
    allow-transfer { key dns-lab-transfer; };
    also-notify    { ${sld_ip}; };
    allow-update   { key dns-lab-transfer; };
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

echo "==> Creating BIND TSIG key file for nsupdate"
mkdir -p /etc/bind/keys
cat > /etc/bind/keys/dns-lab-transfer.key << 'KEY_FILE'
key "dns-lab-transfer" {
    algorithm hmac-sha256;
    secret "${tsig_secret}";
};
KEY_FILE
chmod 600 /etc/bind/keys/dns-lab-transfer.key

echo "==> Creating DNS update script"
cat > /opt/dns-update-gen.sh << 'UPDATE_SCRIPT'
#!/bin/bash
# DNS Lab Dynamic Update Generator
# Generates aggressive TSIG-authenticated DNS updates every 5 minutes
# Targets all 3 zones: root (.), lab., example.lab.

set -euo pipefail

DNSMASTER="10.0.1.15"
TSIG_KEY_FILE="/etc/bind/keys/dns-lab-transfer.key"
LOG_FILE="/var/log/dns-updates.log"
LOCK_FILE="/var/run/dns-update-gen.lock"

# Prevent concurrent execution
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update already in progress (PID $OLD_PID), skipping" >> "$LOG_FILE"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

# Logging function
log_update() {
    local zone=$1
    local action=$2
    local record=$3
    local serial=$4
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $zone | $action | $record | serial=$serial" >> "$LOG_FILE"
}

# Generate date-based serial (YYYYMMDDNN)
get_next_serial() {
    local zone_file=$1
    local today=$(date +%Y%m%d)
    local current_serial=$(grep -A 1 "SOA" "$zone_file" | grep ";" | head -1 | awk '{print $1}' | tail -c 11)

    if [ -z "$current_serial" ]; then
        current_serial="2024010100"
    fi

    local current_date=$(echo "$current_serial" | cut -c1-8)
    local current_version=$(echo "$current_serial" | cut -c9-10)

    if [ "$current_date" = "$today" ]; then
        # Same day - increment version counter
        local new_version=$((10#$current_version + 1))
        if [ $new_version -gt 99 ]; then
            new_version=0
        fi
        printf "%s%02d" "$today" "$new_version"
    else
        # New day - reset version counter to 00
        printf "%s00" "$today"
    fi
}

# Execute nsupdate command batch
execute_updates() {
    local zone=$1
    local updates=$2

    nsupdate -k "$TSIG_KEY_FILE" << NSUPDATE_EOF
server $DNSMASTER
zone $zone
$updates
send
NSUPDATE_EOF

    if [ $? -eq 0 ]; then
        return 0
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: nsupdate failed for zone $zone" >> "$LOG_FILE"
        return 1
    fi
}

# Update function for a zone
update_zone() {
    local zone=$1
    local zone_file=$2
    local auth_server=$3

    log_update "$zone" "START" "processing zone" "N/A"

    # Get next serial
    local new_serial=$(get_next_serial "$zone_file")

    # Build update batch with 10+ changes
    local updates=""
    local timestamp=$(date +%s)

    if [ "$zone" = "." ]; then
        # Root zone - update NS delegation with varying TTLs
        updates+=$'update delete lab. NS\n'
        updates+=$'update add lab. '$((300 + RANDOM % 300))' NS ns.lab.\n'
        log_update "$zone" "MODIFY" "lab. NS" "$new_serial"

        # Add 8 temp delegation records
        idx=1; while [ $idx -le 8 ]; do
            updates+=$'update add tmp'$idx'. '$((3600 + RANDOM % 1800))' NS ns.tmp'$idx'.\n'
            updates+=$'update add ns.tmp'$idx'. 300 A 192.0.2.'$((RANDOM % 256))$'\n'
            log_update "$zone" "ADD" "tmp$idx. delegation" "$new_serial"
            idx=$((idx+1))
        done

    elif [ "$zone" = "lab." ]; then
        # Lab zone - update NS delegation
        updates+=$'update delete example.lab. NS\n'
        updates+=$'update add example.lab. '$((300 + RANDOM % 300))' NS ns.example.lab.\n'
        log_update "$zone" "MODIFY" "example.lab. NS" "$new_serial"

        # Add 8 temp delegation records
        idx=1; while [ $idx -le 8 ]; do
            updates+=$'update add tmp'$idx'.lab. '$((3600 + RANDOM % 1800))' NS ns.tmp'$idx'.lab.\n'
            updates+=$'update add ns.tmp'$idx'.lab. 300 A 192.0.2.'$((RANDOM % 256))$'\n'
            log_update "$zone" "ADD" "tmp$idx.lab. delegation" "$new_serial"
            idx=$((idx+1))
        done

    elif [ "$zone" = "example.lab." ]; then
        # Example.lab zone - update A records and add temp records
        # Modify www record
        updates+=$'update delete www.example.lab. A\n'
        updates+=$'update add www.example.lab. 300 A 192.0.2.'$((100 + RANDOM % 155))$'\n'
        log_update "$zone" "MODIFY" "www.example.lab" "$new_serial"

        # Modify mail record
        updates+=$'update delete mail.example.lab. A\n'
        updates+=$'update add mail.example.lab. 600 A 192.0.2.'$((100 + RANDOM % 155))$'\n'
        log_update "$zone" "MODIFY" "mail.example.lab" "$new_serial"

        # Modify test record
        updates+=$'update delete test.example.lab. A\n'
        updates+=$'update add test.example.lab. '$((300 + RANDOM % 300))' A 192.0.2.'$((100 + RANDOM % 155))$'\n'
        log_update "$zone" "MODIFY" "test.example.lab" "$new_serial"

        # Add 7 temp records with timestamp-based naming
        idx=1; while [ $idx -le 7 ]; do
            updates+=$'update add temp-'$timestamp'-'$idx'.example.lab. 300 A 192.0.2.'$((RANDOM % 256))$'\n'
            log_update "$zone" "ADD" "temp-$timestamp-$idx.example.lab" "$new_serial"
            idx=$((idx+1))
        done
    fi

    # Execute all updates in one batch
    if execute_updates "$zone" "$updates"; then
        log_update "$zone" "SUCCESS" "batch update completed" "$new_serial"
        return 0
    else
        log_update "$zone" "FAILED" "batch update failed" "$new_serial"
        return 1
    fi
}

# Main execution
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== DNS Update Cycle Started ====="

    # Update all three zones
    update_zone "." "/var/named/root.zone" "10.0.1.10"
    update_zone "lab." "/var/named/lab.zone" "10.0.1.11"
    update_zone "example.lab." "/var/named/example.lab.zone" "10.0.1.12"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== DNS Update Cycle Completed ====="
    echo ""
} >> "$LOG_FILE" 2>&1

exit 0
UPDATE_SCRIPT

chmod 755 /opt/dns-update-gen.sh

echo "==> Starting named"
systemctl enable named
systemctl start named

echo "==> Running chronicled-install.sh"
aws s3 cp s3://${scripts_bucket}/chronicled-install.sh /tmp/chronicled-install.sh
chmod +x /tmp/chronicled-install.sh
/tmp/chronicled-install.sh

echo "==> Installing maintenance and DNS update cron jobs"
cat > /etc/cron.d/dns-lab-maintenance << 'CRON'
# DNS dynamic updates - every 5 minutes
*/5 * * * *  root  /opt/dns-update-gen.sh >> /var/log/dns-updates.log 2>&1

# System maintenance
0 2 * * *    root  yum update -y >> /var/log/yum-update.log 2>&1
0 3 * * 1    root  /sbin/reboot
CRON
chmod 644 /etc/cron.d/dns-lab-maintenance

echo "==> Initializing DNS updates log file"
touch /var/log/dns-updates.log
chmod 644 /var/log/dns-updates.log

echo "==> Sending reboot notification"
aws sns publish \
  --region "${aws_region}" \
  --topic-arn "${sns_topic_arn}" \
  --message "$(hostname): setup complete, rebooting now"

echo "==> Rebooting"
reboot
