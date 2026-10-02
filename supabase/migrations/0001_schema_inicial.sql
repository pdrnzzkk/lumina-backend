-- =====================================================================
-- Lumina — schema inicial (Supabase / PostgreSQL 15+)
-- Como rodar: Supabase Dashboard > SQL Editor > colar tudo > Run (uma vez).
--
-- Princípio de segurança deste schema:
--  * O app (role "authenticated") só LÊ os próprios dados e só INSERE
--    registros que representam "o aluno começou/fez algo".
--  * Tudo que é derivado/confiável (correta, duração, pontuação, plano,
--    papel, streak, assinatura) é calculado por trigger ou escrito pelo
--    backend FastAPI com a chave service_role (que ignora RLS).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. ENUMS
-- ---------------------------------------------------------------------
create type public.papel_usuario      as enum ('aluno', 'professor', 'admin');
create type public.plano_usuario      as enum ('gratis', 'premium');
create type public.plano_assinatura   as enum ('premium');
create type public.dificuldade_questao as enum ('facil', 'medio', 'dificil', 'ita');
create type public.origem_questao     as enum ('acervo', 'gerada_ia');
create type public.tipo_simulado      as enum ('multi_materia', 'materia_unica');
create type public.contexto_resposta  as enum ('banco_livre', 'simulado', 'desafio_diario');
create type public.status_assinatura  as enum ('ativa', 'cancelada', 'atrasada');
create type public.status_ticket      as enum ('aberto', 'em_andamento', 'resolvido');

-- ---------------------------------------------------------------------
-- 1. TABELAS
-- ---------------------------------------------------------------------
create table public.materias (
  id    integer generated always as identity primary key,
  nome  text not null unique,
  icone text
);

create table public.vestibulares (
  id        integer generated always as identity primary key,
  nome      text not null unique,
  descricao text
);

-- 1 linha por usuário do Supabase Auth (criada pelo trigger handle_new_user)
create table public.usuarios (
  id                 uuid primary key references auth.users (id) on delete cascade,
  nome               text not null check (length(btrim(nome)) > 0),
  email              text not null unique,
  papel              public.papel_usuario not null default 'aluno',
  vestibular_alvo_id integer references public.vestibulares (id) on delete set null,
  plano              public.plano_usuario not null default 'gratis',
  tema_preferido     text not null default 'escuro'
                       check (tema_preferido in ('escuro', 'claro', 'sistema')),
  streak_atual       integer not null default 0 check (streak_atual >= 0),
  maior_streak       integer not null default 0,
  criado_em          timestamptz not null default now(),
  -- atualizar streak_atual e maior_streak no mesmo UPDATE
  constraint usuarios_maior_streak_ck check (maior_streak >= streak_atual)
);

create table public.questoes (
  id                  bigint generated always as identity primary key,
  enunciado           text not null,
  materia_id          integer not null references public.materias (id) on delete restrict,
  vestibular_id       integer references public.vestibulares (id) on delete set null,
  ano                 smallint check (ano between 1900 and 2100),
  dificuldade         public.dificuldade_questao not null,
  origem              public.origem_questao not null default 'acervo',
  -- questão do acervo usada como âncora para gerar/calibrar uma questão por IA
  questao_ancora_id   bigint references public.questoes (id) on delete set null,
  resolucao_comentada text,
  criado_em           timestamptz not null default now(),
  constraint questoes_ancora_diferente_ck check (questao_ancora_id <> id)
);

create table public.alternativas (
  id         bigint generated always as identity primary key,
  questao_id bigint not null references public.questoes (id) on delete cascade,
  letra      char(1) not null check (letra in ('A', 'B', 'C', 'D', 'E')),
  texto      text not null,
  correta    boolean not null default false,
  unique (questao_id, letra)
);
-- no máximo 1 alternativa correta por questão
create unique index alternativas_uma_correta_uq
  on public.alternativas (questao_id) where correta;

create table public.simulados (
  id                   bigint generated always as identity primary key,
  titulo               text not null,
  tipo                 public.tipo_simulado not null,
  tempo_limite_minutos integer not null check (tempo_limite_minutos > 0),
  criado_por           uuid references public.usuarios (id) on delete set null,
  criado_em            timestamptz not null default now()
);

create table public.simulado_questoes (
  simulado_id bigint not null references public.simulados (id) on delete cascade,
  questao_id  bigint not null references public.questoes (id) on delete cascade,
  ordem       integer not null check (ordem > 0),
  primary key (simulado_id, questao_id),
  -- deferrable permite reordenar questões numa única transação
  constraint simulado_questoes_ordem_uq unique (simulado_id, ordem)
    deferrable initially deferred
);

create table public.tentativas_simulado (
  id            bigint generated always as identity primary key,
  simulado_id   bigint not null references public.simulados (id) on delete cascade,
  usuario_id    uuid not null references public.usuarios (id) on delete cascade,
  iniciado_em   timestamptz not null default now(),
  finalizado_em timestamptz,
  pontuacao     numeric(6, 2) check (pontuacao >= 0),
  constraint tentativas_fim_apos_inicio_ck
    check (finalizado_em is null or finalizado_em >= iniciado_em)
);

-- a questão do dia é sorteada pelo backend (o cliente não escolhe)
create table public.desafios_diarios (
  id          bigint generated always as identity primary key,
  usuario_id  uuid not null references public.usuarios (id) on delete cascade,
  questao_id  bigint not null references public.questoes (id) on delete cascade,
  data        date not null default (timezone('America/Sao_Paulo', now()))::date,
  completado  boolean not null default false,
  unique (usuario_id, data)
);

create table public.respostas (
  id                      bigint generated always as identity primary key,
  usuario_id              uuid not null references public.usuarios (id) on delete cascade,
  questao_id              bigint not null references public.questoes (id) on delete cascade,
  alternativa_escolhida_id bigint not null references public.alternativas (id) on delete cascade,
  correta                 boolean not null,  -- sempre definida pelo trigger, nunca pelo cliente
  contexto                public.contexto_resposta not null,
  tentativa_simulado_id   bigint references public.tentativas_simulado (id) on delete cascade,
  desafio_diario_id       bigint references public.desafios_diarios (id) on delete cascade,
  tempo_gasto_segundos    integer not null default 0 check (tempo_gasto_segundos >= 0),
  respondido_em           timestamptz not null default now(),
  -- o contexto tem que bater com o vínculo informado
  constraint respostas_contexto_simulado_ck
    check ((contexto = 'simulado') = (tentativa_simulado_id is not null)),
  constraint respostas_contexto_desafio_ck
    check ((contexto = 'desafio_diario') = (desafio_diario_id is not null))
);
-- uma resposta por questão em cada tentativa de simulado / por desafio
create unique index respostas_tentativa_questao_uq
  on public.respostas (tentativa_simulado_id, questao_id) where tentativa_simulado_id is not null;
create unique index respostas_desafio_uq
  on public.respostas (desafio_diario_id) where desafio_diario_id is not null;

create table public.sessoes_modo_caverna (
  id                bigint generated always as identity primary key,
  usuario_id        uuid not null references public.usuarios (id) on delete cascade,
  materia_id        integer references public.materias (id) on delete set null,
  iniciado_em       timestamptz not null default now(),
  finalizado_em     timestamptz,
  duracao_segundos  integer check (duracao_segundos >= 0),
  bloqueio_ativado  boolean not null default false,
  constraint sessoes_fim_apos_inicio_ck
    check (finalizado_em is null or finalizado_em >= iniciado_em)
);

create table public.assinaturas (
  id               bigint generated always as identity primary key,
  usuario_id       uuid not null references public.usuarios (id) on delete cascade,
  plano            public.plano_assinatura not null default 'premium',
  status           public.status_assinatura not null default 'ativa',
  iniciada_em      timestamptz not null default now(),
  proxima_cobranca timestamptz
);
-- só uma assinatura ativa por usuário
create unique index assinaturas_uma_ativa_uq
  on public.assinaturas (usuario_id) where status = 'ativa';

create table public.tickets_suporte (
  id             bigint generated always as identity primary key,
  usuario_id     uuid not null references public.usuarios (id) on delete cascade,
  assunto        text not null,
  mensagem       text not null,
  status         public.status_ticket not null default 'aberto',
  criado_em      timestamptz not null default now(),
  respondido_por uuid references public.usuarios (id) on delete set null
);

-- ---------------------------------------------------------------------
-- 2. FUNÇÕES AUXILIARES E TRIGGERS
-- ---------------------------------------------------------------------

-- Papel do usuário logado. SECURITY DEFINER para poder ler "usuarios"
-- dentro de policies sem causar recursão infinita de RLS.
create function public.papel_atual()
returns public.papel_usuario
language sql stable security definer set search_path = ''
as $$ select u.papel from public.usuarios u where u.id = (select auth.uid()) $$;

create function public.eh_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(public.papel_atual() = 'admin', false) $$;

create function public.eh_staff()  -- professor ou admin
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(public.papel_atual() in ('professor', 'admin'), false) $$;

revoke execute on function public.papel_atual(), public.eh_admin(), public.eh_staff()
  from public, anon;
grant execute on function public.papel_atual(), public.eh_admin(), public.eh_staff()
  to authenticated;

-- Cria a linha em "usuarios" quando alguém se cadastra no Supabase Auth.
-- O papel NUNCA vem dos metadados do cadastro (evita virar admin sozinho).
create function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.usuarios (id, nome, email)
  values (
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1)),
    new.email
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Define "correta" a partir da alternativa escolhida (o cliente não decide
-- se acertou) e garante que a alternativa pertence à questão.
create function public.respostas_definir_correta()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_correta boolean;
begin
  select a.correta into v_correta
    from public.alternativas a
   where a.id = new.alternativa_escolhida_id
     and a.questao_id = new.questao_id;

  if not found then
    raise exception 'Alternativa % não pertence à questão %',
      new.alternativa_escolhida_id, new.questao_id;
  end if;

  new.correta := v_correta;
  new.respondido_em := now();
  return new;
end $$;

create trigger trg_respostas_definir_correta
  before insert on public.respostas
  for each row execute function public.respostas_definir_correta();

-- Modo caverna: o servidor controla início, fim e duração (anti-fraude no
-- ranking). O backend (service_role) pode gravar valores livremente.
create function public.caverna_calcular_duracao()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if (select auth.role()) = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.iniciado_em := now();
    new.finalizado_em := null;
    new.duracao_segundos := null;
  else
    new.iniciado_em := old.iniciado_em;
    if old.finalizado_em is not null then          -- sessão encerrada é imutável
      new.finalizado_em := old.finalizado_em;
      new.duracao_segundos := old.duracao_segundos;
    elsif new.finalizado_em is not null then        -- encerrando agora
      new.finalizado_em := now();
      new.duracao_segundos := greatest(0, extract(epoch from (now() - old.iniciado_em))::integer);
    else
      new.duracao_segundos := null;
    end if;
  end if;
  return new;
end $$;

create trigger trg_caverna_calcular_duracao
  before insert or update on public.sessoes_modo_caverna
  for each row execute function public.caverna_calcular_duracao();

-- ---------------------------------------------------------------------
-- 3. VIEWS
-- ---------------------------------------------------------------------

-- Ranking diário do modo caverna. Soma as sessões finalizadas por dia
-- (fuso de Brasília) e numera a posição (empates dividem a posição).
-- Roda com os direitos do dono da view (ignora RLS) de propósito: o ranking
-- precisa somar TODOS os usuários, mas só expõe nome e tempo total.
create or replace view public.ranking_diario as
with diario as (
  select s.usuario_id,
         (s.iniciado_em at time zone 'America/Sao_Paulo')::date as data,
         sum(s.duracao_segundos)::bigint as tempo_total_segundos
    from public.sessoes_modo_caverna s
   where s.duracao_segundos is not null
   group by 1, 2
)
select d.data,
       rank() over (partition by d.data order by d.tempo_total_segundos desc) as posicao,
       d.usuario_id,
       u.nome,
       d.tempo_total_segundos
  from diario d
  join public.usuarios u on u.id = d.usuario_id;

-- Leitura AGREGADA de desempenho. Aluno vê só o próprio; professor/admin
-- veem todos, mas apenas os números agregados (nunca as respostas linha a linha).
create or replace view public.desempenho_usuario_materia as
select r.usuario_id,
       q.materia_id,
       count(*)::integer                                   as total_respostas,
       (count(*) filter (where r.correta))::integer        as acertos,
       round(100.0 * count(*) filter (where r.correta) / count(*), 1) as percentual_acerto,
       round(avg(r.tempo_gasto_segundos))::integer         as tempo_medio_segundos
  from public.respostas r
  join public.questoes q on q.id = r.questao_id
 where r.usuario_id = (select auth.uid())
    or (select public.eh_staff())
 group by r.usuario_id, q.materia_id;

-- ---------------------------------------------------------------------
-- 4. ÍNDICES
-- (PKs, UNIQUEs e o par (usuario_id, data) de desafios já têm índice próprio)
-- ---------------------------------------------------------------------
create index questoes_materia_idx          on public.questoes (materia_id);
create index questoes_vestibular_idx       on public.questoes (vestibular_id);
create index questoes_dificuldade_idx      on public.questoes (dificuldade);
create index questoes_materia_dific_idx    on public.questoes (materia_id, dificuldade);
create index questoes_ancora_idx           on public.questoes (questao_ancora_id)
  where questao_ancora_id is not null;

create index simulados_criado_por_idx      on public.simulados (criado_por);
create index simulado_questoes_questao_idx on public.simulado_questoes (questao_id);

create index tentativas_usuario_idx        on public.tentativas_simulado (usuario_id, iniciado_em desc);
create index tentativas_simulado_idx       on public.tentativas_simulado (simulado_id);

create index respostas_usuario_idx         on public.respostas (usuario_id, respondido_em desc);
create index respostas_questao_idx         on public.respostas (questao_id);

create index sessoes_usuario_idx           on public.sessoes_modo_caverna (usuario_id, iniciado_em desc);
create index sessoes_iniciado_idx          on public.sessoes_modo_caverna (iniciado_em);

create index assinaturas_usuario_idx       on public.assinaturas (usuario_id);
create index tickets_usuario_idx           on public.tickets_suporte (usuario_id);
create index tickets_status_idx            on public.tickets_suporte (status);
create index usuarios_vestibular_alvo_idx  on public.usuarios (vestibular_alvo_id);

-- ---------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- Com RLS ligado e sem policy para um comando, esse comando é NEGADO.
-- (select auth.uid()) em vez de auth.uid() = avaliado 1 vez por query (mais rápido).
-- ---------------------------------------------------------------------
alter table public.materias             enable row level security;
alter table public.vestibulares         enable row level security;
alter table public.usuarios             enable row level security;
alter table public.questoes             enable row level security;
alter table public.alternativas         enable row level security;
alter table public.simulados            enable row level security;
alter table public.simulado_questoes    enable row level security;
alter table public.tentativas_simulado  enable row level security;
alter table public.desafios_diarios     enable row level security;
alter table public.respostas            enable row level security;
alter table public.sessoes_modo_caverna enable row level security;
alter table public.assinaturas          enable row level security;
alter table public.tickets_suporte      enable row level security;

-- ===== usuarios =====
-- Cada um lê a própria linha.
create policy usuarios_select_proprio on public.usuarios
  for select to authenticated
  using (id = (select auth.uid()));

-- Admin lê todos (gestão). Edição de outros usuários passa pelo backend.
create policy usuarios_select_admin on public.usuarios
  for select to authenticated
  using ((select public.eh_admin()));

-- Cada um edita a própria linha. Quais COLUNAS podem mudar é limitado pelos
-- GRANTs da seção 6 (só nome, vestibular_alvo_id e tema_preferido).
create policy usuarios_update_proprio on public.usuarios
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ===== catálogo: materias e vestibulares =====
create policy materias_select on public.materias
  for select to authenticated using (true);
create policy materias_escrita_admin on public.materias
  for all to authenticated
  using ((select public.eh_admin())) with check ((select public.eh_admin()));

create policy vestibulares_select on public.vestibulares
  for select to authenticated using (true);
create policy vestibulares_escrita_admin on public.vestibulares
  for all to authenticated
  using ((select public.eh_admin())) with check ((select public.eh_admin()));

-- ===== questoes e alternativas =====
-- Todo usuário logado lê o banco. Limites do plano grátis ficam no backend.
create policy questoes_select on public.questoes
  for select to authenticated using (true);
-- Professor e admin criam/editam; só admin apaga.
create policy questoes_insert_staff on public.questoes
  for insert to authenticated with check ((select public.eh_staff()));
create policy questoes_update_staff on public.questoes
  for update to authenticated
  using ((select public.eh_staff())) with check ((select public.eh_staff()));
create policy questoes_delete_admin on public.questoes
  for delete to authenticated using ((select public.eh_admin()));

create policy alternativas_select on public.alternativas
  for select to authenticated using (true);
create policy alternativas_insert_staff on public.alternativas
  for insert to authenticated with check ((select public.eh_staff()));
create policy alternativas_update_staff on public.alternativas
  for update to authenticated
  using ((select public.eh_staff())) with check ((select public.eh_staff()));
create policy alternativas_delete_admin on public.alternativas
  for delete to authenticated using ((select public.eh_admin()));

-- ===== simulados e simulado_questoes =====
create policy simulados_select on public.simulados
  for select to authenticated using (true);
-- Professor/admin criam simulados em seu próprio nome.
create policy simulados_insert_staff on public.simulados
  for insert to authenticated
  with check ((select public.eh_staff()) and criado_por = (select auth.uid()));
-- Só o criador (ou admin) edita/apaga.
create policy simulados_update_dono on public.simulados
  for update to authenticated
  using (criado_por = (select auth.uid()) or (select public.eh_admin()))
  with check (criado_por = (select auth.uid()) or (select public.eh_admin()));
create policy simulados_delete_dono on public.simulados
  for delete to authenticated
  using (criado_por = (select auth.uid()) or (select public.eh_admin()));

create policy simulado_questoes_select on public.simulado_questoes
  for select to authenticated using (true);
-- Quem é dono do simulado (ou admin) monta a lista de questões.
create policy simulado_questoes_escrita_dono on public.simulado_questoes
  for all to authenticated
  using (exists (
    select 1 from public.simulados s
     where s.id = simulado_id
       and (s.criado_por = (select auth.uid()) or (select public.eh_admin()))))
  with check (exists (
    select 1 from public.simulados s
     where s.id = simulado_id
       and (s.criado_por = (select auth.uid()) or (select public.eh_admin()))));

-- ===== tentativas_simulado =====
create policy tentativas_select_proprio on public.tentativas_simulado
  for select to authenticated using (usuario_id = (select auth.uid()));
-- O aluno só INICIA a tentativa (sem fim e sem nota). Finalizar e pontuar
-- é feito pelo backend, para a nota não poder ser forjada.
create policy tentativas_insert_proprio on public.tentativas_simulado
  for insert to authenticated
  with check (usuario_id = (select auth.uid())
              and finalizado_em is null and pontuacao is null);

-- ===== desafios_diarios =====
-- Só leitura do próprio. O backend sorteia a questão e marca "completado".
create policy desafios_select_proprio on public.desafios_diarios
  for select to authenticated using (usuario_id = (select auth.uid()));

-- ===== respostas =====
create policy respostas_select_proprio on public.respostas
  for select to authenticated using (usuario_id = (select auth.uid()));
-- O aluno responde em nome próprio, e a tentativa/desafio citados têm que ser
-- DELE (impede lançar respostas na tentativa de outra pessoa). "correta" é
-- recalculada pelo trigger.
create policy respostas_insert_proprio on public.respostas
  for insert to authenticated
  with check (
    usuario_id = (select auth.uid())
    and (tentativa_simulado_id is null or exists (
      select 1 from public.tentativas_simulado t
       where t.id = tentativa_simulado_id and t.usuario_id = (select auth.uid())))
    and (desafio_diario_id is null or exists (
      select 1 from public.desafios_diarios d
       where d.id = desafio_diario_id and d.usuario_id = (select auth.uid())))
  );

-- ===== sessoes_modo_caverna =====
create policy sessoes_select_proprio on public.sessoes_modo_caverna
  for select to authenticated using (usuario_id = (select auth.uid()));
create policy sessoes_insert_proprio on public.sessoes_modo_caverna
  for insert to authenticated with check (usuario_id = (select auth.uid()));
-- Encerrar a própria sessão; o trigger define fim e duração.
create policy sessoes_update_proprio on public.sessoes_modo_caverna
  for update to authenticated
  using (usuario_id = (select auth.uid()))
  with check (usuario_id = (select auth.uid()));

-- ===== assinaturas =====
-- Só leitura do próprio. Criar/alterar vem do webhook de pagamento (backend).
create policy assinaturas_select_proprio on public.assinaturas
  for select to authenticated using (usuario_id = (select auth.uid()));

-- ===== tickets_suporte =====
create policy tickets_select_proprio on public.tickets_suporte
  for select to authenticated using (usuario_id = (select auth.uid()));
-- Abre ticket em nome próprio, sempre como "aberto" e sem responsável.
create policy tickets_insert_proprio on public.tickets_suporte
  for insert to authenticated
  with check (usuario_id = (select auth.uid())
              and status = 'aberto' and respondido_por is null);
-- Admin vê e responde todos os tickets.
create policy tickets_select_admin on public.tickets_suporte
  for select to authenticated using ((select public.eh_admin()));
create policy tickets_update_admin on public.tickets_suporte
  for update to authenticated
  using ((select public.eh_admin())) with check ((select public.eh_admin()));

-- ---------------------------------------------------------------------
-- 6. PERMISSÕES (GRANT/REVOKE)
-- ---------------------------------------------------------------------
-- Visitante sem login não acessa nada.
revoke all on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- Impede que o usuário se promova a admin/premium ou altere o streak:
-- só estas colunas de "usuarios" podem ser editadas pelo app.
revoke update on public.usuarios from authenticated;
grant update (nome, vestibular_alvo_id, tema_preferido) on public.usuarios to authenticated;

-- Views (rodam com direitos do dono; o filtro de segurança está dentro delas)
grant select on public.ranking_diario, public.desempenho_usuario_materia to authenticated;
