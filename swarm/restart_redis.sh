SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

echo "=========================================="
echo "RESTART REDIS AND DEPENDENCIES"
echo "=========================================="

restart_group_services 1 "Redis Cluster" 30 \
  "^kafi_redis-master" \
  "^kafi_redis-sentinel" \
  "^kafi_redis-slave" 

restart_group_services 2 "Domain Common" 30 \
  "^kafi_aaa" \
  "^kafi_kapi-aaa" \
  "^kafi_configuration"

restart_group_services 3 "Domain Business" 30 \
  "^kafi_asset-realtime"

restart_group_services 4 "Domain Market" 30 \
  "^kafi_market-query" \
  "^kafi_market-realtime"

restart_group_services 5 "Domain MO" 30 \
  "^kafi_basket-order"

restart_group_services 6 "Domain Trading" 30 \
  "^kafi_retail-conditional-order" \
  "^kafi_gbi-execution"

restart_group_services 7 "Domain GBI" 30 \
  "^kafi_gbi-pnl-mgmt" \
  "^kafi_gbi-subscribe-mgmt"

restart_group_services 8 "Domain Bridge" 30 \
  "^kafi_fds-bridge" \
  "^kafi_flex-bridge" \
  "^kafi_kapi-fds-bridge" \
  "^kafi_k-internal-service-bridge"

restart_group_services 9 "Event Source" 30 \
  "^kafi_fds-event" \
  "^kafi_kapi-fds-event"

restart_group_services 10 "SCC Services" 30 \
  "^kafi_scc-redis" \
  "^kafi_kapi-market-scc-broker" \
  "^kafi_kapi-market-scc-redis"

restart_group_services 11 "API Services" 30 \
  "^kafi_rest" \
  "^kafi_kapi-rest"

echo ""
echo "=========================================="
echo "✓ ALL REDIS DEPENDENT SERVICES RESTARTED"
echo "=========================================="
echo ""
echo "Lưu ý: cần vào 43.109 restart horizon-market và horizon-trading"
echo "Lưu ý: cần vào 43.165 restart fix-server"
echo "Lưu ý: cần vào 43.161 restart pairs-trading và flex-event"

