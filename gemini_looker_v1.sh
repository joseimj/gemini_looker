#!/bin/bash
# =============================================================================
#  gemini_looker_v1.sh
#  Agente Looker para Gemini Enterprise  ·  Autor: Jose Maldonado (@joseimj)
# =============================================================================
#
#  QUE HACE ESTE SCRIPT
#  --------------------
#  Despliega, de punta a punta e idempotentemente, un agente conversacional de
#  Looker sobre Google Cloud y lo registra en Gemini Enterprise. Al terminar,
#  un usuario puede pedir en lenguaje natural "muestrame el dashboard 1" o
#  "cuantas ordenes hay por estado" y recibir la imagen del grafico (o la tabla
#  de datos) + un link interactivo a Looker, dentro del chat de Gemini Enterprise.
#
#  ARQUITECTURA (v8) - deliberadamente minima
#  ------------------------------------------
#    Gemini Enterprise (UI)
#        -> Agent Engine (ADK LlmAgent + Looker SDK + artifacts + firma SSO)
#            -> Looker API
#
#  SIN Cloud Run, SIN Redis, SIN VPC, SIN MCP, SIN ID tokens. El agente habla
#  con Looker directo via SDK usando las mismas credenciales por env var.
#
#  POR QUE ESTA ARQUITECTURA (dos bugs que la v8 resuelve)
#  -------------------------------------------------------
#  BUG 1 - "las imagenes nunca renderizaban"
#    Antes la imagen se devolvia como data URI base64 dentro de un campo
#    "markdown" y se le pedia al LLM repetir esa cadena caracter por caracter.
#    Es inviable:
#      - un PNG real son cientos de KB -> base64 son cientos de miles de tokens,
#        muy por encima del limite de salida del modelo (se trunca -> img rota)
#      - los LLM no reproducen cadenas opacas largas de forma fiable
#      - el frontend ademas suele bloquear img-src data: por CSP
#    v8 usa ADK Artifacts: la tool guarda los bytes PNG con
#    tool_context.save_artifact() y el agente llama a load_artifacts_tool. Los
#    bytes NUNCA pasan por la salida de texto del LLM; el runtime de Agent
#    Engine los renderiza nativamente en Gemini Enterprise.
#
#  BUG 2 - "a veces no respondia hasta el 2do o 3er intento"
#    Antes el agente hablaba con un toolbox MCP en Cloud Run usando un ID token
#    calculado UNA sola vez al construir el agente. Ese token caduca a ~1h, ADK
#    no lo refresca, y cuando Cloud Run responde 401 ADK se cuelga hasta el
#    timeout en vez de fallar limpio -> "no responde"; al reintentar caia en una
#    instancia fria con token fresco -> funcionaba. v8 ELIMINA la capa MCP +
#    Cloud Run: cero ID tokens, cero invoker IAM, cero cold-start, cero ese bug.
#
#  PASOS (en orden, idempotentes)
#  ------------------------------
#    -1 Validar variables      4 Service account + IAM minimo
#     0 Autenticacion           5 Bucket staging/artifacts
#     1 Habilitar APIs          6 App del agente (ADK)
#     2 (ver paso 4)            7 Deploy a Agent Engine (~15-20 min)
#     3 (ver paso 5)            8 Registro en Gemini Enterprise
#
#  NOTA: el modelo (gemini-2.5-flash) es intercambiable. ADK es agnostico de
#  modelo; puedes usar Claude Sonnet, Llama, etc. via Vertex AI Model Garden o
#  la integracion LiteLLM, cambiando esencialmente una linea en agent.py.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES ANTES DE EJECUTAR
# (el PASO -1 aborta si alguna sigue con un valor YOUR_*)
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"          # unico bucket: staging del deploy + artifacts
BUCKET_LOCATION="US"

# --- Looker (credenciales API + embed) ---
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"   # para firmar los links SSO interactivos
LOOKER_EMBED_HASH="sha1"                          # sha1 (secreto creado por UI) o sha256 (por API)
LOOKER_MODELS='["thelook"]'                       # modelos LookML habilitados para embed

# --- Gemini Enterprise ---
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"          # ID del agente ya creado en Gemini Enterprise
ENGINE_LOCATION="us"                              # "us", "eu" o "global"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker agent that renders dashboards/charts as inline images and answers data questions."
TOOL_DESCRIPTION="Use this tool to answer questions about Looker data and display dashboards/charts as inline images."
# =============================================================================

# Reset defensivo: limpia cualquier valor heredado del entorno para que el
# script sea reproducible aunque se ejecute en una shell ya "sucia".
unset AGENT_SA AGENT_SA_NAME
unset REASONING_ENGINE
unset DEPLOY_LOG DEPLOY_PID DEPLOY_EXIT
unset ACCESS_TOKEN API_ENDPOINT AGENT_API_URL REQUEST_BODY
unset HTTP_RESPONSE HTTP_STATUS RESPONSE_BODY
unset ELAPSED MINS SECS LAST_LINE

# Aborta temprano si una variable obligatoria quedo sin configurar.
validate_var() {
  local var_name="$1"
  local var_value="$2"
  if [[ -z "$var_value" || "$var_value" == YOUR_* ]]; then
    echo "ERROR: La variable '$var_name' no esta configurada."
    exit 1
  fi
}

echo ""
echo "=================================================="
echo " PASO -1: Validar variables"
echo "=================================================="
validate_var "PROJECT_ID" "$PROJECT_ID"
validate_var "PROJECT_NUMBER" "$PROJECT_NUMBER"
validate_var "BUCKET_NAME" "$BUCKET_NAME"
validate_var "LOOKER_URL" "$LOOKER_URL"
validate_var "LOOKER_CLIENT_ID" "$LOOKER_CLIENT_ID"
validate_var "LOOKER_CLIENT_SECRET" "$LOOKER_CLIENT_SECRET"
validate_var "LOOKER_EMBED_SECRET" "$LOOKER_EMBED_SECRET"
validate_var "AS_APP" "$AS_APP"
echo "OK: Variables configuradas."

echo ""
echo "=================================================="
echo " PASO 0: Autenticacion"
echo "=================================================="
# Muestra la identidad activa y fija el proyecto por defecto para gcloud.
gcloud auth list
gcloud config set project "$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 1: Habilitar APIs"
echo "=================================================="
# Solo lo necesario para esta arquitectura. Notar que NO se habilitan
# run / cloudbuild / artifactregistry / secretmanager: la v8 no usa Cloud Run.
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
echo " PASO 2: Service account del agente y permisos minimos"
echo "=================================================="

# Unico service account necesario en la v8 (antes habia tambien uno para el
# toolbox de Cloud Run, ya eliminado). El agente corre con esta identidad.
AGENT_SA_NAME="looker-agent-sa"
AGENT_SA="${AGENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$AGENT_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$AGENT_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker Agent Engine SA"
fi
echo "SA Agente: $AGENT_SA"

echo ""
echo "Asignando permisos al SA del Agente (principio de minimo privilegio)..."

# 1. Correr como Agent Engine (invocar modelos / runtime de Vertex AI).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/aiplatform.user" \
  --condition=None &>/dev/null
echo "  [OK] aiplatform.user"

# 2. Escribir logs (observabilidad del agente en runtime).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
echo "  [OK] logging.logWriter"

# 3. Leer/escribir objetos: staging del deploy + guardado de los ARTIFACTS de
#    imagen (save_artifact escribe los PNG que luego renderiza Gemini Enterprise).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/storage.objectUser" \
  --condition=None &>/dev/null
echo "  [OK] storage.objectUser (staging + artifacts)"

echo "Permisos minimos del SA del agente asignados."

echo ""
echo "=================================================="
echo " PASO 3: Bucket staging (deploy + artifacts)"
echo "=================================================="
# Un solo bucket cubre el staging del paquete del agente y el almacenamiento de
# artifacts. Idempotente: si ya existe, no lo recrea.
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
  echo "Bucket creado: gs://${BUCKET_NAME}"
else
  echo "Bucket ya existe."
fi

echo ""
echo "=================================================="
echo " PASO 4: Entorno Python (limpio)"
echo "=================================================="
# Entorno virtual aislado para construir y desplegar el agente. Se recrea desde
# cero (rm -rf) para evitar arrastrar dependencias de corridas anteriores.
rm -rf my-agents
mkdir -p my-agents && cd my-agents

python3 -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet google-adk looker-sdk
pip install --quiet --upgrade "google-cloud-aiplatform[agent_engines,adk]"

echo ""
echo "=================================================="
echo " PASO 5: Crear aplicacion del agente"
echo "=================================================="
mkdir -p looker_app

# __init__.py: expone el modulo agent al empaquetar con extra_packages.
cat > looker_app/__init__.py <<'EOF'
from . import agent
EOF

# .env: solo para pruebas locales con `adk web`. En produccion las credenciales
# se inyectan como env_vars en agent_engines.create() (ver PASO 6 / deploy.py).
cat > looker_app/.env <<EOF
LOOKERSDK_BASE_URL=${LOOKER_URL}
LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID}
LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET}
LOOKERSDK_VERIFY_SSL=true
LOOKER_EMBED_SECRET=${LOOKER_EMBED_SECRET}
LOOKER_EMBED_HASH=sha1
LOOKER_MODELS=${LOOKER_MODELS}
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
looker_sdk
google-auth
requests
EOF

# ---------------------------------------------------------------------------
# agent.py - logica del agente (ADK). Se escribe via heredoc 'PYEOF' (comillas
# simples) para que bash NO interpole nada: el archivo es Python puro.
# ---------------------------------------------------------------------------
cat > looker_app/agent.py <<'PYEOF'
"""Agente Looker para Gemini Enterprise (v8).

Diseno:
  - Consulta Looker DIRECTO con looker_sdk (sin MCP, sin Cloud Run, sin ID tokens).
  - Las imagenes se entregan como ADK Artifacts (no como base64 en texto), que es
    la unica forma fiable de renderizarlas inline en Gemini Enterprise.
  - Las credenciales llegan por variables de entorno (mismas para el SDK).

El modelo del agente es intercambiable: ADK es agnostico de modelo. Para usar
Claude/Llama, sustituir el string del modelo por un LiteLlm(...) (Vertex AI
Model Garden o LiteLLM) en la definicion de LlmAgent al final del archivo.
"""

import os
import time
import json
import hmac
import base64
import hashlib
import binascii
from urllib.parse import quote_plus

import looker_sdk
from looker_sdk import models40

from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools import ToolContext
from google.adk.tools.load_artifacts_tool import load_artifacts_tool
from google.genai.types import ThinkingConfig, Part

# -----------------------------------------------------------------------------
# Config desde env vars (mismas credenciales para SDK; sin MCP, sin ID tokens)
# -----------------------------------------------------------------------------
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "").replace("http://", "").rstrip("/")
)
EMBED_SECRET = os.environ.get("LOOKER_EMBED_SECRET", "")
# Algoritmo de firma del embed secret: "sha1" si el secreto se creo por la UI de
# Looker (lo mas comun), "sha256" si se creo por API. Si el link da 401 de firma,
# prueba cambiando este valor.
EMBED_HASH = os.environ.get("LOOKER_EMBED_HASH", "sha1").lower()
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')


# -----------------------------------------------------------------------------
# Signed SSO Embed URL para Looker (link interactivo opcional bajo la imagen).
#
# IMPORTANTE: firmamos LOCALMENTE (HMAC), NO con create_sso_embed_url. Llamar al
# SDK aqui agrega un round-trip de red a Looker EN CADA render, y si esa llamada
# se pone lenta o falla cuelga la tool entera -> timeout (la imagen ya estaba
# lista pero el link la arrastra). La firma local es instantanea y sin red.
#
# La firma sigue la implementacion de referencia oficial de Looker
# (github.com/looker/looker_embed_sso_examples, python_example.py). Detalles que
# son criticos y que la version anterior tenia mal:
#   - La URL va a /login/embed/<embed_path URL-encoded>, NO a /embed/...
#   - El embed_path codificado (quote_plus, hex en MAYUSCULAS) es el MISMO string
#     que se firma y que va en la URL.
#   - nonce, time, session_length y los campos de usuario van JSON-encoded, en un
#     ORDEN EXACTO en string_to_sign (incluye external_group_id, que faltaba).
#   - La firma base64 se URL-encodea (quote_plus) al ponerla en el querystring.
#   - Algoritmo segun el secreto: SHA-1 (UI) o SHA-256 (API) -> ver EMBED_HASH.
#
# Va envuelto en try/except: si algo falla, devuelve un link normal (sin firmar)
# y NUNCA rompe ni demora la imagen.
#
# Requisitos en Looker (sin esto, ninguna firma sirve):
#   - Admin > Embed: "Embed SSO Authentication" = Enabled (+ Reset Secret).
#   - El dominio desde el que se abre el link, en el allowlist de embed.
# -----------------------------------------------------------------------------
def _generate_signed_embed_url(target_path: str, external_user_id: str = "gemini-user") -> str:
    # Sin secreto no podemos firmar: devolvemos el link normal de la UI.
    fallback = f"https://{LOOKER_HOST}{target_path}"
    if not EMBED_SECRET:
        return fallback

    try:
        # path: el MISMO valor se firma y se usa en la URL final.
        path = "/login/embed/" + quote_plus(target_path)

        # Todos estos campos van JSON-encoded (asi lo exige el contrato de Looker).
        nonce = json.dumps(binascii.hexlify(os.urandom(16)).decode("ascii"))
        t = json.dumps(int(time.time()))
        session_length = json.dumps(3600)
        ext_user_id = json.dumps(external_user_id)
        permissions = json.dumps([
            "access_data", "see_looks",
            "see_user_dashboards", "see_lookml_dashboards", "explore",
        ])
        models = json.dumps(json.loads(LOOKER_MODELS_ENV))   # normaliza el formato
        group_ids = json.dumps([])
        external_group_id = json.dumps("")
        user_attributes = json.dumps({})
        access_filters = json.dumps({})
        first_name = json.dumps("Gemini")
        last_name = json.dumps("User")
        force_logout_login = json.dumps(True)

        # ORDEN EXACTO - no reordenar.
        string_to_sign = "\n".join([
            LOOKER_HOST, path, nonce, t, session_length,
            ext_user_id, permissions, models,
            group_ids, external_group_id, user_attributes, access_filters,
        ])

        algo = hashlib.sha256 if EMBED_HASH == "sha256" else hashlib.sha1
        signature = base64.b64encode(
            hmac.new(EMBED_SECRET.encode("utf-8"),
                     string_to_sign.encode("utf-8"), algo).digest()
        ).decode("ascii")

        params = {
            "nonce": nonce, "time": t, "session_length": session_length,
            "external_user_id": ext_user_id, "permissions": permissions,
            "models": models, "group_ids": group_ids,
            "external_group_id": external_group_id, "user_attributes": user_attributes,
            "access_filters": access_filters, "signature": signature,
            "first_name": first_name, "last_name": last_name,
            "force_logout_login": force_logout_login,
        }
        # quote_plus tambien sobre la firma -> '+' se vuelve '%2B', etc.
        query = "&".join(f"{k}={quote_plus(v)}" for k, v in params.items())
        return f"https://{LOOKER_HOST}{path}?{query}"
    except Exception:
        # El link nunca debe tumbar la imagen.
        return fallback


# =============================================================================
# TOOLS DE IMAGEN  (via ADK Artifacts -> render nativo en Gemini Enterprise)
#
# Patron clave: cada tool renderiza el PNG, lo guarda con save_artifact() y
# DEVUELVE solo el nombre del artifact. Los bytes NO viajan en el texto del LLM.
# El agente luego llama a load_artifacts (incluido en tools) para mostrarlo.
# =============================================================================
async def show_dashboard_inline(dashboard_id: str, tool_context: ToolContext) -> dict:
    """Renderiza un dashboard de Looker como imagen y la guarda como artifact.

    Args:
        dashboard_id: ID numerico del dashboard.
    Returns:
        Dict con artifact_filename (a mostrar con load_artifacts) e interactive_url.
    """
    sdk = looker_sdk.init40()

    # El render de dashboards es asincrono en Looker: se crea un "render task" y
    # se hace polling hasta success/failure.
    task = sdk.create_dashboard_render_task(
        dashboard_id=dashboard_id,
        result_format="png",
        body=models40.CreateDashboardRenderTask(
            dashboard_style="tiled", dashboard_filters=""
        ),
        width=1200, height=800,
    )

    # Polling con tope de 90s. Dashboards muy pesados pueden no alcanzar a
    # terminar; en ese caso devolvemos un error claro en vez de colgarnos.
    waited = 0
    while waited < 90:
        status = sdk.render_task(task.id)
        if status.status == "success":
            break
        if status.status == "failure":
            return {"status": "error", "message": f"Render fallo para dashboard {dashboard_id}"}
        time.sleep(2)
        waited += 2
    else:
        return {"status": "error", "message": f"Timeout renderizando dashboard {dashboard_id}"}

    png_bytes = sdk.render_task_results(task.id)   # bytes crudos, NO base64
    filename = f"dashboard_{dashboard_id}.png"

    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"No se pudo guardar el artifact: {e}"}

    return {
        "status": "success",
        "artifact_filename": filename,
        "interactive_url": _generate_signed_embed_url(f"/embed/dashboards/{dashboard_id}"),
        "next_step": "Call load_artifacts with this filename to display the image, then add the interactive_url as a link.",
    }


async def show_look_inline(look_id: str, tool_context: ToolContext) -> dict:
    """Renderiza un Look (chart guardado) como imagen y la guarda como artifact.

    Args:
        look_id: ID numerico del Look.
    """
    sdk = looker_sdk.init40()

    # run_look con result_format="png" es sincrono: devuelve los bytes directo.
    try:
        png_bytes = sdk.run_look(
            look_id=look_id, result_format="png",
            image_width=1000, image_height=700,
        )
    except Exception as e:
        return {"status": "error", "message": f"Error al renderizar Look {look_id}: {e}"}

    filename = f"look_{look_id}.png"
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"No se pudo guardar el artifact: {e}"}

    return {
        "status": "success",
        "artifact_filename": filename,
        "interactive_url": _generate_signed_embed_url(f"/embed/looks/{look_id}"),
        "next_step": "Call load_artifacts with this filename to display the image, then add the interactive_url as a link.",
    }


async def show_query_inline(
    model: str, explore: str, fields: list, tool_context: ToolContext,
    vis_type: str = "looker_column",
) -> dict:
    """Crea una query ad-hoc, la renderiza como grafico y la guarda como artifact.

    Args:
        model: Modelo LookML (ej: "thelook").
        explore: Explore (ej: "order_items").
        fields: Lista de campos LookML.
        vis_type: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.
    """
    sdk = looker_sdk.init40()

    try:
        # Se crea la query con vis_config para que el render salga como grafico.
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
        return {"status": "error", "message": f"Error al ejecutar/renderizar query: {e}"}

    filename = f"query_{model}_{explore}.png".replace("/", "_")
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"No se pudo guardar el artifact: {e}"}

    return {
        "status": "success",
        "artifact_filename": filename,
        "interactive_url": _generate_signed_embed_url(
            f"/embed/explore/{model}/{explore}?qid={query.client_id}"
        ),
        "next_step": "Call load_artifacts with this filename to display the chart, then add the interactive_url as a link.",
    }


# =============================================================================
# TOOLS DE DATOS  (looker_sdk directo; reemplazan al antiguo toolbox MCP)
# Devuelven datos/estructura como JSON; el agente los resume en texto o tabla.
# =============================================================================
def query_looker_data(
    model: str, explore: str, fields: list,
    filters: dict = None, sorts: list = None, limit: int = 100,
) -> dict:
    """Ejecuta una query en Looker y devuelve las filas como JSON (sin imagen).

    Usar para responder preguntas de datos en texto/tabla.

    Args:
        model: Modelo LookML (ej: "thelook").
        explore: Explore (ej: "order_items").
        fields: Lista de campos LookML (ej: ["order_items.status", "order_items.count"]).
        filters: Dict opcional de filtros (ej: {"order_items.status": "complete"}).
        sorts: Lista opcional de ordenamientos (ej: ["order_items.count desc"]).
        limit: Maximo de filas (default 100).
    """
    sdk = looker_sdk.init40()
    try:
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                filters=filters or {}, sorts=sorts or [],
                limit=str(limit),
            )
        )
        rows = sdk.run_query(query_id=str(query.id), result_format="json")
        data = json.loads(rows) if isinstance(rows, str) else rows
        return {"status": "success", "row_count": len(data), "rows": data}
    except Exception as e:
        return {"status": "error", "message": f"Error en query: {e}"}


def list_looker_fields(model: str, explore: str) -> dict:
    """Lista dimensiones y medidas de un explore (para que el agente arme queries)."""
    sdk = looker_sdk.init40()
    try:
        exp = sdk.lookml_model_explore(lookml_model_name=model, explore_name=explore)
        dims = [f.name for f in (exp.fields.dimensions or [])] if exp.fields else []
        meas = [f.name for f in (exp.fields.measures or [])] if exp.fields else []
        return {"status": "success", "dimensions": dims, "measures": meas}
    except Exception as e:
        return {"status": "error", "message": f"Error listando campos: {e}"}


def list_available_dashboards(search_term: str = "") -> dict:
    """Lista dashboards disponibles en Looker (id + titulo), opcionalmente filtrados."""
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)

    if not dashboards:
        return {"status": "success", "dashboards": []}

    items = [{"id": str(d.id), "title": d.title} for d in dashboards]
    return {"status": "success", "dashboards": items}


# =============================================================================
# Definicion del agente ADK
#  - model: intercambiable (ver docstring del modulo).
#  - instruction: enseña el patron "renderiza -> load_artifacts -> link".
#  - planner: thinking desactivado (thinking_budget=0) para respuestas directas.
#  - tools: imagenes + datos + load_artifacts_tool (el que muestra el artifact).
# =============================================================================
root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Looker agent: renders dashboards/charts as inline images (ADK artifacts) and answers data questions via the Looker SDK.',
    instruction=(
        'You are a Looker data agent inside Gemini Enterprise.\n\n'
        'HOW TO SHOW IMAGES (dashboards / looks / charts):\n'
        '1. Call the matching tool: show_dashboard_inline, show_look_inline, or '
        'show_query_inline. Each one renders the image and SAVES it as an artifact, '
        'returning an "artifact_filename".\n'
        '2. Then call load_artifacts with that filename so the image is displayed '
        'inline in the chat. This is the ONLY way the image renders - never try to '
        'output image bytes or base64 yourself.\n'
        '3. After the image, add a short caption and the "interactive_url" as a '
        'markdown link "[Abrir version interactiva en Looker](URL)".\n\n'
        'HOW TO ANSWER DATA QUESTIONS (numbers, no chart needed):\n'
        '- Use query_looker_data(model, explore, fields, ...) and summarize the '
        'returned rows in plain text or a small markdown table.\n'
        '- If unsure which fields exist, call list_looker_fields(model, explore) first.\n'
        '- To find dashboards by name, use list_available_dashboards.\n\n'
        'If a tool returns status="error", tell the user the message plainly and '
        'suggest a fix (e.g. wrong id, field name, or model).\n\n'
        'Defaults when unsure: model="thelook", explore="order_items".\n'
        'vis_type options: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.'
    ),
    planner=BuiltInPlanner(
        thinking_config=ThinkingConfig(include_thoughts=False, thinking_budget=0)
    ),
    tools=[
        show_dashboard_inline,
        show_look_inline,
        show_query_inline,
        query_looker_data,
        list_looker_fields,
        list_available_dashboards,
        load_artifacts_tool,   # <-- el que efectivamente renderiza los artifacts en el chat
    ],
)
PYEOF

echo "Agente creado (sin MCP, imagenes via artifacts)."

echo ""
echo "=================================================="
echo " PASO 6: Deploy a Agent Engine (Python SDK)"
echo "  (tarda 15-20 min, usando SA: $AGENT_SA)"
echo "=================================================="

# deploy.py empaqueta el agente y lo crea como Reasoning Engine en Vertex AI.
# Las credenciales de Looker se inyectan aqui como env_vars (no se hornean en
# el codigo). AdkApp en Agent Engine provee session + artifact service
# gestionados, por lo que save_artifact() funciona en runtime sin config extra.
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

vertexai.init(
    project=PROJECT_ID,
    location=REGION,
    staging_bucket=STAGING_BUCKET,
)

print(f"Desplegando agente con SA: {AGENT_SA}", flush=True)
print(f"Staging bucket: {STAGING_BUCKET}", flush=True)

app = reasoning_engines.AdkApp(agent=root_agent, enable_tracing=True)

env_vars = {
    "LOOKERSDK_BASE_URL": os.environ["LOOKER_URL"],
    "LOOKERSDK_CLIENT_ID": os.environ["LOOKER_CLIENT_ID"],
    "LOOKERSDK_CLIENT_SECRET": os.environ["LOOKER_CLIENT_SECRET"],
    "LOOKERSDK_VERIFY_SSL": "true",
    "LOOKER_EMBED_SECRET": os.environ["LOOKER_EMBED_SECRET"],
    "LOOKER_EMBED_HASH": os.environ.get("LOOKER_EMBED_HASH", "sha1"),
    "LOOKER_MODELS": os.environ.get("LOOKER_MODELS", '["thelook"]'),
}

try:
    remote_app = agent_engines.create(
        agent_engine=app,
        display_name="looker-agent1",
        requirements=[
            "google-adk",
            "looker_sdk",
            "google-auth",
            "google-cloud-aiplatform[agent_engines,adk]",
            "requests",
        ],
        extra_packages=["./looker_app"],
        service_account=AGENT_SA,
        env_vars=env_vars,
    )
    # Esta linea es la que el script de bash parsea para obtener el recurso.
    print(f"AGENT_ENGINE_RESOURCE_NAME={remote_app.resource_name}", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
DEPLOYEOF

# Exporta lo que deploy.py lee desde os.environ.
export PROJECT_ID REGION BUCKET_NAME AGENT_SA
export LOOKER_URL LOOKER_CLIENT_ID LOOKER_CLIENT_SECRET
export LOOKER_EMBED_SECRET LOOKER_MODELS LOOKER_EMBED_HASH

# El deploy es largo: se corre en background y se imprime un "latido" cada 15s
# con la ultima linea del log, para que la terminal (p.ej. Cloud Shell) no
# parezca colgada y no expire por inactividad.
DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

python deploy.py > "$DEPLOY_LOG" 2>&1 &
DEPLOY_PID=$!
echo "Deploy en background (PID: $DEPLOY_PID)"

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
echo "=== OUTPUT DEL DEPLOY ==="
cat "$DEPLOY_LOG"
echo "========================="

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "ERROR: Deploy fallo"
  exit 1
fi

# --- Obtener el resource name del Reasoning Engine (3 metodos, en cascada) ---
# 1) Linea explicita que imprimio deploy.py.
REASONING_ENGINE=$(grep "AGENT_ENGINE_RESOURCE_NAME=" "$DEPLOY_LOG" | tail -1 | cut -d= -f2- || true)

# 2) Regex sobre el log por si la linea anterior no esta.
if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)
fi

# 3) Ultimo recurso: consultar la API de reasoningEngines y filtrar por display name.
if [ -z "$REASONING_ENGINE" ]; then
  cat > /tmp/extract_engine.py <<'PYPARSER'
import json, sys
try:
    d = json.load(sys.stdin)
    engines = [e for e in d.get('reasoningEngines', []) if e.get('displayName') == 'looker-agent1']
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
  echo "ERROR: No se pudo obtener Reasoning Engine"
  exit 1
fi

echo "Reasoning Engine: $REASONING_ENGINE"

cd ..

echo ""
echo "=================================================="
echo " PASO 7: Registrar en Gemini Enterprise"
echo "=================================================="
# Asocia el Reasoning Engine recien creado como un agente del assistant por
# defecto de tu app de Gemini Enterprise (Discovery Engine API).
ACCESS_TOKEN=$(gcloud auth print-access-token)

# El host de la API depende de la location del engine (global vs regional).
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

echo "POST a: $AGENT_API_URL"

# Se captura cuerpo + status code juntos para poder reportar errores con detalle.
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
  echo "OK: Agente registrado en Gemini Enterprise"
else
  echo "ERROR HTTP $HTTP_STATUS"
  exit 1
fi

echo ""
echo "=================================================="
echo " SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Reasoning Engine : $REASONING_ENGINE"
echo "  Agent SA         : $AGENT_SA"
echo "  Staging/Artifacts: gs://${BUCKET_NAME}"
echo ""
echo "Imagenes -> ADK Artifacts (render nativo en Gemini Enterprise)"
echo "Datos    -> looker_sdk directo (sin MCP / sin Cloud Run / sin ID tokens)"
echo ""
echo "Prueba con:"
echo "  - 'Muestrame el dashboard 1'"
echo "  - 'Ensename el Look 5'"
echo "  - 'Visualiza ordenes por estado como grafico de barras'"
echo "  - 'Cuantas ordenes hay por estado?' (respuesta en datos, sin imagen)"
echo ""
echo "Configuracion manual en Looker Admin > Embed (para los links interactivos):"
echo "  1. ACTIVAR 'Embed SSO Authentication'"
echo "  2. Agregar el dominio de Gemini Enterprise al allowlist"

#!/bin/bash
# =============================================================================
#  looker_gemini_setup_v8.sh
#  Agente Looker para Gemini Enterprise  ·  Autor: Jose Maldonado (@joseimj)
# =============================================================================
#
#  QUE HACE ESTE SCRIPT
#  --------------------
#  Despliega, de punta a punta e idempotentemente, un agente conversacional de
#  Looker sobre Google Cloud y lo registra en Gemini Enterprise. Al terminar,
#  un usuario puede pedir en lenguaje natural "muestrame el dashboard 1" o
#  "cuantas ordenes hay por estado" y recibir la imagen del grafico (o la tabla
#  de datos) + un link interactivo a Looker, dentro del chat de Gemini Enterprise.
#
#  ARQUITECTURA (v8) - deliberadamente minima
#  ------------------------------------------
#    Gemini Enterprise (UI)
#        -> Agent Engine (ADK LlmAgent + Looker SDK + artifacts + firma SSO)
#            -> Looker API
#
#  SIN Cloud Run, SIN Redis, SIN VPC, SIN MCP, SIN ID tokens. El agente habla
#  con Looker directo via SDK usando las mismas credenciales por env var.
#
#  POR QUE ESTA ARQUITECTURA (dos bugs que la v8 resuelve)
#  -------------------------------------------------------
#  BUG 1 - "las imagenes nunca renderizaban"
#    Antes la imagen se devolvia como data URI base64 dentro de un campo
#    "markdown" y se le pedia al LLM repetir esa cadena caracter por caracter.
#    Es inviable:
#      - un PNG real son cientos de KB -> base64 son cientos de miles de tokens,
#        muy por encima del limite de salida del modelo (se trunca -> img rota)
#      - los LLM no reproducen cadenas opacas largas de forma fiable
#      - el frontend ademas suele bloquear img-src data: por CSP
#    v8 usa ADK Artifacts: la tool guarda los bytes PNG con
#    tool_context.save_artifact() y el agente llama a load_artifacts_tool. Los
#    bytes NUNCA pasan por la salida de texto del LLM; el runtime de Agent
#    Engine los renderiza nativamente en Gemini Enterprise.
#
#  BUG 2 - "a veces no respondia hasta el 2do o 3er intento"
#    Antes el agente hablaba con un toolbox MCP en Cloud Run usando un ID token
#    calculado UNA sola vez al construir el agente. Ese token caduca a ~1h, ADK
#    no lo refresca, y cuando Cloud Run responde 401 ADK se cuelga hasta el
#    timeout en vez de fallar limpio -> "no responde"; al reintentar caia en una
#    instancia fria con token fresco -> funcionaba. v8 ELIMINA la capa MCP +
#    Cloud Run: cero ID tokens, cero invoker IAM, cero cold-start, cero ese bug.
#
#  PASOS (en orden, idempotentes)
#  ------------------------------
#    -1 Validar variables      4 Service account + IAM minimo
#     0 Autenticacion           5 Bucket staging/artifacts
#     1 Habilitar APIs          6 App del agente (ADK)
#     2 (ver paso 4)            7 Deploy a Agent Engine (~15-20 min)
#     3 (ver paso 5)            8 Registro en Gemini Enterprise
#
#  NOTA: el modelo (gemini-2.5-flash) es intercambiable. ADK es agnostico de
#  modelo; puedes usar Claude Sonnet, Llama, etc. via Vertex AI Model Garden o
#  la integracion LiteLLM, cambiando esencialmente una linea en agent.py.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURA ESTAS VARIABLES ANTES DE EJECUTAR
# (el PASO -1 aborta si alguna sigue con un valor YOUR_*)
# =============================================================================
PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
REGION="us-central1"
BUCKET_NAME="YOUR_GCS_BUCKET_NAME"          # unico bucket: staging del deploy + artifacts
BUCKET_LOCATION="US"

# --- Looker (credenciales API + embed) ---
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="YOUR_LOOKER_CLIENT_ID"
LOOKER_CLIENT_SECRET="YOUR_LOOKER_CLIENT_SECRET"
LOOKER_EMBED_SECRET="YOUR_LOOKER_EMBED_SECRET"   # para firmar los links SSO interactivos
LOOKER_EMBED_HASH="sha1"                          # sha1 (secreto creado por UI) o sha256 (por API)
LOOKER_MODELS='["thelook"]'                       # modelos LookML habilitados para embed

# --- Gemini Enterprise ---
AS_APP="YOUR_GEMINI_ENTERPRISE_AGENT_ID"          # ID del agente ya creado en Gemini Enterprise
ENGINE_LOCATION="us"                              # "us", "eu" o "global"
AGENT_DISPLAY_NAME="Looker Agent"
AGENT_DESCRIPTION="Looker agent that renders dashboards/charts as inline images and answers data questions."
TOOL_DESCRIPTION="Use this tool to answer questions about Looker data and display dashboards/charts as inline images."
# =============================================================================

# Reset defensivo: limpia cualquier valor heredado del entorno para que el
# script sea reproducible aunque se ejecute en una shell ya "sucia".
unset AGENT_SA AGENT_SA_NAME
unset REASONING_ENGINE
unset DEPLOY_LOG DEPLOY_PID DEPLOY_EXIT
unset ACCESS_TOKEN API_ENDPOINT AGENT_API_URL REQUEST_BODY
unset HTTP_RESPONSE HTTP_STATUS RESPONSE_BODY
unset ELAPSED MINS SECS LAST_LINE

# Aborta temprano si una variable obligatoria quedo sin configurar.
validate_var() {
  local var_name="$1"
  local var_value="$2"
  if [[ -z "$var_value" || "$var_value" == YOUR_* ]]; then
    echo "ERROR: La variable '$var_name' no esta configurada."
    exit 1
  fi
}

echo ""
echo "=================================================="
echo " PASO -1: Validar variables"
echo "=================================================="
validate_var "PROJECT_ID" "$PROJECT_ID"
validate_var "PROJECT_NUMBER" "$PROJECT_NUMBER"
validate_var "BUCKET_NAME" "$BUCKET_NAME"
validate_var "LOOKER_URL" "$LOOKER_URL"
validate_var "LOOKER_CLIENT_ID" "$LOOKER_CLIENT_ID"
validate_var "LOOKER_CLIENT_SECRET" "$LOOKER_CLIENT_SECRET"
validate_var "LOOKER_EMBED_SECRET" "$LOOKER_EMBED_SECRET"
validate_var "AS_APP" "$AS_APP"
echo "OK: Variables configuradas."

echo ""
echo "=================================================="
echo " PASO 0: Autenticacion"
echo "=================================================="
# Muestra la identidad activa y fija el proyecto por defecto para gcloud.
gcloud auth list
gcloud config set project "$PROJECT_ID"

echo ""
echo "=================================================="
echo " PASO 1: Habilitar APIs"
echo "=================================================="
# Solo lo necesario para esta arquitectura. Notar que NO se habilitan
# run / cloudbuild / artifactregistry / secretmanager: la v8 no usa Cloud Run.
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
echo " PASO 2: Service account del agente y permisos minimos"
echo "=================================================="

# Unico service account necesario en la v8 (antes habia tambien uno para el
# toolbox de Cloud Run, ya eliminado). El agente corre con esta identidad.
AGENT_SA_NAME="looker-agent-sa"
AGENT_SA="${AGENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$AGENT_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create "$AGENT_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Looker Agent Engine SA"
fi
echo "SA Agente: $AGENT_SA"

echo ""
echo "Asignando permisos al SA del Agente (principio de minimo privilegio)..."

# 1. Correr como Agent Engine (invocar modelos / runtime de Vertex AI).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/aiplatform.user" \
  --condition=None &>/dev/null
echo "  [OK] aiplatform.user"

# 2. Escribir logs (observabilidad del agente en runtime).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/logging.logWriter" \
  --condition=None &>/dev/null
echo "  [OK] logging.logWriter"

# 3. Leer/escribir objetos: staging del deploy + guardado de los ARTIFACTS de
#    imagen (save_artifact escribe los PNG que luego renderiza Gemini Enterprise).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/storage.objectUser" \
  --condition=None &>/dev/null
echo "  [OK] storage.objectUser (staging + artifacts)"

echo "Permisos minimos del SA del agente asignados."

echo ""
echo "=================================================="
echo " PASO 3: Bucket staging (deploy + artifacts)"
echo "=================================================="
# Un solo bucket cubre el staging del paquete del agente y el almacenamiento de
# artifacts. Idempotente: si ya existe, no lo recrea.
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$BUCKET_LOCATION"
  echo "Bucket creado: gs://${BUCKET_NAME}"
else
  echo "Bucket ya existe."
fi

echo ""
echo "=================================================="
echo " PASO 4: Entorno Python (limpio)"
echo "=================================================="
# Entorno virtual aislado para construir y desplegar el agente. Se recrea desde
# cero (rm -rf) para evitar arrastrar dependencias de corridas anteriores.
rm -rf my-agents
mkdir -p my-agents && cd my-agents

python3 -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet google-adk looker-sdk
pip install --quiet --upgrade "google-cloud-aiplatform[agent_engines,adk]"

echo ""
echo "=================================================="
echo " PASO 5: Crear aplicacion del agente"
echo "=================================================="
mkdir -p looker_app

# __init__.py: expone el modulo agent al empaquetar con extra_packages.
cat > looker_app/__init__.py <<'EOF'
from . import agent
EOF

# .env: solo para pruebas locales con `adk web`. En produccion las credenciales
# se inyectan como env_vars en agent_engines.create() (ver PASO 6 / deploy.py).
cat > looker_app/.env <<EOF
LOOKERSDK_BASE_URL=${LOOKER_URL}
LOOKERSDK_CLIENT_ID=${LOOKER_CLIENT_ID}
LOOKERSDK_CLIENT_SECRET=${LOOKER_CLIENT_SECRET}
LOOKERSDK_VERIFY_SSL=true
LOOKER_EMBED_SECRET=${LOOKER_EMBED_SECRET}
LOOKER_EMBED_HASH=sha1
LOOKER_MODELS=${LOOKER_MODELS}
EOF

cat > looker_app/requirements.txt <<EOF
google-adk
looker_sdk
google-auth
requests
EOF

# ---------------------------------------------------------------------------
# agent.py - logica del agente (ADK). Se escribe via heredoc 'PYEOF' (comillas
# simples) para que bash NO interpole nada: el archivo es Python puro.
# ---------------------------------------------------------------------------
cat > looker_app/agent.py <<'PYEOF'
"""Agente Looker para Gemini Enterprise (v8).

Diseno:
  - Consulta Looker DIRECTO con looker_sdk (sin MCP, sin Cloud Run, sin ID tokens).
  - Las imagenes se entregan como ADK Artifacts (no como base64 en texto), que es
    la unica forma fiable de renderizarlas inline en Gemini Enterprise.
  - Las credenciales llegan por variables de entorno (mismas para el SDK).

El modelo del agente es intercambiable: ADK es agnostico de modelo. Para usar
Claude/Llama, sustituir el string del modelo por un LiteLlm(...) (Vertex AI
Model Garden o LiteLLM) en la definicion de LlmAgent al final del archivo.
"""

import os
import time
import json
import hmac
import base64
import hashlib
import binascii
from urllib.parse import quote_plus

import looker_sdk
from looker_sdk import models40

from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools import ToolContext
from google.adk.tools.load_artifacts_tool import load_artifacts_tool
from google.genai.types import ThinkingConfig, Part

# -----------------------------------------------------------------------------
# Config desde env vars (mismas credenciales para SDK; sin MCP, sin ID tokens)
# -----------------------------------------------------------------------------
LOOKER_HOST = (
    os.environ.get("LOOKERSDK_BASE_URL", "")
    .replace("https://", "").replace("http://", "").rstrip("/")
)
EMBED_SECRET = os.environ.get("LOOKER_EMBED_SECRET", "")
# Algoritmo de firma del embed secret: "sha1" si el secreto se creo por la UI de
# Looker (lo mas comun), "sha256" si se creo por API. Si el link da 401 de firma,
# prueba cambiando este valor.
EMBED_HASH = os.environ.get("LOOKER_EMBED_HASH", "sha1").lower()
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')


# -----------------------------------------------------------------------------
# Signed SSO Embed URL para Looker (link interactivo opcional bajo la imagen).
#
# IMPORTANTE: firmamos LOCALMENTE (HMAC), NO con create_sso_embed_url. Llamar al
# SDK aqui agrega un round-trip de red a Looker EN CADA render, y si esa llamada
# se pone lenta o falla cuelga la tool entera -> timeout (la imagen ya estaba
# lista pero el link la arrastra). La firma local es instantanea y sin red.
#
# La firma sigue la implementacion de referencia oficial de Looker
# (github.com/looker/looker_embed_sso_examples, python_example.py). Detalles que
# son criticos y que la version anterior tenia mal:
#   - La URL va a /login/embed/<embed_path URL-encoded>, NO a /embed/...
#   - El embed_path codificado (quote_plus, hex en MAYUSCULAS) es el MISMO string
#     que se firma y que va en la URL.
#   - nonce, time, session_length y los campos de usuario van JSON-encoded, en un
#     ORDEN EXACTO en string_to_sign (incluye external_group_id, que faltaba).
#   - La firma base64 se URL-encodea (quote_plus) al ponerla en el querystring.
#   - Algoritmo segun el secreto: SHA-1 (UI) o SHA-256 (API) -> ver EMBED_HASH.
#
# Va envuelto en try/except: si algo falla, devuelve un link normal (sin firmar)
# y NUNCA rompe ni demora la imagen.
#
# Requisitos en Looker (sin esto, ninguna firma sirve):
#   - Admin > Embed: "Embed SSO Authentication" = Enabled (+ Reset Secret).
#   - El dominio desde el que se abre el link, en el allowlist de embed.
# -----------------------------------------------------------------------------
def _generate_signed_embed_url(target_path: str, external_user_id: str = "gemini-user") -> str:
    # Sin secreto no podemos firmar: devolvemos el link normal de la UI.
    fallback = f"https://{LOOKER_HOST}{target_path}"
    if not EMBED_SECRET:
        return fallback

    try:
        # path: el MISMO valor se firma y se usa en la URL final.
        path = "/login/embed/" + quote_plus(target_path)

        # Todos estos campos van JSON-encoded (asi lo exige el contrato de Looker).
        nonce = json.dumps(binascii.hexlify(os.urandom(16)).decode("ascii"))
        t = json.dumps(int(time.time()))
        session_length = json.dumps(3600)
        ext_user_id = json.dumps(external_user_id)
        permissions = json.dumps([
            "access_data", "see_looks",
            "see_user_dashboards", "see_lookml_dashboards", "explore",
        ])
        models = json.dumps(json.loads(LOOKER_MODELS_ENV))   # normaliza el formato
        group_ids = json.dumps([])
        external_group_id = json.dumps("")
        user_attributes = json.dumps({})
        access_filters = json.dumps({})
        first_name = json.dumps("Gemini")
        last_name = json.dumps("User")
        force_logout_login = json.dumps(True)

        # ORDEN EXACTO - no reordenar.
        string_to_sign = "\n".join([
            LOOKER_HOST, path, nonce, t, session_length,
            ext_user_id, permissions, models,
            group_ids, external_group_id, user_attributes, access_filters,
        ])

        algo = hashlib.sha256 if EMBED_HASH == "sha256" else hashlib.sha1
        signature = base64.b64encode(
            hmac.new(EMBED_SECRET.encode("utf-8"),
                     string_to_sign.encode("utf-8"), algo).digest()
        ).decode("ascii")

        params = {
            "nonce": nonce, "time": t, "session_length": session_length,
            "external_user_id": ext_user_id, "permissions": permissions,
            "models": models, "group_ids": group_ids,
            "external_group_id": external_group_id, "user_attributes": user_attributes,
            "access_filters": access_filters, "signature": signature,
            "first_name": first_name, "last_name": last_name,
            "force_logout_login": force_logout_login,
        }
        # quote_plus tambien sobre la firma -> '+' se vuelve '%2B', etc.
        query = "&".join(f"{k}={quote_plus(v)}" for k, v in params.items())
        return f"https://{LOOKER_HOST}{path}?{query}"
    except Exception:
        # El link nunca debe tumbar la imagen.
        return fallback


# =============================================================================
# TOOLS DE IMAGEN  (via ADK Artifacts -> render nativo en Gemini Enterprise)
#
# Patron clave: cada tool renderiza el PNG, lo guarda con save_artifact() y
# DEVUELVE solo el nombre del artifact. Los bytes NO viajan en el texto del LLM.
# El agente luego llama a load_artifacts (incluido en tools) para mostrarlo.
# =============================================================================
async def show_dashboard_inline(dashboard_id: str, tool_context: ToolContext) -> dict:
    """Renderiza un dashboard de Looker como imagen y la guarda como artifact.

    Args:
        dashboard_id: ID numerico del dashboard.
    Returns:
        Dict con artifact_filename (a mostrar con load_artifacts) e interactive_url.
    """
    sdk = looker_sdk.init40()

    # El render de dashboards es asincrono en Looker: se crea un "render task" y
    # se hace polling hasta success/failure.
    task = sdk.create_dashboard_render_task(
        dashboard_id=dashboard_id,
        result_format="png",
        body=models40.CreateDashboardRenderTask(
            dashboard_style="tiled", dashboard_filters=""
        ),
        width=1200, height=800,
    )

    # Polling con tope de 90s. Dashboards muy pesados pueden no alcanzar a
    # terminar; en ese caso devolvemos un error claro en vez de colgarnos.
    waited = 0
    while waited < 90:
        status = sdk.render_task(task.id)
        if status.status == "success":
            break
        if status.status == "failure":
            return {"status": "error", "message": f"Render fallo para dashboard {dashboard_id}"}
        time.sleep(2)
        waited += 2
    else:
        return {"status": "error", "message": f"Timeout renderizando dashboard {dashboard_id}"}

    png_bytes = sdk.render_task_results(task.id)   # bytes crudos, NO base64
    filename = f"dashboard_{dashboard_id}.png"

    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"No se pudo guardar el artifact: {e}"}

    return {
        "status": "success",
        "artifact_filename": filename,
        "interactive_url": _generate_signed_embed_url(f"/embed/dashboards/{dashboard_id}"),
        "next_step": "Call load_artifacts with this filename to display the image, then add the interactive_url as a link.",
    }


async def show_look_inline(look_id: str, tool_context: ToolContext) -> dict:
    """Renderiza un Look (chart guardado) como imagen y la guarda como artifact.

    Args:
        look_id: ID numerico del Look.
    """
    sdk = looker_sdk.init40()

    # run_look con result_format="png" es sincrono: devuelve los bytes directo.
    try:
        png_bytes = sdk.run_look(
            look_id=look_id, result_format="png",
            image_width=1000, image_height=700,
        )
    except Exception as e:
        return {"status": "error", "message": f"Error al renderizar Look {look_id}: {e}"}

    filename = f"look_{look_id}.png"
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"No se pudo guardar el artifact: {e}"}

    return {
        "status": "success",
        "artifact_filename": filename,
        "interactive_url": _generate_signed_embed_url(f"/embed/looks/{look_id}"),
        "next_step": "Call load_artifacts with this filename to display the image, then add the interactive_url as a link.",
    }


async def show_query_inline(
    model: str, explore: str, fields: list, tool_context: ToolContext,
    vis_type: str = "looker_column",
) -> dict:
    """Crea una query ad-hoc, la renderiza como grafico y la guarda como artifact.

    Args:
        model: Modelo LookML (ej: "thelook").
        explore: Explore (ej: "order_items").
        fields: Lista de campos LookML.
        vis_type: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.
    """
    sdk = looker_sdk.init40()

    try:
        # Se crea la query con vis_config para que el render salga como grafico.
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
        return {"status": "error", "message": f"Error al ejecutar/renderizar query: {e}"}

    filename = f"query_{model}_{explore}.png".replace("/", "_")
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"No se pudo guardar el artifact: {e}"}

    return {
        "status": "success",
        "artifact_filename": filename,
        "interactive_url": _generate_signed_embed_url(
            f"/embed/explore/{model}/{explore}?qid={query.client_id}"
        ),
        "next_step": "Call load_artifacts with this filename to display the chart, then add the interactive_url as a link.",
    }


# =============================================================================
# TOOLS DE DATOS  (looker_sdk directo; reemplazan al antiguo toolbox MCP)
# Devuelven datos/estructura como JSON; el agente los resume en texto o tabla.
# =============================================================================
def query_looker_data(
    model: str, explore: str, fields: list,
    filters: dict = None, sorts: list = None, limit: int = 100,
) -> dict:
    """Ejecuta una query en Looker y devuelve las filas como JSON (sin imagen).

    Usar para responder preguntas de datos en texto/tabla.

    Args:
        model: Modelo LookML (ej: "thelook").
        explore: Explore (ej: "order_items").
        fields: Lista de campos LookML (ej: ["order_items.status", "order_items.count"]).
        filters: Dict opcional de filtros (ej: {"order_items.status": "complete"}).
        sorts: Lista opcional de ordenamientos (ej: ["order_items.count desc"]).
        limit: Maximo de filas (default 100).
    """
    sdk = looker_sdk.init40()
    try:
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                filters=filters or {}, sorts=sorts or [],
                limit=str(limit),
            )
        )
        rows = sdk.run_query(query_id=str(query.id), result_format="json")
        data = json.loads(rows) if isinstance(rows, str) else rows
        return {"status": "success", "row_count": len(data), "rows": data}
    except Exception as e:
        return {"status": "error", "message": f"Error en query: {e}"}


def list_looker_fields(model: str, explore: str) -> dict:
    """Lista dimensiones y medidas de un explore (para que el agente arme queries)."""
    sdk = looker_sdk.init40()
    try:
        exp = sdk.lookml_model_explore(lookml_model_name=model, explore_name=explore)
        dims = [f.name for f in (exp.fields.dimensions or [])] if exp.fields else []
        meas = [f.name for f in (exp.fields.measures or [])] if exp.fields else []
        return {"status": "success", "dimensions": dims, "measures": meas}
    except Exception as e:
        return {"status": "error", "message": f"Error listando campos: {e}"}


def list_available_dashboards(search_term: str = "") -> dict:
    """Lista dashboards disponibles en Looker (id + titulo), opcionalmente filtrados."""
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)

    if not dashboards:
        return {"status": "success", "dashboards": []}

    items = [{"id": str(d.id), "title": d.title} for d in dashboards]
    return {"status": "success", "dashboards": items}


# =============================================================================
# Definicion del agente ADK
#  - model: intercambiable (ver docstring del modulo).
#  - instruction: enseña el patron "renderiza -> load_artifacts -> link".
#  - planner: thinking desactivado (thinking_budget=0) para respuestas directas.
#  - tools: imagenes + datos + load_artifacts_tool (el que muestra el artifact).
# =============================================================================
root_agent = LlmAgent(
    model='gemini-2.5-flash',
    name='looker_agent',
    description='Looker agent: renders dashboards/charts as inline images (ADK artifacts) and answers data questions via the Looker SDK.',
    instruction=(
        'You are a Looker data agent inside Gemini Enterprise.\n\n'
        'HOW TO SHOW IMAGES (dashboards / looks / charts):\n'
        '1. Call the matching tool: show_dashboard_inline, show_look_inline, or '
        'show_query_inline. Each one renders the image and SAVES it as an artifact, '
        'returning an "artifact_filename".\n'
        '2. Then call load_artifacts with that filename so the image is displayed '
        'inline in the chat. This is the ONLY way the image renders - never try to '
        'output image bytes or base64 yourself.\n'
        '3. After the image, add a short caption and the "interactive_url" as a '
        'markdown link "[Abrir version interactiva en Looker](URL)".\n\n'
        'HOW TO ANSWER DATA QUESTIONS (numbers, no chart needed):\n'
        '- Use query_looker_data(model, explore, fields, ...) and summarize the '
        'returned rows in plain text or a small markdown table.\n'
        '- If unsure which fields exist, call list_looker_fields(model, explore) first.\n'
        '- To find dashboards by name, use list_available_dashboards.\n\n'
        'If a tool returns status="error", tell the user the message plainly and '
        'suggest a fix (e.g. wrong id, field name, or model).\n\n'
        'Defaults when unsure: model="thelook", explore="order_items".\n'
        'vis_type options: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.'
    ),
    planner=BuiltInPlanner(
        thinking_config=ThinkingConfig(include_thoughts=False, thinking_budget=0)
    ),
    tools=[
        show_dashboard_inline,
        show_look_inline,
        show_query_inline,
        query_looker_data,
        list_looker_fields,
        list_available_dashboards,
        load_artifacts_tool,   # <-- el que efectivamente renderiza los artifacts en el chat
    ],
)
PYEOF

echo "Agente creado (sin MCP, imagenes via artifacts)."

echo ""
echo "=================================================="
echo " PASO 6: Deploy a Agent Engine (Python SDK)"
echo "  (tarda 15-20 min, usando SA: $AGENT_SA)"
echo "=================================================="

# deploy.py empaqueta el agente y lo crea como Reasoning Engine en Vertex AI.
# Las credenciales de Looker se inyectan aqui como env_vars (no se hornean en
# el codigo). AdkApp en Agent Engine provee session + artifact service
# gestionados, por lo que save_artifact() funciona en runtime sin config extra.
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

vertexai.init(
    project=PROJECT_ID,
    location=REGION,
    staging_bucket=STAGING_BUCKET,
)

print(f"Desplegando agente con SA: {AGENT_SA}", flush=True)
print(f"Staging bucket: {STAGING_BUCKET}", flush=True)

app = reasoning_engines.AdkApp(agent=root_agent, enable_tracing=True)

env_vars = {
    "LOOKERSDK_BASE_URL": os.environ["LOOKER_URL"],
    "LOOKERSDK_CLIENT_ID": os.environ["LOOKER_CLIENT_ID"],
    "LOOKERSDK_CLIENT_SECRET": os.environ["LOOKER_CLIENT_SECRET"],
    "LOOKERSDK_VERIFY_SSL": "true",
    "LOOKER_EMBED_SECRET": os.environ["LOOKER_EMBED_SECRET"],
    "LOOKER_EMBED_HASH": os.environ.get("LOOKER_EMBED_HASH", "sha1"),
    "LOOKER_MODELS": os.environ.get("LOOKER_MODELS", '["thelook"]'),
}

try:
    remote_app = agent_engines.create(
        agent_engine=app,
        display_name="looker-agent1",
        requirements=[
            "google-adk",
            "looker_sdk",
            "google-auth",
            "google-cloud-aiplatform[agent_engines,adk]",
            "requests",
        ],
        extra_packages=["./looker_app"],
        service_account=AGENT_SA,
        env_vars=env_vars,
    )
    # Esta linea es la que el script de bash parsea para obtener el recurso.
    print(f"AGENT_ENGINE_RESOURCE_NAME={remote_app.resource_name}", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
DEPLOYEOF

# Exporta lo que deploy.py lee desde os.environ.
export PROJECT_ID REGION BUCKET_NAME AGENT_SA
export LOOKER_URL LOOKER_CLIENT_ID LOOKER_CLIENT_SECRET
export LOOKER_EMBED_SECRET LOOKER_MODELS LOOKER_EMBED_HASH

# El deploy es largo: se corre en background y se imprime un "latido" cada 15s
# con la ultima linea del log, para que la terminal (p.ej. Cloud Shell) no
# parezca colgada y no expire por inactividad.
DEPLOY_LOG="/tmp/adk_deploy_$$.log"
> "$DEPLOY_LOG"

python deploy.py > "$DEPLOY_LOG" 2>&1 &
DEPLOY_PID=$!
echo "Deploy en background (PID: $DEPLOY_PID)"

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
echo "=== OUTPUT DEL DEPLOY ==="
cat "$DEPLOY_LOG"
echo "========================="

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "ERROR: Deploy fallo"
  exit 1
fi

# --- Obtener el resource name del Reasoning Engine (3 metodos, en cascada) ---
# 1) Linea explicita que imprimio deploy.py.
REASONING_ENGINE=$(grep "AGENT_ENGINE_RESOURCE_NAME=" "$DEPLOY_LOG" | tail -1 | cut -d= -f2- || true)

# 2) Regex sobre el log por si la linea anterior no esta.
if [ -z "$REASONING_ENGINE" ]; then
  REASONING_ENGINE=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | head -1 || true)
fi

# 3) Ultimo recurso: consultar la API de reasoningEngines y filtrar por display name.
if [ -z "$REASONING_ENGINE" ]; then
  cat > /tmp/extract_engine.py <<'PYPARSER'
import json, sys
try:
    d = json.load(sys.stdin)
    engines = [e for e in d.get('reasoningEngines', []) if e.get('displayName') == 'looker-agent1']
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
  echo "ERROR: No se pudo obtener Reasoning Engine"
  exit 1
fi

echo "Reasoning Engine: $REASONING_ENGINE"

cd ..

echo ""
echo "=================================================="
echo " PASO 7: Registrar en Gemini Enterprise"
echo "=================================================="
# Asocia el Reasoning Engine recien creado como un agente del assistant por
# defecto de tu app de Gemini Enterprise (Discovery Engine API).
ACCESS_TOKEN=$(gcloud auth print-access-token)

# El host de la API depende de la location del engine (global vs regional).
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

echo "POST a: $AGENT_API_URL"

# Se captura cuerpo + status code juntos para poder reportar errores con detalle.
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
  echo "OK: Agente registrado en Gemini Enterprise"
else
  echo "ERROR HTTP $HTTP_STATUS"
  exit 1
fi

echo ""
echo "=================================================="
echo " SETUP COMPLETO"
echo "=================================================="
echo ""
echo "  Reasoning Engine : $REASONING_ENGINE"
echo "  Agent SA         : $AGENT_SA"
echo "  Staging/Artifacts: gs://${BUCKET_NAME}"
echo ""
echo "Imagenes -> ADK Artifacts (render nativo en Gemini Enterprise)"
echo "Datos    -> looker_sdk directo (sin MCP / sin Cloud Run / sin ID tokens)"
echo ""
echo "Prueba con:"
echo "  - 'Muestrame el dashboard 1'"
echo "  - 'Ensename el Look 5'"
echo "  - 'Visualiza ordenes por estado como grafico de barras'"
echo "  - 'Cuantas ordenes hay por estado?' (respuesta en datos, sin imagen)"
echo ""
echo "Configuracion manual en Looker Admin > Embed (para los links interactivos):"
echo "  1. ACTIVAR 'Embed SSO Authentication'"
echo "  2. Agregar el dominio de Gemini Enterprise al allowlist"
