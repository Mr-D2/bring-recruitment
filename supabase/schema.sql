-- ============================================================
-- br-ing · Recruitment Docenti AS 2026/27 — Schema Supabase
-- v1.0 · basato su Griglia Selezione v1.3 (Fogli 6 e 7)
-- Eseguire per intero nel SQL Editor di Supabase (una sola volta)
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- POOL C1 — 24 combinazioni (Foglio 6, Blocco 3)
-- ------------------------------------------------------------
create table public.c1_pool (
  id text primary key,                -- es. 'C1-T4-S2'
  strategia text not null,            -- Approfondimento | Generalizzazione | Inferenza
  strategia_num int not null,         -- 1 | 2 | 3
  obiettivo_gp text not null,
  definizione_operativa text not null,
  topic_id text not null,             -- T1..T8
  topic text not null,
  aree text[] not null                -- aree ammesse
);

insert into public.c1_pool (id, strategia, strategia_num, obiettivo_gp, definizione_operativa, topic_id, topic, aree)
select
  'C1-' || t.tid || '-S' || s.snum,
  s.nome, s.snum, s.gp, s.defop,
  t.tid, t.nome,
  t.aree
from (values
  (1, 'Approfondimento', 'Research (ricerca)',
   'portare gli studenti a scendere in profondità su un caso singolo: cercare, selezionare e distinguere ciò che è rilevante da ciò che non lo è'),
  (2, 'Generalizzazione', 'Analysis (analisi)',
   'portare gli studenti a estrarre da uno o più casi un principio trasferibile, e ad applicarlo a una situazione nuova'),
  (3, 'Inferenza', 'Evaluation (valutazione)',
   'portare gli studenti ad andare oltre il dato disponibile: dedurre, ipotizzare, e sostenere la conclusione con le evidenze che hanno')
) as s(snum, nome, gp, defop)
cross join (values
  ('T1', 'Acqua, cibo e agricoltura',                    array['lettere','matsci','primaria','inglese']),
  ('T2', 'Ambiente e biodiversità',                      array['lettere','matsci','primaria','inglese']),
  ('T3', 'Energia e risorse',                            array['lettere','matsci','primaria','inglese']),
  ('T4', 'Salute e benessere',                           array['lettere','musica','matsci','primaria','inglese']),
  ('T5', 'Mondo digitale',                               array['lettere','musica','matsci','primaria','inglese']),
  ('T6', 'Tradizione, cultura e identità',               array['lettere','musica','primaria','inglese']),
  ('T7', 'Lavoro, denaro e scambio',                     array['lettere','musica','matsci','primaria','inglese']),
  ('T8', 'Comunità che cambiano: migrazioni e città',    array['lettere','musica','matsci','primaria','inglese'])
) as t(tid, nome, aree);

-- Contatori per il round-robin (Foglio 6, Blocco 4, regole 1-2)
create table public.c1_strategy_counters (
  area text not null,
  strategia_num int not null,
  n int not null default 0,
  primary key (area, strategia_num)
);
insert into public.c1_strategy_counters (area, strategia_num)
select a, s from unnest(array['lettere','musica','matsci','primaria','inglese']) a,
             unnest(array[1,2,3]) s;

create table public.c1_topic_usage (
  area text not null,
  topic_id text not null,
  n int not null default 0,
  primary key (area, topic_id)
);
insert into public.c1_topic_usage (area, topic_id)
select a, t from unnest(array['lettere','musica','matsci','primaria','inglese']) a,
             unnest(array['T1','T2','T3','T4','T5','T6','T7','T8']) t;

-- ------------------------------------------------------------
-- CANDIDATI (Stadio 1)
-- ------------------------------------------------------------
create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  area text not null check (area in ('lettere','musica','matsci','primaria','inglese')),
  nome text, cognome text, telefono text,
  data_nascita date, comune text,
  sede text, auto_propria text, percorrenza text,
  consenso_selezione boolean not null default false,
  consenso_futuro boolean not null default false,
  c1_combo text references public.c1_pool(id),
  stage1_answers jsonb,
  cv_path text,
  status text not null default 'in_compilazione'
    check (status in ('in_compilazione','inviata','stadio2_invitato','stadio2_ricevuto',
                      'stadio3_convocato','esito_positivo','esito_negativo','riserva')),
  created_at timestamptz not null default now(),
  submitted_at timestamptz
);

-- Log override manuale combinazione (Foglio 6, Blocco 4, regola 5)
create table public.c1_overrides (
  id bigserial primary key,
  candidate_id uuid not null references public.candidates(id),
  old_combo text, new_combo text not null,
  changed_by text not null,
  motivo text,
  changed_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- CONTENITORI STADIO 2 e 3 (progettati ora, popolati dal Blocco A)
-- ------------------------------------------------------------
create table public.stage2_submissions (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id),
  consegna text not null,          -- 'lesson_plan' | 'verifica_sommativa' | 'comunicazione_famiglia' | ...
  contenuto jsonb,
  file_path text,
  ai_prescore jsonb,               -- proposta AI (sempre da validare)
  human_score jsonb,               -- valutazione umana che certifica
  created_at timestamptz not null default now()
);

create table public.stage3_interviews (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id),
  data_colloquio timestamptz,
  blocchi jsonb,                   -- note per blocco del protocollo colloquio
  punteggi jsonb,
  created_at timestamptz not null default now()
);

create table public.scoring (
  candidate_id uuid primary key references public.candidates(id),
  dim_scores jsonb,
  fit numeric,
  ko boolean not null default false,
  red_flags jsonb,
  flag_statale text check (flag_statale in ('basso','medio','alto')),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- RPC 1 — Assegnazione C1 al submit della Sezione 0
--   Round-robin sulla strategia (contatore minimo per area),
--   topic random tra gli ammessi meno usati, persistita sul record.
--   Idempotente: stessa email → stessa combinazione (regola 3).
-- ------------------------------------------------------------
create or replace function public.assign_c1(
  p_email text,
  p_area text,
  p_profile jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cand public.candidates%rowtype;
  v_snum int;
  v_topic text;
  v_combo text;
  v_pool public.c1_pool%rowtype;
begin
  if p_email is null or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'email non valida';
  end if;
  if (p_profile->>'consenso_selezione')::boolean is distinct from true then
    raise exception 'consenso obbligatorio mancante';
  end if;

  -- record esistente: restituisce la combinazione già assegnata (persistenza)
  select * into v_cand from public.candidates where lower(email) = lower(p_email);
  if found and v_cand.c1_combo is not null then
    select * into v_pool from public.c1_pool where id = v_cand.c1_combo;
    return jsonb_build_object(
      'candidate_id', v_cand.id, 'combo', v_pool.id,
      'strategia', v_pool.strategia, 'definizione_operativa', v_pool.definizione_operativa,
      'topic', v_pool.topic, 'obiettivo_gp', v_pool.obiettivo_gp,
      'ripresa', true
    );
  end if;

  -- strategia meno usata nell'area (lock per concorrenza)
  select strategia_num into v_snum
  from public.c1_strategy_counters
  where area = p_area
  order by n asc, random()
  limit 1
  for update;

  -- topic meno usato tra gli ammessi per l'area
  select u.topic_id into v_topic
  from public.c1_topic_usage u
  where u.area = p_area
    and exists (
      select 1 from public.c1_pool p
      where p.topic_id = u.topic_id and p_area = any(p.aree)
    )
  order by u.n asc, random()
  limit 1
  for update;

  v_combo := 'C1-' || v_topic || '-S' || v_snum;
  select * into v_pool from public.c1_pool where id = v_combo;

  update public.c1_strategy_counters set n = n + 1
    where area = p_area and strategia_num = v_snum;
  update public.c1_topic_usage set n = n + 1
    where area = p_area and topic_id = v_topic;

  if found and v_cand.id is not null then
    update public.candidates set
      area = p_area, c1_combo = v_combo,
      nome = p_profile->>'nome', cognome = p_profile->>'cognome',
      telefono = p_profile->>'telefono',
      data_nascita = nullif(p_profile->>'data_nascita','')::date,
      comune = p_profile->>'comune',
      sede = p_profile->>'sede', auto_propria = p_profile->>'auto',
      percorrenza = p_profile->>'percorrenza',
      consenso_selezione = true,
      consenso_futuro = coalesce((p_profile->>'consenso_futuro')::boolean, false)
    where id = v_cand.id;
  else
    insert into public.candidates
      (email, area, nome, cognome, telefono, data_nascita, comune,
       sede, auto_propria, percorrenza, consenso_selezione, consenso_futuro, c1_combo)
    values
      (lower(p_email), p_area, p_profile->>'nome', p_profile->>'cognome',
       p_profile->>'telefono', nullif(p_profile->>'data_nascita','')::date,
       p_profile->>'comune', p_profile->>'sede', p_profile->>'auto',
       p_profile->>'percorrenza', true,
       coalesce((p_profile->>'consenso_futuro')::boolean, false), v_combo)
    returning * into v_cand;
  end if;

  return jsonb_build_object(
    'candidate_id', v_cand.id, 'combo', v_pool.id,
    'strategia', v_pool.strategia, 'definizione_operativa', v_pool.definizione_operativa,
    'topic', v_pool.topic, 'obiettivo_gp', v_pool.obiettivo_gp,
    'ripresa', false
  );
end;
$$;

-- ------------------------------------------------------------
-- RPC 2 — Invio finale Stadio 1
-- ------------------------------------------------------------
create or replace function public.submit_stage1(
  p_candidate_id uuid,
  p_email text,
  p_answers jsonb,
  p_cv_path text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok int;
begin
  update public.candidates
  set stage1_answers = p_answers,
      cv_path = coalesce(p_cv_path, cv_path),
      status = 'inviata',
      submitted_at = coalesce(submitted_at, now())
  where id = p_candidate_id and lower(email) = lower(p_email);
  get diagnostics v_ok = row_count;
  if v_ok = 0 then
    raise exception 'candidato non trovato';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- RPC 3 — Override manuale combinazione (solo team autenticato)
-- ------------------------------------------------------------
create or replace function public.admin_override_c1(
  p_candidate_id uuid,
  p_new_combo text,
  p_motivo text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old text;
begin
  if auth.role() is distinct from 'authenticated' then
    raise exception 'non autorizzato';
  end if;
  select c1_combo into v_old from public.candidates where id = p_candidate_id;
  update public.candidates set c1_combo = p_new_combo where id = p_candidate_id;
  insert into public.c1_overrides (candidate_id, old_combo, new_combo, changed_by, motivo)
  values (p_candidate_id, v_old, p_new_combo, coalesce(auth.jwt()->>'email','team'), p_motivo);
  return jsonb_build_object('ok', true, 'old', v_old, 'new', p_new_combo);
end;
$$;

-- ------------------------------------------------------------
-- ROW LEVEL SECURITY
--   Nessun accesso diretto anonimo alle tabelle: i candidati passano
--   SOLO dalle RPC. Il team autenticato legge e aggiorna tutto.
-- ------------------------------------------------------------
alter table public.candidates enable row level security;
alter table public.c1_pool enable row level security;
alter table public.c1_strategy_counters enable row level security;
alter table public.c1_topic_usage enable row level security;
alter table public.c1_overrides enable row level security;
alter table public.stage2_submissions enable row level security;
alter table public.stage3_interviews enable row level security;
alter table public.scoring enable row level security;

create policy team_all_candidates on public.candidates
  for all to authenticated using (true) with check (true);
create policy team_read_pool on public.c1_pool
  for select to authenticated using (true);
create policy team_read_counters on public.c1_strategy_counters
  for select to authenticated using (true);
create policy team_read_usage on public.c1_topic_usage
  for select to authenticated using (true);
create policy team_read_overrides on public.c1_overrides
  for select to authenticated using (true);
create policy team_all_stage2 on public.stage2_submissions
  for all to authenticated using (true) with check (true);
create policy team_all_stage3 on public.stage3_interviews
  for all to authenticated using (true) with check (true);
create policy team_all_scoring on public.scoring
  for all to authenticated using (true) with check (true);

grant execute on function public.assign_c1(text, text, jsonb) to anon;
grant execute on function public.submit_stage1(uuid, text, jsonb, text) to anon;
grant execute on function public.admin_override_c1(uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- STORAGE — bucket privato per i CV (PDF, max 5 MB)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cv', 'cv', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;

create policy cv_anon_upload on storage.objects
  for insert to anon
  with check (bucket_id = 'cv');

create policy cv_team_read on storage.objects
  for select to authenticated
  using (bucket_id = 'cv');
