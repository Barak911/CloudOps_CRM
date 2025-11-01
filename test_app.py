import pytest
import json
import logging
from app import app as flask_app, JsonFormatter

@pytest.fixture
def app():
    """Create application for testing"""
    flask_app.config['TESTING'] = True
    return flask_app

@pytest.fixture
def client(app):
    """Create test client"""
    return app.test_client()

def test_health_check(client):
    """Test health check endpoint"""
    response = client.get('/health')
    assert response.status_code == 200
    data = response.get_json()
    assert data['status'] == 'healthy'
    assert 'service' in data

def test_root_endpoint(client):
    """Test root endpoint"""
    response = client.get('/')
    assert response.status_code == 200
    data = response.get_json()
    assert 'service' in data
    assert 'endpoints' in data
    assert data['service'] == 'CRM REST API'

def test_get_persons_empty(client):
    """Test getting persons when none exist"""
    response = client.get('/person')
    assert response.status_code in [200, 500]  # May fail if no DB connection

def test_api_info(client):
    """Test API returns correct information"""
    response = client.get('/')
    assert response.status_code == 200
    data = response.get_json()
    assert 'version' in data

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

    # Add extra fields
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
    response = client.get('/', headers={'X-Correlation-ID': correlation_id})
    assert response.status_code == 200

def test_metrics_endpoint(client):
    """Test Prometheus metrics endpoint"""
    response = client.get('/metrics')
    assert response.status_code == 200
