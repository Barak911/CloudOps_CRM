#!/bin/bash
# End-to-end testing script for CI/CD pipeline

set -e

BASE_URL="http://localhost:5001"
PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "PASSED: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAILED: $1"; exit 1; }

# Helper: extract HTTP body and status from curl output (macOS-safe)
# Usage: eval "$(split_response "$RESPONSE")"  → sets BODY and STATUS
split_response() {
  STATUS=$(echo "$1" | tail -n 1)
  BODY=$(echo "$1" | sed '$d')
}

echo "Starting E2E tests..."

# Wait for application to be ready
echo "Waiting for application to be healthy..."
for i in {1..30}; do
    if curl -f $BASE_URL/ready > /dev/null 2>&1; then
        echo "Application is healthy!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# ── Core CRUD Tests ──────────────────────────────────────────────────────

# Test 1: Liveness check
echo "Test 1: Liveness check"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" $BASE_URL/health)
[ "$STATUS" = "200" ] && pass "Liveness check" || fail "Liveness check returned $STATUS"

# Test 1b: Readiness check (verifies DB connectivity)
echo "Test 1b: Readiness check"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" $BASE_URL/ready)
[ "$STATUS" = "200" ] && pass "Readiness check" || fail "Readiness check returned $STATUS"

# Test 2: Root serves HTML frontend
echo "Test 2: Root endpoint serves HTML"
BODY=$(curl -s $BASE_URL/)
echo "$BODY" | grep -qi "html" && pass "Root serves HTML" || fail "Root did not return HTML"

# Test 3: API info endpoint
echo "Test 3: API info"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" $BASE_URL/api)
[ "$STATUS" = "200" ] && pass "API info" || fail "API info returned $STATUS"

# Test 4: GET /person (should return empty array initially)
echo "Test 4: GET /person"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" $BASE_URL/person)
[ "$STATUS" = "200" ] && pass "GET /person" || fail "GET /person returned $STATUS"

# Test 5: POST /person/{id}
echo "Test 5: POST /person/123"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"John Doe","email":"john@example.com","phone":"555-1234"}' \
    $BASE_URL/person/123)
[ "$STATUS" = "201" ] && pass "POST /person/123" || fail "POST /person/123 returned $STATUS"

# Test 6: Verify person was added
echo "Test 6: Verify person was added"
RESPONSE=$(curl -s $BASE_URL/person)
echo "$RESPONSE" | grep -q "John Doe" && pass "Person added" || fail "Person not found"

# Test 7: GET /person/{custom_id}
echo "Test 7: GET /person/123"
RESPONSE=$(curl -s -w "\n%{http_code}" $BASE_URL/person/123)
split_response "$RESPONSE"
[ "$STATUS" = "200" ] && echo "$BODY" | grep -q "John Doe" && pass "GET /person/123" || fail "GET /person/123 failed"

# Test 8: PUT /person/{id}
echo "Test 8: PUT /person/123"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    -d '{"name":"Jane Doe","email":"jane@example.com","phone":"555-5678"}' \
    $BASE_URL/person/123)
[ "$STATUS" = "200" ] && pass "PUT /person/123" || fail "PUT /person/123 returned $STATUS"

# Test 9: Verify update
echo "Test 9: Verify update"
RESPONSE=$(curl -s $BASE_URL/person/123)
echo "$RESPONSE" | grep -q "Jane Doe" && echo "$RESPONSE" | grep -q "jane@example.com" \
    && pass "Update verified" || fail "Update verification failed"

# Test 10: POST person for deletion
echo "Test 10: POST /person/456"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"Delete Me","email":"delete@example.com","phone":"555-0000"}' \
    $BASE_URL/person/456)
[ "$STATUS" = "201" ] && pass "POST /person/456" || fail "POST /person/456 returned $STATUS"

# Test 11: DELETE /person/{id}
echo "Test 11: DELETE /person/456"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE $BASE_URL/person/456)
[ "$STATUS" = "200" ] && pass "DELETE /person/456" || fail "DELETE /person/456 returned $STATUS"

# Test 12: Verify deletion
echo "Test 12: Verify deletion (expect 404)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" $BASE_URL/person/456)
[ "$STATUS" = "404" ] && pass "Deletion verified" || fail "Expected 404, got $STATUS"

# ── New Endpoint Tests ───────────────────────────────────────────────────

# Test 13: Stats endpoint
echo "Test 13: GET /stats"
RESPONSE=$(curl -s -w "\n%{http_code}" $BASE_URL/stats)
split_response "$RESPONSE"
[ "$STATUS" = "200" ] && echo "$BODY" | grep -q "total_persons" \
    && pass "Stats endpoint" || fail "Stats returned $STATUS"

# Test 14: Search endpoint
echo "Test 14: GET /person/search?q=Jane"
RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/person/search?q=Jane")
split_response "$RESPONSE"
[ "$STATUS" = "200" ] && echo "$BODY" | grep -q "Jane Doe" \
    && pass "Search found Jane" || fail "Search failed ($STATUS)"

# Test 15: Search — no results
echo "Test 15: GET /person/search?q=zzzznotfound"
RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/person/search?q=zzzznotfound")
split_response "$RESPONSE"
[ "$STATUS" = "200" ] && [ "$BODY" = "[]" ] \
    && pass "Search empty result" || fail "Search empty failed ($STATUS)"

# Test 16: Search — missing query param
echo "Test 16: GET /person/search (no q param)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/person/search")
[ "$STATUS" = "400" ] && pass "Search missing q → 400" || fail "Expected 400, got $STATUS"

# Test 17: Pagination
echo "Test 17: GET /person?page=1&limit=5"
RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/person?page=1&limit=5")
split_response "$RESPONSE"
[ "$STATUS" = "200" ] && echo "$BODY" | grep -q '"page"' && echo "$BODY" | grep -q '"total"' \
    && pass "Pagination" || fail "Pagination failed ($STATUS)"

# Test 18: Bulk add
echo "Test 18: POST /person/bulk"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '[
      {"person_id":"bulk-1","name":"Bulk User 1","email":"b1@test.com"},
      {"person_id":"bulk-2","name":"Bulk User 2","email":"b2@test.com"},
      {"person_id":"bulk-3","name":"Bulk User 3","email":"b3@test.com"}
    ]' \
    $BASE_URL/person/bulk)
[ "$STATUS" = "201" ] && pass "Bulk add" || fail "Bulk add returned $STATUS"

# Test 19: Verify bulk add
echo "Test 19: Verify bulk users exist"
RESPONSE=$(curl -s $BASE_URL/person)
echo "$RESPONSE" | grep -q "Bulk User 1" && echo "$RESPONSE" | grep -q "Bulk User 3" \
    && pass "Bulk users found" || fail "Bulk users not found"

# Test 20: Bulk delete
echo "Test 20: DELETE /person/bulk"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Content-Type: application/json" \
    -d '{"ids":["bulk-1","bulk-2","bulk-3"]}' \
    $BASE_URL/person/bulk)
[ "$STATUS" = "200" ] && pass "Bulk delete" || fail "Bulk delete returned $STATUS"

# ── Cleanup ──────────────────────────────────────────────────────────────

# Delete remaining test person
curl -s -o /dev/null -X DELETE $BASE_URL/person/123

echo ""
echo "======================================"
echo "All $PASSED E2E tests passed! (including readiness check)"
echo "======================================"
exit 0
