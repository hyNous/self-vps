#!/usr/bin/env bash
set -Eeuo pipefail

source_dir="/etc/letsencrypt/live/__NODE_DOMAIN__"
target_dir="/usr/local/etc/xray/cert"

install -d -o root -g nogroup -m 750 "$target_dir"
install -o root -g nogroup -m 644 "$source_dir/fullchain.pem" "$target_dir/fullchain.pem"
install -o root -g nogroup -m 640 "$source_dir/privkey.pem" "$target_dir/privkey.pem"

if systemctl is-active --quiet xray; then
  systemctl restart xray
fi
