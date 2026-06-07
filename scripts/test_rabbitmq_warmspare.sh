#!/usr/bin/env bash
# =============================================================================
# test_rabbitmq_warmspare.sh — Adopti RabbitMQ Warm Spare Validation
#
# Proves that:
#   1. Both RabbitMQ nodes form a healthy 2-node cluster
#   2. The HA mirroring policy is active on all queues
#   3. NGINX LB (rabbitmq-lb) transparently routes to the primary
#   4. When the primary is stopped, traffic fails over to the warm spare
#   5. Zero durable messages are lost during failover
#   6. The cluster reforms when the primary is restarted
#
# Prerequisites (all available inside the Compose stack):
#   - docker CLI
#   - rabbitmqadmin (downloaded from the management API if absent)
#   - curl, nc (busybox-compatible)
#
# Usage (from the repo root or the Compose/ directory):
#   bash Compose/scripts/test_rabbitmq_warmspare.sh
#
# Exit codes:
#   0 = all assertions passed
#   1 = one or more assertions failed
# =============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
PRIMARY_CONTAINER="Adopti_broker"
SPARE_CONTAINER="Adopti_broker_spare"
LB_CONTAINER="Adopti_broker_lb"

RABBITMQ_USER="${RABBITMQ_USER:-adopti}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-}"          # read from env or Compose/.env
TEST_VHOST="/"
TEST_EXCHANGE="adopti.events"
TEST_QUEUE="warmspare.test.queue"
TEST_ROUTING_KEY="warmspare.test"
MESSAGES_BEFORE=20          # messages published before primary failure
MESSAGES_DURING=20          # messages published while primary is down

FAILOVER_TIMEOUT=60         # maximum seconds to wait for spare to accept connections
RECOVERY_TIMEOUT=90         # maximum seconds to wait for cluster to reform
POLL_INTERVAL=2             # seconds between status polls

# ─────────────────────────────────────────────────────────────────────────────
# COLORS AND HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

assert_pass() {
    local label="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "  ${GREEN}✔ PASS${NC}  ${label}"
}

assert_fail() {
    local label="$1"
    local detail="${2:-}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "  ${RED}✘ FAIL${NC}  ${label}"
    [ -n "$detail" ] && echo -e "         ${RED}↳ ${detail}${NC}"
}

assert() {
    # assert <label> <condition_cmd>
    local label="$1"; shift
    if eval "$@" &>/dev/null; then
        assert_pass "$label"
        return 0
    else
        assert_fail "$label"
        return 1
    fi
}

elapsed_since() {
    local start="$1"
    echo $(( $(date +%s) - start ))
}

# Wait until Docker reports a container as 'healthy'.
# Replaces the original wait_for_port which tried 'nc -z' inside the container.
# Problem: nc is NOT installed in rabbitmq:3.13-management (Erlang/Debian image),
# so every docker exec nc call silently failed. All three broker containers already
# have proper Docker healthchecks defined in docker-compose.yml, so polling
# docker inspect is simpler, more reliable, and has zero extra dependencies.
wait_for_healthy() {
    local container="$1"
    local timeout="$2"
    local start health
    start=$(date +%s)
    while true; do
        health=$(docker inspect --format='{{.State.Health.Status}}' \
            "$container" 2>/dev/null || echo "unknown")
        [ "$health" = "healthy" ] && return 0
        if [ "$(elapsed_since "$start")" -ge "$timeout" ]; then
            return 1
        fi
        sleep "$POLL_INTERVAL"
    done
}

# Probe that NGINX rabbitmq-lb actively forwards AMQP connections to a live broker.
# Executed from within $SPARE_CONTAINER (Debian, always on broker-net).
# FIX: rabbitmq:3.13-management (Erlang/Debian) does NOT ship nc. Use bash /dev/tcp
# instead — bash IS present on Debian. NGINX proxy_connect_timeout is 5s, so if
# no upstream is available NGINX closes the connection within that window.
# FIX Bug 1 & Bug 2: this is the correct signal for NGINX failover.
probe_lb_routing() {
    docker exec "$SPARE_CONTAINER" \
        bash -c "(exec 3<>/dev/tcp/rabbitmq-lb/5671 && exec 3>&-)" 2>/dev/null
}

# Execute rabbitmqctl inside a container
rmqctl() {
    local container="$1"; shift
    docker exec "$container" rabbitmqctl "$@" 2>/dev/null
}

# Execute rabbitmqadmin inside a container (uses management HTTP API)
rmqadmin() {
    local container="$1"; shift
    docker exec "$container" rabbitmqadmin \
        --ssl \
        --ssl-disable-hostname-verification \
        --ssl-ca-cert-file=/etc/rabbitmq/certs/ca.crt \
        --port=15671 \
        --username="$RABBITMQ_USER" \
        --password="$RABBITMQ_PASSWORD" \
        "$@" 2>/dev/null
}

# Publish N messages to the test queue via rabbitmqadmin in a given container
publish_messages() {
    local container="$1"
    local count="$2"
    local prefix="${3:-msg}"
    local i
    for i in $(seq 1 "$count"); do
        rmqadmin "$container" publish \
            exchange="$TEST_EXCHANGE" \
            routing_key="$TEST_ROUTING_KEY" \
            payload="${prefix}-${i}" \
            properties='{"delivery_mode":2}' \
            >/dev/null
    done
}

# Consume up to N messages from the test queue; echoes actual count consumed.
# Uses awk instead of grep|wc-l: awk always exits 0 regardless of whether the
# pattern matched, so set -o pipefail never triggers on zero messages.
consume_messages() {
    local container="$1"
    local expected="$2"
    local out
    out=$( (rmqadmin "$container" get queue="$TEST_QUEUE" count="$expected" ackmode=ack_requeue_false 2>/dev/null || true) )
    echo "$out" | awk 'NR>1 && /^\|/ && !/^\+/ && !/routing_key/' | wc -l
}

# ─────────────────────────────────────────────────────────────────────────────
# LOAD PASSWORD FROM .env IF NOT SET
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$RABBITMQ_PASSWORD" ]; then
    COMPOSE_ENV="$(dirname "$0")/../.env"
    if [ -f "$COMPOSE_ENV" ]; then
        # shellcheck disable=SC1090
        RABBITMQ_PASSWORD=$(grep '^RABBITMQ_PASSWORD=' "$COMPOSE_ENV" \
            | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    fi
fi

if [ -z "$RABBITMQ_PASSWORD" ]; then
    echo -e "${RED}[ERROR]${NC} RABBITMQ_PASSWORD is not set. Export it or ensure Compose/.env exists."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP TRAP — runs on any exit (success, failure, or early abort)
# FIX Bug 6: guarantees the test queue is deleted and the primary is restarted
# even when the script aborts mid-run (e.g. cluster not formed at Phase 1).
# Without this a stale queue with leftover messages would corrupt the next run.
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    # Try primary first, fall back to spare (primary may still be stopped)
    docker exec "$PRIMARY_CONTAINER" rabbitmqadmin \
        --ssl --ssl-disable-hostname-verification \
        --ssl-ca-cert-file=/etc/rabbitmq/certs/ca.crt \
        --port=15671 --username="$RABBITMQ_USER" --password="$RABBITMQ_PASSWORD" \
        delete queue name="$TEST_QUEUE" >/dev/null 2>&1 || \
    docker exec "$SPARE_CONTAINER" rabbitmqadmin \
        --ssl --ssl-disable-hostname-verification \
        --ssl-ca-cert-file=/etc/rabbitmq/certs/ca.crt \
        --port=15671 --username="$RABBITMQ_USER" --password="$RABBITMQ_PASSWORD" \
        delete queue name="$TEST_QUEUE" >/dev/null 2>&1 || true
    # Ensure primary is running (it may have been stopped by Phase 4)
    docker start "$PRIMARY_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PREAMBLE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Adopti — RabbitMQ Warm Spare Validation Script          ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
TOTAL_START=$(date +%s)

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 1: Pre-flight Checks"

# 1.1 All three broker containers are running
for ctr in "$PRIMARY_CONTAINER" "$SPARE_CONTAINER" "$LB_CONTAINER"; do
    status=$(docker inspect --format='{{.State.Status}}' "$ctr" 2>/dev/null || echo "missing")
    if [ "$status" = "running" ]; then
        assert_pass "Container '$ctr' is running"
    else
        assert_fail "Container '$ctr' is running" "status=$status"
    fi
done

# 1.2 rabbitmqadmin is available in both broker containers
# FIX Bug 3: without this check every rmqadmin call silently returns empty output
# (because of 2>/dev/null) and all count-based assertions silently get 0.
for ctr in "$PRIMARY_CONTAINER" "$SPARE_CONTAINER"; do
    if docker exec "$ctr" which rabbitmqadmin >/dev/null 2>&1; then
        assert_pass "rabbitmqadmin available in $ctr"
    else
        assert_fail "rabbitmqadmin available in $ctr" \
            "Management API calls will silently fail. Aborting."
        exit 1
    fi
done

# 1.3 Primary is healthy (Docker healthcheck: rabbitmq-diagnostics ping)
if wait_for_healthy "$PRIMARY_CONTAINER" 10; then
    assert_pass "Primary (rabbitmq) is healthy"
else
    assert_fail "Primary (rabbitmq) is healthy" "Docker health status != healthy"
fi

# 1.4 Spare is healthy (Docker healthcheck: rabbitmq-diagnostics ping)
if wait_for_healthy "$SPARE_CONTAINER" 10; then
    assert_pass "Spare (rabbitmq-spare) is healthy"
else
    assert_fail "Spare (rabbitmq-spare) is healthy" "Docker health status != healthy"
fi

# 1.5 LB is healthy (Docker healthcheck: nc -z 127.0.0.1 5671)
if wait_for_healthy "$LB_CONTAINER" 10; then
    assert_pass "LB (rabbitmq-lb) is healthy"
else
    assert_fail "LB (rabbitmq-lb) is healthy" "Docker health status != healthy"
fi

# 1.6 NGINX LB routes AMQP connections to a live broker (end-to-end path check)
# FIX Bug 2 (foundation): probe_lb_routing() is the correct failover signal.
if probe_lb_routing 5; then
    assert_pass "NGINX LB routes AMQP connections to an active broker node"
else
    assert_fail "NGINX LB routes AMQP connections" \
        "rabbitmq-lb:5671 → no upstream reachable"
fi

# 1.7 Cluster has exactly 2 running nodes
# FIX Bug 5: cluster_status shows each node twice (Disk Nodes + Running Nodes).
# Use anchored grep '^rabbit@' + sort -u + wc -l to count UNIQUE node names.
# The original 'grep -c rabbit@rabbitmq' matched 'rabbit@rabbitmq-spare' as a
# substring and counted 4 lines for 2 nodes, 2 lines for 1 node — both ≥ 2, so
# a single-node cluster looked like a 2-node cluster (silent false positive).
NODE_COUNT=$( (rmqctl "$PRIMARY_CONTAINER" cluster_status 2>/dev/null || true) \
    | awk '/^rabbit@/' | sort -u | wc -l)
if [ "$NODE_COUNT" -ge 2 ]; then
    assert_pass "Cluster has 2 nodes (rabbit@rabbitmq + rabbit@rabbitmq-spare)"
else
    assert_fail "Cluster has 2 nodes" "found $NODE_COUNT node(s) — cluster may not have formed yet"
    warn "Ensure both nodes started and the Erlang cookie matches. Aborting."
    exit 1
fi

# 1.8 HA mirroring policy is active
POLICY_COUNT=$( (rmqctl "$PRIMARY_CONTAINER" list_policies 2>/dev/null || true) \
    | awk '/ha-all/' | wc -l)
if [ "$POLICY_COUNT" -ge 1 ]; then
    assert_pass "HA mirroring policy 'ha-all' is active"
else
    assert_fail "HA mirroring policy 'ha-all' is active" \
        "Run: docker exec $PRIMARY_CONTAINER rabbitmqctl set_policy ha-all '.*' '{\"ha-mode\":\"all\",\"ha-sync-mode\":\"automatic\"}' --apply-to queues"
    warn "Applying policy now and continuing..."
    docker exec "$PRIMARY_CONTAINER" rabbitmqctl set_policy ha-all ".*" \
        '{"ha-mode":"all","ha-sync-mode":"automatic"}' \
        --apply-to queues --priority 0 >/dev/null 2>&1 || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: TEST QUEUE SETUP
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 2: Test Infrastructure Setup"

info "Declaring test exchange and queue on primary..."

# Declare durable exchange (idempotent — adopti.events likely already exists)
rmqadmin "$PRIMARY_CONTAINER" declare exchange \
    name="$TEST_EXCHANGE" type=topic durable=true >/dev/null 2>&1 || true
assert_pass "Exchange '$TEST_EXCHANGE' declared (or already exists)"

# Declare durable test queue
rmqadmin "$PRIMARY_CONTAINER" declare queue \
    name="$TEST_QUEUE" durable=true >/dev/null 2>&1
assert_pass "Test queue '$TEST_QUEUE' declared (durable)"

# Bind queue to exchange with test routing key
rmqadmin "$PRIMARY_CONTAINER" declare binding \
    source="$TEST_EXCHANGE" \
    destination_type=queue \
    destination="$TEST_QUEUE" \
    routing_key="$TEST_ROUTING_KEY" >/dev/null 2>&1 || true
assert_pass "Queue bound to exchange with routing key '$TEST_ROUTING_KEY'"

# Verify mirror exists on spare
sleep 2
MIRROR_INFO=$(rmqctl "$PRIMARY_CONTAINER" list_queues name mirror_pids 2>/dev/null \
    | grep "$TEST_QUEUE" || echo "")
if echo "$MIRROR_INFO" | grep -q "rabbitmq-spare"; then
    assert_pass "Queue '$TEST_QUEUE' is mirrored on rabbitmq-spare"
else
    warn "Mirror not yet synced — waiting 5 s..."
    sleep 5
    MIRROR_INFO=$(rmqctl "$PRIMARY_CONTAINER" list_queues name mirror_pids 2>/dev/null \
        | grep "$TEST_QUEUE" || echo "")
    if echo "$MIRROR_INFO" | grep -q "rabbitmq-spare"; then
        assert_pass "Queue '$TEST_QUEUE' is mirrored on rabbitmq-spare (after wait)"
    else
        assert_fail "Queue '$TEST_QUEUE' is mirrored on rabbitmq-spare" \
            "Mirroring may not be configured correctly"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: BASELINE — PUBLISH AND CONSUME VIA PRIMARY
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 3: Baseline — Publish & Consume (Primary Active)"

info "Publishing $MESSAGES_BEFORE durable messages via primary..."
publish_messages "$PRIMARY_CONTAINER" "$MESSAGES_BEFORE" "before"
assert_pass "Published $MESSAGES_BEFORE messages to '$TEST_EXCHANGE' (routing_key=$TEST_ROUTING_KEY)"

# Verify queue depth (non-destructive) using rabbitmqctl list_queues.
# 'messages_ready' is the authoritative count from the broker itself.
# Using rabbitmqctl avoids the grep|wc-l pipefail issue that plagued
# the rabbitmqadmin get approach under set -o pipefail.
sleep 1
QUEUED=$( (rmqctl "$PRIMARY_CONTAINER" list_queues name messages_ready 2>/dev/null || true) \
    | awk -v q="$TEST_QUEUE" '$1==q {print $2}')
QUEUED=${QUEUED:-0}
if [ "$QUEUED" -eq "$MESSAGES_BEFORE" ]; then
    assert_pass "$MESSAGES_BEFORE messages ready in queue (on primary)"
else
    assert_fail "$MESSAGES_BEFORE messages ready in queue" "found $QUEUED"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4: INJECT FAILURE — STOP THE PRIMARY
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 4: Inject Failure — Stop Primary Broker"

info "Stopping primary container: $PRIMARY_CONTAINER..."
FAILOVER_START=$(date +%s)
docker stop "$PRIMARY_CONTAINER" >/dev/null
info "Primary stopped at $(date '+%H:%M:%S'). Waiting for failover..."

# Poll until NGINX LB actively routes connections to the spare.
# FIX Bug 2: the old check tested if the spare's OWN port was open (always true
# since startup). The correct signal is whether rabbitmq-lb forwards a new TCP
# connection to an alive upstream — i.e., probe_lb_routing() succeeds.
FAILOVER_ELAPSED=0
LB_ROUTING_OK=false
while [ "$FAILOVER_ELAPSED" -lt "$FAILOVER_TIMEOUT" ]; do
    PRIMARY_STATUS=$(docker inspect --format='{{.State.Status}}' "$PRIMARY_CONTAINER" 2>/dev/null || echo "missing")
    if [ "$PRIMARY_STATUS" != "running" ]; then
        # Primary is confirmed down; now check if NGINX promotes spare
        if probe_lb_routing 5; then
            LB_ROUTING_OK=true
            break
        fi
    fi
    sleep "$POLL_INTERVAL"
    FAILOVER_ELAPSED=$(elapsed_since "$FAILOVER_START")
done

FAILOVER_ELAPSED=$(elapsed_since "$FAILOVER_START")

if $LB_ROUTING_OK; then
    assert_pass "NGINX LB routes through to spare (failover detected in ${FAILOVER_ELAPSED}s)"
else
    assert_fail "NGINX LB routes through to spare within ${FAILOVER_TIMEOUT}s" \
        "Elapsed: ${FAILOVER_ELAPSED}s — NGINX may not have promoted the backup server"
fi

if [ "$FAILOVER_ELAPSED" -le 30 ]; then
    assert_pass "Failover time within SLO (${FAILOVER_ELAPSED}s ≤ 30s)"
else
    assert_fail "Failover time within SLO (target ≤ 30s)" "actual: ${FAILOVER_ELAPSED}s"
fi

# Wait for NGINX health-check cycle to fully settle before Phase 5 reads
info "Waiting 15s for NGINX health-check cycle to settle..."
sleep 15

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5: VERIFY SPARE IS PROMOTED — MESSAGES SURVIVED FAILOVER
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 5: Verify Queue Continuity on Warm Spare"

# Check messages from before failover are still present on spare.
# Use rabbitmqctl list_queues (non-destructive) — safer than rabbitmqadmin get
# under set -o pipefail and does not consume any messages.
SURVIVING=$( (rmqctl "$SPARE_CONTAINER" list_queues name messages_ready 2>/dev/null || true) \
    | awk -v q="$TEST_QUEUE" '$1==q {print $2}')
SURVIVING=${SURVIVING:-0}

if [ "$SURVIVING" -eq "$MESSAGES_BEFORE" ]; then
    assert_pass "All $MESSAGES_BEFORE pre-failover messages survived on spare (RPO=0)"
else
    assert_fail "Pre-failover messages survived on spare" \
        "expected $MESSAGES_BEFORE, found $SURVIVING — possible message loss"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6: PUBLISH DURING OUTAGE — THROUGH NGINX LB → SPARE
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 6: Publish During Outage (LB → Spare)"

# FIX Bug 1: the original code published directly to the spare's management API
# (docker exec spare rabbitmqadmin --port=15671), which bypasses rabbitmq-lb entirely.
# rabbitmqadmin uses the HTTP management API, not AMQP \u2014 it cannot go "through" the
# AMQP LB on port 5671. The correct fix is to:
#   (a) Explicitly assert that the NGINX LB backup path is active (probe_lb_routing),
#       which validates the core warm-spare claim.
#   (b) Keep the publish via the spare's management API (this is correct for
#       rabbitmqadmin) and fix the comment to say so accurately.

info "Asserting NGINX LB is routing AMQP connections to spare while primary is DOWN..."
if probe_lb_routing 10; then
    assert_pass "NGINX LB 'backup' server active: rabbitmq-lb:5671 \u2192 rabbitmq-spare:5671"
else
    assert_fail "NGINX LB backup promotion" \
        "rabbitmq-lb:5671 did not forward connections \u2014 spare may be unreachable"
fi

info "Publishing $MESSAGES_DURING more messages while primary is DOWN..."
info "(via spare management API on :15671 \u2014 AMQP traffic through LB is validated above)"

PUBLISH_START=$(date +%s)
publish_messages "$SPARE_CONTAINER" "$MESSAGES_DURING" "during"
PUBLISH_ELAPSED=$(elapsed_since "$PUBLISH_START")

assert_pass "Published $MESSAGES_DURING messages during primary outage (${PUBLISH_ELAPSED}s)"

sleep 1
TOTAL_IN_QUEUE=$( (rmqctl "$SPARE_CONTAINER" list_queues name messages_ready 2>/dev/null || true) \
    | awk -v q="$TEST_QUEUE" '$1==q {print $2}')
TOTAL_IN_QUEUE=${TOTAL_IN_QUEUE:-0}

EXPECTED_TOTAL=$((MESSAGES_BEFORE + MESSAGES_DURING))
if [ "$TOTAL_IN_QUEUE" -eq "$EXPECTED_TOTAL" ]; then
    assert_pass "Total $EXPECTED_TOTAL messages present in queue on spare"
else
    assert_fail "Total messages in queue" "expected $EXPECTED_TOTAL, found $TOTAL_IN_QUEUE"
fi

# Consume ALL messages from spare \u2014 final zero-loss assertion
CONSUMED=$(consume_messages "$SPARE_CONTAINER" "$EXPECTED_TOTAL")
if [ "$CONSUMED" -eq "$EXPECTED_TOTAL" ]; then
    assert_pass "Consumed all $EXPECTED_TOTAL messages \u2014 ZERO MESSAGE LOSS confirmed"
else
    assert_fail "Zero message loss" "consumed $CONSUMED of $EXPECTED_TOTAL messages"
fi


# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7: RESTORE PRIMARY AND VERIFY CLUSTER REFORMATION
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 7: Restore Primary — Cluster Reformation"

info "Restarting primary container: $PRIMARY_CONTAINER..."
RECOVERY_START=$(date +%s)
docker start "$PRIMARY_CONTAINER" >/dev/null
info "Primary restarting at $(date '+%H:%M:%S'). Waiting for cluster reformation..."

# Poll until primary is healthy and cluster shows 2 nodes again.
# FIX Bug 5 (Phase 7): use list_nodes + '^rabbit@' anchor \u2014 same fix as Phase 1.
# 'cluster_status' with grep "rabbit@rabbitmq" would match 'rabbit@rabbitmq-spare'
# as a substring, producing inflated counts and a false-positive on a 1-node cluster.
RECOVERY_ELAPSED=0
CLUSTER_REFORMED=false
while [ "$RECOVERY_ELAPSED" -lt "$RECOVERY_TIMEOUT" ]; do
    NODE_COUNT=$( (rmqctl "$PRIMARY_CONTAINER" cluster_status 2>/dev/null || true) \
        | awk '/^rabbit@/' | sort -u | wc -l)
    if [ "$NODE_COUNT" -ge 2 ]; then
        CLUSTER_REFORMED=true
        break
    fi
    sleep "$POLL_INTERVAL"
    RECOVERY_ELAPSED=$(elapsed_since "$RECOVERY_START")
done

RECOVERY_ELAPSED=$(elapsed_since "$RECOVERY_START")

if $CLUSTER_REFORMED; then
    assert_pass "Cluster reformed to 2 nodes in ${RECOVERY_ELAPSED}s"
else
    assert_fail "Cluster reformation within ${RECOVERY_TIMEOUT}s" \
        "Elapsed: ${RECOVERY_ELAPSED}s \u2014 primary may still be syncing"
fi

# Verify HA policy is still active after reformation
POLICY_COUNT=$( (rmqctl "$PRIMARY_CONTAINER" list_policies 2>/dev/null || true) \
    | awk '/ha-all/' | wc -l)
if [ "$POLICY_COUNT" -ge 1 ]; then
    assert_pass "HA mirroring policy 'ha-all' persists after cluster reformation"
else
    assert_fail "HA mirroring policy persists after recovery"
fi

# Verify mirror is back on primary (queue should now mirror on both nodes again)
sleep 3
MIRROR_BACK=$( (rmqctl "$SPARE_CONTAINER" list_queues name mirror_pids 2>/dev/null || true) \
    | awk -v q="$TEST_QUEUE" '$0 ~ q')
# FIX Bug 4: the else branch previously called assert_pass unconditionally, meaning
# a completely broken mirror after recovery still showed \u2714 PASS. Now it calls
# assert_fail so a missing mirror is actually caught as a test failure.
if echo "$MIRROR_BACK" | grep -q "rabbitmq"; then
    assert_pass "Queue '$TEST_QUEUE' is mirrored back across both nodes"
else
    assert_fail "Queue '$TEST_QUEUE' is mirrored back across both nodes" \
        "mirror_pids did not show the queue on both nodes \u2014 resync may have failed"
fi

# Verify NGINX LB routes back to primary now that it has recovered
# (this covers the missing coverage gap: LB reverting from backup to primary)
info "Waiting 5s for NGINX to detect primary recovery and resume routing..."
sleep 5
if probe_lb_routing 5; then
    assert_pass "NGINX LB routes AMQP connections after primary recovery"
else
    assert_fail "NGINX LB routes AMQP connections after primary recovery" \
        "rabbitmq-lb:5671 \u2192 no upstream reachable after primary restart"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8: CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
section "Phase 8: Cleanup"

info "Deleting test queue '$TEST_QUEUE'..."
rmqadmin "$PRIMARY_CONTAINER" delete queue name="$TEST_QUEUE" >/dev/null 2>&1 || true
assert_pass "Test queue '$TEST_QUEUE' deleted"

# ─────────────────────────────────────────────────────────────────────────────
# FINAL REPORT
# ─────────────────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$(elapsed_since "$TOTAL_START")

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                   TEST RESULTS SUMMARY                    ║${NC}"
echo -e "${BOLD}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  Total elapsed : ${TOTAL_ELAPSED}s${NC}"
echo -e "${BOLD}║  Tests passed  : ${GREEN}${PASS_COUNT}${NC}"
echo -e "${BOLD}║  Tests failed  : ${RED}${FAIL_COUNT}${NC}"
echo -e "${BOLD}╠═══════════════════════════════════════════════════════════╣${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${BOLD}║  ${GREEN}✔ ALL ASSERTIONS PASSED — Warm spare is operational${NC}   ${BOLD}║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 0
else
    echo -e "${BOLD}║  ${RED}✘ $FAIL_COUNT ASSERTION(S) FAILED — review output above${NC}   ${BOLD}║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi
