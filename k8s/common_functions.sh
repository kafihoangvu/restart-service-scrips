#!/bin/sh

countdown() {
    local seconds=$1
    local message=${2:-"Waiting"}
    local i=$seconds
    while [ $i -gt 0 ]; do
        printf "\r  ⏳ %s: %ds remaining..." "$message" "$i"
        sleep 1
        i=$((i - 1))
    done
    printf "\r  ✓ %s: Done!          \n" "$message"
}

get_pods_by_pattern() {
    local pattern=$1
    local namespace=$2
    kubectl get pods -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' | grep -E "$pattern" || true
}

get_pod_phase() {
    local pod=$1
    local namespace=$2
    kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
}

is_pod_terminating() {
    local pod=$1
    local namespace=$2
    local deletion_timestamp=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
    [ -n "$deletion_timestamp" ]
}

pod_exists() {
    local pod=$1
    local namespace=$2
    kubectl get pod "$pod" -n "$namespace" >/dev/null 2>&1
}

restart_pod() {
    local pod=$1
    local namespace=$2
    local timeout=${3:-30}
    
    echo "  - Restarting $pod"
    
    # Kiểm tra pod có tồn tại không
    if ! pod_exists "$pod" "$namespace"; then
        echo "    ⚠ Pod $pod does not exist, may have been deleted already"
        echo "    Waiting for pod to be recreated..."
        local elapsed=0
        while [ $elapsed -lt $timeout ]; do
            if pod_exists "$pod" "$namespace"; then
                local new_phase=$(get_pod_phase "$pod" "$namespace")
                if [ "$new_phase" = "Running" ] || [ "$new_phase" = "Pending" ]; then
                    echo "    ✓ Pod recreated, new status: $new_phase"
                    return 0
                fi
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done
        echo "    ⚠ Pod recreation timeout (waited ${timeout}s)"
        return 1
    fi
    
    local phase=$(get_pod_phase "$pod" "$namespace")
    echo "    Current status: $phase"
    
    # Nếu pod đang terminating, đợi nó terminate xong
    if is_pod_terminating "$pod" "$namespace"; then
        echo "    ⚠ Pod is already terminating, waiting for termination..."
        local elapsed=0
        while [ $elapsed -lt $timeout ] && pod_exists "$pod" "$namespace"; do
            sleep 2
            elapsed=$((elapsed + 2))
        done
        if pod_exists "$pod" "$namespace"; then
            echo "    ⚠ Pod still exists after ${timeout}s, trying to force delete..."
        else
            echo "    ✓ Pod terminated successfully"
        fi
    fi
    
    # Thử delete pod
    if kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null 2>&1; then
        echo "    ✓ Delete command sent successfully"
    elif ! pod_exists "$pod" "$namespace"; then
        echo "    ✓ Pod already deleted"
    else
        echo "    ⚠ Delete command failed, but continuing to wait for recreation..."
    fi
    
    # Đợi pod được recreate
    echo "    Waiting for pod to be recreated..."
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if pod_exists "$pod" "$namespace"; then
            local new_phase=$(get_pod_phase "$pod" "$namespace")
            if [ "$new_phase" = "Running" ] || [ "$new_phase" = "Pending" ]; then
                echo "    ✓ Pod recreated, new status: $new_phase"
                return 0
            elif [ "$new_phase" = "Unknown" ]; then
                # Nếu vẫn Unknown, đợi thêm một chút
                sleep 2
                elapsed=$((elapsed + 2))
                continue
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    # Kiểm tra lại lần cuối
    if pod_exists "$pod" "$namespace"; then
        local final_phase=$(get_pod_phase "$pod" "$namespace")
        if [ "$final_phase" = "Running" ] || [ "$final_phase" = "Pending" ]; then
            echo "    ✓ Pod recreated, new status: $final_phase"
            return 0
        else
            echo "    ⚠ Pod recreation timeout, final status: $final_phase (waited ${timeout}s)"
            return 1
        fi
    else
        echo "    ⚠ Pod recreation timeout, pod not found (waited ${timeout}s)"
        return 1
    fi
}

restart_group_pods() {
    local step_num=$1
    local group_name=$2
    local namespace=$3
    local wait_time=${4:-30}
    shift 4
    
    echo ""
    echo "Step $step_num: Restarting $group_name pods..."
    
    local pods=""
    for pattern; do
        pods="$pods$(get_pods_by_pattern "$pattern" "$namespace")\n"
    done
    pods=$(echo "$pods" | grep -v '^$' | sort -u)
    
    if [ -z "$pods" ]; then
        echo "  ⚠ No pods found for $group_name"
        return
    fi
    
    local pod_count=$(echo "$pods" | wc -l | tr -d ' ')
    echo "  ✓ Found $pod_count pod(s):"
    echo "$pods" | sed 's/^/    - /'
    
    local restarted=0
    local failed=0
    for pod in $pods; do
        if restart_pod "$pod" "$namespace"; then
            restarted=$((restarted + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    echo "  ✓ $group_name: $restarted restarted, $failed failed"
    if [ $wait_time -gt 0 ]; then
        countdown "$wait_time" "Stabilizing $group_name pods"
    fi
}

show_pod_status() {
    local pattern=$1
    local namespace=$2
    echo ""
    echo "Current pod status:"
    kubectl get pods -n "$namespace" | grep -E "$pattern" || echo "  (No pods found)"
}

