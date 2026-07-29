# HMCTS Dev Test Backend

A Spring Boot service for tracking caseworker cases, wired up to PostgreSQL, packaged as a
container, built and scanned by GitHub Actions, and deployed to Azure Container Apps with
Terraform.

 — database wiring and containerisation → [`application.yaml`](src/main/resources/application.yaml), [`Dockerfile`](Dockerfile), [`docker-compose.yml`](docker-compose.yml)
 — CI/CD pipeline → [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
 — infrastructure as code → [`infrastructure/`](infrastructure)

This is a README about getting it running on your machine and the reasoning behind the design decisions, that's further down under

## What you'll need

You don't need all of this at once. Docker on its own is enough to run the whole stack, since the
image builds the jar inside itself.

| Tool | What it's for |
| --- | --- |
| Docker Desktop | Running the app and database together |
| JDK 21 | Building and testing outside a container |
| Terraform 1.9+ | Checking the infrastructure code |
| Trivy | Scanning the image before CI does |

On Windows, use Git Bash or WSL rather than PowerShell the commands below assume a POSIX shell.

---

## 1. Run it with Docker Compose

This is the quickest path to a working service. Copy the example environment file, set a password,
and bring the stack up:

```bash
cp .env.example .env
```

Open `.env` and change `DB_PASSWORD` to something of your own. The format is plain `KEY=value` with
no spaces or quotes. it's not YAML, and a stray colon will leave the variable unset. Then:

```bash
docker compose up --build
```

The first build takes a few minutes because Gradle resolves the whole dependency tree inside the
builder stage. After that, layer caching makes it much quicker.

Once it's up, check both containers are healthy in another terminal:

```bash
docker compose ps
```

You're looking for `(healthy)` next to both. The app has a 60-second grace period before its
healthcheck counts, so give it a minute.

### Prove it works

```bash
curl http://localhost:4000/
curl http://localhost:4000/get-example-case
curl http://localhost:4000/health
```

The last one is the important one. It should come back `"status":"UP"` with a `"db"` component
that's also `UP` that's the database connection working, not just the app being alive. There's
also `/health/readiness`, which is the narrower database-only check that the Azure readiness probe
uses.

Worth confirming the container isn't running as root, since that was one of the requirements:

```bash
docker compose exec app id
```

That should report `uid=1001(spring)`.

### Stopping and cleaning up

```bash
docker compose down       # stop
docker compose down -v    # stop and delete the database volume
```

Use `-v` if you ever change `DB_PASSWORD`. Postgres only applies the password when it first creates
its data directory, so an existing volume keeps the old one and you'll get a confusing
authentication failure.

---

## 2. Build and test with Gradle

If you'd rather work outside a container, you'll need JDK 21 and a database running somewhere. The
app won't start without one now that the datasource is enabled.

Start a throwaway Postgres:

```bash
docker run -d --name pg-local \
  -e POSTGRES_PASSWORD=localdev \
  -e POSTGRES_USER=devtest \
  -e POSTGRES_DB=devtest \
  -p 5432:5432 postgres:16
```

Point the app at it and run:

```bash
export DB_HOST=localhost DB_PORT=5432 DB_NAME=devtest \
       DB_USER_NAME=devtest DB_PASSWORD=localdev

./gradlew clean build
./gradlew bootRun
```

`build` compiles the code, runs Checkstyle, and runs both the unit and integration tests the same
thing CI does. If you only want the linting:

```bash
./gradlew checkstyleMain checkstyleTest checkstyleIntegrationTest
```

Reports land in `build/reports/`. When you're finished, `docker rm -f pg-local` clears up the
database, and it's worth doing before you go back to Docker Compose since both want port 5432.

---

## 3. Scan the image with Trivy

CI blocks on critical vulnerabilities, so it's cheaper to find them here than after a push. Build
the image first if you haven't already, then:

```bash
trivy image --severity CRITICAL --ignore-unfixed hmcts/test-backend:local
```

Nothing returned means you're clear. If something does show up, bumping the base image in the
Dockerfile to a newer tag usually resolves it, since these are almost always inherited from the OS
layer rather than anything in the application.

You can scan the Terraform the same way. This one is advisory in CI rather than blocking:

```bash
trivy config --severity HIGH,CRITICAL infrastructure/
```

It flags the database being reachable from the Azure network rather than sitting on a private
subnet, which is a deliberate call explained at the bottom of this file.

---

## 4. Check the Terraform

None of this needs an Azure account. From the repo root:

```bash
cd infrastructure

terraform fmt -check -recursive -diff
terraform init -backend=false
terraform validate
```

`-backend=false` is what lets `init` run without credentials and it skips remote state but still pulls
the providers so `validate` can check everything against the real schema.

If `fmt -check` complains, run `terraform fmt -recursive` and it'll fix the spacing for you.

A real deployment would go further, though `plan` and `apply` both need Azure authentication:

```bash
terraform init -backend-config=backends/prod.tfbackend
terraform plan -var-file=prod.tfvars \
  -var="container_image_tag=sha-$(git rev-parse --short HEAD)" -out=tfplan
terraform apply tfplan
```

Note the image tag being pinned to a commit SHA rather than `latest`. That's deliberate more on
why below.

---
### How it would actually be deployed

The commands above are the mechanics. In practice nobody runs them by hand, a deploy workflow does
it, and the process matters more than the commands.

Authentication would use OpenID Connect rather than a stored service principal secret. GitHub
requests a short-lived token from Azure at the point it needs one, so there's no long-lived
credential sitting in repository settings waiting to leak. On the Azure side that's a federated
credential scoped to this repository and, ideally, to a specific environment.

From there the flow splits by branch, much like the build pipeline. A pull request runs `plan` and
posts the diff as a comment, so the infrastructure change is reviewed alongside the code change
rather than discovered afterwards. Merging to main runs `apply`, but behind a protected GitHub
Environment that requires a human to approve it. Terraform will happily replace a database server
if you let it, and someone should read the plan before that happens.

The image tag is the join between the two pipelines. The build publishes `sha-<commit>`, and the
deploy passes that same tag into `container_image_tag`, which is why nothing in the Terraform ever
references `latest`.

## 5. Watch the pipeline run 

Push a branch and open a pull request:

```bash
git checkout -b main
git commit --allow-empty -m "ci: check pipeline"
git push -u origin main
``` 
On a pull request you'll see four jobs run in parallel Checkstyle, tests, Terraform checks, and
the image build. The image gets built and scanned but never published, because there's no reason to
push an artefact from a branch that might not merge.

Merge it and the same pipeline runs again, this time pushing to GitHub Container Registry. If the
push step fails, check `Settings → Actions → General` and make sure workflow permissions are set to
read and write.

---

## If something goes wrong

**Compose says a variable must be set.** Your `.env` is missing or misnamed. On Windows, Notepad
likes to save it as `.env.txt`. Run `ls -la .env` to check, and `docker compose config` to see what
values are actually being read.

**Postgres complains the password isn't specified.** That's a container started outside Compose.
Check `docker ps -a` for one with a random name and remove it, it'll also be holding port 5432.

**The Gradle build inside Docker runs out of memory.** On Windows, Docker's memory comes from WSL
rather than Docker Desktop's settings. Create `C:\Users\<you>\.wslconfig` with `memory=8GB` under a
`[wsl2]` heading, run `wsl --shutdown`, and restart Docker Desktop.

**Terraform reports a deprecated or missing argument.** The provider pin allows patch updates, so a
newer version may have renamed something. The error names the file and line, and the provider
documentation for that resource will have the current form.

-------

## How the pipeline is put together

Four gates run, three of them at the same time, followed by a single check that ties them together.

**Checkstyle** runs on its own rather than as part of the test job, so a formatting problem shows up
in seconds instead of being buried behind a full test run.

**Build and test** does `./gradlew build`, which covers compilation, unit tests and integration
tests, then generates a coverage report. Test results and the jar are uploaded either way, so a
failed run is still debuggable.

**Terraform checks** run `fmt -check` and `validate`, plus an advisory scan for infrastructure
misconfigurations. Neither of the first two needs Azure credentials, which is why they can sit in
every pull request.

**The image job** builds the container, loads it locally, scans it, and only then considers
pushing. Critical vulnerabilities fail the build outright so nothing reaches the registry. High
findings get reported into the Security tab but don't block, because a team needs some way to ship
while waiting on an upstream base image fix.

Finally, **pipeline-gate** aggregates all four into one status check. Branch protection only needs
to require that single check, which means adding a new job later doesn't mean going back and editing
protection rules.
In practice that means setting merges to main to require `pipeline-gate` passing, one approving
review, and the branch to be up to date, with force pushes off. That single rule covers everything:
you can't merge with failing tests, Checkstyle violations, invalid Terraform, or a critical
vulnerability in the image.


### About the image tags

Every build produces a `sha-<short commit>` tag, and that's what deployments actually reference.
It's immutable and points at exactly one commit, so "what's running in production?" always has an
answer and rollbacks are reliable.

The other tags exist for people rather than machines. Branch builds also get
`<branch>-<run number>` so you can trace a running image back to a specific pipeline run, version
tags produce proper semver tags for anything with external consumers, and `latest` is there for
convenience when pulling locally. None of those should ever appear in a deployment, because they all
move.

---

## What the Terraform sets up

Everything lives under `infrastructure/`, split by concern:

```
versions.tf     provider versions, and a note on remote state
variables.tf    every input, typed and validated
main.tf         naming conventions, resource group, logging workspace
postgres.tf     the database server and application database
keyvault.tf     the vault and its access rules
container_app.tf  the managed identity and the running service
outputs.tf      URLs and resource names
```

It creates a resource group, a PostgreSQL Flexible Server with zone-redundant failover and
geo-redundant backups, a Key Vault holding the database credentials, and an Azure Container App
running the published image.

Container Apps was chosen over App Service mainly for three reasons: it handles revisions and
traffic splitting natively, so blue-green and canary rollouts need no extra infrastructure; it
scales on HTTP concurrency, which suits a bursty internal API better than instance-based scaling;
and it supports proper liveness, readiness and startup probes that map onto the health endpoints the
app already exposes. App Service would have been the safer pick if the goal were matching existing
estate patterns, but for a service that'll be deployed often, the revision model wins.

### How the password stays out of the repo

Terraform generates the database password itself and writes it straight into Key Vault. The
Container App then declares that password as a Key Vault reference rather than a value, and resolves
it at startup using a managed identity. So it's never a variable, never in a tfvars file, and never
visible in the app's configuration.

Everything that isn't secret host, port, database name, username is passed as an ordinary
environment variable. That's on purpose: the container reads exactly the same variable names in
Azure as it does under Docker Compose on your laptop, so there's no separate code path for
production.

### State

The remote state block in `versions.tf` is commented out so that `validate` runs without
credentials. In a real deployment, state would live in its own storage account with versioning and
soft delete turned on, access restricted to the deployment identity, and a separate state file per
environment. The generated password ends up in state, so that account needs treating as sensitive in
its own right.

---
### Assumptions

No Java changes were needed or wanted; everything is configuration, packaging and infrastructure.
The application image is published to GHCR by CI, but the Terraform defaults point at an
Azure Container Registry, which is what a real HMCTS deployment would pull from. Swapping the registry is a variable change.
The service is stateless. No schema migrations are defined if the service later owns
tables, Flyway or Liquibase should be added and run as an init container or startup step rather than by the application on boot.
`master` is the default branch in this repository, so the pipeline triggers on both `main`
  and `master`.

--------

## Notes and trade-offs

A few decisions worth explaining, and what I'd change given more time.

**The database is reachable from the Azure network rather than a private subnet.** Doing it properly
means a virtual network, a delegated subnet, and a private DNS zone, which roughly doubles the
configuration and can't be verified without a real subscription. It's the first thing I'd fix.

**The password exists, when ideally it wouldn't.** Entra ID authentication with the app's managed
identity would remove it entirely, but that needs token handling in the application code, and this
exercise was explicitly about configuration rather than Java.

**Tests don't run during the image build.** It keeps builds fast, and the pipeline already gates on
them but it does mean a plain `docker build` on someone's laptop proves nothing about correctness.

**The infrastructure scan is advisory.** It flags the networking decision above, which is a known
and accepted trade-off. Making it blocking without a proper exception process would just teach
people to ignore failures, which is worse than not having the check.

Beyond fixing the networking, the next things I'd add are integration tests that run against a real
PostgreSQL container so the database wiring is actually covered by a test rather than a manual
`curl`, a separate deployment workflow using federated credentials instead of stored secrets, and
image signing so only verified builds can run.

---

### With more time

1. Private networking end to end VNet, delegated subnet, private DNS, private endpoints for
   Key Vault and ACR.
2. Entra ID authentication to PostgreSQL, eliminating the stored password.
3. Testcontainers-backed integration tests hitting a real PostgreSQL instance in CI, so the
   datasource wiring is actually covered by a test rather than by a manual `curl`.
4. A separate deploy workflow with OIDC auth, PR-time `terraform plan` comments, and a
   protected production environment with manual approval.
5. Image signing with Cosign and SBOM generation (Syft), with an admission policy that only
   signed images can run.
6. Alerting: Azure Monitor alerts on Container App restarts, 5xx rate, replica count at
   maximum, and PostgreSQL connection saturation.
7. `tflint` and `checkov` alongside Trivy, and Renovate configured to raise base-image bumps
   automatically.
8. A `terraform plan` gate on PRs once federated credentials exist, since `validate` catches
   syntax and schema errors but not the many things that only surface against a real API.


