# Condozap — Bot de Portaria para WhatsApp

Produto da **Automatiz.ia** que automatiza a portaria de condomínios via WhatsApp. Composto por três artefatos:

| Arquivo | O que é |
|---|---|
| `bot_condominio.json` | Workflow n8n principal (bot WhatsApp) |
| `notificacao_webhook.json` | Workflow n8n auxiliar — webhook de notificação de encomendas |
| `index.html` | Dashboard admin SPA (HTML/CSS/JS puro, sem build) |

---

## Infraestrutura

| Serviço | Uso | Credencial no projeto |
|---|---|---|
| **n8n** | Plataforma de automação que roda os workflows | host: `n8n.automacaopme.com.br` |
| **Evolution API** | Gateway WhatsApp | `apikey: F5E45E6A06AC-4857-807A-923D226DE8E1` (host: `evolution.automacaopme.com.br`, instance: `Bot_Condominio`) |
| **Supabase** | Banco PostgreSQL via REST | anon key hardcoded em ambos os arquivos (project: `rcghqqwbwxbhrxjwutqu`) |

> As credenciais estão hardcoded nos arquivos. Ao escalar ou entregar para outros clientes, extraí-las para variáveis de ambiente no n8n ou para um arquivo de configuração separado.

---

## Schema do Banco (Supabase)

```
moradores    — id, nome, telefone (PK de negócio), apartamento, bloco
sessoes      — telefone (PK), etapa, dados (JSONB), updated_at
encomendas   — id, morador_id (FK→moradores), descricao, data_recebimento, status, retirada_em
visitantes   — id, nome, morador_id, documento, entrada
atendimentos — id, telefone, titulo, mensagem, local_ocorrencia, urgencia, status, created_at
requisicoes  — id, telefone, morador_id, tipo, local_servico, descricao, urgencia, status, created_at
reservas     — id, morador_id (FK→moradores), area, data (date), horario, status, created_at
comunicados  — id, titulo, mensagem, status, enviado_em, destinatarios, created_at
```

**Status de encomenda:** `aguardando` → `retirado`

**Status de atendimento/ocorrência:** `aberta` → `analise` → `andamento` → `resolvida` — movido pelo dashboard (Kanban).

**Status de requisição de serviço:** `pendente` → `analise` → `andamento` → `resolvido` — movido pelo dashboard (Kanban).

---

## Workflow n8n — Arquitetura do Bot

### Entrada e resposta imediata
```
Webhook (POST /condominio)
  ├─► Respond 200   ← responde HTTP imediatamente (padrão async)
  └─► Parsear Mensagem
```

**Parsear Mensagem** descarta:
- Mensagens enviadas pelo próprio bot (`fromMe === true`)
- Mensagens de grupos (`remoteJid` contém `@g.us`)

Extrai: `from` (telefone limpo), `texto`, `buttonId`, `instance`.

### Lookup e consolidação
```
Parsear Mensagem → GET Morador → GET Sessao → Consolidar → Morador existe? (IF)
```

`Consolidar` mescla dados do morador e da sessão em um único objeto passado adiante.

### Fluxo de cadastro (morador não encontrado)
```
Morador existe? [false] → Lógica Cadastro → DELETE Sessao → Cadastro OK? (IF)
  ├─► [ainda em andamento] INSERT Sessao + Enviar Cadastro
  └─► [ok=true] INSERT Morador + Enviar Cadastro
```

**Etapas de sessão do cadastro:**
```
null → aguardando_nome → aguardando_apto → aguardando_bloco → (ok=true, sem sessão)
```

### Roteamento principal (morador cadastrado)
```
Morador existe? [true] → Roteador → Switch Rota
  ├── encomendas   → texto="1" ou buttonId="btn_encomendas"
  ├── visitantes   → texto="2", "btn_visitantes" ou etapa.startsWith("visitante_")
  ├── servicos     → texto="3", "btn_servicos" ou etapa.startsWith("servico_")
  ├── reservas     → texto="4", "btn_reservas" ou etapa.startsWith("reserva_")
  ├── ocorrencias  → texto="5", "btn_ocorrencias" ou etapa.startsWith("ocorrencia_")
  ├── retirada     → texto começa com "RETIREI" (ex: "RETIREI 2")
  ├── cancelar     → texto é "CANCELAR" (maiúsculo)
  └── menu         → qualquer outra coisa
```

**Menu enviado ao morador:**
```
1️⃣  📦 Minhas Encomendas
2️⃣  🚗 Autorizar Visitantes
3️⃣  🔧 Solicitar Serviços
4️⃣  📅 Fazer Reserva
5️⃣  ⚠️ Registrar Ocorrências
```

### Fluxo de encomendas
```
GET Encomendas (status=aguardando, order=id.asc) → Formatar Encomendas → Enviar Encomendas
```
Lista todas as encomendas aguardando e instrui o morador a usar `RETIREI N`.

### Fluxo de retirada
```
Parsear RETIREI → Formato válido? (IF)
  ├─► [inválido] Erro Formato
  └─► [válido] GET Enc Retirada (offset=N-1) → Check Enc → Enc encontrada? (IF)
        ├─► [sim] PATCH Retirada (status=retirado, retirada_em=now) → Confirmar Retirada
        └─► [não] Enc Nao Encontrada
```

### Fluxo de visitantes (multi-step)
**Etapas de sessão:**
```
visitante_nome → visitante_documento → visitante_data → visitante_motivo → (ok=true)
```
Ao concluir: INSERT em `visitantes` (nome, morador_id, documento, entrada=now).

**Padrão de sessão em todos os fluxos multi-step:**
```
DELETE Sessao → Fluxo OK? (IF)
  ├─► [ainda em andamento] INSERT Sessao (próxima etapa) → Enviar resposta
  └─► [ok=true] INSERT dado final → Enviar resposta final
```
> A sessão usa DELETE+INSERT, não UPSERT. Isso garante sempre um único registro por telefone.

### Fluxo de solicitação de serviço (multi-step)
**Etapas de sessão:**
```
servico_tipo → servico_local → servico_descricao → servico_urgencia → (ok=true)
```
Ao concluir: INSERT em `requisicoes` (status='pendente'). Protocolo gerado: `SV-` + 6 últimos dígitos de `Date.now()`.

Campos salvos: `tipo`, `local_servico`, `descricao`, `urgencia`, `morador_id`, `telefone`.

### Fluxo de ocorrências (multi-step)
**Etapas de sessão:**
```
ocorrencia_tipo → ocorrencia_local → ocorrencia_descricao → ocorrencia_urgencia → (ok=true)
```
Ao concluir: INSERT em `atendimentos` com campos separados: `titulo` (tipo + local), `mensagem` (descrição), `local_ocorrencia`, `urgencia`, status='aberta'. Protocolo gerado: `OC-` + 6 últimos dígitos de `Date.now()`.

Urgências aceitas: `baixa`, `média`/`media`, `alta`. Qualquer outro valor vira `Não informada`.

### Fluxo de reservas de áreas comuns (multi-step)
**Etapas de sessão:**
```
reserva_area → reserva_data → reserva_horario → (ok=true)
```
Áreas disponíveis: `1` → Salão de Festas, `2` → Churrasqueira, `3` → Quadra Esportiva.

Data aceita no formato DD/MM/AAAA (validação por regex). Ao concluir: INSERT em `reservas` com `morador_id`, `area`, `data` (ISO YYYY-MM-DD), `horario`, `status='pendente'`. O administrador confirma ou recusa pelo dashboard.

### Fluxo de cancelamento
```
Cancelar Fluxo → DELETE Sessao Cancelar → Enviar Cancelamento
```
Limpa a sessão e orienta o morador a digitar `menu`.

---

## Webhook de Notificação (`notificacao_webhook.json`)

Workflow n8n auxiliar importado junto com o bot principal. Permite que o dashboard envie WhatsApp sem bloqueio de CORS (browser não pode chamar Evolution API diretamente com PUT/POST+JSON).

**Endpoint:** `GET https://n8n.automacaopme.com.br/webhook/notificar-encomenda?number=55...&text=...`

**Fluxo:** Webhook1 (GET) → Enviar WhatsApp (POST Evolution API `Bot_Condominio`)

- Response Mode: "When Last Node Finishes" (sem nó Responder 200)
- Expressões no nó Enviar WhatsApp: `{{ $json.query.number }}` e `{{ $json.query.text }}`
- Usado pelo `PackageApp.advance()` ao mover encomenda para "Notificado"

---

## Dashboard Admin (`index.html`)

SPA pura: nenhum framework, nenhum build. Abre direto no browser. Navegação client-side via atributos `data-page`.

### Páginas
| Página | Conteúdo |
|---|---|
| **Dashboard** | Status do bot, métricas (ocorrências, visitantes, encomendas, moradores), fila de aprovações, ocorrências em aberto (top 3), reservas dinâmicas, comunicados dinâmicos, atividade recente |
| **Requisições** | Kanban conectado à tabela `requisicoes` |
| **Ocorrências** | Kanban 4 colunas: Aberta → Em análise → Em andamento → Resolvida — conectado à tabela `atendimentos` |
| **Encomendas** | Kanban 3 colunas: Recebida → Notificado → Retirada. Avançar para "Notificado" dispara WhatsApp via webhook n8n |
| **Visitantes** | Lista com filtros (todos/hoje/sem saída) + form de registro manual |
| **Moradores** | Busca + lista agrupada por bloco (ordem numérica de apartamento) + form de cadastro + edição inline + exclusão |
| **Reservas** | Lista filtrada por status (todas/pendentes/confirmadas/canceladas) + form de nova reserva + confirmar/recusar por card |

### Funcionalidades do dashboard por módulo

**Encomendas (`PackageApp`):**
- Card mostra: descrição, nome do morador em negrito, Ap. X · Bl. Y
- Botão ✕ exclui a encomenda do Supabase
- Avançar para "Notificado" → envia WhatsApp via `sendWhatsApp()` (GET ao webhook n8n)
- Form de nova encomenda: busca morador por apto+bloco com preview em tempo real; salva somente se morador for encontrado (`createWithMorador`)
- `fmtRelative()` mostra hora real HH:MM (ex: "hoje 14:19") em vez de apenas "há Xh"

**Moradores (`MoradorApp`):**
- Lista agrupada por bloco com cabeçalho "Bloco A (N)" e ordenação numérica de apartamento
- Botão "✏️ Editar" abre modal com campos pré-preenchidos; salva via PATCH no Supabase
- Botão "🗑 Excluir" com confirmação; DELETE no Supabase
- Telefone obrigatório no cadastro
- Bloco obrigatório com opção N/A (checkbox desabilita campo)

**Reservas (`ReservaApp`):**
- Layout 2 colunas no desktop: calendário mensal fixo à esquerda, lista à direita
- **Calendário:** chips coloridos por área (🔵 Salão · 🟠 Churrasqueira · 🟢 Quadra); chips opacos = pendente, sólidos = confirmada; canceladas ocultadas; clicar em dia filtra a lista para aquela data; tag "📅 DD/MM ×" aparece para limpar o filtro
- **Navegação:** botões ‹/› percorrem meses; variáveis `calYear`/`calMonth`/`calDateFilter` controlam o estado
- Lista filtrada por status (todas/pendentes/confirmadas/canceladas) + filtro de data do calendário combinados
- Botões Confirmar / Recusar em cards pendentes; PATCH `status` + re-renderiza calendário e widget do dashboard
- Form de nova reserva (admin): busca morador por apto+bloco com preview; campos área, data (type=date), horário
- **Validação de conflito em tempo real:** ao mudar área ou data, verifica reservas existentes — aviso amarelo se há pendente, vermelho + bloqueio do botão se há confirmada na mesma área+data
- Widget "Próximas reservas" no dashboard: 5 próximas reservas não canceladas, ordenadas por data
- `fmtDataBr()` converte ISO YYYY-MM-DD para DD/MM/AAAA na exibição

**Comunicados (`ComunicadoApp`):**
- Widget no dashboard mostra últimos 10 comunicados com badge Enviado / Rascunho
- Modal "+ Novo": título + mensagem; dois botões: "Salvar rascunho" e "Enviar a todos"
- "Enviar a todos": cria registro no banco, busca todos os moradores com telefone, envia WhatsApp a cada um via webhook n8n, atualiza `status='enviado'`, `enviado_em` e `destinatarios`
- Envio é sequencial com barra de progresso (ex: "Enviando... 47/128")

**Configurações do Bot (modal):**
- Ícone ⚙️ na topbar abre modal de configurações
- Campo para alterar o nome do bot no WhatsApp via `POST /chat/updateProfileName/Bot_Condominio` com body `{ "name": "..." }` (Evolution API v2.3.7)

### Tema
- **Dark:** `--bg-page: #0B1623` (navy Automatiz.ia)
- **Light:** `--bg-page: #F7F3EC` (off-white quente)
- Persistido em `localStorage['portaria-theme']`. Padrão: `light`.

### Cores de marca
```css
--brand-primary:      #3D8BFF  /* azul */
--brand-primary-dark: #0E2D7A
--brand-accent:       #F5A623  /* laranja */
```

### Fontes
- **Outfit** (400/500/600/700/800) — UI principal
- **Space Mono** (400/700) — labels monospace, métricas

### Ícones
SVG sprite inline no topo do `<body>`. Novos ícones devem ser adicionados ao sprite como `<symbol id="icon-NOME">`. Uso: `<svg class="icon"><use href="#icon-NOME"/></svg>`.

### Helper Supabase
```js
supaApi(method, path, body)  // retorna Promise
// Exemplos:
supaApi('GET', '/moradores?select=*')
supaApi('POST', '/moradores', { nome, telefone, apartamento, bloco })
supaApi('PATCH', '/encomendas?id=eq.5', { status: 'retirado' })
supaApi('DELETE', '/sessoes?telefone=eq.5511999999999')
```

### Toast
```js
showToast('Mensagem de sucesso')
showToast('Algo deu errado', 'error')
```

### Responsivo
- **Mobile (<768px):** bottom nav, colunas em 1 ou 2, Kanban em lista agrupada
- **Desktop (≥768px):** sidebar lateral, grid 4 colunas, Kanban em matriz

---

## Como editar o workflow do bot

1. Abra o n8n e importe `bot_condominio.json` (ou edite diretamente se já importado).
2. Ao adicionar um novo módulo (ex: votação em assembleia), siga o padrão:
   - Prefixo de sessão único (ex: `votacao_`)
   - Adicionar nova rota no **Roteador** (Code node) e uma nova saída no **Switch Rota**
   - DELETE sessão → Lógica → IF ok? → INSERT sessão (se continua) ou INSERT dado final (se concluiu) → Enviar mensagem
3. Exporte como JSON e substitua `bot_condominio.json`.

## Como editar o dashboard

`index.html` é auto-contido. Edite diretamente — não há processo de build, transpilação ou dependências locais. Ao adicionar uma nova página:
1. Criar `<div class="page" id="page-NOME">` dentro de `<main class="main">`
2. Adicionar item no `.sidebar` com `data-page="NOME"`
3. Adicionar item no `.bottom-nav` com `data-page="NOME"`
4. O sistema de navegação detecta automaticamente pelo atributo `data-page`.

---

## Persistência do dashboard

Todas as páginas recarregam dados do Supabase ao serem navegadas. Auto-refresh a cada 60s cobre todas as páginas.

| App JS | Tabela Supabase | Padrão de escrita |
|---|---|---|
| `OccApp` | `atendimentos` | PATCH status via `advance()` |
| `ReqApp` | `requisicoes` | PATCH status via `advance()` |
| `PackageApp` | `encomendas` | PATCH status + DELETE + POST via `createWithMorador()` |
| `VisitorApp` | `visitantes` | POST + lista |
| `MoradorApp` | `moradores` | POST + PATCH (edição) + DELETE + busca |
| `ReservaApp` | `reservas` | POST + PATCH status (confirmar/cancelar) |
| `ComunicadoApp` | `comunicados` | POST (rascunho ou envio) + PATCH status após envio em massa via WhatsApp |

---

## Módulos pendentes / TODOs

- **SQL no Supabase** — rodar o script abaixo se ainda não aplicado:
  ```sql
  ALTER TABLE atendimentos
    ADD COLUMN IF NOT EXISTS titulo text,
    ADD COLUMN IF NOT EXISTS local_ocorrencia text,
    ADD COLUMN IF NOT EXISTS urgencia text DEFAULT 'media',
    ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

  CREATE TABLE IF NOT EXISTS requisicoes (
    id bigint generated always as identity primary key,
    telefone text,
    morador_id bigint REFERENCES moradores(id),
    tipo text,
    local_servico text,
    descricao text,
    urgencia text DEFAULT 'media',
    status text DEFAULT 'pendente',
    created_at timestamptz DEFAULT now()
  );
  ALTER TABLE requisicoes ENABLE ROW LEVEL SECURITY;
  CREATE POLICY "anon all" ON requisicoes USING (true) WITH CHECK (true);

  CREATE TABLE IF NOT EXISTS reservas (
    id bigint generated always as identity primary key,
    morador_id bigint REFERENCES moradores(id),
    area text NOT NULL,
    data date NOT NULL,
    horario text,
    status text DEFAULT 'pendente',
    created_at timestamptz DEFAULT now()
  );
  ALTER TABLE reservas ENABLE ROW LEVEL SECURITY;
  CREATE POLICY "anon all" ON reservas USING (true) WITH CHECK (true);

  CREATE TABLE IF NOT EXISTS comunicados (
    id bigint generated always as identity primary key,
    titulo text NOT NULL,
    mensagem text NOT NULL,
    status text DEFAULT 'rascunho',
    enviado_em timestamptz,
    destinatarios int DEFAULT 0,
    created_at timestamptz DEFAULT now()
  );
  ALTER TABLE comunicados ENABLE ROW LEVEL SECURITY;
  CREATE POLICY "anon all" ON comunicados USING (true) WITH CHECK (true);
  ```
- **Reservas de áreas comuns** ✅ — bot com fluxo multi-step (`reserva_area` → `reserva_data` → `reserva_horario`); menu posição 4 ("Fazer Reserva"); dashboard com calendário mensal, validação de conflito em tempo real, kanban de aprovação e widget no painel; tabela `reservas` criada no Supabase. A fila de aprovações do painel principal ainda está mockada.
- **Comunicados** ✅ — modal para criar/enviar comunicados, `ComunicadoApp` conectado à tabela `comunicados`, envio em massa via webhook n8n WhatsApp; tabela `comunicados` criada no Supabase.
- **Painel de aprovações** — botões de aprovar/rejeitar existem no HTML mas sem JS conectado.
- **Nós legados** — `Resp Visitantes` e `Resp Ocorrencias` (usando API key `720C1736...`) são stubs antigos que foram substituídos pelos fluxos multi-step. Podem ser removidos do workflow.
- **Segurança** — mover as chaves de API (Supabase anon key e Evolution API key) para variáveis de ambiente do n8n antes de usar em produção com múltiplos clientes.
