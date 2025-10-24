from flask import Flask, request, jsonify
from flask_pymongo import PyMongo
from bson.objectid import ObjectId
import os

app = Flask(__name__)

# MongoDB configuration
app.config["MONGO_URI"] = os.getenv("MONGO_URI", "mongodb://localhost:27017/crm_db")
mongo = PyMongo(app)

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({"status": "healthy", "service": "CRM API"}), 200

@app.route('/person', methods=['GET'])
def get_persons():
    """Get all persons or filter by ID query parameter"""
    try:
        person_id = request.args.get('id')

        if person_id:
            # Get specific person by ID
            person = mongo.db.persons.find_one({"_id": ObjectId(person_id)})
            if person:
                person['_id'] = str(person['_id'])
                return jsonify(person), 200
            return jsonify({"error": "Person not found"}), 404
        else:
            # Get all persons
            persons = list(mongo.db.persons.find())
            for person in persons:
                person['_id'] = str(person['_id'])
            return jsonify(persons), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/person/<person_id>', methods=['POST'])
def add_person(person_id):
    """Add a new person with the given ID"""
    try:
        data = request.get_json()

        if not data:
            return jsonify({"error": "No data provided"}), 400

        # Add the person_id from URL to the document
        data['person_id'] = person_id

        # Insert into MongoDB
        result = mongo.db.persons.insert_one(data)

        return jsonify({
            "message": "Person added successfully",
            "id": str(result.inserted_id),
            "person_id": person_id
        }), 201

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/', methods=['GET'])
def root():
    """Root endpoint with API information"""
    return jsonify({
        "service": "CRM REST API",
        "version": "1.0.0",
        "endpoints": {
            "GET /health": "Health check",
            "GET /person": "Get all persons",
            "GET /person?id=<id>": "Get person by ID",
            "POST /person/<id>": "Add person with ID"
        }
    }), 200

if __name__ == '__main__':
    port = int(os.getenv("PORT", 5000))
    app.run(host='0.0.0.0', port=port, debug=False)
