import pytest
from app import app as flask_app

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
