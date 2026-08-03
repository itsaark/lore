# Lore

Lore is a privacy-first iPhone journal that turns voice notes into a durable local transcript archive and grounded biography entries.

## Repository layout

- `lore/`, `lore.xcodeproj`, `loreTests/`, `loreUITests/`: the iOS application and tests
- `backend/`: the request-ephemeral Lore Processing API, deployed independently to Vercel
- `web/`: reserved for the future public website and account portal; it should be a separate Vercel project when created
- `architecture.md`: system architecture and product boundaries
- `backend-delivery-plan.md`: requirements, acceptance criteria, and verification gates for remote processing
- `production-runbook.md`: Production-only deployment, verification, rotation, rollback, and incident procedures
- `inference-strategy.md`: local/remote model and routing strategy
- `vision.md`: product vision and near-term scope

Lore intentionally uses a monorepo while the product and team are small. The iOS app, API, and future web app remain separate deployable units, but keeping them in one repository makes contract changes, privacy reviews, and end-to-end pull requests easier to verify.

## Vercel projects

Create Vercel projects by importing this GitHub repository. Do not create a disconnected CLI-owned project.

### Processing API

- Git repository: this repository
- Production branch: `main`
- Root directory: `backend`
- Framework preset: Other
- Node.js version: 24.x
- Project name: `lore`

The API project owns only API domains and server-side secrets. See `backend/README.md` for environment variables and verification commands.

### Website (future)

Create `web/` as a Next.js application when the landing page work starts. Import the same GitHub repository into a second Vercel project with `web` as its root directory. That project should own the public website domain, authentication UI, and eventual account-management experience; it must not expose Fireworks, Groq, or other backend-only inference credentials.

The public website and API should remain separate Vercel projects even if both live in this repository. This preserves independent deployments, environment scopes, domains, observability, and rollback.

## Production remote processing

The iOS app contains a provider-neutral HTTPS client. Fireworks and Groq keys stay in Vercel and are never added to the Xcode project.

Debug and Simulator builds are deliberately local-only. They ignore backend URL and token environment variables, so there is no Preview credential or remote Debug mode to configure.

Release builds use the source-controlled Production API origin and App Attest-backed, short-lived installation sessions. If the origin changes, update `LoreRemoteServices.productionOrigin` in `RemoteProcessingRuntime.swift`. If App Attest is unsupported or enrollment fails, remote processing fails closed while local recording and local processing remain available.
