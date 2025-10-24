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

echo ""
echo "======================================"
echo "All E2E tests passed successfully!"
echo "======================================"
exit 0
