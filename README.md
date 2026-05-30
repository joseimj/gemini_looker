# gemini_looker

**A conversational Looker analytics agent for Google's Gemini Enterprise.**

`gemini_looker.sh` is a single, idempotent script that stands up an end‑to‑end analytics agent: it provisions the cloud resources, deploys an [Agent Development Kit (ADK)](https://google.github.io/adk-docs/) agent to **Vertex AI Agent Engine**, and registers it in **Gemini Enterprise**. Once deployed, a business user can ask, in plain language, to *see* a dashboard, *get the numbers*, or *get an interactive link* — and the agent answers right inside the chat.

**Author:** Jose Maldonado ([@joseimj](https://github.com/joseimj))

---

## Table of contents

- [What it does](#what-it-does)
- [What this project demonstrates](#what-this-project-demonstrates)
- [Architecture](#architecture)
- [Key design decisions](#key-design-decisions)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
- [What the agent can do](#what-the-agent-can-do)
- [Swapping the reasoning model](#swapping-the-reasoning-model)
- [A note on data access](#a-note-on-data-access)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What it does

A user types a request in Gemini Enterprise and the agent responds in kind:

| The user asks… | The agent does… |
| --- | --- |
| "Show me the sales dashboard" | Renders the dashboard as an **inline image** |
| "How many orders are complete?" | Runs a Looker query and answers **with the numbers** |
| "Chart orders by status as a bar chart" | Builds an ad‑hoc visualization and shows it inline |
| "Give me the link to dashboard 1" | Returns a **signed, interactive Looker URL** |

---

## What this project demonstrates

- Building and deploying a production agent on **Vertex AI Agent Engine** with the **ADK**.
- Integrating a managed agent into **Gemini Enterprise** end to end.
- A pragmatic Looker integration: rendering, ad‑hoc queries, and signed SSO embed links.
- An intentionally **minimal, low‑cost architecture** — and the reasoning behind it.

---

## Architecture

```
┌─────────────────────┐
│  Gemini Enterprise  │   the chat UI the user sees
└──────────┬──────────┘
           │
           ▼
┌──────────────────────────────────┐
│  Vertex AI Agent Engine (ADK)      │   managed runtime hosting the agent
│  - LlmAgent (Gemini, swappable)    │
│  - Render PNG -> ADK Artifacts     │
│  - Signed links via Looker API     │
│  - Dedicated service account       │
└──────────────────┬─────────────────┘
                   │  HTTPS (Looker API credentials via env vars)
                   ▼
          ┌──────────────────┐
          │    Looker API    │   dashboards · Looks · explores · data
          └──────────────────┘
```

No Cloud Run, no message broker, no caching tier, no VPC. The agent talks to Looker directly.

---

## Key design decisions

- **Images are returned as ADK artifacts, not as text.** Each render tool saves the PNG as an artifact and the runtime displays it natively. The image bytes never pass through the model's text output — the only approach that renders reliably in Gemini Enterprise.
- **No middle tier.** The agent calls Looker directly through its SDK. Fewer moving parts means fewer ways to fail, plus a cheaper and faster deployment.
- **Signed links are minted by Looker, on demand.** Interactive URLs are created via the Looker `create_sso_embed_url` API (Looker signs them server‑side), in a *separate* tool from rendering — so producing a link never blocks or delays the image.
- **The reasoning model is swappable.** Defaults to Gemini; can be switched to Claude or another model without touching the rendering pipeline (see below).

---

## Prerequisites

- A Google Cloud project with **billing enabled**.
- `gcloud` CLI, authenticated (`gcloud auth login`). Cloud Shell works out of the box.
- A **Looker** instance with API credentials (Client ID and Client Secret).
- **Embedding enabled** in Looker (Admin → Embed → *Embed SSO Authentication* + *Reset Secret*) for the interactive links.
- A **Gemini Enterprise** app already created (you need its `AS_APP` ID).
- A **GCS bucket** for deploy staging and image artifacts.
- **Owner** (or equivalent) on the project.
- `bash` and `python3` (the script creates its own virtual environment).

---

## Configuration

Edit the variables at the top of `gemini_looker.sh` before running:

```bash
PROJECT_ID="your-gcp-project"
PROJECT_NUMBER="123456789012"
REGION="us-central1"
BUCKET_NAME="your-staging-bucket"

# Looker
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="..."
LOOKER_CLIENT_SECRET="..."
LOOKER_EMBED_SECRET="..."     # configured in Looker Admin; not read by the code
LOOKER_MODELS='["thelook"]'   # LookML model(s) the agent may use

# Gemini Enterprise
AS_APP="your-agent-id"
ENGINE_LOCATION="us"
```

Step `-1` refuses to run while any value still starts with `YOUR_`.

---

## Usage

```bash
git clone https://github.com/joseimj/gemini_looker.git
cd gemini_looker

chmod +x gemini_looker.sh
# edit the configuration block, then:
./gemini_looker.sh
```

The script runs, in order:

1. Validate configuration
2. Authenticate
3. Enable required APIs (IAM, Vertex AI, Discovery Engine, Looker, Storage, Resource Manager)
4. Create the agent service account and grant minimal IAM
5. Create the staging bucket (deploy + artifacts)
6. Build the agent application (ADK)
7. Deploy the agent to Agent Engine *(~15–20 min)*
8. Register the agent in Gemini Enterprise

> The deploy prints a heartbeat every 15s. In Cloud Shell, keep the tab active during the deploy (idle timeout is ~20 min).

---

## What the agent can do

All capabilities call Looker directly through its SDK.

**Show images (rendered inline via artifacts):**
- `show_dashboard_inline` — render a dashboard as a PNG
- `show_look_inline` — render a saved Look as a PNG
- `show_query_inline` — run an ad‑hoc query and render it as a chart (`looker_column`, `looker_bar`, `looker_line`, `looker_pie`, `looker_scatter`)

**Interactive links (signed by Looker, on demand):**
- `get_dashboard_link`, `get_look_link`, `get_explore_link` — return a signed SSO embed URL

**Data (text/table answers):**
- `query_looker_data` — run a query and return rows
- `list_looker_models` — list the models the API credentials can reach (data‑access diagnostics)
- `list_looker_fields` — list an explore's dimensions and measures
- `list_available_dashboards` — find dashboards by title

---

## Swapping the reasoning model

The reasoning model is independent of rendering, so you can change it freely **without losing the image feature**. The default is Gemini:

```python
AGENT_MODEL = "gemini-2.5-flash"
```

To drive the agent with **Anthropic Claude (e.g. Sonnet 4.6)** instead:

1. Enable the model in **Vertex AI Model Garden** (`publishers/anthropic/model-garden/claude-sonnet-4-6`).
2. Add `litellm` to the `requirements` list in `deploy.py`.
3. Replace the model line in `looker_app/agent.py`:

```python
from google.adk.models.lite_llm import LiteLlm
AGENT_MODEL = LiteLlm(model="vertex_ai/claude-sonnet-4-6")
```

(For the public Anthropic API instead of Vertex, use `LiteLlm(model="anthropic/claude-sonnet-4-6")` with `ANTHROPIC_API_KEY` set.)

---

## A note on data access

If a data query returns an access error ("cannot access data"), the cause is almost always **Looker‑side, not the code**: the role assigned to the API credentials must include a permission set with `access_data` / `explore` **and** a model set that contains the model being queried. Note that `"all"` is not a valid model name. Use `list_looker_models` to see which models the credentials can actually reach — if the model you expect isn't listed, fix the role in Looker Admin.

---

## Troubleshooting

**Image renders but no link appears.** The agent should call `get_dashboard_link` (etc.) and output `signed_url`. If links fail, confirm embedding is enabled in Looker (Admin → Embed) and that the Gemini Enterprise domain is on the embed allowlist. Validate a generated URL with Looker's **Embed URI Validator**.

**Data queries fail with an access error.** See [A note on data access](#a-note-on-data-access). Run `list_looker_models` to confirm what the API user can reach.

**Deploy fails with a 500 ("revision not ready").** This is a catch‑all for a container that didn't start. Check **Logs Explorer → resource type "Vertex AI Reasoning Engine"** for the real error. The most common cause is a freshly upgraded dependency: pin exact versions in both Step 4 and `deploy.py` so the build and runtime match.

**Dashboard render times out.** Heavy dashboards can be slow; the render task is capped at 90s. Try a Look or an ad‑hoc query (faster), or raise the cap in `show_dashboard_inline`.

---

## License

Set your repository license here (e.g. MIT). _TODO._
