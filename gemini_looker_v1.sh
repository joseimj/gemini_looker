#!/bin/bash
# =============================================================================
#  gemini_looker.sh
#  A Looker analytics agent for Google's Gemini Enterprise
#  Author: Jose Maldonado (@joseimj)
# =============================================================================
#
#  WHAT THIS PROJECT DOES (read this first)
#  ----------------------------------------
#  This single script stands up, end to end, a conversational analytics agent
#  that lives inside Gemini Enterprise and talks to a Looker instance. A
#  business user can ask, in plain language:
#
#      "show me the sales dashboard"   -> the agent renders it as an image
#      "how many orders are complete?" -> the agent answers with the numbers
#      "give me the link to look 9"    -> the agent returns a signed Looker URL
#
#  The script is idempotent: it provisions the cloud resources, deploys the
#  agent, and registers it in Gemini Enterprise. Run it again and it reuses
#  what already exists instead of duplicating it.
#
#  HOW IT WORKS (the end-to-end flow)
#  ----------------------------------
#      Gemini Enterprise (the chat UI the user sees)
#          -> Vertex AI Agent Engine (the managed runtime that hosts the agent)
#              -> the ADK agent (Python), which talks to Looker via its SDK
#                  -> Looker (dashboards, Looks, explores, data)
#
#  Two design decisions worth calling out:
#    1. Images are returned as ADK "artifacts", not as text/base64. The agent
#       saves the rendered PNG and the runtime displays it natively. This is
#       the only reliable way to show images inline in Gemini Enterprise.
#    2. There is no intermediate service (no Cloud Run, no message broker, no
#       caching tier). The agent calls Looker directly. Fewer moving parts
#       means fewer ways to fail, and it keeps the deployment cheap and fast.
#
#  THE STEPS THIS SCRIPT RUNS
#  --------------------------
#    -1  Validate configuration      4  Python build environment
#     0  Authenticate                5  Build the agent application (ADK)
#     1  Enable required APIs         6  Deploy the agent to Agent Engine
#     2  Create the agent's identity  7  Register the agent in Gemini Enterprise
#     3  Create the staging bucket
#
#  Total time on a first run: roughly 15-20 minutes (the Agent Engine deploy
#  is the long part).
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION  --  set these before running.
# (Step -1 refuses to run while any value still starts with YOUR_.)
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"          # one bucket: deploy staging + image artifacts
BUCKET_LOCATION="US"

# --- Looker connection (API credentials) ---
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"
# The embed secret is NOT read by this code. Looker signs the embed URLs on its
# own side (we ask for them via the API). You only need to enable embedding in
# Looker (Admin > Embed > "Embed SSO Authentication" + Reset Secret). It is
# validated below purely as a reminder that embedding must be configured.
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"
LOOKER_MODELS='["thelook"]'                  # LookML model(s) the agent may use

# --- Gemini Enterprise ---
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"     # ID of the app already created in Gemini Enterprise
ENGINE_LOCATION="us"                         # "us", "eu" or "global"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker agent that renders dashboards/charts as inline images and answers data questions."
TOOL_DESCRIPTION="Use this tool to answer questions about Looker data and display dashboards/charts as inline images."
# =============================================================================

# Defensive reset: clear any inherited values so the script behaves the same
# whether it runs in a clean shell or a reused one.
unset AGENT_SA AGENT_SA_NAME
unset REASONING_ENGINE
unset DEPLOY_LOG DEPLOY_PID DEPLOY_EXIT
unset ACCESS_TOKEN API_ENDPOINT AGENT_API_URL REQUEST_BODY
unset HTTP_RESPONSE HTTP_STATUS RESPONSE_BODY
unset ELAPSED MINS SECS LAST_LINE

# Fail fast if a required value was left as a placeholder.
validate_var() {
  local var_name="$1"
  local var_value="$2"
  if [[ -z "$var_value" || "$var_value" == YOUR_* ]]; then
    echo "ERROR: configuration variable '$var_name' is not set."
    exit 1
  fi
}

echo ""
echo "=================================================="
echo " STEP -1: Validate configuration"
echo "=================================================="
validate_var "PROJECT_ID" "$PROJECT_ID"
validate_var "PROJECT_NUMBER" "$PROJECT_NUMBER"
validate_var "BUCKET_NAME" "$BUCKET_NAME"
validate_var "LOOKER_URL" "$LOOKER_URL"
validate_var "LOOKER_CLIENT_ID" "$LOOKER_CLIENT_ID"
validate_var "LOOKER_CLIENT_SECRET" "$LOOKER_CLIENT_SECRET"
validate_var "LOOKER_EMBED_SECRET" "$LOOKER_EMBED_SECRET"
validate_var "AS_APP" "$AS_APP"
echo "OK: configuration looks complete."

echo ""
echo "=================================================="
echo " STEP 0: Authenticate"
echo "=================================================="
# Show the active identity and pin the default project for gcloud.
gcloud auth list
gcloud config set project "$PROJECT_ID"

echo ""
echo "=================================================="
echo " STEP 1: Enable required Google Cloud APIs"
echo "=================================================="
# Only what this architecture needs. Notably absent: Cloud Run, Cloud Build and
# Secret Manager, because the agent talks to Looker directly (no middle tier).
gcloud services enable \
  iam.googleapis.com \
  aiplatform.googleapis.com \
  discoveryengine.googleapis.com \
  looker.googleapis.com \
  storage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "=================================================="
echo " STEP 2: Create the agent's identity and grant minimal permissions"
echo "=================================================="
# The agent runs as its own dedicated service account (least privilege).
AGENT_SA_NAME="looker-agent-sa"
AGENT_SA="${AGENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$AGENT_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$AGENT_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker Agent Engine SA"
fi
echo "Agent service account: $AGENT_SA"

echo ""
echo "Granting the agent service account only the roles it needs..."

# Run on Agent Engine / call Vertex AI models.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/aiplatform.user" \
  --condition=None &>/dev/null
echo "  [OK] aiplatform.user"

# Write runtime logs (observability).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
echo "  [OK] logging.logWriter"

# Read/write objects: deploy staging package + the rendered image artifacts.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/storage.objectUser" \
  --condition=None &>/dev/null
echo "  [OK] storage.objectUser (staging + artifacts)"

# Allow the Agent Engine service agent to mint tokens for the custom service
# account. This prevents a class of deploy failures (the runtime needs to act
# as the agent's identity). Safe to run repeatedly.
gcloud iam service-accounts add-iam-policy-binding "$AGENT_SA" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" &>/dev/null || true
echo "  [OK] reasoning-engine service agent can act as the agent SA"

echo "Minimal permissions assigned."

echo ""
echo "=================================================="
echo " STEP 3: Create the staging bucket (deploy package + artifacts)"
echo "=================================================="
# A single bucket backs both the deploy package upload and the image artifacts.
# Idempotent: skipped if it already exists.
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
  echo "Bucket created: gs://${BUCKET_NAME}"
else
  echo "Bucket already exists."
fi

echo ""
echo "=================================================="
echo " STEP 4: Prepare an isolated Python environment"
echo "=================================================="
# Built from scratch each run so no stale dependency leaks in from a prior run.
rm -rf my-agents
mkdir -p my-agents && cd my-agents

python3 -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet google-adk looker-sdk
pip install --quiet --upgrade "google-cloud-aiplatform[agent_engines,adk]"
# NOTE: if a freshly released dependency ever breaks the deploy, pin exact
# versions here AND in deploy.py's requirements so dev and runtime match.

echo ""
echo "=================================================="
echo " STEP 5: Build the agent application (ADK)"
echo "=================================================="
mkdir -p looker_app

# __init__.py exposes the agent module when the package is shipped to the runtime.
cat > looker_app/__init__.py <<'EOF'
from . import agent
EOF

# .env is only for local testing with `adk web`. In production the same values
# are injected as environment variables at deploy time (see STEP 6 / deploy.py).
cat > looker_app/.env <<EOF
LOOKERSDK_BASE_URL=${LOOKER_URL}
LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID}
LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET}
LOOKERSDK_VERIFY_SSL=true
LOOKER_MODELS=${LOOKER_MODELS}
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
looker_sdk
google-auth
requests
EOF

# ---------------------------------------------------------------------------
# agent.py -- the agent logic. Written through a single-quoted 'PYEOF' heredoc
# so the shell does NOT interpolate anything; the file is pure Python.
# ---------------------------------------------------------------------------
cat > looker_app/agent.py <<'PYEOF'
"""Looker analytics agent for Gemini Enterprise.

Responsibilities:
  - Render Looker dashboards/Looks/charts and display them inline as images
    (via ADK artifacts -- the image bytes never pass through the model's text).
  - Answer data questions by querying Looker directly through its SDK.
  - Produce signed, interactive Looker embed links on demand (Looker signs them
    server-side, so we never hand-roll the signature).

Credentials arrive as environment variables (the Looker SDK reads LOOKERSDK_*).
"""

import os
import json
import time

import looker_sdk
from looker_sdk import models40

from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools import ToolContext
from google.adk.tools.load_artifacts_tool import load_artifacts_tool
from google.genai.types import ThinkingConfig, Part

# -----------------------------------------------------------------------------
# Configuration read from environment variables.
# -----------------------------------------------------------------------------
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "").replace("http://", "").rstrip("/")
)
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')

# Permissions granted to the temporary embed user inside the signed link.
EMBED_PERMISSIONS = [
    "access_data", "see_looks", "see_user_dashboards",
    "see_lookml_dashboards", "explore", "save_content", "embed_browse_spaces",
]

# -----------------------------------------------------------------------------
# Reasoning model (swappable -- this does NOT affect image rendering).
#
# Rendering is handled by the tools below plus load_artifacts_tool, which work
# the same no matter which LLM drives the agent. So you can change the model
# freely without losing the rendering feature.
#
# Default: Gemini on Vertex AI.
AGENT_MODEL = "gemini-2.5-flash"
#
# To drive the agent with Anthropic Claude (e.g. Sonnet 4.6) instead:
#   1) Enable the model in Vertex AI Model Garden
#      (publishers/anthropic/model-garden/claude-sonnet-4-6).
#   2) Add "litellm" to the requirements in deploy.py.
#   3) Replace the line above with:
#         from google.adk.models.lite_llm import LiteLlm
#         AGENT_MODEL = LiteLlm(model="vertex_ai/claude-sonnet-4-6")
#      (For the public Anthropic API instead of Vertex, use
#       LiteLlm(model="anthropic/claude-sonnet-4-6") with ANTHROPIC_API_KEY set.)
# -----------------------------------------------------------------------------


def _signed_embed_url(embed_path: str, external_user_id: str = "gemini-user") -> str:
    """Ask Looker to mint a signed SSO embed URL.

    We let Looker create and sign the URL server-side via create_sso_embed_url
    instead of building the HMAC by hand. Hand-signing is error-prone (exact
    endpoint, field order, and SHA-1 vs SHA-256 all have to match), and the API
    does it correctly every time.

    `embed_path` is the embed target, e.g. "/embed/dashboards/1".
    """
    sdk = looker_sdk.init40()
    resp = sdk.create_sso_embed_url(
        body=models40.EmbedSsoParams(
            target_url=f"https://{LOOKER_HOST}{embed_path}",
            session_length=3600,
            force_logout_login=True,
            external_user_id=external_user_id,
            first_name="Gemini",
            last_name="User",
            permissions=EMBED_PERMISSIONS,
            models=json.loads(LOOKER_MODELS_ENV),
        )
    )
    return resp.url


# =============================================================================
# IMAGE TOOLS
#
# Each tool renders a PNG, stores it as an artifact, and returns ONLY the
# artifact filename. The image bytes are never returned as text. The agent then
# calls load_artifacts to display it. We deliberately do NOT create the embed
# link here -- that is a separate, on-demand tool (below), to keep rendering
# fast and off any extra network call.
# =============================================================================
async def show_dashboard_inline(dashboard_id: str, tool_context: ToolContext) -> dict:
    """Render a Looker dashboard as an image and save it as an artifact.

    Args:
        dashboard_id: numeric dashboard ID.
    """
    sdk = looker_sdk.init40()

    # Dashboard rendering is asynchronous in Looker: create a render task, then
    # poll until it succeeds or fails.
    task = sdk.create_dashboard_render_task(
        dashboard_id=dashboard_id,
        result_format="png",
        body=models40.CreateDashboardRenderTask(
            dashboard_style="tiled", dashboard_filters=""
        ),
        width=1200, height=800,
    )

    waited = 0
    while waited < 90:  # cap the wait so a heavy dashboard fails cleanly, not forever
        status = sdk.render_task(task.id)
        if status.status == "success":
            break
        if status.status == "failure":
            return {"status": "error", "message": f"Render failed for dashboard {dashboard_id}"}
        time.sleep(2)
        waited += 2
    else:
        return {"status": "error", "message": f"Timed out rendering dashboard {dashboard_id}"}

    png_bytes = sdk.render_task_results(task.id)
    filename = f"dashboard_{dashboard_id}.png"
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not save the image artifact: {e}"}

    return {"status": "success", "artifact_filename": filename,
            "next_step": "Call load_artifacts with this filename to display the image."}


async def show_look_inline(look_id: str, tool_context: ToolContext) -> dict:
    """Render a Looker Look (saved chart) as an image and save it as an artifact.

    Args:
        look_id: numeric Look ID.
    """
    sdk = looker_sdk.init40()
    try:
        # run_look with PNG output is synchronous: it returns the bytes directly.
        png_bytes = sdk.run_look(
            look_id=look_id, result_format="png",
            image_width=1000, image_height=700,
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not render Look {look_id}: {e}"}

    filename = f"look_{look_id}.png"
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not save the image artifact: {e}"}

    return {"status": "success", "artifact_filename": filename,
            "next_step": "Call load_artifacts with this filename to display the image."}


async def show_query_inline(
    model: str, explore: str, fields: list, tool_context: ToolContext,
    vis_type: str = "looker_column",
) -> dict:
    """Build an ad-hoc query, render it as a chart, and save it as an artifact.

    Args:
        model: LookML model (e.g. "thelook").
        explore: explore name (e.g. "order_items").
        fields: list of LookML fields.
        vis_type: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.
    """
    sdk = looker_sdk.init40()
    try:
        # vis_config makes Looker render the result as a chart rather than a table.
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                limit="500", vis_config={"type": vis_type},
            )
        )
        png_bytes = sdk.run_query(
            query_id=str(query.id), result_format="png",
            image_width=1000, image_height=700,
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not run/render the query: {e}"}

    filename = f"query_{model}_{explore}.png".replace("/", "_")
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not save the image artifact: {e}"}

    return {"status": "success", "artifact_filename": filename,
            "next_step": "Call load_artifacts with this filename to display the chart."}


# =============================================================================
# SIGNED-LINK TOOLS (on demand)
#
# Dedicated tools so the agent can fetch a signed, interactive Looker URL
# explicitly. Kept separate from the render tools: the image displays first and
# the (network) call to mint the link never blocks or delays rendering.
# =============================================================================
def get_dashboard_link(dashboard_id: str) -> dict:
    """Return a signed, interactive Looker URL for a dashboard."""
    try:
        return {"status": "success",
                "signed_url": _signed_embed_url(f"/embed/dashboards/{dashboard_id}")}
    except Exception as e:
        return {"status": "error", "message": f"Could not create the signed link: {e}"}


def get_look_link(look_id: str) -> dict:
    """Return a signed, interactive Looker URL for a Look."""
    try:
        return {"status": "success",
                "signed_url": _signed_embed_url(f"/embed/looks/{look_id}")}
    except Exception as e:
        return {"status": "error", "message": f"Could not create the signed link: {e}"}


def get_explore_link(model: str, explore: str) -> dict:
    """Return a signed, interactive Looker URL for an explore."""
    try:
        return {"status": "success",
                "signed_url": _signed_embed_url(f"/embed/explore/{model}/{explore}")}
    except Exception as e:
        return {"status": "error", "message": f"Could not create the signed link: {e}"}


# =============================================================================
# DATA TOOLS (text/table answers, no image)
# =============================================================================
def query_looker_data(
    model: str, explore: str, fields: list,
    filters: dict = None, sorts: list = None, limit: int = 100,
) -> dict:
    """Run a Looker query and return the rows as JSON.

    If this returns an access error, the cause is almost always Looker-side: the
    API credentials' role must include a permission set with access_data/explore
    AND a model set that contains `model`. Use list_looker_models to see which
    models the credentials can actually reach.

    Args:
        model: LookML model (e.g. "thelook").
        explore: explore name (e.g. "order_items").
        fields: LookML fields (e.g. ["order_items.status", "order_items.count"]).
        filters: optional dict of filters (e.g. {"order_items.status": "complete"}).
        sorts: optional list of sorts (e.g. ["order_items.count desc"]).
        limit: max rows (default 100).
    """
    sdk = looker_sdk.init40()
    try:
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                filters=filters or {}, sorts=sorts or [], limit=str(limit),
            )
        )
        rows = sdk.run_query(query_id=str(query.id), result_format="json")
        data = json.loads(rows) if isinstance(rows, str) else rows
        return {"status": "success", "row_count": len(data), "rows": data}
    except Exception as e:
        return {"status": "error",
                "message": f"Query failed (check model/explore/field names and the "
                           f"Looker role of the API user): {e}"}


def list_looker_models() -> dict:
    """List the LookML models the API credentials can access.

    Diagnostic helper for "cannot access data": if the model you expect is not
    in this list, the Looker role assigned to the API credentials does not grant
    access to it (fix it in Looker Admin, not in this code)."""
    sdk = looker_sdk.init40()
    try:
        models = sdk.all_lookml_models()
        names = [m.name for m in models if getattr(m, "name", None)]
        return {"status": "success", "models": names}
    except Exception as e:
        return {"status": "error", "message": f"Could not list models: {e}"}


def list_looker_fields(model: str, explore: str) -> dict:
    """List the dimensions and measures of an explore (to build valid queries)."""
    sdk = looker_sdk.init40()
    try:
        exp = sdk.lookml_model_explore(lookml_model_name=model, explore_name=explore)
        dims = [f.name for f in (exp.fields.dimensions or [])] if exp.fields else []
        meas = [f.name for f in (exp.fields.measures or [])] if exp.fields else []
        return {"status": "success", "dimensions": dims, "measures": meas}
    except Exception as e:
        return {"status": "error", "message": f"Could not list fields: {e}"}


def list_available_dashboards(search_term: str = "") -> dict:
    """List available dashboards (id + title), optionally filtered by title."""
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)
    if not dashboards:
        return {"status": "success", "dashboards": []}
    return {"status": "success",
            "dashboards": [{"id": str(d.id), "title": d.title} for d in dashboards]}


# =============================================================================
# Agent definition.
#   - model: swappable (see AGENT_MODEL above); rendering is unaffected.
#   - instruction: teaches the render -> load_artifacts -> link pattern and how
#     to answer data questions and diagnose access errors.
#   - planner: thinking disabled (budget 0) for direct, low-latency answers.
# =============================================================================
root_agent = LlmAgent(
    model=AGENT_MODEL,
    name='looker_agent',
    description='Looker agent: renders dashboards/charts as inline images and answers data questions via the Looker SDK.',
    instruction=(
        'You are a Looker analytics agent inside Gemini Enterprise.\n\n'
        'TO SHOW AN IMAGE (dashboard / look / chart):\n'
        '1. Call show_dashboard_inline, show_look_inline, or show_query_inline. '
        'Each renders the image and saves it as an artifact, returning '
        '"artifact_filename".\n'
        '2. Call load_artifacts with that filename to display it inline. This is '
        'the ONLY way the image renders; never output image bytes or base64.\n'
        '3. Then ALSO provide the interactive link: call get_dashboard_link / '
        'get_look_link / get_explore_link for the same item and output the '
        'returned "signed_url" as a markdown link '
        '"[Open the interactive version in Looker](signed_url)". Output the '
        'signed_url exactly as returned.\n\n'
        'IF THE USER ASKS ONLY FOR THE LINK: call the matching get_*_link tool '
        'directly and return the signed_url.\n\n'
        'CRITICAL LINK RULE: NEVER write, guess, or construct a Looker URL from '
        'your own knowledge. The ONLY acceptable link is the exact "signed_url" '
        'string returned by a get_dashboard_link / get_look_link / get_explore_link '
        'call in THIS turn. A real link looks like '
        'https://<host>/login/embed/...&signature=...; if you are about to output '
        'anything else (e.g. a plain /embed/dashboards/... URL, or a host you were '
        'not given by a tool), STOP - that is wrong. If a get_*_link tool returned '
        'status="error" or you have no signed_url from a tool this turn, do NOT '
        'output any link; instead tell the user the link could not be generated '
        'and relay the tool error.\n\n'
        'TO ANSWER A DATA QUESTION (numbers, no chart):\n'
        '- Use query_looker_data and summarize the rows in plain text or a small '
        'markdown table.\n'
        '- If you are unsure which model/explore/fields exist, call '
        'list_looker_models, then list_looker_fields, before querying.\n'
        '- If a data tool returns an access error, call list_looker_models and '
        'tell the user plainly which models are accessible; the Looker role of '
        'the API credentials may simply not grant access to the requested model.\n\n'
        'When any tool returns status="error", relay the message plainly and '
        'suggest a concrete fix.\n\n'
        'Hints when unsure: model="thelook", explore="order_items". '
        'vis_type options: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.'
    ),
    planner=BuiltInPlanner(
        thinking_config=ThinkingConfig(include_thoughts=False, thinking_budget=0)
    ),
    tools=[
        show_dashboard_inline,
        show_look_inline,
        show_query_inline,
        get_dashboard_link,
        get_look_link,
        get_explore_link,
        query_looker_data,
        list_looker_models,
        list_looker_fields,
        list_available_dashboards,
        load_artifacts_tool,   # displays the saved artifacts in the chat
    ],
)
PYEOF

echo "Agent application created (images via artifacts, links via Looker SSO API)."

echo ""
echo "=================================================="
echo " STEP 6: Deploy the agent to Vertex AI Agent Engine"
echo "  (takes ~15-20 min; runs as: $AGENT_SA)"
echo "=================================================="

# deploy.py packages the agent and creates it as a managed Reasoning Engine.
# Looker credentials are injected here as environment variables (never baked
# into the code). Agent Engine provides the managed session + artifact services,
# so saving image artifacts works at runtime with no extra wiring.
cat > deploy.py <<'DEPLOYEOF'
import os
import sys
import vertexai
from vertexai.preview import reasoning_engines
from vertexai import agent_engines

from looker_app.agent import root_agent

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
STAGING_BUCKET = f"gs://{os.environ['BUCKET_NAME']}"
AGENT_SA = os.environ["AGENT_SA"]

vertexai.init(project=PROJECT_ID, location=REGION, staging_bucket=STAGING_BUCKET)

print(f"Deploying agent as service account: {AGENT_SA}", flush=True)
print(f"Staging bucket: {STAGING_BUCKET}", flush=True)

app = reasoning_engines.AdkApp(agent=root_agent, enable_tracing=False)

env_vars = {
    "LOOKERSDK_BASE_URL": os.environ["LOOKER_URL"],
    "LOOKERSDK_CLIENT_ID": os.environ["LOOKER_CLIENT_ID"],
    "LOOKERSDK_CLIENT_SECRET": os.environ["LOOKER_CLIENT_SECRET"],
    "LOOKERSDK_VERIFY_SSL": "true",
    "LOOKER_MODELS": os.environ.get("LOOKER_MODELS", '["thelook"]'),
}

try:
    remote_app = agent_engines.create(
        agent_engine=app,
        display_name="gemini-looker-agent",
        requirements=[
            "google-adk",
            "looker_sdk",
            "google-auth",
            "google-cloud-aiplatform[agent_engines,adk]",
            "requests",
            # If you switch the model to Claude via LiteLlm, also add "litellm".
        ],
        extra_packages=["./looker_app"],
        service_account=AGENT_SA,
        env_vars=env_vars,
    )
    # The shell script parses this exact line to capture the resource name.
    print(f"AGENT_ENGINE_RESOURCE_NAME={remote_app.resource_name}", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
DEPLOYEOF

# Export what deploy.py reads from the environment.
export PROJECT_ID REGION BUCKET_NAME AGENT_SA
export LOOKER_URL LOOKER_CLIENT_ID LOOKER_CLIENT_SECRET LOOKER_MODELS

# The deploy is long, so run it in the background and print a heartbeat with the
# latest log line every 15s. This keeps interactive terminals (e.g. Cloud Shell)
# from looking frozen or timing out on inactivity.
DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

python deploy.py > "$DEPLOY_LOG" 2>&1 &
DEPLOY_PID=$!
echo "Deploy running in background (PID: $DEPLOY_PID)"

ELAPSED=0
while kill -0 $DEPLOY_PID 2>/dev/null; do
  sleep 15
  ELAPSED=$((ELAPSED + 15))
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))
  LAST_LINE=$(tail -1 "$DEPLOY_LOG" 2>/dev/null || echo "...")
  echo "[${MINS}m${SECS}s] $LAST_LINE"
done

wait $DEPLOY_PID
DEPLOY_EXIT=$?

echo ""
echo "=== DEPLOY OUTPUT ==="
cat "$DEPLOY_LOG"
echo "====================="

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "ERROR: deploy failed (see output above; for runtime errors check Logs"
  echo "       Explorer -> resource type 'Vertex AI Reasoning Engine')."
  exit 1
fi

# Capture the Reasoning Engine resource name (three fallbacks, in order).
REASONING_ENGINE=$(grep "AGENT_ENGINE_RESOURCE_NAME=" "$DEPLOY_LOG" | tail -1 | cut -d= -f2- || true)

if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)
fi

if [ -z "$REASONING_ENGINE" ]; then
  cat > /tmp/extract_engine.py <<'PYPARSER'
import json, sys
try:
    d = json.load(sys.stdin)
    engines = [e for e in d.get('reasoningEngines', []) if e.get('displayName') == 'gemini-looker-agent']
    if engines:
        print(engines[-1]['name'])
except Exception:
    pass
PYPARSER
  REASONING_ENGINE=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
    | python3 /tmp/extract_engine.py)
fi

if [ -z "$REASONING_ENGINE" ]; then
  echo "ERROR: could not determine the Reasoning Engine resource name."
  exit 1
fi

echo "Reasoning Engine: $REASONING_ENGINE"

cd ..

echo ""
echo "=================================================="
echo " STEP 7: Register the agent in Gemini Enterprise"
echo "=================================================="
# Attach the deployed Reasoning Engine as an agent of your Gemini Enterprise
# app's default assistant (Discovery Engine API).
ACCESS_TOKEN=$(gcloud auth print-access-token)

# The API host depends on the engine location (global vs regional).
if [ "$ENGINE_LOCATION" = "global" ]; then
  API_ENDPOINT="discoveryengine.googleapis.com"
else
  API_ENDPOINT="${ENGINE_LOCATION}-discoveryengine.googleapis.com"
fi

AGENT_API_URL="https://${API_ENDPOINT}/v1alpha/projects/${PROJECT_NUMBER}/locations/${ENGINE_LOCATION}/collections/default_collection/engines/${AS_APP}/assistants/default_assistant/agents"

REQUEST_BODY=$(cat <<EOF
{
  "displayName": "${AGENT_DISPLAY_NAME}",
  "description": "${AGENT_DESCRIPTION}",
  "adk_agent_definition": {
    "tool_settings": {"tool_description": "${TOOL_DESCRIPTION}"},
    "provisioned_reasoning_engine": {"reasoning_engine": "${REASONING_ENGINE}"}
  }
}
EOF
)

echo "POST to: $AGENT_API_URL"

# Capture body + status code together so failures can be reported with detail.
HTTP_RESPONSE=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}" -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_NUMBER}" \
  "$AGENT_API_URL" -d "$REQUEST_BODY")

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep "__HTTP_STATUS__" | cut -d: -f2)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '/__HTTP_STATUS__/d')

echo "HTTP Status: $HTTP_STATUS"
echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "OK: agent registered in Gemini Enterprise"
else
  echo "ERROR: HTTP $HTTP_STATUS"
  exit 1
fi

echo ""
echo "=================================================="
echo " SETUP COMPLETE"
echo "=================================================="
echo ""
echo "  Reasoning Engine : $REASONING_ENGINE"
echo "  Agent SA         : $AGENT_SA"
echo "  Staging/Artifacts: gs://${BUCKET_NAME}"
echo ""
echo "Images  -> ADK artifacts (rendered natively in Gemini Enterprise)"
echo "Links   -> Looker-signed SSO embed URLs (created via the Looker API)"
echo "Data    -> Looker SDK queries (no middle tier)"
echo ""
echo "Try:"
echo "  - 'Show me dashboard 1'"
echo "  - 'Show me look 5'"
echo "  - 'Chart orders by status as a bar chart'"
echo "  - 'How many orders are there per status?'  (data answer, no image)"
echo "  - 'Give me the interactive link to dashboard 1'"
echo ""
echo "In Looker Admin > Embed (required for the interactive links):"
echo "  1. Enable 'Embed SSO Authentication' (and Reset Secret)."
echo "  2. Add the Gemini Enterprise domain to the embed allowlist."
echo "  3. Make sure the API user's role can access the model(s) in LOOKER_MODELS,"
echo "     otherwise data queries will return an access error."

