countdown() {
    local seconds=$1
    local message=${2:-"Waiting"}
    for ((i=seconds; i>0; i--)); do
        printf "\r  ⏳ %s: %ds remaining..." "$message" "$i"
        sleep 1
    done
    printf "\r  ✓ %s: Done!          \n" "$message"
}

restart_service() {
    local services=("$@")
    for service in "${services[@]}"; do
        echo "  - Restarting $service"
        docker service update --force "$service" &
    done
    wait
}

get_services_by_pattern() {
    local pattern=$1
    docker service ls --format "{{.Name}}" | grep "$pattern"
}

restart_group_services() {
    local step_num=$1
    local group_name=$2
    local wait_time=${3:-30}
    shift 3
    local patterns=("$@")
    
    echo ""
    echo "Step $step_num: Restarting $group_name services..."
    
    local services=()
    for pattern in "${patterns[@]}"; do
        services+=($(get_services_by_pattern "$pattern"))
    done
    
    if [ ${#services[@]} -eq 0 ]; then
        echo "  ⚠ No services found for $group_name"
        return
    fi
    
    restart_service "${services[@]}"
    echo "✓ $group_name services restarted"
    countdown "$wait_time" "Stabilizing $group_name services"
}

