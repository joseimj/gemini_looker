# gemini_looker

🌐 [English](README.md) | [Español](README.es.md) | **Français** | [Português](README.pt.md)

**Un agent conversationnel d'analytique Looker pour Gemini Enterprise de Google.**

`gemini_looker.sh` est un script unique et idempotent qui met en place un agent d'analytique de bout en bout : il provisionne les ressources cloud, déploie un agent [Agent Development Kit (ADK)](https://google.github.io/adk-docs/) sur **Vertex AI Agent Engine** et l'enregistre dans **Gemini Enterprise**. Une fois déployé, un utilisateur métier peut demander, en langage naturel, de *voir* un dashboard, d'*obtenir les chiffres* ou d'*obtenir un lien interactif* — et l'agent répond directement dans le chat.

**Auteur :** Jose Maldonado ([@joseimj](https://github.com/joseimj))

---

## Table des matières

- [Ce qu'il fait](#ce-quil-fait)
- [Ce que ce projet démontre](#ce-que-ce-projet-démontre)
- [Architecture](#architecture)
- [Décisions de conception clés](#décisions-de-conception-clés)
- [Prérequis](#prérequis)
- [Configuration](#configuration)
- [Utilisation](#utilisation)
- [Ce que l'agent peut faire](#ce-que-lagent-peut-faire)
- [Changer le modèle de raisonnement](#changer-le-modèle-de-raisonnement)
- [Une note sur l'accès aux données](#une-note-sur-laccès-aux-données)
- [Dépannage](#dépannage)

---

## Ce qu'il fait

L'utilisateur tape une demande dans Gemini Enterprise et l'agent répond en conséquence :

| L'utilisateur demande…                                  | L'agent fait…                                              |
| ------------------------------------------------------- | ---------------------------------------------------------- |
| « Montre-moi le dashboard des ventes »                   | Affiche le dashboard sous forme d'**image intégrée**       |
| « Combien de commandes sont terminées ? »                | Exécute une requête Looker et répond **avec les chiffres** |
| « Trace les commandes par statut en graphique à barres » | Construit une visualisation ad hoc et l'affiche en ligne   |
| « Donne-moi le lien vers le dashboard 1 »                | Renvoie une **URL Looker signée et interactive**           |

---

## Ce que ce projet démontre

- Construire et déployer un agent de production sur **Vertex AI Agent Engine** avec l'**ADK**.
- Intégrer un agent managé dans **Gemini Enterprise** de bout en bout.
- Une intégration Looker pragmatique : rendu d'images, requêtes ad hoc et liens d'embed SSO signés.
- Une architecture volontairement **minimale et à faible coût** — et le raisonnement qui la justifie.

---

## Architecture

```
┌─────────────────────┐
│  Gemini Enterprise  │   l'interface de chat vue par l'utilisateur
└──────────┬──────────┘
           │
           ▼
┌──────────────────────────────────┐
│  Vertex AI Agent Engine (ADK)      │   runtime managé hébergeant l'agent
│  - LlmAgent (Gemini, interchangeable)│
│  - Rendu PNG -> ADK Artifacts      │
│  - Liens signés via l'API Looker   │
│  - Compte de service dédié         │
└──────────────────┬─────────────────┘
                   │  HTTPS (identifiants API Looker via variables d'environnement)
                   ▼
          ┌──────────────────┐
          │    Looker API    │   dashboards · Looks · explores · données
          └──────────────────┘
```

Pas de Cloud Run, pas de broker de messages, pas de couche de cache, pas de VPC. L'agent communique directement avec Looker.

---

## Décisions de conception clés

- **Les images sont renvoyées comme artifacts ADK, pas comme texte.** Chaque outil de rendu enregistre le PNG comme artifact et le runtime l'affiche nativement. Les octets de l'image ne passent jamais par la sortie texte du modèle — la seule approche qui s'affiche de manière fiable dans Gemini Enterprise.
- **Pas de couche intermédiaire.** L'agent appelle Looker directement via son SDK. Moins de pièces mobiles signifie moins de points de défaillance, ainsi qu'un déploiement moins cher et plus rapide.
- **Les liens signés sont générés par Looker, à la demande.** Les URLs interactives sont créées via l'API `create_sso_embed_url` de Looker (Looker les signe côté serveur), dans un outil *distinct* du rendu — produire un lien ne bloque donc jamais l'image et ne la retarde pas.
- **Le modèle de raisonnement est interchangeable.** Gemini par défaut ; il peut être remplacé par Claude ou un autre modèle sans toucher au pipeline de rendu (voir ci-dessous).

---

## Prérequis

- Un projet Google Cloud avec la **facturation activée**.
- La CLI `gcloud` authentifiée (`gcloud auth login`). Cloud Shell fonctionne directement.
- Une instance **Looker** avec des identifiants API (Client ID et Client Secret).
- **L'embedding activé** dans Looker (Admin → Embed → *Embed SSO Authentication* + *Reset Secret*) pour les liens interactifs.
- Une app **Gemini Enterprise** déjà créée (vous avez besoin de son ID `AS_APP`).
- Un **bucket GCS** pour le staging du déploiement et les artifacts d'images.
- Le rôle **Owner** (ou équivalent) sur le projet.
- `bash` et `python3` (le script crée son propre environnement virtuel).

---

## Configuration

Modifiez les variables en haut de `gemini_looker.sh` avant de l'exécuter :

```bash
PROJECT_ID="your-gcp-project"
PROJECT_NUMBER="123456789012"
REGION="us-central1"
BUCKET_NAME="your-staging-bucket"

# Looker
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="..."
LOOKER_CLIENT_SECRET="..."
LOOKER_EMBED_SECRET="..."     # configuré dans Looker Admin ; non lu par le code
LOOKER_MODELS='["thelook"]'   # modèle(s) LookML que l'agent peut utiliser

# Gemini Enterprise
AS_APP="your-agent-id"
ENGINE_LOCATION="us"
```

L'étape `-1` refuse de s'exécuter tant qu'une valeur commence encore par `YOUR_`.

---

## Utilisation

```bash
git clone https://github.com/joseimj/gemini_looker.git
cd gemini_looker

chmod +x gemini_looker.sh
# modifiez le bloc de configuration, puis :
./gemini_looker.sh
```

Le script exécute, dans l'ordre :

1. Valider la configuration
2. S'authentifier
3. Activer les APIs requises (IAM, Vertex AI, Discovery Engine, Looker, Storage, Resource Manager)
4. Créer le compte de service de l'agent et accorder un IAM minimal
5. Créer le bucket de staging (déploiement + artifacts)
6. Construire l'application de l'agent (ADK)
7. Déployer l'agent sur Agent Engine *(~15–20 min)*
8. Enregistrer l'agent dans Gemini Enterprise

> Le déploiement affiche un heartbeat toutes les 15 s. Dans Cloud Shell, gardez l'onglet actif pendant le déploiement (le timeout d'inactivité est d'environ 20 min).

---

## Ce que l'agent peut faire

Toutes les fonctionnalités appellent Looker directement via son SDK.

**Afficher des images (rendues en ligne via artifacts) :**

- `show_dashboard_inline` — rend un dashboard en PNG
- `show_look_inline` — rend un Look enregistré en PNG
- `show_query_inline` — exécute une requête ad hoc et la rend en graphique (`looker_column`, `looker_bar`, `looker_line`, `looker_pie`, `looker_scatter`)

**Liens interactifs (signés par Looker, à la demande) :**

- `get_dashboard_link`, `get_look_link`, `get_explore_link` — renvoient une URL d'embed SSO signée

**Données (réponses texte/tableau) :**

- `query_looker_data` — exécute une requête et renvoie des lignes
- `list_looker_models` — liste les modèles accessibles aux identifiants API (diagnostic d'accès aux données)
- `list_looker_fields` — liste les dimensions et mesures d'un explore
- `list_available_dashboards` — recherche des dashboards par titre

---

## Changer le modèle de raisonnement

Le modèle de raisonnement est indépendant du rendu, vous pouvez donc le changer librement **sans perdre la fonctionnalité d'images**. Le modèle par défaut est Gemini :

```python
AGENT_MODEL = "gemini-2.5-flash"
```

Pour piloter l'agent avec **Anthropic Claude (p. ex. Sonnet 4.6)** à la place :

1. Activez le modèle dans **Vertex AI Model Garden** (`publishers/anthropic/model-garden/claude-sonnet-4-6`).
2. Ajoutez `litellm` à la liste `requirements` dans `deploy.py`.
3. Remplacez la ligne du modèle dans `looker_app/agent.py` :

```python
from google.adk.models.lite_llm import LiteLlm
AGENT_MODEL = LiteLlm(model="vertex_ai/claude-sonnet-4-6")
```

(Pour l'API publique d'Anthropic au lieu de Vertex, utilisez `LiteLlm(model="anthropic/claude-sonnet-4-6")` avec `ANTHROPIC_API_KEY` définie.)

---

## Une note sur l'accès aux données

Si une requête de données renvoie une erreur d'accès (« cannot access data »), la cause est presque toujours **côté Looker, pas dans le code** : le rôle attribué aux identifiants API doit inclure un permission set avec `access_data` / `explore` **et** un model set contenant le modèle interrogé. Notez que `"all"` n'est pas un nom de modèle valide. Utilisez `list_looker_models` pour voir quels modèles les identifiants peuvent réellement atteindre — si le modèle attendu n'apparaît pas, corrigez le rôle dans Looker Admin.

---

## Dépannage

**L'image s'affiche mais aucun lien n'apparaît.** L'agent devrait appeler `get_dashboard_link` (etc.) et renvoyer `signed_url`. Si les liens échouent, vérifiez que l'embedding est activé dans Looker (Admin → Embed) et que le domaine Gemini Enterprise figure sur l'allowlist d'embed. Validez une URL générée avec l'**Embed URI Validator** de Looker.

**Les requêtes de données échouent avec une erreur d'accès.** Voir [Une note sur l'accès aux données](#une-note-sur-laccès-aux-données). Exécutez `list_looker_models` pour confirmer ce que l'utilisateur API peut atteindre.

**Le déploiement échoue avec une erreur 500 (« revision not ready »).** C'est une erreur fourre-tout pour un conteneur qui n'a pas démarré. Consultez **Logs Explorer → type de ressource « Vertex AI Reasoning Engine »** pour l'erreur réelle. La cause la plus fréquente est une dépendance fraîchement mise à jour : épinglez des versions exactes à la fois à l'Étape 4 et dans `deploy.py` pour que le build et le runtime correspondent.

**Le rendu du dashboard expire (timeout).** Les dashboards lourds peuvent être lents ; la tâche de rendu est plafonnée à 90 s. Essayez un Look ou une requête ad hoc (plus rapides), ou augmentez le plafond dans `show_dashboard_inline`.

