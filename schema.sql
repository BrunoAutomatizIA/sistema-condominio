-- ============================================================
--  Escola Digital — Colégio Raio de Luz
--  Schema Supabase
--  Rodar no SQL Editor do novo projeto Supabase
-- ============================================================

-- 1. RESPONSÁVEIS (pais / responsáveis)
CREATE TABLE IF NOT EXISTS responsaveis (
  id          bigint generated always as identity primary key,
  nome        text NOT NULL,
  telefone    text NOT NULL,
  aluno       text,
  turma       text,
  created_at  timestamptz DEFAULT now()
);
ALTER TABLE responsaveis ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON responsaveis USING (true) WITH CHECK (true);

-- 2. CARDÁPIO SEMANAL
CREATE TABLE IF NOT EXISTS cardapio (
  id            bigint generated always as identity primary key,
  semana_inicio date NOT NULL,
  segunda       text,
  terca         text,
  quarta        text,
  quinta        text,
  sexta         text,
  created_at    timestamptz DEFAULT now()
);
ALTER TABLE cardapio ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON cardapio USING (true) WITH CHECK (true);

-- 3. AGENDA DE EVENTOS
CREATE TABLE IF NOT EXISTS agenda (
  id         bigint generated always as identity primary key,
  titulo     text NOT NULL,
  data       date NOT NULL,
  turma      text,
  descricao  text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE agenda ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON agenda USING (true) WITH CHECK (true);

-- 4. OCORRÊNCIAS ESCOLARES
CREATE TABLE IF NOT EXISTS ocorrencias_escola (
  id             bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id) ON DELETE SET NULL,
  aluno          text,
  titulo         text,
  descricao      text,
  urgencia       text DEFAULT 'media',
  status         text DEFAULT 'aberta',
  created_at     timestamptz DEFAULT now()
);
ALTER TABLE ocorrencias_escola ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON ocorrencias_escola USING (true) WITH CHECK (true);

-- 5. SOLICITAÇÕES DE SERVIÇO
CREATE TABLE IF NOT EXISTS solicitacoes (
  id             bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id) ON DELETE SET NULL,
  tipo           text,
  descricao      text,
  urgencia       text DEFAULT 'media',
  status         text DEFAULT 'pendente',
  created_at     timestamptz DEFAULT now()
);
ALTER TABLE solicitacoes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON solicitacoes USING (true) WITH CHECK (true);

-- 6. AVISOS INDIVIDUAIS / POR TURMA
CREATE TABLE IF NOT EXISTS avisos (
  id             bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id) ON DELETE SET NULL,
  titulo         text NOT NULL,
  mensagem       text,
  status         text DEFAULT 'pendente',
  created_at     timestamptz DEFAULT now()
);
ALTER TABLE avisos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON avisos USING (true) WITH CHECK (true);

-- 7. AUTORIZAÇÕES DE SAÍDA
CREATE TABLE IF NOT EXISTS autorizacoes (
  id               bigint generated always as identity primary key,
  responsavel_id   bigint REFERENCES responsaveis(id) ON DELETE SET NULL,
  nome_autorizador text,
  documento        text,
  parentesco       text,
  created_at       timestamptz DEFAULT now()
);
ALTER TABLE autorizacoes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON autorizacoes USING (true) WITH CHECK (true);

-- 8. RESERVAS DE ESPAÇOS
CREATE TABLE IF NOT EXISTS reservas_escola (
  id             bigint generated always as identity primary key,
  responsavel_id bigint REFERENCES responsaveis(id) ON DELETE SET NULL,
  local          text NOT NULL,
  data           date NOT NULL,
  horario        text,
  status         text DEFAULT 'pendente',
  created_at     timestamptz DEFAULT now()
);
ALTER TABLE reservas_escola ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON reservas_escola USING (true) WITH CHECK (true);

-- 9. COMUNICADOS GERAIS
CREATE TABLE IF NOT EXISTS comunicados_escola (
  id           bigint generated always as identity primary key,
  turma        text,
  titulo       text NOT NULL,
  mensagem     text NOT NULL,
  status       text DEFAULT 'rascunho',
  enviado_em   timestamptz,
  destinatarios int DEFAULT 0,
  created_at   timestamptz DEFAULT now()
);
ALTER TABLE comunicados_escola ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon all" ON comunicados_escola USING (true) WITH CHECK (true);
