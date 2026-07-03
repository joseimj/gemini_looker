# gemini_looker

🌐 [English](README.md) | [Español](README.es.md) | [Français](README.fr.md) | **Português**

**Um agente conversacional de analytics do Looker para o Gemini Enterprise do Google.**

`gemini_looker.sh` é um único script idempotente que monta um agente de analytics de ponta a ponta: provisiona os recursos de nuvem, faz o deploy de um agente do [Agent Development Kit (ADK)](https://google.github.io/adk-docs/) no **Vertex AI Agent Engine** e o registra no **Gemini Enterprise**. Depois do deploy, um usuário de negócio pode pedir, em linguagem natural, para *ver* um dashboard, *obter os números* ou *obter um link interativo* — e o agente responde diretamente no chat.

**Autor:** Jose Maldonado ([@joseimj](https://github.com/joseimj))

---

## Sumário

- [O que ele faz](#o-que-ele-faz)
- [O que este projeto demonstra](#o-que-este-projeto-demonstra)
- [Arquitetura](#arquitetura)
- [Decisões-chave de design](#decisões-chave-de-design)
- [Pré-requisitos](#pré-requisitos)
- [Configuração](#configuração)
- [Uso](#uso)
- [O que o agente pode fazer](#o-que-o-agente-pode-fazer)
- [Trocando o modelo de raciocínio](#trocando-o-modelo-de-raciocínio)
- [Uma nota sobre acesso a dados](#uma-nota-sobre-acesso-a-dados)
- [Solução de problemas](#solução-de-problemas)

---

## O que ele faz

O usuário digita um pedido no Gemini Enterprise e o agente responde de acordo:

| O usuário pede…                                     | O agente faz…                                              |
| ---------------------------------------------------- | ---------------------------------------------------------- |
| "Mostre o dashboard de vendas"                       | Renderiza o dashboard como **imagem inline**               |
| "Quantos pedidos estão completos?"                   | Executa uma consulta no Looker e responde **com os números** |
| "Faça um gráfico de barras dos pedidos por status"   | Constrói uma visualização ad hoc e a exibe inline          |
| "Me dê o link do dashboard 1"                        | Retorna uma **URL do Looker assinada e interativa**        |

---

## O que este projeto demonstra

- Construir e fazer deploy de um agente de produção no **Vertex AI Agent Engine** com o **ADK**.
- Integrar um agente gerenciado ao **Gemini Enterprise** de ponta a ponta.
- Uma integração pragmática com o Looker: renderização, consultas ad hoc e links de embed SSO assinados.
- Uma arquitetura intencionalmente **mínima e de baixo custo** — e o raciocínio por trás dela.

---

## Arquitetura

```
┌─────────────────────┐
│  Gemini Enterprise  │   a interface de chat que o usuário vê
└──────────┬──────────┘
           │
           ▼
┌──────────────────────────────────┐
│  Vertex AI Agent Engine (ADK)      │   runtime gerenciado que hospeda o agente
│  - LlmAgent (Gemini, substituível) │
│  - Render PNG -> ADK Artifacts     │
│  - Links assinados via Looker API  │
│  - Service account dedicada        │
└──────────────────┬─────────────────┘
                   │  HTTPS (credenciais da API do Looker via variáveis de ambiente)
                   ▼
          ┌──────────────────┐
          │    Looker API    │   dashboards · Looks · explores · dados
          └──────────────────┘
```

Sem Cloud Run, sem message broker, sem camada de cache, sem VPC. O agente fala diretamente com o Looker.

---

## Decisões-chave de design

- **As imagens são retornadas como artifacts do ADK, não como texto.** Cada ferramenta de renderização salva o PNG como artifact e o runtime o exibe nativamente. Os bytes da imagem nunca passam pela saída de texto do modelo — a única abordagem que renderiza de forma confiável no Gemini Enterprise.
- **Sem camada intermediária.** O agente chama o Looker diretamente pelo SDK. Menos peças móveis significa menos formas de falhar, além de um deploy mais barato e rápido.
- **Os links assinados são gerados pelo Looker, sob demanda.** As URLs interativas são criadas pela API `create_sso_embed_url` do Looker (o Looker as assina no lado do servidor), em uma ferramenta *separada* da renderização — assim, produzir um link nunca bloqueia nem atrasa a imagem.
- **O modelo de raciocínio é substituível.** O padrão é o Gemini; pode ser trocado pelo Claude ou outro modelo sem mexer no pipeline de renderização (veja abaixo).

---

## Pré-requisitos

- Um projeto do Google Cloud com **faturamento habilitado**.
- CLI `gcloud` autenticada (`gcloud auth login`). O Cloud Shell funciona sem configuração adicional.
- Uma instância do **Looker** com credenciais de API (Client ID e Client Secret).
- **Embedding habilitado** no Looker (Admin → Embed → *Embed SSO Authentication* + *Reset Secret*) para os links interativos.
- Um app do **Gemini Enterprise** já criado (você precisa do ID `AS_APP`).
- Um **bucket do GCS** para o staging do deploy e os artifacts de imagens.
- Papel de **Owner** (ou equivalente) no projeto.
- `bash` e `python3` (o script cria seu próprio ambiente virtual).

---

## Configuração

Edite as variáveis no topo de `gemini_looker.sh` antes de executar:

```bash
PROJECT_ID="your-gcp-project"
PROJECT_NUMBER="123456789012"
REGION="us-central1"
BUCKET_NAME="your-staging-bucket"

# Looker
LOOKER_URL="https://your-instance.looker.com"
LOOKER_CLIENT_ID="..."
LOOKER_CLIENT_SECRET="..."
LOOKER_EMBED_SECRET="..."     # configurado no Looker Admin; não é lido pelo código
LOOKER_MODELS='["thelook"]'   # modelo(s) LookML que o agente pode usar

# Gemini Enterprise
AS_APP="your-agent-id"
ENGINE_LOCATION="us"
```

O passo `-1` se recusa a executar enquanto algum valor ainda começar com `YOUR_`.

---

## Uso

```bash
git clone https://github.com/joseimj/gemini_looker.git
cd gemini_looker

chmod +x gemini_looker.sh
# edite o bloco de configuração e então:
./gemini_looker.sh
```

O script executa, nesta ordem:

1. Validar a configuração
2. Autenticar
3. Habilitar as APIs necessárias (IAM, Vertex AI, Discovery Engine, Looker, Storage, Resource Manager)
4. Criar a service account do agente e conceder IAM mínimo
5. Criar o bucket de staging (deploy + artifacts)
6. Construir a aplicação do agente (ADK)
7. Fazer o deploy do agente no Agent Engine *(~15–20 min)*
8. Registrar o agente no Gemini Enterprise

> O deploy imprime um heartbeat a cada 15 s. No Cloud Shell, mantenha a aba ativa durante o deploy (o timeout de inatividade é de ~20 min).

---

## O que o agente pode fazer

Todas as capacidades chamam o Looker diretamente pelo SDK.

**Mostrar imagens (renderizadas inline via artifacts):**

- `show_dashboard_inline` — renderiza um dashboard como PNG
- `show_look_inline` — renderiza um Look salvo como PNG
- `show_query_inline` — executa uma consulta ad hoc e a renderiza como gráfico (`looker_column`, `looker_bar`, `looker_line`, `looker_pie`, `looker_scatter`)

**Links interativos (assinados pelo Looker, sob demanda):**

- `get_dashboard_link`, `get_look_link`, `get_explore_link` — retornam uma URL de embed SSO assinada

**Dados (respostas em texto/tabela):**

- `query_looker_data` — executa uma consulta e retorna linhas
- `list_looker_models` — lista os modelos que as credenciais de API podem acessar (diagnóstico de acesso a dados)
- `list_looker_fields` — lista as dimensões e medidas de um explore
- `list_available_dashboards` — encontra dashboards pelo título

---

## Trocando o modelo de raciocínio

O modelo de raciocínio é independente da renderização, então você pode trocá-lo livremente **sem perder o recurso de imagens**. O padrão é o Gemini:

```python
AGENT_MODEL = "gemini-2.5-flash"
```

Para usar o **Anthropic Claude (p. ex. Sonnet 4.6)** no lugar:

1. Habilite o modelo no **Vertex AI Model Garden** (`publishers/anthropic/model-garden/claude-sonnet-4-6`).
2. Adicione `litellm` à lista `requirements` em `deploy.py`.
3. Substitua a linha do modelo em `looker_app/agent.py`:

```python
from google.adk.models.lite_llm import LiteLlm
AGENT_MODEL = LiteLlm(model="vertex_ai/claude-sonnet-4-6")
```

(Para a API pública da Anthropic em vez do Vertex, use `LiteLlm(model="anthropic/claude-sonnet-4-6")` com `ANTHROPIC_API_KEY` definida.)

---

## Uma nota sobre acesso a dados

Se uma consulta de dados retornar um erro de acesso ("cannot access data"), a causa quase sempre está **no lado do Looker, não no código**: o papel atribuído às credenciais de API precisa incluir um permission set com `access_data` / `explore` **e** um model set que contenha o modelo consultado. Note que `"all"` não é um nome de modelo válido. Use `list_looker_models` para ver quais modelos as credenciais realmente conseguem acessar — se o modelo esperado não aparecer, corrija o papel no Looker Admin.

---

## Solução de problemas

**A imagem renderiza, mas nenhum link aparece.** O agente deve chamar `get_dashboard_link` (etc.) e retornar `signed_url`. Se os links falharem, confirme que o embedding está habilitado no Looker (Admin → Embed) e que o domínio do Gemini Enterprise está na allowlist de embed. Valide uma URL gerada com o **Embed URI Validator** do Looker.

**Consultas de dados falham com erro de acesso.** Veja [Uma nota sobre acesso a dados](#uma-nota-sobre-acesso-a-dados). Execute `list_looker_models` para confirmar o que o usuário de API pode acessar.

**O deploy falha com um 500 ("revision not ready").** É um erro genérico de um contêiner que não iniciou. Verifique **Logs Explorer → tipo de recurso "Vertex AI Reasoning Engine"** para ver o erro real. A causa mais comum é uma dependência recém-atualizada: fixe versões exatas tanto no Passo 4 quanto em `deploy.py` para que o build e o runtime coincidam.

**A renderização do dashboard estoura o timeout.** Dashboards pesados podem ser lentos; a tarefa de render é limitada a 90 s. Tente um Look ou uma consulta ad hoc (mais rápidos), ou aumente o limite em `show_dashboard_inline`.

