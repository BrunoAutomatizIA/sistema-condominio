# EscolaZap — Bot de Escola Infantil para WhatsApp

Produto da **Automatiz.ia** que conecta pais/responsáveis à escola infantil via WhatsApp. Composto por três artefatos:

| Arquivo | O que é |
|---|---|
| `bot_escola.json` | Workflow n8n principal (bot WhatsApp) |
| `notificacao_webhook.json` | Workflow n8n auxiliar — webhook de notificação do dashboard |
| `index.html` | Dashboard admin SPA (HTML/CSS/JS puro, sem build) |

---

## Infraestrutura

| Serviço | Uso | Credencial no projeto |
|---|---|---|
| **n8n** | Plataforma de automação que roda os workflows | host: `n8n.automacaopme.com.br` |
| **Evolution API** | Gateway WhatsApp | `apikey: F5E45E6A06AC-4857-807A-923D226DE8E1` (host: `evolution.automacaopme.com.br`, instance: `Bot_Escola`) |
| **Supabase** | Banco PostgreSQL via REST | anon key hardcoded (project: `rcghqqwbwxbhrxjwutqu`) |

> ⚠️ As credenciais estão hardcoded nos arquivos. Antes de entregar a outros clientes, extraí-las para variáveis de ambiente no n8n.

---

## Schema do Banco (Supabase)

```
responsaveis      — id, nome, telefone (PK negócio), aluno, turma, created_at
sessoes_escola    — telefone (PK), etapa, dados (JSONB), updated_at
cardapio          — id, semana_inicio (date UNIQUE), segunda, terca, quarta, quinta, sexta, created_at
avisos            — id, responsavel_id (FK), titulo, mensagem, status, lido_em, created_at
ocorrencias_escola — id, responsavel_id (FK), aluno, titulo, descricao, urgencia, status, created_at
autorizacoes      — id, responsavel_id (FK), nome_autorizador, documento, parentesco, created_at
solicitacoes      — id, responsavel_id (FK), tipo, descricao, status, created_at
comunicados_escola — id, titulo, mensagem, status, enviado_em, destinatarios, turma, created_at
agenda            — id, data (date), titulo, descricao, turma (null=todos), created_at
```

**Status de ocorrência:** `aberta` → `analise` → `andamento` → `resolvida`

**Status de solicitação:** `pendente` → `analise` → `andamento` → `resolvido`

**Status de aviso:** `pendente` → `lido`

---

## SQL Script — Criar Tabelas no Supabase

```sql
-- Responsáveis (pais/mães)
CREATE TABLE IF NOT EXISTS responsaveis (
  id bigint generated always as identity primary key,
  nome text NOT NULL,
  telefone text UNIQUE NOT NULL,
  aluno text NOT NULL,
  turma text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE responsaveis ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON responsaveis USING (true) WITH CHECK (true);

-- Sessões do bot
CREATE TABLE IF NOT EXISTS sessoes_escola (
  telefone text PRIMARY KEY,
  etapa text,
  dados jsonb DEFAULT '{}',
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE sessoes_escola ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON sessoes_escola USING (true) WITH CHECK (true);

-- Cardápio semanal
CREATE TABLE IF NOT EXISTS cardapio (
  id bigint generated always as identity primary key,
  semana_inicio date UNIQUE NOT NULL,
  segunda text, terca text, quarta text, quinta text, sexta text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE cardapio ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON cardapio USING (true) WITH CHECK (true);

-- Avisos individuais
CREATE TABLE IF NOT EXISTS avisos (
  id bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id),
  titulo text NOT NULL,
  mensagem text NOT NULL,
  status text DEFAULT 'pendente',
  lido_em timestamptz,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE avisos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON avisos USING (true) WITH CHECK (true);

-- Ocorrências com aluno
CREATE TABLE IF NOT EXISTS ocorrencias_escola (
  id bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id),
  aluno text,
  titulo text,
  descricao text,
  urgencia text DEFAULT 'media',
  status text DEFAULT 'aberta',
  created_at timestamptz DEFAULT now()
);
ALTER TABLE ocorrencias_escola ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON ocorrencias_escola USING (true) WITH CHECK (true);

-- Autorizações de busca
CREATE TABLE IF NOT EXISTS autorizacoes (
  id bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id),
  nome_autorizador text NOT NULL,
  documento text,
  parentesco text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE autorizacoes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON autorizacoes USING (true) WITH CHECK (true);

-- Solicitações administrativas
CREATE TABLE IF NOT EXISTS solicitacoes (
  id bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id),
  tipo text,
  descricao text,
  status text DEFAULT 'pendente',
  created_at timestamptz DEFAULT now()
);
ALTER TABLE solicitacoes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON solicitacoes USING (true) WITH CHECK (true);

-- Comunicados em massa
CREATE TABLE IF NOT EXISTS comunicados_escola (
  id bigint generated always as identity primary key,
  titulo text NOT NULL,
  mensagem text NOT NULL,
  status text DEFAULT 'rascunho',
  enviado_em timestamptz,
  destinatarios int DEFAULT 0,
  turma text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE comunicados_escola ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON comunicados_escola USING (true) WITH CHECK (true);

-- Agenda de eventos
CREATE TABLE IF NOT EXISTS agenda (
  id bigint generated always as identity primary key,
  data date NOT NULL,
  titulo text NOT NULL,
  descricao text,
  turma text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE agenda ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON agenda USING (true) WITH CHECK (true);
```

---

## Workflow n8n — Arquitetura do Bot

### Entrada e resposta imediata
```
Webhook (POST /escola-bot)
  ├─► Respond 200    ← responde HTTP imediatamente
  └─► Parsear Mensagem
```

**Parsear Mensagem** descarta:
- Mensagens do próprio bot (`fromMe === true`)
- Mensagens de grupos (`@g.us`)

### Lookup e consolidação
```
Parsear Mensagem → GET Responsavel → GET Sessao → Consolidar → Responsavel existe? (IF)
```

### Fluxo de cadastro (responsável não encontrado)
```
Responsavel existe? [false] → Lógica Cadastro → DELETE Sessao → Cadastro OK? (IF)
  ├─► [em andamento] INSERT Sessao Cadastro + Enviar Cadastro
  └─► [ok=true] INSERT Responsavel + Enviar Cadastro
```

**Etapas de sessão do cadastro:**
```
null → aguardando_nome → aguardando_aluno → aguardando_turma → (ok=true)
```

### Menu enviado ao responsável (cadastrado)
```
🏫 *EscolaZap*

Olá, *[Nome]*! 👋
👶 [Aluno] — Turma [Turma]

Como posso ajudar?

1️⃣  📅 Agenda & Eventos
2️⃣  🍽️ Cardápio da Semana
3️⃣  ✅ Autorizar Busca
4️⃣  ⚠️ Registrar Ocorrência
5️⃣  📋 Solicitações
6️⃣  📢 Meus Avisos
```

### Roteamento principal
```
Roteador → Switch Rota
  ├── agenda       → texto="1" ou buttonId="btn_agenda"
  ├── cardapio     → texto="2" ou "btn_cardapio"
  ├── autorizacao  → texto="3", "btn_autorizacao" ou etapa.startsWith("autorizacao_")
  ├── ocorrencia   → texto="4", "btn_ocorrencia" ou etapa.startsWith("ocorrencia_")
  ├── solicitacao  → texto="5", "btn_solicitacao" ou etapa.startsWith("solicitacao_")
  ├── avisos       → texto="6" ou "btn_avisos"
  ├── cancelar     → texto é "CANCELAR" (maiúsculo)
  └── menu         → qualquer outra coisa
```

### Fluxo de Agenda
```
GET Agenda (data>=hoje, order=data.asc, limit=5) → Formatar Agenda → Enviar Agenda
```
Filtra eventos da turma do aluno + eventos gerais (turma null).

### Fluxo de Cardápio
```
GET Cardapio (semana_inicio<=hoje, order=desc, limit=1) → Formatar Cardapio → Enviar Cardapio
```

### Fluxo de Autorização de Busca (multi-step)
**Etapas de sessão:**
```
autorizacao_nome → autorizacao_documento → autorizacao_parentesco → (ok=true)
```
Ao concluir: INSERT em `autorizacoes` (nome_autorizador, documento, parentesco, responsavel_id).

### Fluxo de Ocorrência (multi-step)
**Etapas de sessão:**
```
ocorrencia_titulo → ocorrencia_descricao → ocorrencia_urgencia → (ok=true)
```
Ao concluir: INSERT em `ocorrencias_escola` com status='aberta'. Protocolo: `OC-` + 6 dígitos.

### Fluxo de Solicitação (multi-step)
**Etapas de sessão:**
```
solicitacao_tipo → solicitacao_descricao → (ok=true)
```
Ao concluir: INSERT em `solicitacoes` com status='pendente'. Protocolo: `SL-` + 6 dígitos.

### Fluxo de Avisos
```
GET Avisos (responsavel_id, status=pendente, limit=10) → Formatar Avisos → Enviar Avisos
```

### Cancelamento
```
Cancelar Fluxo → DELETE Sessao Cancelar → Enviar Cancelamento
```

---

## Webhook de Notificação (`notificacao_webhook.json`)

Permite que o dashboard envie WhatsApp sem bloqueio de CORS.

**Endpoint:** `POST https://n8n.automacaopme.com.br/webhook/notificar-escola`

**Body:** `{ "number": "5511999999999", "text": "mensagem" }`

**Fluxo:** Webhook → Responder 200 + Enviar WhatsApp (POST Evolution API `Bot_Escola`)

---

## Dashboard Admin (`index.html`)

SPA pura, sem framework, sem build. Abre direto no browser.

### Páginas
| Página | Conteúdo |
|---|---|
| **Dashboard** | Métricas (responsáveis, ocorrências abertas, avisos pendentes, próximos eventos), agenda resumida, ocorrências recentes, comunicados, cardápio da semana |
| **Responsáveis** | Busca + lista por turma + cadastro + edição inline + exclusão |
| **Cardápio** | Publicar semana (segunda a sexta) + histórico semanal |
| **Agenda** | Eventos futuros/passados + filtro por turma + cadastro + exclusão |
| **Ocorrências** | Kanban 4 colunas: Aberta → Em Análise → Em Andamento → Resolvida |
| **Solicitações** | Kanban 4 colunas: Pendente → Análise → Andamento → Resolvido |
| **Avisos** | Criar aviso individual (por responsável) ou por turma + envio WhatsApp |
| **Comunicados** | Envio em massa para todos ou por turma via WhatsApp |
| **Autorizações** | Lista de autorizados de cada aluno (gerado pelo bot) |

### Tema Visual
- **Paleta:** Verde `#27AE60` + Roxo `#8E44AD` + Laranja `#F39C12`
- **Dark mode:** fundo `#0D1B12`
- **Light mode:** fundo `#F4FDF6`
- **Fonte:** **Nunito** (400/600/700/800/900) — amigável, arredondada
- **Mono:** Space Mono — métricas e telefones

### Helper Supabase
```js
supaApi(method, path, body)  // retorna Promise
// Exemplos:
supaApi('GET', '/responsaveis?select=*')
supaApi('POST', '/responsaveis', { nome, telefone, aluno, turma })
supaApi('PATCH', '/ocorrencias_escola?id=eq.5', { status: 'analise' })
supaApi('DELETE', '/autorizacoes?id=eq.3')
```

### WhatsApp Helper
```js
sendWhatsApp(number, text)  // POST ao webhook n8n
```

### Toast
```js
showToast('Mensagem de sucesso')
showToast('Algo deu errado', 'error')
showToast('Informação', 'info')
```

---

## Como adicionar um novo módulo ao bot

1. Abra o n8n, edite `bot_escola.json`
2. Adicionar nova rota no **Roteador** (Code node) com prefixo único
3. Adicionar nova saída no **Switch Rota**
4. Seguir o padrão: Lógica → DELETE Sessao → IF ok? → INSERT Sessao (continua) ou INSERT dado final (concluiu) → Enviar mensagem

## Como adicionar uma nova página ao dashboard

1. Criar `<div class="page" id="page-NOME">` dentro de `<main class="page-area">`
2. Adicionar `.nav-item[data-page="NOME"]` no sidebar
3. Adicionar `.bnav-item[data-page="NOME"]` no bottom-nav
4. Adicionar `NOME: 'Título'` no objeto `titles` dentro da função `navigate()`
5. Adicionar `NOME: () => MinhaApp.load()` no objeto `loaders` em `loadPage()`

---

## Como implantar

### 1. Supabase — Criar tabelas
1. Acesse [supabase.com](https://supabase.com) → projeto `rcghqqwbwxbhrxjwutqu`
2. Vá em **SQL Editor** e execute o script SQL acima completo

### 2. Evolution API — Criar instância
1. Acesse o painel da Evolution API
2. Criar nova instância com nome `Bot_Escola`
3. Escanear QR code com o WhatsApp da escola
4. Configurar o webhook para apontar para `https://n8n.automacaopme.com.br/webhook/escola-bot`

### 3. n8n — Importar workflows
1. No n8n, ir em **Workflows → Import from File**
2. Importar `bot_escola.json` e ativar
3. Importar `notificacao_webhook.json` e ativar

### 4. Dashboard
1. Abrir `index.html` diretamente no browser
2. Não requer servidor — funciona como arquivo local

---

## Turmas suportadas
- Berçário
- Maternal I
- Maternal II
- Jardim I
- Jardim II
- Pré

Para alterar as turmas, buscar por `<option>Berçário</option>` no `index.html` e no `bot_escola.json` (nó "Lógica Cadastro") e atualizar a lista.
