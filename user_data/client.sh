#!/bin/bash
# Terraform template vars: resolver_ip=${resolver_ip}
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s) 2>&1

echo "==> Setting hostname"
hostnamectl set-hostname dns-lab-client

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

echo "==> Installing DNS tools"
yum install -y bind-utils

echo "==> Writing traffic generation script"
cat > /usr/local/bin/dns-traffic-gen << 'SCRIPT'
#!/bin/bash
# dns-traffic-gen — DNS query traffic generator for dns-lab
#
# Fires DNS queries at the lab resolver and prints a running tally.
# Ctrl-C (or reaching COUNT) prints final statistics and exits cleanly.
#
# Usage: dns-traffic-gen [-r RESOLVER] [-n COUNT] [-i INTERVAL_MS] [-v]
#   -r RESOLVER     Resolver IP or hostname  (default: ${resolver_ip})
#   -n COUNT        Queries to send; 0 = infinite  (default: 100)
#   -i INTERVAL_MS  Sleep between queries, in ms   (default: 100)
#   -v              Verbose — print every query result

RESOLVER="${resolver_ip}"
COUNT=100
INTERVAL_MS=100
VERBOSE=0

usage() { sed -n '3,11p' "$0" | sed 's/^# //'; exit 1; }

while getopts ":r:n:i:vh" opt; do
  case $opt in
    r) RESOLVER=$OPTARG ;;
    n) COUNT=$OPTARG ;;
    i) INTERVAL_MS=$OPTARG ;;
    v) VERBOSE=1 ;;
    h) usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
    ?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Query mix: cycles through 10 entries per round
# Indices 0-3 yield NOERROR; 4-9 yield NXDOMAIN (not defined in the lab zone)
pick_query() {
  case $(( $1 % 10 )) in
    0) echo "www.example.lab A"           ;;  # NOERROR — A 192.0.2.1
    1) echo "www.example.lab AAAA"        ;;  # NOERROR — no AAAA configured
    2) echo "example.lab SOA"             ;;  # NOERROR — zone SOA
    3) echo "example.lab NS"              ;;  # NOERROR — zone NS
    4) echo "mail.example.lab A"          ;;  # NXDOMAIN
    5) echo "api.example.lab A"           ;;  # NXDOMAIN
    6) echo "app.example.lab A"           ;;  # NXDOMAIN
    7) echo "ftp.example.lab A"           ;;  # NXDOMAIN
    8) echo "nx1.example.lab A"           ;;  # NXDOMAIN
    9) echo "nx2.example.lab A"           ;;  # NXDOMAIN
  esac
}

SENT=0; NOERROR=0; NXDOMAIN=0; SERVFAIL=0; OTHER=0; TOTAL_RTT=0

INTERVAL_SEC=$(awk "BEGIN { printf \"%.3f\", $INTERVAL_MS / 1000 }")

print_summary() {
  printf "\n%s\n" "────────────────────────────────"
  printf "  Queries sent : %d\n"   "$SENT"
  printf "  NOERROR      : %d\n"   "$NOERROR"
  printf "  NXDOMAIN     : %d\n"   "$NXDOMAIN"
  printf "  SERVFAIL     : %d\n"   "$SERVFAIL"
  printf "  Other/timeout: %d\n"   "$OTHER"
  if [ "$SENT" -gt 0 ]; then
    AVG=$(awk "BEGIN { printf \"%.1f\", $TOTAL_RTT / $SENT }")
    printf "  Avg RTT      : %sms\n" "$AVG"
  fi
  printf "%s\n" "────────────────────────────────"
}

trap 'print_summary; exit 0' INT TERM

printf "dns-traffic-gen\n"
printf "  resolver  : %s\n"  "$RESOLVER"
if [ "$COUNT" -eq 0 ]; then
  printf "  count     : infinite (Ctrl-C to stop)\n"
else
  printf "  count     : %d\n" "$COUNT"
fi
printf "  interval  : %dms\n\n" "$INTERVAL_MS"

i=0
while true; do
  [ "$COUNT" -gt 0 ] && [ "$i" -ge "$COUNT" ] && break

  QUERY=$(pick_query $i)
  NAME=$(echo "$QUERY" | cut -d' ' -f1)
  TYPE=$(echo "$QUERY" | cut -d' ' -f2)

  OUTPUT=$(dig "@$RESOLVER" "$NAME" "$TYPE" +noall +comments +answer +time=3 +tries=1 2>/dev/null || true)
  STATUS=$(echo "$OUTPUT" | grep -oE 'status: [A-Z]+' | head -1 | cut -d' ' -f2)
  RTT=$(echo "$OUTPUT" | awk '/Query time:/ { print $4; exit }')
  [ -z "$STATUS" ] && STATUS="TIMEOUT"
  [ -z "$RTT"    ] && RTT=0

  SENT=$(( SENT + 1 ))
  TOTAL_RTT=$(( TOTAL_RTT + RTT ))

  case "$STATUS" in
    NOERROR)  NOERROR=$(( NOERROR + 1 ))  ;;
    NXDOMAIN) NXDOMAIN=$(( NXDOMAIN + 1 )) ;;
    SERVFAIL) SERVFAIL=$(( SERVFAIL + 1 )) ;;
    *)        OTHER=$(( OTHER + 1 ))       ;;
  esac

  if [ "$VERBOSE" -eq 1 ]; then
    ANSWER=$(echo "$OUTPUT" | awk '!/^;/ && NF { print $NF; exit }')
    printf "  [%4d] %-30s %-6s %-10s %4dms  %s\n" \
      "$i" "$NAME" "$TYPE" "$STATUS" "$RTT" "$ANSWER"
  elif [ $(( SENT % 10 )) -eq 0 ]; then
    printf "  %d queries (ok=%d nxd=%d fail=%d err=%d)\n" \
      "$SENT" "$NOERROR" "$NXDOMAIN" "$SERVFAIL" "$OTHER"
  fi

  i=$(( i + 1 ))
  [ "$COUNT" -eq 0 ] || [ "$i" -lt "$COUNT" ] && sleep "$INTERVAL_SEC"
done

print_summary
SCRIPT
chmod +x /usr/local/bin/dns-traffic-gen

echo "==> Writing dns-traffic-gen README"
cat > /home/brettcarr/dns-traffic-gen.md << 'README'
# dns-traffic-gen

Sends DNS queries to the lab resolver and reports statistics.
The script lives at /usr/local/bin/dns-traffic-gen and is on PATH.

## Usage

    dns-traffic-gen [-r RESOLVER] [-n COUNT] [-i INTERVAL_MS] [-v]

| Flag | Default    | Description                                  |
|------|------------|----------------------------------------------|
| -r   | 10.0.1.13  | Resolver IP or hostname to query             |
| -n   | 100        | Number of queries to send (0 = run forever)  |
| -i   | 100        | Interval between queries in milliseconds     |
| -v   | off        | Verbose — print one line per query           |

## Examples

    # Default run: 100 queries at 100 ms intervals, summary at end
    dns-traffic-gen

    # Verbose: see every query and response inline
    dns-traffic-gen -v

    # Burst: 1000 queries as fast as possible (10 ms interval)
    dns-traffic-gen -n 1000 -i 10

    # Run forever at ~20 qps until Ctrl-C
    dns-traffic-gen -n 0 -i 50

    # Target a different resolver
    dns-traffic-gen -r 10.0.1.13 -n 200 -v

## Output

Normal mode prints a tally line every 10 queries:

    dns-traffic-gen
      resolver  : 10.0.1.13
      count     : 100
      interval  : 100ms

      10 queries (ok=4 nxd=6 fail=0 err=0)
      20 queries (ok=8 nxd=12 fail=0 err=0)
      ...
    ────────────────────────────────
      Queries sent : 100
      NOERROR      : 40
      NXDOMAIN     : 60
      SERVFAIL     : 0
      Other/timeout: 0
      Avg RTT      : 3.2ms
    ────────────────────────────────

Verbose mode (-v) prints one line per query:

      [   0] www.example.lab                A      NOERROR       3ms  192.0.2.1
      [   1] www.example.lab                AAAA   NOERROR       2ms
      [   2] example.lab                    SOA    NOERROR       2ms  ns.example.lab.
      ...

## Query mix

Each round of 10 queries covers:

    Index  Name                    Type  Expected
    -----  ----                    ----  --------
    0      www.example.lab         A     NOERROR  (192.0.2.1)
    1      www.example.lab         AAAA  NOERROR  (no record — empty answer)
    2      example.lab             SOA   NOERROR
    3      example.lab             NS    NOERROR
    4      mail.example.lab        A     NXDOMAIN
    5      api.example.lab         A     NXDOMAIN
    6      app.example.lab         A     NXDOMAIN
    7      ftp.example.lab         A     NXDOMAIN
    8      nx1.example.lab         A     NXDOMAIN
    9      nx2.example.lab         A     NXDOMAIN

40 % of queries should resolve (NOERROR), 60 % should return NXDOMAIN.
SERVFAIL or timeouts indicate a problem with the resolver or the chain.

## DNS lab topology (for reference)

    10.0.1.10  root      BIND, authoritative for .        delegates lab.
    10.0.1.11  tld       BIND, authoritative for lab.     delegates example.lab.
    10.0.1.12  2ld       BIND, authoritative for example.lab.
    10.0.1.13  resolver  Unbound, recursive, root-hints -> 10.0.1.10
    10.0.1.14  client    (this host)
README
chown brettcarr:brettcarr /home/brettcarr/dns-traffic-gen.md

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
