# gemini_looker

🌐 [English](README.md) | **Español** | [Français](README.fr.md) | [Português](README.pt.md)

**Un agente conversacional de analítica de Looker para Gemini Enterprise de Google.**

`gemini_looker.sh` es un único script idempotente que levanta un agente de analítica de extremo a extremo: aprovisiona los recursos en la nube, despliega un agente del [Agent Development Kit (ADK)](https://google.github.io/adk-docs/) en **Vertex AI Agent Engine** y lo registra en **Gemini Enterprise**. Una vez desplegado, un usuario de negocio puede pedir, en lenguaje natural, *ver* un dashboard, *obtener las cifras* u *obtener un enlace interactivo* — y el agente responde directamente dentro del chat.

**Autor:** Jose Maldonado ([@joseimj](https://github.com/joseimj))

---

## Tabla de contenidos

- [Qué hace](#qué-hace)
- [Qué demuestra este proyecto](#qué-demuestra-este-proyecto)
- [Arquitectura](#arquitectura)
- [Decisiones clave de diseño](#decisiones-clave-de-diseño)
- [Requisitos previos](#requisitos-previos)
- [Configuración](#configuración)
- [Uso](#uso)
- [Qué puede hacer el agente](#qué-puede-hacer-el-agente)
- [Cambiar el modelo de razonamiento](#cambiar-el-modelo-de-razonamiento)
- [Una nota sobre el acceso a datos](#una-nota-sobre-el-acceso-a-datos)
- [Solución de problemas](#solución-de-problemas)

---

## Qué hace

El usuario escribe una petición en Gemini Enterprise y el agente responde en consecuencia:

| El usuario pide…                                    | El agente hace…                                            |
| --------------------------------------------------- | ---------------------------------------------------------- |
| "Muéstrame el dashboard de ventas"                  | Renderiza el dashboard como **imagen en línea**            |
| "¿Cuántos pedidos están completos?"                 | Ejecuta una consulta en Looker y responde **con las cifras** |
| "Grafica los pedidos por estado como gráfico de barras" | Construye una visualización ad hoc y la muestra en línea |
| "Dame el enlace al dashboard 1"                     | Devuelve una **URL de Looker firmada e interactiva**       |

---

## Qué demuestra este proyecto

- Construir y desplegar un agente de producción en **Vertex AI Agent Engine** con el **ADK**.
- Integrar un agente gestionado en **Gemini Enterprise** de extremo a extremo.
- Una integración pragmática con Looker: renderizado, consultas ad hoc y enlaces de embed SSO firmados.
- Una arquitectura intencionadamente **mínima y de bajo coste** — y el razonamiento detrás de ella.

---

## Arquitectura

```
┌─────────────────────┐
│  Gemini Enterprise  │   la interfaz de chat que ve el usuario
└──────────┬──────────┘
           │
           ▼
┌──────────────────────────────────┐
│  Vertex AI Agent Engine (ADK)      │   runtime gestionado que aloja el agente
│  - LlmAgent (Gemini, intercambiable)│
│  - Render PNG -> ADK Artifacts     │
│  - Enlaces firmados vía Looker API │
│  - Cuenta de servicio dedicada     │
└──────────────────┬─────────────────┘
                   │  HTTPS (credenciales de la API de Looker vía variables de entorno)
                   ▼
          ┌──────────────────┐
          │    Looker API    │   dashboards · Looks · explores · datos
          └──────────────────┘
```

Sin Cloud Run, sin broker de mensajes, sin capa de caché, sin VPC. El agente habla directamente con Looker.

---

## Decisiones clave de diseño

- **Las imágenes se devuelven como artifacts del ADK, no como texto.** Cada herramienta de renderizado guarda el PNG como artifact y el runtime lo muestra de forma nativa. Los bytes de la imagen nunca pasan por la salida de texto del modelo — el único enfoque que renderiza de forma fiable en Gemini Enterprise.
- **Sin capa intermedia.** El agente llama a Looker directamente a través de su SDK. Menos piezas móviles significa menos formas de fallar, además de un despliegue más barato y rápido.
- **Los enlaces firmados los genera Looker, bajo demanda.** Las URLs interactivas se crean mediante la API `create_sso_embed_url` de Looker (Looker las firma del lado del servidor), en una herramienta *separada* del renderizado — de modo que producir un enlace nunca bloquea ni retrasa la imagen.
- **El modelo de razonamiento es intercambiable.** Por defecto usa Gemini; se puede cambiar a Claude u otro modelo sin tocar el pipeline de renderizado (ver más abajo).

---

## Requisitos previos

- Un proyecto de Google Cloud con **facturación habilitada**.
- CLI de `gcloud` autenticada (`gcloud auth login`). Cloud Shell funciona sin configuración adicional.
- Una instancia de **Looker** con credenciales de API (Client ID y Client Secret).
- **Embedding habilitado** en Looker (Admin → Embed → *Embed SSO Authentication* + *Reset Secret*) para los enlaces interactivos.
- Una app de **Gemini Enterprise** ya creada (necesitas su ID `AS_APP`).
- Un **bucket de GCS** para el staging del despliegue y los artifacts de imágenes.
- Rol de **Owner** (o equivalente) en el proyecto.
- `bash` y `python3` (el script crea su propio entorno virtual).

---

## Configuración

Edita las variables al inicio de `gemini_looker.sh` antes de ejecutarlo:

```bash
PROJECT_ID="your-gcp-project"
PROJECT_NUMBER="123456789012"
REGION="us-central1"
BUCKET_NAME="your-staging-bucket"

# Looker
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="..."
LOOKER_CLIENT_SECRET="..."
LOOKER_EMBED_SECRET="..."     # se configura en Looker Admin; el código no lo lee
LOOKER_MODELS='["thelook"]'   # modelo(s) LookML que el agente puede usar

# Gemini Enterprise
AS_APP="your-agent-id"
ENGINE_LOCATION="us"
```

El paso `-1` se niega a ejecutarse mientras algún valor siga empezando por `YOUR_`.

---

## Uso

```bash
git clone https://github.com/joseimj/gemini_looker.git
cd gemini_looker

chmod +x gemini_looker.sh
# edita el bloque de configuración y luego:
./gemini_looker.sh
```

El script ejecuta, en orden:

1. Validar la configuración
2. Autenticar
3. Habilitar las APIs necesarias (IAM, Vertex AI, Discovery Engine, Looker, Storage, Resource Manager)
4. Crear la cuenta de servicio del agente y otorgar IAM mínimo
5. Crear el bucket de staging (despliegue + artifacts)
6. Construir la aplicación del agente (ADK)
7. Desplegar el agente en Agent Engine *(~15–20 min)*
8. Registrar el agente en Gemini Enterprise

> El despliegue imprime un heartbeat cada 15 s. En Cloud Shell, mantén la pestaña activa durante el despliegue (el timeout por inactividad es de ~20 min).

---

## Qué puede hacer el agente

Todas las capacidades llaman a Looker directamente a través de su SDK.

**Mostrar imágenes (renderizadas en línea vía artifacts):**

- `show_dashboard_inline` — renderiza un dashboard como PNG
- `show_look_inline` — renderiza un Look guardado como PNG
- `show_query_inline` — ejecuta una consulta ad hoc y la renderiza como gráfico (`looker_column`, `looker_bar`, `looker_line`, `looker_pie`, `looker_scatter`)

**Enlaces interactivos (firmados por Looker, bajo demanda):**

- `get_dashboard_link`, `get_look_link`, `get_explore_link` — devuelven una URL de embed SSO firmada

**Datos (respuestas en texto/tabla):**

- `query_looker_data` — ejecuta una consulta y devuelve filas
- `list_looker_models` — lista los modelos a los que las credenciales de API pueden acceder (diagnóstico de acceso a datos)
- `list_looker_fields` — lista las dimensiones y medidas de un explore
- `list_available_dashboards` — busca dashboards por título

---

## Cambiar el modelo de razonamiento

El modelo de razonamiento es independiente del renderizado, así que puedes cambiarlo libremente **sin perder la función de imágenes**. El valor por defecto es Gemini:

```python
AGENT_MODEL = "gemini-2.5-flash"
```

Para usar **Anthropic Claude (p. ej. Sonnet 4.6)** en su lugar:

1. Habilita el modelo en **Vertex AI Model Garden** (`publishers/anthropic/model-garden/claude-sonnet-4-6`).
2. Añade `litellm` a la lista `requirements` en `deploy.py`.
3. Reemplaza la línea del modelo en `looker_app/agent.py`:

```python
from google.adk.models.lite_llm import LiteLlm
AGENT_MODEL = LiteLlm(model="vertex_ai/claude-sonnet-4-6")
```

(Para la API pública de Anthropic en lugar de Vertex, usa `LiteLlm(model="anthropic/claude-sonnet-4-6")` con `ANTHROPIC_API_KEY` configurada.)

---

## Una nota sobre el acceso a datos

Si una consulta de datos devuelve un error de acceso ("cannot access data"), la causa casi siempre está **del lado de Looker, no del código**: el rol asignado a las credenciales de API debe incluir un permission set con `access_data` / `explore` **y** un model set que contenga el modelo consultado. Ten en cuenta que `"all"` no es un nombre de modelo válido. Usa `list_looker_models` para ver a qué modelos pueden acceder realmente las credenciales — si el modelo que esperas no aparece, corrige el rol en Looker Admin.

---

## Solución de problemas

**La imagen se renderiza pero no aparece el enlace.** El agente debería llamar a `get_dashboard_link` (etc.) y devolver `signed_url`. Si los enlaces fallan, confirma que el embedding está habilitado en Looker (Admin → Embed) y que el dominio de Gemini Enterprise está en la allowlist de embed. Valida una URL generada con el **Embed URI Validator** de Looker.

**Las consultas de datos fallan con un error de acceso.** Ver [Una nota sobre el acceso a datos](#una-nota-sobre-el-acceso-a-datos). Ejecuta `list_looker_models` para confirmar a qué puede acceder el usuario de API.

**El despliegue falla con un 500 ("revision not ready").** Es un error genérico de un contenedor que no arrancó. Revisa **Logs Explorer → tipo de recurso "Vertex AI Reasoning Engine"** para ver el error real. La causa más común es una dependencia recién actualizada: fija versiones exactas tanto en el Paso 4 como en `deploy.py` para que el build y el runtime coincidan.

**El renderizado del dashboard se agota por timeout.** Los dashboards pesados pueden ser lentos; la tarea de render está limitada a 90 s. Prueba con un Look o una consulta ad hoc (más rápidos), o aumenta el límite en `show_dashboard_inline`.

