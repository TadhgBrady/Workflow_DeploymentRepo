# Demo Release Workflow

Use this when you want production to stay on an old version while staging shows a newer feature, then promote that tested staging version into production during a demo.

## Version Model

The deployment pipeline pins all services from a single `IMAGE_VERSION` value. That value is the short source commit SHA produced by the development repo. The image tags must already exist, for example:

```text
bencev04/4th-year-proj-tadgh-bence:auth-service-097716b7
bencev04/4th-year-proj-tadgh-bence:frontend-097716b7
```

The CD pipeline verifies those tags before it deploys.

## One-Time Setup

Create a pipeline trigger token in `yr4-projectdeploymentrepo`:

```text
Settings > CI/CD > Pipeline trigger tokens
```

Then set it only in your local shell:

```powershell
$env:DEPLOYMENT_TRIGGER_TOKEN = "<deployment repo pipeline trigger token>"
```

Do not commit this token.

## Seed Production With The Old Version

If production is already on the old version, skip this step.

Trigger a full release for the old image version:

```powershell
.\local\trigger-demo-release.ps1 -ImageVersion <OLD_SHA> -PipelineMode full-release
```

Wait for staging tests to pass, then run the manual `promote-to-production` job in that pipeline. When production validation passes, production is pinned to `<OLD_SHA>`.

## Stage The New Version And Pause

Trigger a full release for the new image version:

```powershell
.\local\trigger-demo-release.ps1 -ImageVersion <NEW_SHA> -PipelineMode full-release
```

Let the pipeline deploy and test staging. Stop when it reaches the manual `promote-to-production` job. At that point:

- staging is running `<NEW_SHA>`
- production is still running `<OLD_SHA>`
- the tested production promotion is waiting behind one manual job

During the demo, run the manual `promote-to-production` job. The production deploy uses the exact same `<NEW_SHA>` that passed staging.

## Repeat The Demo

To reset the story, run the old version through `full-release` and promote it to production again, then run the new version through `full-release` and leave it paused at `promote-to-production`.

For a cheaper rehearsal that does not touch production, use:

```powershell
.\local\trigger-demo-release.ps1 -ImageVersion <NEW_SHA> -PipelineMode staging-only
```

`staging-only` is good for testing the new feature in staging, but it does not create the production promotion gate. Use `full-release` for the actual demo flow.
