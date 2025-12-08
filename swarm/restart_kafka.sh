#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

echo "=========================================="
echo "RESTART KAFKA AND DEPENDENCIES"
echo "=========================================="

restart_group_services 1 "Kafka" 30 \
  "^kafi_kafka"

restart_group_services 2 "GBI Rest go & order mgmt" 30 \
  "^kafi_gbi-rest-go" \
  "^kafi_order-mgmt"

echo ""
echo "=========================================="
echo "✓ ALL KAFKA DEPENDENT SERVICES RESTARTED"
echo "=========================================="
echo ""
echo "Lưu ý: cần vào 43.109 kiểm tra horizon-market và horizon-trading"
echo "Lưu ý: cần vào 43.165 kiểm tra fix-server"
echo "Lưu ý: cần vào 43.161 kiểm tra pairs-trading và flex-event"
