# CRM Application

A simple Python Flask REST API for managing customer relationship data, deployed on AWS EKS with a complete CI/CD pipeline.

## Architecture

This is part of a 2-tier architecture:
- **Application Tier**: Python Flask REST API (this repository)
- **Database Tier**: MongoDB (deployed via Kubernetes manifests)

## Related Repositories

- **Infrastructure**: [Terraform files for EKS cluster provisioning]
- **Cluster Resources**: [CloudOps_CRM_cluster](https://github.com/Barak911/CloudOps_CRM_cluster) - Kubernetes manifests

## Features

### Current REST API Endpoints

- `GET /` - API information and available endpoints
- `GET /health` - Health check endpoint
- `GET /person` - Get all persons from database
- `GET /person?id=<mongodb_id>` - Get specific person by MongoDB ObjectId
- `POST /person/<custom_id>` - Add new person with custom ID

### Upcoming Endpoints (Stage 2)

- `PUT /person/<id>` - Update existing person
- `DELETE /person/<id>` - Delete person from database

## Technology Stack

- **Language**: Python 3.11
- **Framework**: Flask
- **Database**: MongoDB (via PyMongo)
- **Containerization**: Docker
- **CI/CD**: GitHub Actions
- **Container Registry**: Amazon ECR
- **Orchestration**: Kubernetes (AWS EKS)

## Prerequisites

- Python 3.11+
- Docker & Docker Compose
- AWS Account with ECR and EKS access
- kubectl configured for EKS cluster

## Local Development

### 1. Clone the repository

```bash
git clone https://github.com/Barak911/CloudOps_CRM.git
cd CloudOps_CRM
```

### 2. Create virtual environment

```bash
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

### 3. Install dependencies

```bash
pip install -r requirements.txt
```

### 4. Run with Docker Compose

```bash
docker compose up -d
```

The API will be available at `http://localhost:5001`

### 5. Test the API

```bash
# Health check
curl http://localhost:5001/health

# Get all persons
curl http://localhost:5001/person

# Add a person
curl -X POST http://localhost:5001/person/123 \
  -H "Content-Type: application/json" \
  -d '{"name":"John Doe","email":"john@example.com","phone":"555-1234"}'

# Get person by ID (use MongoDB _id from previous response)
curl "http://localhost:5001/person?id=<mongodb_id>"
```

## Docker

### Build Docker image

```bash
docker build -t crm-app:latest .
```

### Run with Docker

```bash
docker run -p 5001:5000 \
  -e MONGO_URI="mongodb://host.docker.internal:27017/crm_db" \
  crm-app:latest
```

## Testing

### Unit Tests

```bash
pytest test_app.py -v
```

### E2E Tests

```bash
# Start test environment
docker compose -f docker-compose.test.yml up -d

# Run E2E tests
./test_e2e.sh

# Clean up
docker compose -f docker-compose.test.yml down -v
```

## CI/CD Pipeline

### Main Branch Workflow (`cicd.yml`)

Triggered on push to `main` branch:

1. **Build** - Install dependencies and build application
2. **Unit Tests** - Run pytest tests
3. **Package** - Build Docker image
4. **E2E Tests** - Deploy test environment and run integration tests
5. **Publish** - Push image to Amazon ECR
6. **Deploy** - Update running deployment in EKS cluster (if exists)

### Initial Deployment Workflow (`initial-deploy.yml`)

Manual workflow for first-time deployment:

1. **Build and Push to ECR** - Build image and push to registry
2. **Deploy MongoDB** - Deploy MongoDB StatefulSet with persistent storage
3. **Deploy CRM Application** - Deploy app with 2 replicas and LoadBalancer
4. **Integration Tests** - Comprehensive API testing (6 test scenarios)
5. **Deployment Report** - Generate summary with URLs and test commands

### Required GitHub Secrets

- `AWS_ROLE_ARN` - IAM role ARN for GitHub Actions OIDC authentication

## Deployment

### Prerequisites

1. EKS cluster must be provisioned (via Infrastructure repository)
2. ECR repository must exist: `crm-app`
3. GitHub Actions role must have:
   - ECR push permissions
   - EKS describe and access permissions
   - EKS access entry configured

### Initial Deployment

Use the GitHub Actions "Initial Deployment" workflow:

1. Go to Actions → Initial Deployment
2. Click "Run workflow"
3. Select branch: `main`
4. Optionally override AWS region and cluster name
5. Click "Run workflow"

The workflow will:
- Build and push Docker image
- Deploy MongoDB
- Deploy application with LoadBalancer
- Run integration tests
- Provide LoadBalancer URL for access

### Continuous Deployment

After initial deployment, pushes to `main` branch automatically:
- Run tests
- Build new image
- Push to ECR
- Update deployment with new image

## Environment Variables

### Application

- `MONGO_URI` - MongoDB connection string (default: `mongodb://localhost:27017/crm_db`)
- `PORT` - Application port (default: `5000`)

### CI/CD

- `AWS_REGION` - AWS region for ECR and EKS (default: `us-east-1`)
- `ECR_REPOSITORY` - ECR repository name (default: `crm-app`)
- `EKS_CLUSTER_NAME` - EKS cluster name (default: `develeap-eks-cluster`)

## Project Structure

```
.
├── .github/
│   └── workflows/
│       ├── cicd.yml              # Main CI/CD pipeline
│       └── initial-deploy.yml    # Initial deployment workflow
├── app.py                        # Main Flask application
├── test_app.py                   # Unit tests
├── test_e2e.sh                   # E2E test script
├── requirements.txt              # Python dependencies
├── Dockerfile                    # Docker image definition
├── docker-compose.yml            # Local development setup
├── docker-compose.test.yml       # E2E testing environment
└── README.md                     # This file
```

## API Documentation

### GET /

Returns API information and available endpoints.

**Response:**
```json
{
  "service": "CRM REST API",
  "version": "1.0.0",
  "endpoints": {
    "GET /health": "Health check",
    "GET /person": "Get all persons",
    "GET /person?id=<id>": "Get person by ID",
    "POST /person/<id>": "Add person with ID"
  }
}
```

### GET /health

Health check endpoint.

**Response:**
```json
{
  "status": "healthy",
  "service": "CRM API"
}
```

### GET /person

Get all persons from the database.

**Response:**
```json
[
  {
    "_id": "67fc8c0c18cb3fe85318dd6d6",
    "name": "John Doe",
    "email": "john@example.com",
    "phone": "555-1234",
    "person_id": "123"
  }
]
```

### GET /person?id=<mongodb_id>

Get a specific person by their MongoDB ObjectId.

**Parameters:**
- `id` (query) - MongoDB ObjectId (24-character hex string)

**Response:**
```json
{
  "_id": "67fc8c0c18cb3fe85318dd6d6",
  "name": "John Doe",
  "email": "john@example.com",
  "phone": "555-1234",
  "person_id": "123"
}
```

### POST /person/<custom_id>

Add a new person to the database.

**Parameters:**
- `custom_id` (path) - Custom identifier for the person

**Request Body:**
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "phone": "555-1234"
}
```

**Response:**
```json
{
  "message": "Person added successfully",
  "id": "67fc8c0c18cb3fe85318dd6d6",
  "person_id": "123"
}
```

## Troubleshooting

### Port 5000 already in use (macOS)

macOS uses port 5000 for AirPlay Receiver. The docker-compose files use port 5001 externally:

```bash
# Access via port 5001
curl http://localhost:5001/health
```

### MongoDB connection issues

Ensure MongoDB is running and accessible:

```bash
# Check MongoDB in Docker
docker ps | grep mongo

# Check MongoDB in Kubernetes
kubectl get pods -l app=mongodb
kubectl logs -l app=mongodb
```

### ECR authentication

If Docker push fails:

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
```

## Contributing

1. Create a feature branch: `git checkout -b feature/my-feature`
2. Make your changes
3. Run tests: `pytest test_app.py -v`
4. Commit: `git commit -am 'Add new feature'`
5. Push: `git push origin feature/my-feature`
6. Create Pull Request

## License

This project is part of a DevOps portfolio demonstrating CI/CD best practices.

## Contact

For questions or issues, please open a GitHub issue in this repository.
