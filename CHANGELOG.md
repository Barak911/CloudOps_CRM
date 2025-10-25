# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Rate limiting for API endpoints
- API key authentication
- Request logging and monitoring
- Data validation improvements
- API versioning (v1, v2 prefixes)

## [2.0.0] - 2025-10-22

### Added
- **API Endpoints:**
  - `GET /person/<custom_id>` - Retrieve person by custom ID
  - `PUT /person/<custom_id>` - Update person by custom ID
  - `DELETE /person/<custom_id>` - Delete person by custom ID
- **Documentation:**
  - Comprehensive README for Application repository (368 lines)
  - Enhanced README for Infrastructure repository with troubleshooting
  - Git branching strategy documentation (BRANCHING_STRATEGY.md)
  - Semantic versioning documentation (VERSIONING.md)
  - Changelog file (CHANGELOG.md)
- **Testing:**
  - 6 new E2E tests for CRUD operations (total: 11 tests)
  - 3 new integration tests in GitHub Actions (total: 9 tests)
  - Update verification in tests
  - Deletion verification with 404 status check

### Changed
- Updated API version from 1.0.0 to 2.0.0 in `/` endpoint
- Enhanced MongoDB query patterns using `person_id` field
- Improved error handling with specific error messages
- Updated endpoint documentation in root response

### Technical
- Multi-stage Dockerfile optimization (builder + runtime stages)
- Production-ready Gunicorn server with 2 workers
- Health check endpoint for Kubernetes liveness/readiness probes
- Non-root user (appuser) for container security
- Optimized Docker layers with virtual environment isolation

### CI/CD
- Updated `initial-deploy.yml` workflow with new endpoint tests
- Updated `test_e2e.sh` script with comprehensive CRUD testing
- Enhanced deployment verification steps
- Added 404 status code validation for deleted resources

## [1.0.0] - 2025-10-21

### Added
- **API Endpoints:**
  - `GET /` - API information and available endpoints
  - `GET /health` - Health check endpoint
  - `GET /person` - Get all persons from database
  - `GET /person?id=<mongodb_id>` - Get specific person by MongoDB ObjectId
  - `POST /person/<custom_id>` - Add new person with custom ID
- **Application:**
  - Flask REST API with Python 3.11
  - MongoDB integration using PyMongo
  - Docker containerization
  - Environment-based configuration
- **CI/CD:**
  - GitHub Actions workflow for continuous integration
  - Automated testing with pytest
  - Docker build and push to Amazon ECR
  - Automated deployment to AWS EKS
  - End-to-end testing in Docker Compose environment
  - Initial deployment workflow for first-time setup
- **Testing:**
  - Unit tests with pytest
  - E2E tests covering basic CRUD operations (5 tests)
  - Health check testing
  - MongoDB integration testing
- **Infrastructure:**
  - AWS EKS cluster (Kubernetes 1.28)
  - VPC with public/private subnets across 2 AZs
  - Amazon ECR repository for Docker images
  - NAT Gateway for private subnet internet access
  - EBS CSI driver for persistent volumes
  - Security groups and IAM roles
- **Kubernetes:**
  - MongoDB StatefulSet with persistent storage
  - CRM application Deployment with 2 replicas
  - LoadBalancer Service for external access
  - ConfigMaps for environment variables
  - PersistentVolumeClaims for data persistence

### Technical
- Python 3.11 with Flask framework
- MongoDB 7.0 for data storage
- Docker multi-stage build
- Kubernetes manifests with best practices
- Terraform infrastructure-as-code
- GitHub OIDC authentication for AWS

### Documentation
- README files for all repositories
- API endpoint documentation
- Local development setup instructions
- Deployment guides
- Troubleshooting sections

## [0.1.0] - 2025-10-20 (Pre-release)

### Added
- Initial project setup
- Basic Flask application structure
- MongoDB connection setup
- Docker Compose for local development
- Basic pytest configuration

### Technical
- Python virtual environment
- Requirements.txt with initial dependencies
- Basic .gitignore file
- Project directory structure

---

## Version History Summary

| Version | Date | Type | Description |
|---------|------|------|-------------|
| **2.0.0** | 2025-10-22 | Major | Full CRUD operations, comprehensive docs |
| **1.0.0** | 2025-10-21 | Major | Initial stable release with basic API |
| **0.1.0** | 2025-10-20 | Minor | Pre-release, development setup |

---

## Migration Guides

### Upgrading from 1.0.0 to 2.0.0

**No breaking changes** - Version 2.0.0 is fully backward compatible with 1.0.0.

**New features available:**
1. You can now retrieve persons by custom ID:
   ```bash
   # Before (v1.0.0) - only MongoDB ObjectId
   GET /person?id=67fc8c0c18cb3fe85318dd6d6

   # Now (v2.0.0) - also custom ID
   GET /person/123
   ```

2. You can now update persons:
   ```bash
   PUT /person/123
   Content-Type: application/json
   {"name": "Updated Name", "email": "new@example.com"}
   ```

3. You can now delete persons:
   ```bash
   DELETE /person/123
   ```

**No action required** - All existing endpoints continue to work as before.

---

## Links

- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Repository](https://github.com/Barak911/CloudOps_CRM)
- [Issues](https://github.com/Barak911/CloudOps_CRM/issues)
- [Releases](https://github.com/Barak911/CloudOps_CRM/releases)
