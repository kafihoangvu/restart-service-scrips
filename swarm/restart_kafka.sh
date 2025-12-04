SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

echo "=========================================="
echo "RESTART KAFKA AND DEPENDENCIES"
echo "=========================================="

restart_group_services 1 "Kafka" 30 \
  "^kafi_kafka"

restart_group_services 2 "Domain Business" 30 \
  "^kafi_user-utilities" \
  "^kafi_asset-realtime"

restart_group_services 3 "Domain Common" 30 \
  "^kafi_aaa" \
  "^kafi_kapi-aaa" \
  "^kafi_notification" \
  "^kafi_configuration"

restart_group_services 4 "Domain GBI" 30 \
  "^kafi_gbi-algo-bridge" \
  "^kafi_gbi-pnl-mgmt" \
  "^kafi_gbi-report" \
  "^kafi_gbi-subscribe-mgmt"

restart_group_services 5 "Domain MO" 30 \
  "^kafi_basket-order"

restart_group_services 6 "Domain Market" 30 \
  "^kafi_market-query" \
  "^kafi_market-realtime"

restart_group_services 7 "Flow Mgmt" 30 \
  "^kafi_process-mgmt"

restart_group_services 8 "Domain Trading" 30 \
  "^kafi_gbi-execution" \
  "^kafi_retail-conditional-order"

restart_group_services 9 "Domain Bridge" 30 \
  "^kafi_fds-bridge" \
  "^kafi_flex-bridge" \
  "^kafi_kapi-fds-bridge" \
  "^kafi_kapi-flex-bridge" \
  "^kafi_k-internal-service-bridge"

restart_group_services 10 "Event Source" 30 \
  "^kafi_fds-event" \
  "^kafi_kapi-fds-event"

echo ""
echo "=========================================="
echo "✓ ALL KAFKA DEPENDENT SERVICES RESTARTED"
echo "=========================================="
echo ""
echo "Lưu ý: cần vào 43.109 restart horizon-market và horizon-trading"
echo "Lưu ý: cần vào 43.165 restart fix-server"
echo "Lưu ý: cần vào 43.161 restart pairs-trading và flex-event"
