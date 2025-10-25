# Git Branching Strategy

This project follows a **Feature Branch Workflow** with **Trunk-Based Development** principles for efficient CI/CD and collaboration.

## Branch Structure

### Main Branches

#### `main`
- **Purpose**: Production-ready code
- **Protection**: Protected branch, requires pull request reviews
- **CI/CD**: Automatic deployment to EKS on push
- **Naming**: `main`
- **Lifetime**: Permanent

### Supporting Branches

#### Feature Branches
- **Purpose**: Develop new features or enhancements
- **Branch from**: `main`
- **Merge into**: `main` (via Pull Request)
- **Naming Convention**: `feature/<issue-number>-<short-description>`
  - Examples:
    - `feature/123-add-user-authentication`
    - `feature/456-improve-error-handling`
- **Lifetime**: Temporary (deleted after merge)

#### Bugfix Branches
- **Purpose**: Fix bugs found in production or development
- **Branch from**: `main`
- **Merge into**: `main` (via Pull Request)
- **Naming Convention**: `bugfix/<issue-number>-<short-description>`
  - Examples:
    - `bugfix/789-fix-mongodb-connection`
    - `bugfix/234-handle-null-person-id`
- **Lifetime**: Temporary (deleted after merge)

#### Hotfix Branches
- **Purpose**: Urgent fixes for production issues
- **Branch from**: `main`
- **Merge into**: `main` (via Pull Request, can be fast-tracked)
- **Naming Convention**: `hotfix/<issue-number>-<short-description>`
  - Examples:
    - `hotfix/999-critical-security-patch`
    - `hotfix/888-fix-loadbalancer-timeout`
- **Lifetime**: Temporary (deleted after merge)

## Workflow

### 1. Creating a Feature Branch

```bash
# Update main branch
git checkout main
git pull origin main

# Create feature branch
git checkout -b feature/123-add-caching

# Work on your feature
git add .
git commit -m "feat: Add Redis caching layer"

# Push to remote
git push -u origin feature/123-add-caching
```

### 2. Working on a Feature

```bash
# Make changes
git add .
git commit -m "feat: Implement cache invalidation"

# Keep branch updated with main (recommended for long-lived branches)
git checkout main
git pull origin main
git checkout feature/123-add-caching
git rebase main

# Push changes
git push origin feature/123-add-caching
```

### 3. Creating a Pull Request

1. Push your feature branch to GitHub
2. Go to GitHub repository → Pull Requests → New Pull Request
3. Select `main` as base branch and your feature branch as compare branch
4. Fill in PR template:
   - **Title**: Clear, concise description (e.g., "Add Redis caching layer")
   - **Description**: What changed, why, and how to test
   - **Link**: Related issue number
5. Request review from team members
6. Wait for CI/CD checks to pass

### 4. Merging a Pull Request

**Requirements before merge:**
- ✅ All CI/CD checks passing (unit tests, E2E tests, build)
- ✅ Code review approved
- ✅ No merge conflicts with `main`
- ✅ Feature branch is up to date with `main`

**Merge Strategy:**
- **Squash and Merge**: Preferred for feature branches (keeps history clean)
- **Merge Commit**: For hotfixes (preserves context)

**After merge:**
```bash
# Delete local branch
git checkout main
git pull origin main
git branch -d feature/123-add-caching

# Remote branch is auto-deleted by GitHub after merge
```

## Commit Message Convention

We follow **Conventional Commits** specification:

### Format
```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, no code change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks (dependencies, build config)
- `ci`: CI/CD changes

### Examples
```bash
# Feature
git commit -m "feat(api): Add GET /person/<id> endpoint"

# Bug fix
git commit -m "fix(database): Handle MongoDB connection timeout"

# Documentation
git commit -m "docs: Update API documentation with new endpoints"

# Test
git commit -m "test: Add E2E tests for CRUD operations"

# CI/CD
git commit -m "ci: Update GitHub Actions workflow for deployment"
```

## CI/CD Integration

### Automated Workflows

#### On Push to Feature Branch
- ✅ Run unit tests (`pytest`)
- ✅ Run linting checks
- ✅ Build Docker image (no push)
- ✅ Run E2E tests in Docker Compose

#### On Pull Request to `main`
- ✅ Run all checks from feature branch
- ✅ Build and push Docker image to ECR (with PR tag)
- ✅ Post deployment preview link (if configured)
- ✅ Run security scans

#### On Merge to `main`
- ✅ Run full test suite
- ✅ Build and push Docker image to ECR (with `latest` tag)
- ✅ Deploy to EKS cluster (update existing deployment)
- ✅ Run integration tests against live deployment
- ✅ Create Git tag (if semantic version bump)

## Branch Protection Rules

### `main` Branch
- ✅ Require pull request before merging
- ✅ Require status checks to pass before merging
  - Unit tests
  - E2E tests
  - Docker build
- ✅ Require branches to be up to date before merging
- ✅ Require conversation resolution before merging
- ✅ Do not allow bypassing the above settings
- ❌ Do not allow force pushes
- ❌ Do not allow deletions

## Best Practices

### Keep Branches Short-Lived
- ✅ Feature branches should live for **days, not weeks**
- ✅ Merge frequently to avoid large conflicts
- ✅ Use feature flags for incomplete features

### Rebase vs Merge
- ✅ Use **rebase** when updating feature branch from main (keeps history linear)
- ✅ Use **squash and merge** when merging PR to main (keeps main history clean)
- ❌ Avoid merge commits in feature branches

### Pull Request Size
- ✅ Keep PRs small (< 400 lines of code changed)
- ✅ Split large features into multiple PRs
- ✅ Each PR should have a single purpose

### Code Review
- ✅ Review code within 24 hours
- ✅ Provide constructive feedback
- ✅ Test the changes locally if needed
- ✅ Approve only when confident

## Example Workflow: Adding a New Feature

```bash
# 1. Start from main
git checkout main
git pull origin main

# 2. Create feature branch
git checkout -b feature/567-add-rate-limiting

# 3. Implement feature
echo "Rate limiting implementation" > rate_limit.py
git add rate_limit.py
git commit -m "feat(api): Add rate limiting middleware"

# 4. Add tests
echo "Rate limiting tests" > test_rate_limit.py
git add test_rate_limit.py
git commit -m "test(api): Add rate limiting tests"

# 5. Update documentation
echo "Rate limiting docs" >> README.md
git add README.md
git commit -m "docs: Document rate limiting feature"

# 6. Push to remote
git push -u origin feature/567-add-rate-limiting

# 7. Create Pull Request on GitHub
# - Title: "Add rate limiting to API endpoints"
# - Description: "Implements rate limiting using Flask-Limiter..."
# - Link to issue: #567

# 8. After PR approval and merge
git checkout main
git pull origin main
git branch -d feature/567-add-rate-limiting
```

## Hotfix Emergency Workflow

For critical production issues:

```bash
# 1. Create hotfix branch from main
git checkout main
git pull origin main
git checkout -b hotfix/999-fix-critical-bug

# 2. Fix the issue
git add .
git commit -m "hotfix: Fix critical security vulnerability"

# 3. Push and create PR
git push -u origin hotfix/999-fix-critical-bug

# 4. Fast-track PR review
# - Get immediate review
# - Merge as soon as CI passes
# - Deploy immediately

# 5. Clean up
git checkout main
git pull origin main
git branch -d hotfix/999-fix-critical-bug
```

## Troubleshooting

### Merge Conflicts

```bash
# Update your branch with latest main
git checkout main
git pull origin main
git checkout feature/123-add-caching
git rebase main

# If conflicts occur
# 1. Resolve conflicts in your editor
# 2. Mark as resolved
git add <conflicted-files>
git rebase --continue

# Force push (safe because it's your feature branch)
git push --force-with-lease origin feature/123-add-caching
```

### Undo Last Commit (before push)

```bash
# Keep changes, undo commit
git reset --soft HEAD~1

# Discard changes, undo commit
git reset --hard HEAD~1
```

### Recover Deleted Branch

```bash
# Find commit hash
git reflog

# Recreate branch
git checkout -b feature/123-add-caching <commit-hash>
```

## Related Documentation

- [Conventional Commits](https://www.conventionalcommits.org/)
- [GitHub Flow](https://guides.github.com/introduction/flow/)
- [Trunk-Based Development](https://trunkbaseddevelopment.com/)

## Questions?

If you have questions about the branching strategy, please:
1. Check this document first
2. Ask in the team chat
3. Open a GitHub Discussion for clarification
