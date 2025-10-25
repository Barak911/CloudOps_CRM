# Semantic Versioning and Release Strategy

This project follows [Semantic Versioning 2.0.0](https://semver.org/) for version management and release tagging.

## Version Format

```
MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]
```

### Components

- **MAJOR**: Incompatible API changes (breaking changes)
- **MINOR**: New functionality in a backward-compatible manner
- **PATCH**: Backward-compatible bug fixes
- **PRERELEASE** (optional): Pre-release version (alpha, beta, rc)
- **BUILD** (optional): Build metadata

### Examples
- `1.0.0` - Initial stable release
- `2.0.0` - Major version with breaking changes
- `2.1.0` - Minor version with new features
- `2.1.1` - Patch version with bug fixes
- `3.0.0-alpha.1` - Pre-release alpha version
- `3.0.0-beta.2` - Pre-release beta version
- `3.0.0-rc.1` - Release candidate
- `2.1.1+20250122` - Build with metadata

## Version Increment Rules

### MAJOR Version (X.0.0)

Increment when you make **incompatible API changes**:

- ❌ **Breaking Changes**:
  - Removing or renaming API endpoints
  - Changing request/response formats
  - Removing fields from database models
  - Changing authentication mechanisms
  - Modifying configuration file structure

**Example:**
```
Before: GET /person/{id}
After:  GET /api/v2/persons/{id}  ← Breaking change
Version: 1.5.3 → 2.0.0
```

### MINOR Version (x.Y.0)

Increment when you add **new functionality** in a backward-compatible manner:

- ✅ **New Features**:
  - Adding new API endpoints
  - Adding optional fields to requests
  - Adding new fields to responses
  - Adding new configuration options
  - Adding new functionality

**Example:**
```
Before: GET /person, POST /person
After:  GET /person, POST /person, PUT /person, DELETE /person
Version: 2.0.0 → 2.1.0
```

### PATCH Version (x.y.Z)

Increment when you make **backward-compatible bug fixes**:

- 🔧 **Bug Fixes**:
  - Fixing incorrect behavior
  - Fixing security vulnerabilities
  - Improving error handling
  - Performance improvements
  - Dependency updates

**Example:**
```
Before: MongoDB connection times out
After:  Added connection retry logic
Version: 2.1.0 → 2.1.1
```

## Current Version History

### v2.0.0 (2025-10-22)
**Major Release - Full CRUD Operations**

**Added:**
- ✨ GET `/person/<custom_id>` - Get person by custom ID
- ✨ PUT `/person/<custom_id>` - Update person by custom ID
- ✨ DELETE `/person/<custom_id>` - Delete person by custom ID
- 📚 Comprehensive documentation for all repositories
- 🧪 11 E2E tests covering all CRUD operations
- 🧪 9 integration tests in CI/CD pipeline

**Changed:**
- Updated API version to 2.0.0
- Enhanced error handling for all endpoints
- Improved MongoDB query patterns

**Technical:**
- Multi-stage Dockerfile for optimized builds
- Gunicorn production server with 2 workers
- Health check endpoint for Kubernetes
- LoadBalancer service for external access

### v1.0.0 (2025-10-21)
**Initial Stable Release**

**Added:**
- ✨ GET `/` - API information endpoint
- ✨ GET `/health` - Health check endpoint
- ✨ GET `/person` - Get all persons
- ✨ GET `/person?id=<mongodb_id>` - Get person by MongoDB ID
- ✨ POST `/person/<custom_id>` - Create person with custom ID
- 🚀 CI/CD pipeline with GitHub Actions
- 🐳 Docker containerization
- ☸️ Kubernetes deployment on AWS EKS
- 🗄️ MongoDB with persistent storage
- 🔄 Automated deployment workflow

**Infrastructure:**
- AWS EKS cluster (Kubernetes 1.28)
- Amazon ECR for container registry
- VPC with public/private subnets
- NAT Gateway for private subnet internet access
- EBS CSI driver for persistent volumes

## Tagging Strategy

### Creating Version Tags

Tags should be created when:
- ✅ All tests pass in CI/CD
- ✅ Code is merged to `main` branch
- ✅ Release notes are documented
- ✅ Deployment is successful

### Tag Format

```bash
# Annotated tags (preferred)
git tag -a v2.1.0 -m "Release v2.1.0: Add caching layer"

# Lightweight tags (not recommended for releases)
git tag v2.1.0
```

### Tagging Workflow

```bash
# 1. Ensure you're on main and up to date
git checkout main
git pull origin main

# 2. Verify version in code
grep "version" app.py  # Should match the tag you're creating

# 3. Create annotated tag
git tag -a v2.1.0 -m "Release v2.1.0: Add rate limiting

Features:
- Add rate limiting middleware
- Configure Redis for rate limit storage
- Add rate limit documentation

Bug Fixes:
- Fix MongoDB connection pool issues
- Handle null person_id gracefully

Technical:
- Update dependencies to latest versions
- Improve error logging"

# 4. Push tag to remote
git push origin v2.1.0

# 5. Create GitHub Release
# Go to GitHub → Releases → Create new release
# - Tag: v2.1.0
# - Title: "Release v2.1.0 - Rate Limiting"
# - Description: Same as tag annotation
# - Attach artifacts if needed
```

### Viewing Tags

```bash
# List all tags
git tag

# List tags with version pattern
git tag -l "v2.*"

# Show tag details
git show v2.1.0

# Checkout specific version
git checkout v2.1.0
```

### Deleting Tags (use carefully!)

```bash
# Delete local tag
git tag -d v2.1.0

# Delete remote tag
git push origin --delete v2.1.0
```

## Pre-release Versions

For testing before stable release:

### Alpha Versions
- **Purpose**: Internal testing, unstable
- **Format**: `v3.0.0-alpha.1`, `v3.0.0-alpha.2`
- **When**: Early development, not feature-complete

```bash
git tag -a v3.0.0-alpha.1 -m "Alpha release for testing"
```

### Beta Versions
- **Purpose**: External testing, feature-complete but may have bugs
- **Format**: `v3.0.0-beta.1`, `v3.0.0-beta.2`
- **When**: Feature-complete, needs broader testing

```bash
git tag -a v3.0.0-beta.1 -m "Beta release for user testing"
```

### Release Candidates
- **Purpose**: Final testing before stable release
- **Format**: `v3.0.0-rc.1`, `v3.0.0-rc.2`
- **When**: No known critical bugs, preparing for release

```bash
git tag -a v3.0.0-rc.1 -m "Release candidate 1"
```

## Version Synchronization

Version must be updated in multiple places:

### 1. Application Code
```python
# app.py
@app.route('/', methods=['GET'])
def root():
    return jsonify({
        "service": "CRM REST API",
        "version": "2.1.0",  # ← Update here
        "endpoints": {...}
    }), 200
```

### 2. Docker Image Tag
```yaml
# .github/workflows/cicd.yml
- name: Tag image
  run: |
    docker tag crm-app:latest $ECR_REGISTRY/crm-app:2.1.0  # ← Update here
    docker tag crm-app:latest $ECR_REGISTRY/crm-app:latest
```

### 3. Git Tag
```bash
git tag -a v2.1.0 -m "Release v2.1.0"  # ← Create tag
```

### 4. Documentation
```markdown
# README.md
## Current Version: v2.1.0  # ← Update here
```

## Release Checklist

Before creating a new release:

- [ ] All tests pass (`pytest test_app.py -v`)
- [ ] E2E tests pass (`./test_e2e.sh`)
- [ ] Code merged to `main` branch
- [ ] Version updated in `app.py`
- [ ] CHANGELOG.md updated with changes
- [ ] Documentation updated (if needed)
- [ ] Security scan completed (no critical issues)
- [ ] Pull request approved and merged
- [ ] CI/CD pipeline successful
- [ ] Deployment to EKS successful
- [ ] Integration tests pass in production
- [ ] Create Git tag
- [ ] Push tag to GitHub
- [ ] Create GitHub Release with notes
- [ ] Notify team of new release

## Changelog Format

Maintain a `CHANGELOG.md` file following [Keep a Changelog](https://keepachangelog.com/):

```markdown
# Changelog

All notable changes to this project will be documented in this file.

## [2.1.0] - 2025-10-25

### Added
- Rate limiting middleware for API endpoints
- Redis integration for rate limit storage
- Rate limit configuration in environment variables

### Changed
- Improved MongoDB connection handling with retry logic
- Updated Flask to version 3.0.0

### Fixed
- Fixed null person_id handling in GET endpoint
- Fixed MongoDB connection pool exhaustion issue

### Security
- Updated dependencies to patch CVE-2024-XXXXX

## [2.0.0] - 2025-10-22

### Added
- GET /person/<custom_id> endpoint
- PUT /person/<custom_id> endpoint
- DELETE /person/<custom_id> endpoint
- Comprehensive documentation for all repositories

### Changed
- API version bumped to 2.0.0
- Enhanced error handling

## [1.0.0] - 2025-10-21

### Added
- Initial stable release with basic CRUD operations
- CI/CD pipeline with GitHub Actions
- Kubernetes deployment on AWS EKS
```

## Version Automation (Future Enhancement)

Consider automating versioning with tools:

### Option 1: Python Versioning Tools
```bash
# Install bump2version
pip install bump2version

# Bump patch version
bump2version patch

# Bump minor version
bump2version minor

# Bump major version
bump2version major
```

### Option 2: GitHub Actions Automation
Create a workflow to auto-tag releases based on commit messages:

```yaml
name: Auto Tag Release

on:
  push:
    branches: [main]

jobs:
  tag:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Determine version bump
        id: version
        run: |
          # Parse commit messages for version bump
          # feat: -> minor
          # fix: -> patch
          # BREAKING CHANGE: -> major

      - name: Create tag
        run: |
          git tag -a v${{ steps.version.outputs.version }} -m "Auto-tagged release"
          git push origin v${{ steps.version.outputs.version }}
```

## Docker Image Tagging Strategy

### Tags Applied to Every Build

1. **Semantic Version**: `v2.1.0`
2. **Latest**: `latest` (only for main branch)
3. **Commit SHA**: `sha-abc123f` (for traceability)
4. **Branch**: `main`, `develop` (for environment-specific tags)

```bash
# Example tagging in CI/CD
docker tag crm-app:build $ECR_REGISTRY/crm-app:v2.1.0
docker tag crm-app:build $ECR_REGISTRY/crm-app:latest
docker tag crm-app:build $ECR_REGISTRY/crm-app:sha-abc123f
docker tag crm-app:build $ECR_REGISTRY/crm-app:main
```

## Best Practices

### DO ✅
- Use annotated tags (`git tag -a`)
- Follow semantic versioning strictly
- Update CHANGELOG.md with every release
- Create GitHub Releases with detailed notes
- Tag only after successful deployment
- Keep version synchronized across all files
- Document breaking changes clearly

### DON'T ❌
- Don't skip version numbers
- Don't reuse or move existing tags
- Don't delete tags from remote unless critical
- Don't tag before testing is complete
- Don't forget to update version in code
- Don't create tags on feature branches (only on main)

## Troubleshooting

### Version Mismatch
If version in code doesn't match git tag:
```bash
# Update version in app.py
# Create new tag with correct version
git tag -a v2.1.1 -m "Fix version mismatch"
```

### Tag Already Exists
```bash
# Delete and recreate (use with caution!)
git tag -d v2.1.0
git tag -a v2.1.0 -m "Release v2.1.0"
git push origin v2.1.0 --force
```

### Rollback to Previous Version
```bash
# Checkout previous version
git checkout v2.0.0

# Deploy previous version
kubectl set image deployment/crm-app crm-app=$ECR_REGISTRY/crm-app:v2.0.0
```

## Related Documentation

- [Semantic Versioning 2.0.0](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Git Tagging Documentation](https://git-scm.com/book/en/v2/Git-Basics-Tagging)

## Questions?

For questions about versioning:
1. Check this document
2. Review [semver.org](https://semver.org/)
3. Ask in team chat
4. Open a GitHub Discussion
