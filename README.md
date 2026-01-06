# slack_deployer
A Sinatra Service to trigger github actions for deployment

# Slack → GitHub Actions → Capistrano Deployment Bridge

This project provides a secure and auditable way to trigger **Capistrano deployments** directly from **Slack** using a slash command.  
It acts as a small gateway service (`slack_deployer`) that validates Slack requests and dispatches a GitHub Actions workflow, which performs the actual deployment.

---

## Overview

The deployment flow is:

```
Slack (/deploy)
↓
slack_deployer (Sinatra)
↓
GitHub Actions (workflow_dispatch)
↓
Capistrano (deploy to target environment)
```

This approach keeps:
- Slack free of SSH access
- All deployment logic inside CI/CD
- A clear audit trail in GitHub Actions

---

## Features

- Slash-command–based deployments from Slack
- HMAC verification using Slack signing secret
- Workspace allow-listing
- Input validation for stages and branches
- Asynchronous GitHub Actions dispatch (no Slack timeouts)
- Reuses existing Capistrano configuration
- Works with Rack 3 / Sinatra 4

---

## Command Usage

In Slack:

```
/deploy <stage> <branch>
```

for example:
```
/deploy staging_two feature/TT-127
```

---

## Architecture
```
┌────────────┐
│ Slack      │
│ /deploy    │
└─────┬──────┘
      │ HTTPS (signed request)
      ▼
┌────────────────────────┐
│ slack_deployer         │
│ (Sinatra app)          │
│ - Verifies Slack       │
│ - Validates input      │
│ - Triggers CI          │
└─────┬──────────────────┘
      │ GitHub API
      ▼
┌────────────────────────┐
│ GitHub Actions         │
│ - Runs Capistrano      │
│ - Deploys app          │
│ - Notifies Slack       │
└────────────────────────┘
```

### Setup
```
% bundle install
% bundle exec rackup -p 4567
```
