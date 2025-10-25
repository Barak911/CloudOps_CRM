#!/bin/bash
# End-to-end testing script for CI/CD pipeline

set -e

echo "Starting E2E tests..."

# Wait for application to be ready
echo "Waiting for application to be healthy..."
for i in {1..30}; do
    if curl -f http://localhost:5001/health > /dev/null 2>&1; then
        echo "Application is healthy!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Test 1: Health check
echo "Test 1: Health check"
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:5001/health)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "200" ]; then
    echo "FAILED: Health check returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: Health check"

# Test 2: Root endpoint
echo "Test 2: Root endpoint"
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:5001/)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "200" ]; then
    echo "FAILED: Root endpoint returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: Root endpoint"

# Test 3: GET /person (should return empty array initially)
echo "Test 3: GET /person"
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:5001/person)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "200" ]; then
    echo "FAILED: GET /person returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: GET /person"

# Test 4: POST /person/{id}
echo "Test 4: POST /person/123"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"John Doe","email":"john@example.com","phone":"555-1234"}' \
    http://localhost:5001/person/123)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "201" ]; then
    echo "FAILED: POST /person/123 returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: POST /person/123"

# Test 5: Verify person was added
echo "Test 5: Verify person was added (GET /person)"
RESPONSE=$(curl -s http://localhost:5001/person)
if echo "$RESPONSE" | grep -q "John Doe"; then
    echo "PASSED: Person was added successfully"
else
    echo "FAILED: Person not found in database"
    exit 1
fi

# Test 6: GET /person/{custom_id}
echo "Test 6: GET /person/123 (by custom ID)"
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:5001/person/123)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | head -n -1)
if [ "$STATUS_CODE" != "200" ]; then
    echo "FAILED: GET /person/123 returned $STATUS_CODE"
    exit 1
fi
if echo "$BODY" | grep -q "John Doe"; then
    echo "PASSED: GET /person/123"
else
    echo "FAILED: Person not found by custom ID"
    exit 1
fi

# Test 7: PUT /person/{id} - Update person
echo "Test 7: PUT /person/123 (update)"
RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    -d '{"name":"Jane Doe","email":"jane@example.com","phone":"555-5678"}' \
    http://localhost:5001/person/123)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "200" ]; then
    echo "FAILED: PUT /person/123 returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: PUT /person/123"

# Test 8: Verify update
echo "Test 8: Verify update (GET /person/123)"
RESPONSE=$(curl -s http://localhost:5001/person/123)
if echo "$RESPONSE" | grep -q "Jane Doe" && echo "$RESPONSE" | grep -q "jane@example.com"; then
    echo "PASSED: Person was updated successfully"
else
    echo "FAILED: Update verification failed"
    exit 1
fi

# Test 9: POST another person for deletion test
echo "Test 9: POST /person/456 (for deletion test)"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"Delete Me","email":"delete@example.com","phone":"555-0000"}' \
    http://localhost:5001/person/456)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "201" ]; then
    echo "FAILED: POST /person/456 returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: POST /person/456"

# Test 10: DELETE /person/{id}
echo "Test 10: DELETE /person/456"
RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:5001/person/456)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "200" ]; then
    echo "FAILED: DELETE /person/456 returned $STATUS_CODE"
    exit 1
fi
echo "PASSED: DELETE /person/456"

# Test 11: Verify deletion (should return 404)
echo "Test 11: Verify deletion (GET /person/456 should return 404)"
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:5001/person/456)
STATUS_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$STATUS_CODE" != "404" ]; then
    echo "FAILED: GET /person/456 returned $STATUS_CODE (expected 404)"
    exit 1
fi
echo "PASSED: Person was deleted successfully"

echo ""
echo "======================================"
echo "All 11 E2E tests passed successfully!"
echo "======================================"
exit 0
