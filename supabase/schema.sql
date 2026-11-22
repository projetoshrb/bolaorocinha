-- BOLAO ROCINHA: banco de dados no Supabase.
-- O site chama só a função public.api(t, a, d), que confere a sessão e chama a ação bolao.a_<nome>.
-- As tabelas ficam no esquema "bolao", que não é exposto na internet (sem acesso direto pela chave pública).
-- Pode ser rodado de novo sem perder dados (cria só o que falta e substitui as funções).

create extension if not exists pgcrypto with schema extensions;
create schema if not exists bolao;
revoke all on schema bolao from public, anon, authenticated;

-- ===== Tabelas =====
create table if not exists bolao.usuarios(
  u text primary key, hash text not null, adm boolean not null default false,
  nome text not null default '', v int not null default 0, criado timestamptz not null default now());
create table if not exists bolao.sessoes(
  t uuid primary key default gen_random_uuid(), u text not null, adm boolean not null, v int not null, expira timestamptz not null);
create table if not exists bolao.falhas(u text primary key, n int not null, ate timestamptz not null);
-- ciclo vazio (null) = semana atual; preenchido = semana arquivada ("Qui 26/11/2026 a Dom 29/11/2026")
create table if not exists bolao.jogos(
  id bigserial primary key, u text not null, criado timestamptz not null default now(),
  c text not null, j int not null, d smallint[] not null, ciclo text);
create index if not exists jogos_ciclo_idx on bolao.jogos(ciclo);
create index if not exists jogos_uc_idx on bolao.jogos(u, c);
create index if not exists jogos_c_idx on bolao.jogos(c);
create table if not exists bolao.sorteios(
  id bigserial primary key, data date not null, horario text not null, dezenas smallint[] not null,
  ciclo text, criado timestamptz not null default now());
create unique index if not exists sorteios_atual_uk on bolao.sorteios(data, horario) where ciclo is null;
create table if not exists bolao.log(id bigserial primary key, quando timestamptz not null default now(), u text, txt text);
create table if not exists bolao.config(k text primary key, v text);
insert into bolao.config(k, v) values ('cod_segredo', encode(extensions.gen_random_bytes(32), 'hex')) on conflict do nothing;
insert into bolao.config(k, v) values ('cron_segredo', encode(extensions.gen_random_bytes(24), 'hex')) on conflict do nothing;
insert into bolao.config(k, v) values ('tg_env', '[]') on conflict do nothing;

alter table bolao.usuarios enable row level security;
alter table bolao.sessoes enable row level security;
alter table bolao.falhas enable row level security;
alter table bolao.jogos enable row level security;
alter table bolao.sorteios enable row level security;
alter table bolao.log enable row level security;
alter table bolao.config enable row level security;

-- ===== Utilitários =====
create or replace function bolao.dt(ts timestamptz) returns text language sql stable as
$$ select to_char(ts at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') $$;
create or replace function bolao.ordh(h text) returns int language sql immutable as
$$ select case h when '14h' then 1 when '16h' then 2 when '18h' then 3 when '21h' then 4 else 9 end $$;
create or replace function bolao.hor_nome(h text) returns text language sql immutable as
$$ select case h when '14h' then 'PT 14h' when '16h' then 'PTV 16h' when '18h' then 'PTN 18h' when '21h' then 'COR 21h' end $$;
create or replace function bolao.dia(d date) returns text language sql immutable as
$$ select (array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'])[extract(dow from d)::int + 1] $$;
-- Semana começa na segunda às 06:00 (horário de Brasília); o nome é a parte dos sorteios: quinta a domingo.
create or replace function bolao.ciclo_label(ts timestamptz) returns text language sql stable as $$
  select bolao.dia(seg + 3) || ' ' || to_char(seg + 3, 'DD/MM/YYYY') || ' a ' || bolao.dia(seg + 6) || ' ' || to_char(seg + 6, 'DD/MM/YYYY')
  from (select (date_trunc('week', (ts at time zone 'America/Sao_Paulo') - interval '6 hours'))::date as seg) s $$;
create or replace function bolao.chave_ciclo(c text) returns date language sql immutable as
$$ select to_date(substring(c from '\d{2}/\d{2}/\d{4}'), 'DD/MM/YYYY') $$;
create or replace function bolao.pad(n int) returns text language sql immutable as $$ select lpad(n::text, 2, '0') $$;
create or replace function bolao.nome_ok(n text) returns text language sql immutable as
$$ select left(trim(regexp_replace(regexp_replace(coalesce(n, ''), '[<>&"]', '', 'g'), '\s+', ' ', 'g')), 40) $$;
-- Cadastro aberto: segunda 06:00 até quinta 13:00 (horário de Brasília).
create or replace function bolao.cad_aberto() returns boolean language sql stable as $$
  select m >= 360 and m < 3 * 1440 + 780 from (
    select (extract(isodow from l)::int - 1) * 1440 + extract(hour from l)::int * 60 + extract(minute from l)::int as m
    from (select now() at time zone 'America/Sao_Paulo' as l) q) z $$;
create or replace function bolao.req_adm(p_u jsonb) returns void language plpgsql as $$
begin if not coalesce((p_u->>'adm')::boolean, false) then raise exception 'Apenas administrador'; end if; end $$;
create or replace function bolao.log_(p_u text, p_txt text) returns void language sql as
$$ insert into bolao.log(u, txt) values (p_u, p_txt) $$;
-- 10 dezenas diferentes de 00 a 99 (aceita números ou textos como "05"); null se inválido.
create or replace function bolao.dez10(p jsonb) returns smallint[] language plpgsql immutable as $$
declare r smallint[] := '{}'; e text;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 10 then return null; end if;
  for e in select jsonb_array_elements(p) #>> '{}' loop
    if e is null or e !~ '^\s*\d{1,2}\s*$' then return null; end if;
    if trim(e)::smallint = any(r) then return null; end if;
    r := r || trim(e)::smallint;
  end loop;
  return r;
end $$;
-- 5 dezenas de um sorteio (podem repetir: são os finais de milhares diferentes).
create or replace function bolao.dez5(p jsonb) returns smallint[] language plpgsql immutable as $$
declare r smallint[] := '{}'; e text;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 5 then return null; end if;
  for e in select jsonb_array_elements(p) #>> '{}' loop
    if e is null or e !~ '^\s*\d{1,2}\s*$' then return null; end if;
    r := r || trim(e)::smallint;
  end loop;
  return r;
end $$;
create or replace function bolao.acertos(d smallint[], acc int[]) returns int language sql immutable as
$$ select count(*)::int from unnest(d) x where x = any(acc) $$;

-- Código de conferência do comprovante (ex.: K7Q-29F): HMAC do vendedor, cartela e data/hora do envio.
create or replace function bolao.codigo(p_u text, p_c text, p_dt text) returns text language plpgsql stable as $$
declare b bytea; alf text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; r text := ''; i int; seg text;
begin
  select v into seg from bolao.config where k = 'cod_segredo';
  b := extensions.hmac(convert_to(p_u || '|' || p_c || '|' || p_dt, 'UTF8'), convert_to(seg, 'UTF8'), 'sha256');
  for i in 0..5 loop r := r || substr(alf, (get_byte(b, i) % 32) + 1, 1); end loop;
  return substr(r, 1, 3) || '-' || substr(r, 4, 3);
end $$;
create or replace function bolao.norm_cod(k text) returns text language sql immutable as
$$ select upper(regexp_replace(coalesce(k, ''), '[^0-9A-Za-z]', '', 'g')) $$;

create or replace function bolao.jogo_json(r bolao.jogos, acc int[]) returns jsonb language sql stable as $$
  select jsonb_build_object('u', r.u, 'n', coalesce(nullif((select nome from bolao.usuarios where u = r.u), ''), r.u),
    'c', r.c, 'j', r.j::text, 'd', to_jsonb(r.d::int[]), 'dt', bolao.dt(r.criado),
    'k', bolao.codigo(r.u, r.c, bolao.dt(r.criado)), 'ac', case when acc is null then null else bolao.acertos(r.d, acc) end) $$;
create or replace function bolao.sorteio_json(s bolao.sorteios) returns jsonb language sql stable as $$
  select jsonb_build_object('data', to_char(s.data, 'DD/MM/YYYY'), 'horario', s.horario, 'nome', bolao.hor_nome(s.horario),
    'dezenas', (select jsonb_agg(bolao.pad(x)) from unnest(s.dezenas) x)) $$;

-- ===== Apuração =====
-- Sorteios em ordem (data + horário); o acumulado para no PRIMEIRO sorteio em que algum jogo completa 10/10.
create or replace function bolao.apurar(p_ciclo text) returns jsonb language plpgsql stable as $$
declare s record; acc int[] := '{}'; vit jsonb := null;
begin
  for s in select * from bolao.sorteios where ciclo is not distinct from p_ciclo order by data, bolao.ordh(horario) loop
    acc := array(select distinct x from unnest(acc || s.dezenas::int[]) x);
    if exists (select 1 from bolao.jogos jg where jg.ciclo is not distinct from p_ciclo and jg.d::int[] <@ acc) then
      vit := jsonb_build_object('data', to_char(s.data, 'DD/MM/YYYY'), 'horario', s.horario, 'nome', bolao.hor_nome(s.horario));
      exit;
    end if;
  end loop;
  return jsonb_build_object('set', to_jsonb(coalesce((select array_agg(x order by x) from unnest(acc) x), '{}'::int[])), 'vit', vit);
end $$;

-- Painel (Dashboard e Histórico). p_tot_filtra: os totais respeitam o vendedor escolhido (Histórico) ou não (Dashboard).
create or replace function bolao.painel(p_ciclo text, p_usu text, p_cart text, p_tot_filtra boolean) returns jsonb language plpgsql stable as $$
declare ap jsonb; acc int[]; res jsonb;
begin
  ap := bolao.apurar(p_ciclo);
  acc := array(select jsonb_array_elements_text(ap->'set')::int);
  with base as (select jg.id, jg.u, jg.c, bolao.acertos(jg.d, acc) as ac, jg as r from bolao.jogos jg where jg.ciclo is not distinct from p_ciclo),
    t as (select * from base where not p_tot_filtra or p_usu = '' or base.u = p_usu),
    l as (select * from base where (p_usu = '' or base.u = p_usu) and (case when p_cart <> '' then base.c = p_cart else base.ac >= 7 end)
          order by base.ac desc, base.id limit 3000)
  select jsonb_build_object(
    'total', (select count(*) from t),
    'cont', jsonb_build_object('7', (select count(*) from t where ac = 7), '8', (select count(*) from t where ac = 8),
                               '9', (select count(*) from t where ac = 9), '10', (select count(*) from t where ac = 10)),
    'vit', ap->'vit',
    'venc', coalesce((select jsonb_agg(bolao.jogo_json(t.r, acc) order by t.id) from t where t.ac = 10), '[]'::jsonb),
    'lista', coalesce((select jsonb_agg(bolao.jogo_json(l.r, acc) order by l.ac desc, l.id) from l), '[]'::jsonb),
    'sorteadas', to_jsonb(acc)) into res;
  return res;
end $$;

-- ===== Ciclo semanal =====
create or replace function bolao.resetar_ciclo(quem text) returns jsonb language plpgsql as $$
declare base timestamptz; lbl text; ns int; nj int;
begin
  perform pg_advisory_xact_lock(424242);
  select (min(data)::timestamp + interval '12 hours') at time zone 'America/Sao_Paulo' into base from bolao.sorteios where ciclo is null;
  if base is null then select min(criado) into base from bolao.jogos where ciclo is null; end if;
  lbl := bolao.ciclo_label(coalesce(base, now()));
  update bolao.sorteios set ciclo = lbl where ciclo is null; get diagnostics ns = row_count;
  update bolao.jogos set ciclo = lbl where ciclo is null; get diagnostics nj = row_count;
  -- guarda só as 26 semanas mais recentes (cerca de 6 meses)
  with todos as (select ciclo from bolao.sorteios where ciclo is not null union select ciclo from bolao.jogos where ciclo is not null),
       manter as (select ciclo from todos order by bolao.chave_ciclo(ciclo) desc limit 26)
  delete from bolao.sorteios where ciclo is not null and ciclo not in (select ciclo from manter);
  with todos as (select ciclo from bolao.sorteios where ciclo is not null union select ciclo from bolao.jogos where ciclo is not null),
       manter as (select ciclo from todos order by bolao.chave_ciclo(ciclo) desc limit 26)
  delete from bolao.jogos where ciclo is not null and ciclo not in (select ciclo from manter);
  perform bolao.log_(coalesce(quem, 'sistema'), 'Encerrou o ciclo [' || lbl || ']: ' || ns || ' sorteio(s) e ' || nj || ' jogo(s) arquivados.');
  return jsonb_build_object('ok', true, 'sorteios', ns, 'jogos', nj);
end $$;

-- Usado no editor SQL do Supabase para criar o primeiro admin: select bolao.criar_usuario('login', 'senha', true, 'Nome');
create or replace function bolao.criar_usuario(p_u text, p_p text, p_adm boolean, p_nome text default '') returns text language plpgsql as $$
declare v_u text := lower(trim(p_u));
begin
  if v_u !~ '^[a-z0-9_]{3,20}$' then raise exception 'Usuário: 3 a 20 letras minúsculas, números ou _'; end if;
  if length(trim(p_p)) < 6 then raise exception 'Senha muito curta (mínimo 6)'; end if;
  insert into bolao.usuarios(u, hash, adm, nome) values (v_u, extensions.crypt(trim(p_p), extensions.gen_salt('bf', 8)), p_adm, bolao.nome_ok(p_nome))
    on conflict (u) do update set hash = excluded.hash, adm = excluded.adm, nome = case when excluded.nome <> '' then excluded.nome else bolao.usuarios.nome end,
      v = bolao.usuarios.v + 1;
  return 'ok: ' || v_u;
end $$;

-- ===== Ações (uma função por ação do site) =====
create or replace function bolao.a_login(p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := lower(trim(coalesce(p_d->>'u', ''))); v_p text := trim(coalesce(p_d->>'p', '')); f record; us record; tk uuid;
begin
  select * into f from bolao.falhas where u = v_u;
  if found and f.n >= 5 and f.ate > now() then return jsonb_build_object('erro', 'Muitas tentativas erradas. Aguarde 15 minutos e tente de novo.'); end if;
  select * into us from bolao.usuarios where u = v_u;
  if not found or us.hash <> extensions.crypt(v_p, us.hash) then
    insert into bolao.falhas(u, n, ate) values (v_u, 1, now() + interval '15 minutes')
      on conflict (u) do update set n = case when bolao.falhas.ate > now() then bolao.falhas.n + 1 else 1 end, ate = now() + interval '15 minutes';
    return jsonb_build_object('erro', 'Usuário ou senha incorretos');
  end if;
  delete from bolao.falhas where u = v_u;
  delete from bolao.sessoes where expira < now();
  insert into bolao.sessoes(u, adm, v, expira) values (v_u, us.adm, us.v, now() + interval '6 hours') returning t into tk;
  return jsonb_build_object('token', tk, 'u', v_u, 'adm', us.adm, 'n', coalesce(nullif(us.nome, ''), v_u));
end $$;

create or replace function bolao.a_cadstatus(p_u jsonb, p_d jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('aberto', coalesce((p_u->>'adm')::boolean, false) or bolao.cad_aberto(),
    'msg', 'Cadastro encerrado. Ele abre na segunda às 06:00 e fecha na quinta às 13:00.') $$;

create or replace function bolao.a_salvar(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := p_u->>'u'; v_c text := trim(coalesce(p_d->>'cartela', '')); js jsonb := p_d->'jogos'; n int; i int; ja int; ts timestamptz := now(); v_dt text;
begin
  if not coalesce((p_u->>'adm')::boolean, false) and not bolao.cad_aberto() then
    raise exception 'Cadastro encerrado. Ele abre na segunda às 06:00 e fecha na quinta às 13:00.'; end if;
  if v_c !~ '^[A-Za-z0-9_]{1,15}$' then raise exception 'Número da cartela inválido'; end if;
  if js is null or jsonb_typeof(js) <> 'array' or jsonb_array_length(js) = 0 then raise exception 'Nenhum jogo enviado'; end if;
  n := jsonb_array_length(js);
  if n > 50 then raise exception 'Máximo de 50 jogos por cartela em cada envio'; end if;
  for i in 0..n - 1 loop
    if bolao.dez10(js->i) is null then raise exception 'Jogo %: precisa de 10 dezenas diferentes (00-99)', i + 1; end if;
  end loop;
  perform pg_advisory_xact_lock(hashtext(v_u || '|' || v_c));
  select coalesce(max(j), 0) into ja from bolao.jogos where u = v_u and c = v_c and ciclo is null;
  for i in 0..n - 1 loop
    insert into bolao.jogos(u, criado, c, j, d) values (v_u, ts, v_c, ja + i + 1, bolao.dez10(js->i));
  end loop;
  v_dt := bolao.dt(ts);
  return jsonb_build_object('ok', true, 'qtd', n, 'ini', ja + 1, 'dt', v_dt, 'cod', bolao.codigo(v_u, v_c, v_dt));
end $$;

create or replace function bolao.a_importar(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := lower(trim(coalesce(p_d->>'usuario', ''))); ls jsonb := p_d->'linhas'; l jsonb; n int; i int; v_c text; cont jsonb := '{}'; ts timestamptz := now();
begin
  perform bolao.req_adm(p_u);
  if v_u = '' or not exists (select 1 from bolao.usuarios where u = v_u) then raise exception 'Usuário inválido'; end if;
  if ls is null or jsonb_typeof(ls) <> 'array' or jsonb_array_length(ls) = 0 then raise exception 'Nada para importar'; end if;
  n := jsonb_array_length(ls);
  if n > 3000 then raise exception 'Máximo de 3000 jogos por importação'; end if;
  for i in 0..n - 1 loop
    l := ls->i;
    if jsonb_typeof(l) <> 'array' or jsonb_array_length(l) <> 11 or coalesce(trim(l->>0), '') !~ '^[A-Za-z0-9_]{1,15}$' or bolao.dez10(l - 0) is null then
      raise exception 'Linha % inválida', i + 1; end if;
  end loop;
  for i in 0..n - 1 loop
    l := ls->i; v_c := trim(l->>0);
    if not cont ? v_c then
      cont := cont || jsonb_build_object(v_c, (select coalesce(max(j), 0) from bolao.jogos where u = v_u and c = v_c and ciclo is null));
    end if;
    cont := jsonb_set(cont, array[v_c], to_jsonb((cont->>v_c)::int + 1));
    insert into bolao.jogos(u, criado, c, j, d) values (v_u, ts, v_c, (cont->>v_c)::int, bolao.dez10(l - 0));
  end loop;
  perform bolao.log_(p_u->>'u', 'Importou ' || n || ' jogo(s) para ' || v_u);
  return jsonb_build_object('ok', true, 'qtd', n);
end $$;

create or replace function bolao.a_jogos(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
declare alvo text := case when coalesce((p_u->>'adm')::boolean, false) then lower(trim(coalesce(p_d->>'usuario', ''))) else p_u->>'u' end;
begin
  return jsonb_build_object('jogos', coalesce((select jsonb_agg(bolao.jogo_json(jg, null) order by jg.id)
    from bolao.jogos jg where jg.ciclo is null and (alvo = '' or jg.u = alvo)), '[]'::jsonb));
end $$;

create or replace function bolao.a_dash(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
begin
  perform bolao.req_adm(p_u);
  return bolao.painel(null, lower(trim(coalesce(p_d->>'usuario', ''))), trim(coalesce(p_d->>'cartela', '')), false);
end $$;

create or replace function bolao.a_sorteios(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
begin
  perform bolao.req_adm(p_u);
  return jsonb_build_object(
    'sorteios', coalesce((select jsonb_agg(bolao.sorteio_json(s) order by s.data, bolao.ordh(s.horario)) from bolao.sorteios s where s.ciclo is null), '[]'::jsonb),
    'acumulado', coalesce((select jsonb_agg(x order by x) from (select distinct unnest(dezenas)::int x from bolao.sorteios where ciclo is null) q), '[]'::jsonb));
end $$;

create or replace function bolao.a_histciclos(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
begin
  perform bolao.req_adm(p_u);
  return jsonb_build_object('guardar', 26, 'ciclos', coalesce((
    select jsonb_agg(jsonb_build_object('c', q.ciclo,
      'ns', (select count(*) from bolao.sorteios s where s.ciclo = q.ciclo), 'nj', (select count(*) from bolao.jogos jg where jg.ciclo = q.ciclo))
      order by bolao.chave_ciclo(q.ciclo) desc)
    from (select ciclo from bolao.sorteios where ciclo is not null union select ciclo from bolao.jogos where ciclo is not null) q), '[]'::jsonb));
end $$;

create or replace function bolao.a_histdash(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
declare v_ci text := coalesce(p_d->>'ciclo', '');
begin
  perform bolao.req_adm(p_u);
  if v_ci = '' then raise exception 'Escolha um ciclo'; end if;
  return bolao.painel(v_ci, lower(trim(coalesce(p_d->>'usuario', ''))), trim(coalesce(p_d->>'cartela', '')), true) || jsonb_build_object(
    'sorteios', coalesce((select jsonb_agg(bolao.sorteio_json(s) order by s.data, bolao.ordh(s.horario)) from bolao.sorteios s where s.ciclo = v_ci), '[]'::jsonb),
    'acumulado', coalesce((select jsonb_agg(x order by x) from (select distinct unnest(dezenas)::int x from bolao.sorteios where ciclo = v_ci) q), '[]'::jsonb));
end $$;

create or replace function bolao.a_histsorteiosalvar(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare z smallint[] := bolao.dez5(p_d->'dezenas'); n int;
begin
  perform bolao.req_adm(p_u);
  if z is null then raise exception 'Informe 5 dezenas (00-99)'; end if;
  update bolao.sorteios set dezenas = z where ciclo = p_d->>'ciclo' and data = to_date(p_d->>'data', 'DD/MM/YYYY') and horario = p_d->>'horario';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Sorteio não encontrado no histórico'; end if;
  perform bolao.log_(p_u->>'u', 'Corrigiu sorteio do histórico [' || (p_d->>'ciclo') || '] ' || (p_d->>'data') || ' ' || (p_d->>'horario') || ' → '
    || array_to_string(array(select bolao.pad(x) from unnest(z) x), ' '));
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_histsorteioexcluir(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare n int;
begin
  perform bolao.req_adm(p_u);
  delete from bolao.sorteios where ciclo = p_d->>'ciclo' and data = to_date(p_d->>'data', 'DD/MM/YYYY') and horario = p_d->>'horario';
  get diagnostics n = row_count;
  perform bolao.log_(p_u->>'u', 'Excluiu sorteio do histórico [' || (p_d->>'ciclo') || '] ' || (p_d->>'data') || ' ' || (p_d->>'horario'));
  return jsonb_build_object('ok', true, 'qtd', n);
end $$;

create or replace function bolao.a_histjogoexcluir(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare n int; v_j text := coalesce(p_d->>'j', '');
begin
  perform bolao.req_adm(p_u);
  delete from bolao.jogos where ciclo = p_d->>'ciclo' and u = p_d->>'u' and c = p_d->>'c' and (v_j = '' or j::text = v_j);
  get diagnostics n = row_count;
  perform bolao.log_(p_u->>'u', 'Excluiu ' || n || ' jogo(s) do histórico [' || (p_d->>'ciclo') || ']: cartela ' || (p_d->>'c')
    || case when v_j <> '' then ' jogo ' || v_j else ' (inteira)' end || ' de ' || (p_d->>'u'));
  return jsonb_build_object('ok', true, 'qtd', n);
end $$;

create or replace function bolao.a_excluirjogo(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare n int; v_j text := coalesce(p_d->>'j', '');
begin
  perform bolao.req_adm(p_u);
  delete from bolao.jogos where ciclo is null and u = p_d->>'u' and c = p_d->>'c' and (v_j = '' or j::text = v_j);
  get diagnostics n = row_count;
  perform bolao.log_(p_u->>'u', 'Excluiu ' || n || ' jogo(s): cartela ' || (p_d->>'c') || case when v_j <> '' then ' jogo ' || v_j else ' (inteira)' end || ' de ' || (p_d->>'u'));
  return jsonb_build_object('ok', true, 'qtd', n);
end $$;

create or replace function bolao.a_excluirsorteio(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
begin
  perform bolao.req_adm(p_u);
  delete from bolao.sorteios where ciclo is null and data = to_date(p_d->>'data', 'DD/MM/YYYY') and horario = p_d->>'horario';
  perform bolao.log_(p_u->>'u', 'Excluiu sorteio ' || (p_d->>'data') || ' ' || (p_d->>'horario'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_sorteiomanual(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare z smallint[] := bolao.dez5(p_d->'dezenas'); v_data text := coalesce(p_d->>'data', ''); v_h text := coalesce(p_d->>'horario', ''); n int; v_key text; env jsonb;
begin
  perform bolao.req_adm(p_u);
  if z is null then raise exception 'Informe 5 dezenas (00-99)'; end if;
  if v_data !~ '^\d{2}/\d{2}/\d{4}$' or bolao.hor_nome(v_h) is null then raise exception 'Data (dd/mm/aaaa) ou horário inválido'; end if;
  delete from bolao.sorteios where ciclo is null and data = to_date(v_data, 'DD/MM/YYYY') and horario = v_h;
  get diagnostics n = row_count;
  insert into bolao.sorteios(data, horario, dezenas) values (to_date(v_data, 'DD/MM/YYYY'), v_h, z);
  if n > 0 then   -- já tinha ido para o Telegram com números errados: o bot manda a versão corrigida
    v_key := v_data || '|' || v_h;
    select v::jsonb into env from bolao.config where config.k = 'tg_env';
    update bolao.config set v = coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(env, '[]'::jsonb)) e where e #>> '{}' <> v_key), '[]'::jsonb)::text
      where config.k = 'tg_env';
  end if;
  perform bolao.log_(p_u->>'u', case when n > 0 then 'Corrigiu' else 'Lançou' end || ' sorteio manual ' || v_data || ' ' || v_h || ' → '
    || array_to_string(array(select bolao.pad(x) from unnest(z) x), ' '));
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_encerrarciclo(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
begin perform bolao.req_adm(p_u); return bolao.resetar_ciclo(p_u->>'u'); end $$;

create or replace function bolao.a_nomes(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
begin
  perform bolao.req_adm(p_u);
  return jsonb_build_object('nomes', coalesce((select jsonb_agg(jsonb_build_object('u', u, 'n', coalesce(nullif(nome, ''), u)) order by lower(coalesce(nullif(nome, ''), u)))
    from bolao.usuarios), '[]'::jsonb));
end $$;

create or replace function bolao.a_usuarios(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
begin
  perform bolao.req_adm(p_u);
  return jsonb_build_object('usuarios', coalesce((select jsonb_agg(jsonb_build_object('u', u, 'n', nome, 'adm', adm) order by criado) from bolao.usuarios), '[]'::jsonb));
end $$;

create or replace function bolao.a_excluirusuario(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := coalesce(p_d->>'u', '');
begin
  perform bolao.req_adm(p_u);
  if v_u = p_u->>'u' then raise exception 'Você não pode excluir a si mesmo'; end if;
  delete from bolao.usuarios where u = v_u;
  delete from bolao.sessoes where u = v_u;
  perform bolao.log_(p_u->>'u', 'Excluiu acesso do usuário ' || v_u || ' (os jogos dele continuam no sistema)');
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_trocarsenha(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := p_u->>'u'; nova text := trim(coalesce(p_d->>'nova', '')); us record;
begin
  if length(nova) < 6 then raise exception 'Senha nova muito curta (mínimo 6)'; end if;
  select * into us from bolao.usuarios where u = v_u;
  if not found then raise exception 'Usuário não encontrado'; end if;
  if us.hash <> extensions.crypt(trim(coalesce(p_d->>'atual', '')), us.hash) then raise exception 'A senha atual está incorreta'; end if;
  update bolao.usuarios set hash = extensions.crypt(nova, extensions.gen_salt('bf', 8)), v = v + 1 where u = v_u;
  -- derruba os outros aparelhos, mas mantém esta sessão
  update bolao.sessoes set v = us.v + 1 where t::text = p_u->>'t';
  perform bolao.log_(v_u, 'Trocou a própria senha');
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_redefinirsenha(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := coalesce(p_d->>'u', ''); p text := trim(coalesce(p_d->>'p', ''));
begin
  perform bolao.req_adm(p_u);
  if not exists (select 1 from bolao.usuarios where u = v_u) then raise exception 'Usuário não encontrado'; end if;
  if length(p) < 6 then raise exception 'Senha muito curta (mínimo 6)'; end if;
  update bolao.usuarios set hash = extensions.crypt(p, extensions.gen_salt('bf', 8)), v = v + 1 where u = v_u;
  perform bolao.log_(p_u->>'u', 'Redefiniu a senha de ' || v_u);
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_novousuario(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := lower(trim(coalesce(p_d->>'u', '')));
begin
  perform bolao.req_adm(p_u);
  if v_u !~ '^[a-z0-9_]{3,20}$' then raise exception 'Usuário: 3 a 20 letras minúsculas, números ou _'; end if;
  if exists (select 1 from bolao.usuarios where u = v_u) then
    raise exception 'O usuário "%" já existe. Para trocar a senha dele, use o botão 🔑 Senha.', v_u; end if;
  perform bolao.criar_usuario(v_u, coalesce(p_d->>'p', ''), false, coalesce(p_d->>'nome', ''));
  perform bolao.log_(p_u->>'u', 'Criou o usuário ' || v_u);
  return jsonb_build_object('ok', true);
end $$;

create or replace function bolao.a_renomearusuario(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := coalesce(p_d->>'u', ''); n int;
begin
  perform bolao.req_adm(p_u);
  update bolao.usuarios set nome = bolao.nome_ok(p_d->>'nome') where u = v_u;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Usuário não encontrado'; end if;
  perform bolao.log_(p_u->>'u', 'Mudou o nome de ' || v_u || ' para "' || bolao.nome_ok(p_d->>'nome') || '"');
  return jsonb_build_object('ok', true);
end $$;

-- Confere um comprovante: procura a cartela na semana atual e nas arquivadas e testa o código de cada envio.
create or replace function bolao.a_conferir(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
declare v_c text := trim(coalesce(p_d->>'cartela', '')); k text := bolao.norm_cod(p_d->>'codigo'); g record;
begin
  perform bolao.req_adm(p_u);
  if v_c !~ '^[A-Za-z0-9_]{1,15}$' or length(k) <> 6 then raise exception 'Informe o número da cartela e o código de 6 letras/números'; end if;
  for g in select jg.u, coalesce(jg.ciclo, '') as ciclo, bolao.dt(jg.criado) as dt,
      jsonb_agg(jsonb_build_object('j', jg.j::text, 'd', to_jsonb(jg.d::int[])) order by jg.j) as jogos
    from bolao.jogos jg where jg.c = v_c group by 1, 2, 3 loop
    if bolao.norm_cod(bolao.codigo(g.u, v_c, g.dt)) = k then
      return jsonb_build_object('ok', true, 'valido', true, 'cartela', v_c, 'u', g.u,
        'n', coalesce(nullif((select nome from bolao.usuarios where u = g.u), ''), g.u), 'dt', g.dt, 'ciclo', g.ciclo, 'jogos', g.jogos);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'valido', false);
end $$;

-- Telegram: o admin cola o token e o chat no site (o valor nunca volta para a tela).
create or replace function bolao.a_tgstatus(p_u jsonb, p_d jsonb) returns jsonb language plpgsql stable as $$
begin
  perform bolao.req_adm(p_u);
  return jsonb_build_object('token', exists (select 1 from bolao.config where k = 'tg_token' and coalesce(v, '') <> ''),
    'chat', (select v from bolao.config where k = 'tg_chat'));
end $$;
create or replace function bolao.a_tgconfig(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare tk text := trim(coalesce(p_d->>'token', '')); ch text := trim(coalesce(p_d->>'chat', ''));
begin
  perform bolao.req_adm(p_u);
  if tk <> '' then
    if tk !~ '^\d+:[A-Za-z0-9_-]{30,}$' then raise exception 'Token inválido: copie o token inteiro do @BotFather (números:letras)'; end if;
    insert into bolao.config(k, v) values ('tg_token', tk) on conflict (k) do update set v = excluded.v;
  end if;
  if ch <> '' then
    if ch !~ '^-?\d+$' and ch !~ '^@\w+$' then raise exception 'Chat id inválido (ex.: -1001234567890)'; end if;
    insert into bolao.config(k, v) values ('tg_chat', ch) on conflict (k) do update set v = excluded.v;
  end if;
  -- sorteios que já existem ficam como enviados, para o bot não despejar o histórico no canal
  update bolao.config set v = coalesce((select jsonb_agg(to_char(data, 'DD/MM/YYYY') || '|' || horario) from bolao.sorteios where ciclo is null), '[]'::jsonb)::text
    where k = 'tg_env' and (v is null or v = '[]');
  perform bolao.log_(p_u->>'u', 'Configurou o Telegram');
  return jsonb_build_object('ok', true);
end $$;

-- Tornar ou remover admin. Não deixa mexer em si mesmo nem ficar sem nenhum admin; derruba a sessão da pessoa.
create or replace function bolao.a_definiradm(p_u jsonb, p_d jsonb) returns jsonb language plpgsql as $$
declare v_u text := coalesce(p_d->>'u', ''); v_adm boolean := coalesce((p_d->>'adm')::boolean, false); n int;
begin
  perform bolao.req_adm(p_u);
  if v_u = p_u->>'u' then raise exception 'Você não pode mudar o seu próprio acesso de admin'; end if;
  if not v_adm and (select count(*) from bolao.usuarios where adm and u <> v_u) = 0 then raise exception 'O sistema precisa ter pelo menos um admin'; end if;
  update bolao.usuarios set adm = v_adm, v = v + 1 where u = v_u;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Usuário não encontrado'; end if;
  delete from bolao.sessoes where u = v_u;
  perform bolao.log_(p_u->>'u', case when v_adm then 'Tornou admin o usuário ' else 'Removeu o admin do usuário ' end || v_u);
  return jsonb_build_object('ok', true);
end $$;

-- ===== Porta de entrada do site =====
create or replace function public.api(t text default null, a text default null, d jsonb default null) returns jsonb
language plpgsql security definer set search_path = bolao, public, extensions as $f$
declare v_t text := t; v_a text := lower(coalesce(a, '')); v_d jsonb := coalesce(d, '{}'::jsonb); ses record; res jsonb;
begin
  begin
    if v_a = 'login' then return bolao.a_login(v_d); end if;
    if v_a = 'sair' then
      if v_t ~ '^[0-9a-fA-F-]{36}$' then delete from bolao.sessoes ss where ss.t = v_t::uuid; end if;
      return jsonb_build_object('ok', true);
    end if;
    if v_t is null or v_t !~ '^[0-9a-fA-F-]{36}$' then return jsonb_build_object('erro', 'Sessão expirada', 'sessao', 1); end if;
    select ss.u, ss.adm, ss.v as sv, uu.v as uv into ses from bolao.sessoes ss left join bolao.usuarios uu on uu.u = ss.u
      where ss.t = v_t::uuid and ss.expira > now();
    if not found then return jsonb_build_object('erro', 'Sessão expirada', 'sessao', 1); end if;
    if ses.uv is null or ses.uv <> ses.sv then
      delete from bolao.sessoes ss where ss.t = v_t::uuid;
      return jsonb_build_object('erro', 'Sessão encerrada. Entre de novo.', 'sessao', 1);
    end if;
    if v_a !~ '^[a-z]+$' or v_a = 'login' or not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'bolao' and p.proname = 'a_' || v_a) then
      return jsonb_build_object('erro', 'Ação desconhecida: ' || coalesce(a, ''));
    end if;
    execute format('select bolao.%I($1, $2)', 'a_' || v_a) into res using jsonb_build_object('u', ses.u, 'adm', ses.adm, 't', v_t), v_d;
    return res;
  exception when others then
    return jsonb_build_object('erro', sqlerrm);
  end;
end $f$;
revoke all on function public.api(text, text, jsonb) from public;
grant execute on function public.api(text, text, jsonb) to anon, authenticated;

-- ===== Backup semanal (lido pelo Apps Script e gravado numa planilha do Google Drive) =====
-- Protegido por um segredo próprio (config backup_segredo). Não inclui senhas nem sessões.
insert into bolao.config(k, v) values ('backup_segredo', encode(extensions.gen_random_bytes(18), 'hex')) on conflict do nothing;
create or replace function public.backup_bolao(s text default null) returns jsonb
language plpgsql security definer set search_path = bolao, public, extensions as $f$
begin
  if s is null or s <> (select v from bolao.config where k = 'backup_segredo') then return jsonb_build_object('erro', 'Não autorizado'); end if;
  return jsonb_build_object('gerado', bolao.dt(now()),
    'usuarios', coalesce((select jsonb_agg(jsonb_build_object('usuario', u, 'nome', nome, 'admin', adm) order by criado) from bolao.usuarios), '[]'::jsonb),
    'jogos', coalesce((select jsonb_agg(jsonb_build_object('ciclo', coalesce(ciclo, 'semana atual'), 'usuario', u, 'data', bolao.dt(criado), 'cartela', c, 'jogo', j,
      'dezenas', array_to_string(array(select bolao.pad(x) from unnest(d) x), ' ')) order by id) from bolao.jogos), '[]'::jsonb),
    'sorteios', coalesce((select jsonb_agg(jsonb_build_object('ciclo', coalesce(ciclo, 'semana atual'), 'data', to_char(data, 'DD/MM/YYYY'), 'horario', horario,
      'dezenas', array_to_string(array(select bolao.pad(x) from unnest(dezenas) x), ' ')) order by data, bolao.ordh(horario)) from bolao.sorteios), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('quando', bolao.dt(quando), 'usuario', u, 'texto', txt) order by id) from (select * from bolao.log order by id desc limit 2000) q), '[]'::jsonb));
end $f$;
revoke all on function public.backup_bolao(text) from public;
grant execute on function public.backup_bolao(text) to anon;

-- Avisa a API para enxergar funções novas.
notify pgrst, 'reload schema';
