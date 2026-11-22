-- Agendamentos do BOLAO ROCINHA (pg_cron). Horários em UTC: Brasília = UTC - 3.
-- Pode ser rodado de novo: cron.schedule com o mesmo nome substitui o agendamento.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Toda segunda às 05:00 de Brasília (08:00 UTC): arquiva a semana e começa um novo ciclo.
select cron.schedule('bolao-reset', '0 8 * * 1', $$select bolao.resetar_ciclo('sistema')$$);

-- Busca de resultados a cada 15 min, de quinta a segunda de madrugada (UTC); a função confere o dia em Brasília.
select cron.schedule('bolao-resultados', '*/15 * * * 0,1,4,5,6', $$
  select net.http_post(url := 'https://cborhjhmaznboxwtckgj.supabase.co/functions/v1/bolao',
    body := '{"a":"resultados"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select v from bolao.config where k = 'cron_segredo')))
$$);

-- Telegram: a cada minuto nos mesmos dias, envia o que estiver pendente (em fila, respeitando o limite do Telegram).
select cron.schedule('bolao-telegram', '* * * * 0,1,4,5,6', $$
  select net.http_post(url := 'https://cborhjhmaznboxwtckgj.supabase.co/functions/v1/bolao',
    body := '{"a":"telegram"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select v from bolao.config where k = 'cron_segredo')))
$$);

-- Limpa o histórico de execuções do pg_cron e as respostas guardadas pelo pg_net (todo dia às 04:00 UTC).
select cron.schedule('bolao-limpeza', '0 4 * * *', $$
  delete from cron.job_run_details where end_time < now() - interval '7 days';
  delete from net._http_response where created < now() - interval '1 day';
$$);
