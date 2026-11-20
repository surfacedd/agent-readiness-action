# Surfacedd agent readiness check (GitHub Action)

Catch agent-readiness regressions before you ship. This action checks whether AI crawlers and
agents can **reach** your site, **understand** what each page offers and **act** on its forms,
using the same rules and scores as the [Surfacedd app](https://surfacedd.com/features/agent-readiness).
It writes a job summary with the scores, the problems and how to fix each one, and fails the step
when the overall score is under the number you set.

- Free: no account, no licence, no API keys, no AI calls.
- Only the site you name is contacted. robots.txt is respected. Nothing is stored or uploaded.
- Deterministic: the same pages give the same score.

```yaml
- uses: surfacedd/agent-readiness-action@v1
  with:
    url: https://staging.example.com
    fail-under: 70
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `url` | (required) | Where to start, e.g. `https://staging.example.com` or `http://localhost:3000` |
| `fail-under` | empty | Fail the step when the overall score is under this number (0–100), or when no rule applied. Empty never fails on the score |
| `max-pages` | `50` | Pages to crawl (1–500) |
| `allow-private` | `false` | `true` to check a local or private address, such as a server started earlier in the job |
| `version` | `latest` | `surfacedd-check` release, e.g. `v1.0.0` (pin it for reproducible builds) |
| `summary` | `true` | `false` skips the job summary |

## Outputs

`score`, `reach`, `understand`, `act` (0–100, empty when not scored), `passed` (`true`/`false`),
`problems` (how many scored rules have problems) and `report` (the path of the JSON report,
schema [`surfacedd.cli/v1`](https://surfacedd.com/schemas/cli/v1.json)).

## Recipes

Check a preview deployment on every pull request and keep the report:

```yaml
name: Agent readiness
on: [pull_request]
jobs:
  agent-readiness:
    runs-on: ubuntu-latest
    steps:
      - id: ar
        uses: surfacedd/agent-readiness-action@v1
        with:
          url: https://staging.example.com
          fail-under: 70
      - if: always()
        uses: actions/upload-artifact@v4
        with:
          name: agent-readiness
          path: ${{ steps.ar.outputs.report }}
```

Check the build itself before it is deployed (a local server needs `allow-private`):

```yaml
      - run: npm ci && npm run build
      - run: npx serve -l 3000 dist &
      - uses: surfacedd/agent-readiness-action@v1
        with:
          url: http://localhost:3000
          allow-private: true
          fail-under: 80
```

Without the action (any runner with `curl`): install, then call the binary. Exit code 5 means
"under the threshold".

```sh
curl -fsSL https://surfacedd.com/install-check.sh | sh -s -- --dir "$HOME/.local/bin"
surfacedd-check agent-readiness check https://staging.example.com --fail-under 70
```

## What the job summary shows

Real output for `https://example.com` with `fail-under: 70` (the step fails with exit code 5):

```text
## Agent readiness: 47/100 · failed (under 70)

https://example.com/ · 1 page checked · rules 2026-11-19.1

| Category | Score |
| **Overall** | **47/100** |
| Reach | 94/100 |
| Understand | 0/100 |
| Act | not scored (no rule applies) |

### Fix these first
| 2 | understand | `understand.organization-schema` | The home page has no Organization markup. |
| 2 | understand | `understand.landmarks` | 1 of 1 pages lack a main or navigation landmark. |
| 1 | reach | `reach.sitemap` | No sitemap found in robots.txt or at /sitemap.xml. |
| 1 | understand | `understand.heading-order` | 1 of 1 pages have heading problems. |
```

Each problem then has a "how to fix" panel with the evidence, a snippet to copy and the sources the
rule rests on. The log gets the same lines and an error annotation when the step fails.

## How it works

1. Downloads `surfacedd-check` for the runner (Linux x64/arm64, macOS, Windows x64) from the
   Surfacedd release and checks its SHA-256 against the release's `surfacedd-check-SHA256SUMS`.
   The checksum file is signed with Sigstore by the release workflow.
2. Runs `surfacedd-check agent-readiness check <url> --json`: a crawl of up to `max-pages` pages,
   bot-wall probes with AI agents' User-Agent tokens, and the app's agent-readiness rule table
   (listed on the [agent readiness checker](https://surfacedd.com/tools/agent-readiness-checker) page).
3. Turns the JSON into the job summary and outputs with Node (preinstalled on GitHub runners).

## Limits

- JavaScript isn't run: content checks read the HTML the server sends, as most crawlers do.
- The bot-wall test sends agents' User-Agent tokens from the runner. It can't present a verified
  agent's IP range or signature, so a firewall may treat real agents differently.
- Requests go straight to the site (proxy variables are ignored).
- One URL per step. Add steps for more sites.

## Develop

The source lives in the Surfacedd repository at `integrations/github-action/`; the published repo
`surfacedd/agent-readiness-action` is a copy of this folder. `test/run.sh` runs the action's steps
locally against fixture sites and a fake release (no Docker needed):

```sh
cargo build -p sd-check --release
integrations/github-action/test/run.sh
```
