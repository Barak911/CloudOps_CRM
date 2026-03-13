from flask import Flask, request, jsonify, send_from_directory
from flask_pymongo import PyMongo
from bson.objectid import ObjectId
from prometheus_flask_exporter import PrometheusMetrics
import os
import logging
import json
from datetime import datetime, timezone
import uuid
import re

app = Flask(__name__, static_folder='static')

# MongoDB configuration
app.config["MONGO_URI"] = os.getenv("MONGO_URI", "mongodb://localhost:27017/crm_db")
mongo = PyMongo(app)

# Prometheus metrics configuration
metrics = PrometheusMetrics(app)

# Custom metrics
metrics.info('crm_app_info', 'CRM Application info', version='3.1.0', environment=os.getenv("ENVIRONMENT", "production"))

# Configure JSON structured logging
class JsonFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno
        }

        # Add extra fields if they exist
        if hasattr(record, 'correlation_id'):
            log_data['correlation_id'] = record.correlation_id
        if hasattr(record, 'request_method'):
            log_data['request_method'] = record.request_method
        if hasattr(record, 'request_path'):
            log_data['request_path'] = record.request_path
        if hasattr(record, 'status_code'):
            log_data['status_code'] = record.status_code
        if hasattr(record, 'user_id'):
            log_data['user_id'] = record.user_id

        return json.dumps(log_data)

# Set up logging
handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
app.logger.addHandler(handler)
app.logger.setLevel(logging.INFO)
logger = app.logger

# Request logging middleware
@app.before_request
def before_request():
    request.correlation_id = request.headers.get('X-Correlation-ID', str(uuid.uuid4()))
    logger.info(
        f"Incoming request: {request.method} {request.path}",
        extra={
            'correlation_id': request.correlation_id,
            'request_method': request.method,
            'request_path': request.path,
            'remote_addr': request.remote_addr
        }
    )

@app.after_request
def after_request(response):
    logger.info(
        f"Request completed: {request.method} {request.path}",
        extra={
            'correlation_id': getattr(request, 'correlation_id', 'unknown'),
            'request_method': request.method,
            'request_path': request.path,
            'status_code': response.status_code
        }
    )
    return response

# ---------------------------------------------------------------------------
# Frontend
# ---------------------------------------------------------------------------

@app.route('/', methods=['GET'])
def index():
    """Serve the frontend UI"""
    return send_from_directory(app.static_folder, 'index.html')

# ---------------------------------------------------------------------------
# API info
# ---------------------------------------------------------------------------

@app.route('/api', methods=['GET'])
def api_info():
    """API information and endpoint listing"""
    return jsonify({
        "service": "CRM REST API",
        "version": "3.1.0",
        "endpoints": {
            "GET  /health": "Health check",
            "GET  /metrics": "Prometheus metrics",
            "GET  /stats": "Collection statistics",
            "GET  /person": "List all persons (supports ?page=&limit=)",
            "GET  /person/search?q=<term>": "Search persons by name or email",
            "GET  /person/<custom_id>": "Get person by custom ID",
            "POST /person/<custom_id>": "Add person with custom ID",
            "POST /person/bulk": "Add multiple persons",
            "PUT  /person/<custom_id>": "Update person by custom ID",
            "DELETE /person/<custom_id>": "Delete person by custom ID",
            "DELETE /person/bulk": "Delete multiple persons by custom IDs"
        }
    }), 200

# ---------------------------------------------------------------------------
# Health & Stats
# ---------------------------------------------------------------------------

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({"status": "healthy", "service": "CRM API"}), 200

@app.route('/stats', methods=['GET'])
def stats():
    """Collection statistics"""
    try:
        total = mongo.db.persons.count_documents({})
        latest = mongo.db.persons.find_one(sort=[("_id", -1)])
        latest_id = str(latest['_id']) if latest else None

        return jsonify({
            "total_persons": total,
            "latest_entry_id": latest_id
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ---------------------------------------------------------------------------
# Person CRUD
# ---------------------------------------------------------------------------

@app.route('/person', methods=['GET'])
def get_persons():
    """Get all persons — supports pagination via ?page=&limit= and legacy ?id= lookup"""
    try:
        person_id = request.args.get('id')

        if person_id:
            person = mongo.db.persons.find_one({"_id": ObjectId(person_id)})
            if person:
                person['_id'] = str(person['_id'])
                return jsonify(person), 200
            return jsonify({"error": "Person not found"}), 404

        # Pagination
        page = request.args.get('page', default=None, type=int)
        limit = request.args.get('limit', default=20, type=int)
        limit = min(limit, 100)  # cap at 100

        if page is not None:
            skip = (max(page, 1) - 1) * limit
            total = mongo.db.persons.count_documents({})
            persons = list(mongo.db.persons.find().skip(skip).limit(limit))
            for p in persons:
                p['_id'] = str(p['_id'])
            return jsonify({
                "data": persons,
                "page": max(page, 1),
                "limit": limit,
                "total": total,
                "pages": (total + limit - 1) // limit if limit else 1
            }), 200

        # No pagination — return all
        persons = list(mongo.db.persons.find())
        for p in persons:
            p['_id'] = str(p['_id'])
        return jsonify(persons), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

@app.route('/person/search', methods=['GET'])
def search_persons():
    """Search persons by name or email (case-insensitive substring match)"""
    try:
        query = request.args.get('q', '').strip()
        if not query:
            return jsonify({"error": "Query parameter 'q' is required"}), 400

        regex = re.compile(re.escape(query), re.IGNORECASE)
        results = list(mongo.db.persons.find({
            "$or": [
                {"name": {"$regex": regex}},
                {"email": {"$regex": regex}}
            ]
        }))

        for p in results:
            p['_id'] = str(p['_id'])

        return jsonify(results), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ---------------------------------------------------------------------------
# Bulk operations
# ---------------------------------------------------------------------------

@app.route('/person/bulk', methods=['POST'])
def bulk_add_persons():
    """Add multiple persons in one request. Body: [{ person_id, name, ... }, ...]"""
    try:
        data = request.get_json(silent=True)

        if not data or not isinstance(data, list):
            return jsonify({"error": "Request body must be a JSON array"}), 400

        if len(data) > 100:
            return jsonify({"error": "Maximum 100 persons per bulk request"}), 400

        # Validate each entry has person_id
        for i, entry in enumerate(data):
            if 'person_id' not in entry:
                return jsonify({"error": f"Entry {i} missing 'person_id'"}), 400

        result = mongo.db.persons.insert_many(data)

        return jsonify({
            "message": f"{len(result.inserted_ids)} persons added",
            "inserted_count": len(result.inserted_ids)
        }), 201

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/person/bulk', methods=['DELETE'])
def bulk_delete_persons():
    """Delete multiple persons by custom IDs. Body: { "ids": ["id1", "id2"] }"""
    try:
        data = request.get_json(silent=True)

        if not data or 'ids' not in data or not isinstance(data['ids'], list):
            return jsonify({"error": "Request body must contain 'ids' array"}), 400

        result = mongo.db.persons.delete_many({"person_id": {"$in": data['ids']}})

        return jsonify({
            "message": f"{result.deleted_count} persons deleted",
            "deleted_count": result.deleted_count
        }), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ---------------------------------------------------------------------------
# Single-person CRUD (existing)
# ---------------------------------------------------------------------------

@app.route('/person/<person_id>', methods=['POST'])
def add_person(person_id):
    """Add a new person with the given ID"""
    try:
        data = request.get_json(silent=True)

        if not data:
            logger.warning("Add person failed: No data provided", extra={'correlation_id': getattr(request, 'correlation_id', 'unknown')})
            return jsonify({"error": "No data provided"}), 400

        data['person_id'] = person_id
        result = mongo.db.persons.insert_one(data)

        logger.info(
            f"Person added successfully: {person_id}",
            extra={
                'correlation_id': getattr(request, 'correlation_id', 'unknown'),
                'person_id': person_id,
                'mongodb_id': str(result.inserted_id)
            }
        )

        return jsonify({
            "message": "Person added successfully",
            "id": str(result.inserted_id),
            "person_id": person_id
        }), 201

    except Exception as e:
        logger.error(
            f"Error adding person: {str(e)}",
            extra={
                'correlation_id': getattr(request, 'correlation_id', 'unknown'),
                'person_id': person_id,
                'error': str(e)
            },
            exc_info=True
        )
        return jsonify({"error": str(e)}), 500

@app.route('/person/<person_id>', methods=['GET'])
def get_person_by_custom_id(person_id):
    """Get a person by their custom person_id"""
    try:
        person = mongo.db.persons.find_one({"person_id": person_id})

        if person:
            person['_id'] = str(person['_id'])
            return jsonify(person), 200

        return jsonify({"error": "Person not found"}), 404

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/person/<person_id>', methods=['PUT'])
def update_person(person_id):
    """Update an existing person by their custom person_id"""
    try:
        data = request.get_json(silent=True)

        if not data:
            return jsonify({"error": "No data provided"}), 400

        result = mongo.db.persons.update_one(
            {"person_id": person_id},
            {"$set": data}
        )

        if result.matched_count == 0:
            return jsonify({"error": "Person not found"}), 404

        if result.modified_count == 0:
            return jsonify({
                "message": "No changes made",
                "person_id": person_id
            }), 200

        return jsonify({
            "message": "Person updated successfully",
            "person_id": person_id,
            "modified_count": result.modified_count
        }), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/person/<person_id>', methods=['DELETE'])
def delete_person(person_id):
    """Delete a person by their custom person_id"""
    try:
        result = mongo.db.persons.delete_one({"person_id": person_id})

        if result.deleted_count == 0:
            return jsonify({"error": "Person not found"}), 404

        return jsonify({
            "message": "Person deleted successfully",
            "person_id": person_id
        }), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    port = int(os.getenv("PORT", 5000))
    app.run(host='0.0.0.0', port=port, debug=False)
