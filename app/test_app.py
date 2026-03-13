import pytest
import json
import logging
import mongomock
from unittest.mock import patch
from app import app as flask_app, JsonFormatter

@pytest.fixture
def app():
    """Create application for testing with in-memory MongoDB"""
    flask_app.config['TESTING'] = True
    # Create a mongomock client and patch the global mongo object
    mock_client = mongomock.MongoClient()
    mock_db = mock_client['test_crm_db']

    import app as app_module
    original_db = app_module.mongo.db
    app_module.mongo.db = mock_db

    yield flask_app

    # Clean up
    mock_db.persons.drop()
    app_module.mongo.db = original_db

@pytest.fixture
def client(app):
    """Create test client"""
    return app.test_client()

# ---------------------------------------------------------------------------
# Existing tests
# ---------------------------------------------------------------------------

def test_health_check(client):
    """Test health check endpoint"""
    response = client.get('/health')
    assert response.status_code == 200
    data = response.get_json()
    assert data['status'] == 'healthy'
    assert 'service' in data

def test_root_serves_html(client):
    """Test root endpoint serves frontend HTML"""
    response = client.get('/')
    assert response.status_code == 200
    assert b'<!DOCTYPE html>' in response.data or b'<html' in response.data

def test_api_info_endpoint(client):
    """Test /api endpoint returns JSON info"""
    response = client.get('/api')
    assert response.status_code == 200
    data = response.get_json()
    assert data['service'] == 'CRM REST API'
    assert data['version'] == '3.1.0'
    assert 'endpoints' in data

def test_get_persons_empty(client):
    """Test getting persons when none exist"""
    response = client.get('/person')
    assert response.status_code == 200
    data = response.get_json()
    assert data == []

def test_json_formatter():
    """Test JSON logging formatter"""
    formatter = JsonFormatter()
    record = logging.LogRecord(
        name='test',
        level=logging.INFO,
        pathname='test.py',
        lineno=10,
        msg='Test message',
        args=(),
        exc_info=None
    )

    record.correlation_id = 'test-123'
    record.request_method = 'GET'
    record.request_path = '/test'
    record.status_code = 200

    formatted = formatter.format(record)
    log_data = json.loads(formatted)

    assert log_data['message'] == 'Test message'
    assert log_data['level'] == 'INFO'
    assert log_data['correlation_id'] == 'test-123'
    assert log_data['request_method'] == 'GET'
    assert log_data['request_path'] == '/test'
    assert log_data['status_code'] == 200
    assert 'timestamp' in log_data

def test_correlation_id_header(client):
    """Test that correlation ID header is used"""
    correlation_id = 'custom-correlation-123'
    response = client.get('/api', headers={'X-Correlation-ID': correlation_id})
    assert response.status_code == 200

def test_metrics_endpoint(client):
    """Test Prometheus metrics endpoint"""
    response = client.get('/metrics')
    assert response.status_code == 200

# ---------------------------------------------------------------------------
# CRUD tests with in-memory MongoDB
# ---------------------------------------------------------------------------

def test_add_and_get_person(client):
    """Test adding a person and retrieving it"""
    response = client.post('/person/test-001',
                           data=json.dumps({"name": "Alice", "email": "alice@test.com"}),
                           content_type='application/json')
    assert response.status_code == 201
    data = response.get_json()
    assert data['person_id'] == 'test-001'

    response = client.get('/person/test-001')
    assert response.status_code == 200
    data = response.get_json()
    assert data['name'] == 'Alice'
    assert data['email'] == 'alice@test.com'

def test_search_missing_query(client):
    """Test search returns 400 when q parameter is missing"""
    response = client.get('/person/search')
    assert response.status_code == 400
    data = response.get_json()
    assert 'error' in data

def test_search_empty_query(client):
    """Test search returns 400 when q parameter is empty"""
    response = client.get('/person/search?q=')
    assert response.status_code == 400

def test_search_finds_person(client):
    """Test search finds a person by name"""
    client.post('/person/s-001',
                data=json.dumps({"name": "Bob Smith", "email": "bob@test.com"}),
                content_type='application/json')
    response = client.get('/person/search?q=Bob')
    assert response.status_code == 200
    data = response.get_json()
    assert len(data) == 1
    assert data[0]['name'] == 'Bob Smith'

def test_bulk_add_not_array(client):
    """Test bulk add returns 400 when body is not an array"""
    response = client.post('/person/bulk',
                           data=json.dumps({"name": "test"}),
                           content_type='application/json')
    assert response.status_code == 400

def test_bulk_add_empty_body(client):
    """Test bulk add returns 400 when body is empty"""
    response = client.post('/person/bulk',
                           data=json.dumps(None),
                           content_type='application/json')
    assert response.status_code == 400

def test_bulk_add_missing_person_id(client):
    """Test bulk add validates person_id in entries"""
    response = client.post('/person/bulk',
                           data=json.dumps([{"name": "No ID"}]),
                           content_type='application/json')
    assert response.status_code == 400

def test_bulk_delete_missing_ids(client):
    """Test bulk delete returns 400 when ids array is missing"""
    response = client.delete('/person/bulk',
                             data=json.dumps({"wrong": "field"}),
                             content_type='application/json')
    assert response.status_code == 400

def test_bulk_delete_empty_body(client):
    """Test bulk delete returns 400 when body is empty"""
    response = client.delete('/person/bulk',
                             data=json.dumps(None),
                             content_type='application/json')
    assert response.status_code == 400

def test_stats_endpoint(client):
    """Test stats endpoint returns expected structure"""
    response = client.get('/stats')
    assert response.status_code == 200
    data = response.get_json()
    assert 'total_persons' in data
    assert data['total_persons'] == 0

def test_pagination_params(client):
    """Test pagination query parameters are accepted"""
    response = client.get('/person?page=1&limit=5')
    assert response.status_code == 200
    data = response.get_json()
    assert 'data' in data
    assert 'page' in data
    assert 'limit' in data
    assert 'total' in data
    assert 'pages' in data

def test_add_person_no_body(client):
    """Test add person returns 400 when no body provided"""
    response = client.post('/person/test-id',
                           data=None,
                           content_type='application/json')
    assert response.status_code == 400

def test_update_person_no_body(client):
    """Test update person returns 400 when no body provided"""
    response = client.put('/person/nonexistent',
                          data=None,
                          content_type='application/json')
    assert response.status_code == 400

def test_update_existing_person(client):
    """Test updating an existing person"""
    client.post('/person/upd-001',
                data=json.dumps({"name": "Original", "email": "orig@test.com"}),
                content_type='application/json')
    response = client.put('/person/upd-001',
                          data=json.dumps({"name": "Updated"}),
                          content_type='application/json')
    assert response.status_code == 200
    data = response.get_json()
    assert data['modified_count'] == 1

def test_delete_person(client):
    """Test deleting a person"""
    client.post('/person/del-001',
                data=json.dumps({"name": "ToDelete"}),
                content_type='application/json')
    response = client.delete('/person/del-001')
    assert response.status_code == 200

    response = client.get('/person/del-001')
    assert response.status_code == 404

def test_delete_nonexistent_person(client):
    """Test deleting a person that doesn't exist"""
    response = client.delete('/person/nonexistent')
    assert response.status_code == 404
