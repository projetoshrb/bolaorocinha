// BOLAO ROCINHA: função do Supabase para o que precisa de internet.
// - Busca automática dos resultados (agendada a cada 15 min).
// - Envio do resumo ao Telegram, com as cartelas em imagem (agendado a cada minuto, em fila).
// - Botões do admin: "Buscar resultados agora" e os testes/reenvio do Telegram.
// Os agendamentos chamam com o cabeçalho x-cron (segredo guardado no banco); o site chama com o token da sessão.
import postgres from 'npm:postgres@3.4.4';
import { initWasm, Resvg } from 'npm:@resvg/resvg-wasm@2.6.2';
import { REGULAR, BOLD } from './fontes.ts';

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void };

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 3, prepare: false, idle_timeout: 20 });
const TZ = 'America/Sao_Paulo';
const NOME_BOT = 'BOLAO ROCINHA';
const HOR: Record<string, string> = { '14h': 'PT 14h', '16h': 'PTV 16h', '18h': 'PTN 18h', '21h': 'COR 21h' };
const ORDH: Record<string, number> = { '14h': 1, '16h': 2, '18h': 3, '21h': 4 };
const DIAS_SEM = ['Domingo', 'Segunda-feira', 'Terça-feira', 'Quarta-feira', 'Quinta-feira', 'Sexta-feira', 'Sábado'];
const LIMITE_7 = 100;        // com mais cartelas de 7 acertos que isso, só 8 e 9 são listados
const TG_PAUSA_MS = 3100;    // o Telegram aceita cerca de 20 mensagens por minuto no mesmo canal
const TEMPO_MS = 100_000;    // tempo máximo de envio por execução; o restante sai na próxima (1 min depois)

const pad = (n: number | string) => String(n).padStart(2, '0');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// ===== Banco =====
async function cfg(k: string): Promise<string | null> { const r = await sql`select v from bolao.config where k = ${k}`; return r[0]?.v ?? null; }
async function setCfg(k: string, v: string | null) {
  await sql`insert into bolao.config(k, v) values (${k}, ${v}) on conflict (k) do update set v = excluded.v`;
}
async function log(u: string, t: string) { await sql`insert into bolao.log(u, txt) values (${u}, ${t})`; }
async function sessaoAdm(t: string): Promise<string | null> {
  if (!/^[0-9a-fA-F-]{36}$/.test(t || '')) return null;
  const r = await sql`select ss.u, ss.adm, ss.v as sv, uu.v as uv from bolao.sessoes ss join bolao.usuarios uu on uu.u = ss.u
    where ss.t = ${t}::uuid and ss.expira > now()`;
  return r[0] && r[0].adm && r[0].sv === r[0].uv ? r[0].u : null;
}
type Sorteio = { data: string; horario: string; dezenas: string[] };
type Jogo = { c: string; j: string; d: number[] };
async function dados(): Promise<{ sorteios: Sorteio[]; jogos: Jogo[] }> {
  const s = await sql`select to_char(data, 'DD/MM/YYYY') as data, horario, dezenas from bolao.sorteios where ciclo is null`;
  const j = await sql`select c, j::text as j, d from bolao.jogos where ciclo is null order by id`;
  return {
    sorteios: s.map((x) => ({ data: x.data, horario: x.horario, dezenas: (x.dezenas as number[]).map((n) => pad(n)) })),
    jogos: j.map((x) => ({ c: x.c, j: x.j, d: (x.d as number[]).map(Number) })),
  };
}
const chaveS = (s: { data: string; horario: string }) => s.data.split('/').reverse().join('') + ORDH[s.horario];
const ordenar = <T extends { data: string; horario: string }>(l: T[]) => l.sort((a, b) => (chaveS(a) < chaveS(b) ? -1 : 1));

// ===== Resultados =====
function agoraSP() {
  const p: Record<string, string> = {};
  new Intl.DateTimeFormat('en-GB', { timeZone: TZ, weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })
    .formatToParts(new Date()).forEach((x) => (p[x.type] = x.value));
  const dow = ({ Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 } as Record<string, number>)[p.weekday];
  return { hoje: `${p.day}/${p.month}/${p.year}`, dow };
}
// A página mostra a data de hoje mesmo ANTES do sorteio ("Aguardando sorteio", prêmios "--"):
// os prêmios precisam vir logo depois de "<data de hoje>", no mesmo bloco.
async function buscar(url: string, hoje: string): Promise<number[] | null> {
  try {
    const r = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36' } });
    if (r.status !== 200) return null;
    const t = (await r.text()).replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ').replace(/&nbsp;/gi, ' ').replace(/&ordm;|&#186;/gi, 'º').replace(/\s+/g, ' ');
    const re = new RegExp(hoje.replace(/\//g, '\\/') + '[^º]{0,300}?1º\\s+(\\d{4})[^º]{0,100}?2º\\s+(\\d{4})[^º]{0,100}?3º\\s+(\\d{4})' +
      '[^º]{0,100}?4º\\s+(\\d{4})[^º]{0,100}?5º\\s+(\\d{4})', 'i');
    const m = t.match(re);
    return m ? m.slice(1, 6).map((x) => Number(x.slice(-2))) : null;
  } catch { return null; }
}
async function atualizarResultados() {
  const { hoje, dow } = agoraSP();
  if (dow < 4) return { ok: true, msg: 'Hoje não há sorteios (quinta a domingo).' };
  const horas = dow === 7 ? ['14h'] : Object.keys(HOR);
  const ja = new Set((await sql`select horario from bolao.sorteios where ciclo is null and data = to_date(${hoje}, 'DD/MM/YYYY')`).map((r) => r.horario));
  const gravados: string[] = [];
  for (const h of horas) {
    if (ja.has(h)) continue;
    const r = await buscar('https://deunopostenacional.com.br/deu-no-poste/' + h.replace('h', '-horas') + '/', hoje);
    if (!r) continue;
    const ins = await sql`insert into bolao.sorteios(data, horario, dezenas) values (to_date(${hoje}, 'DD/MM/YYYY'), ${h}, ${'{' + r.join(',') + '}'}::smallint[])
      on conflict (data, horario) where ciclo is null do nothing returning id`;
    if (ins.length) gravados.push(h);
  }
  return { ok: true, gravados };
}

// ===== Imagens (mesmos modelos de antes), desenhadas em SVG e convertidas em PNG =====
const C = { dk: '#173d2b', gr: '#0b6b43', cr: '#f4efdd', al: '#efe8d6', br: '#8a5a2b', tx: '#1d2330', gy: '#555555' };
const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const FONTES = [b64(REGULAR), b64(BOLD)];
let wasmPronto: Promise<void> | null = null;
const prepararWasm = () => (wasmPronto ??= initWasm(fetch('https://cdn.jsdelivr.net/npm/@resvg/resvg-wasm@2.6.2/index_bg.wasm')));
const xml = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
const dz = (a: unknown) => (Array.isArray(a) ? a : []).map((n) => pad(Math.max(0, Math.min(99, Math.floor(Number(n)) || 0))));
const tx = (s: string, x: number, y: number, tam: number, neg: boolean, cor: string, al = 'start') =>
  `<text x="${x}" y="${y}" font-family="Liberation Sans" font-size="${tam}" font-weight="${neg ? 700 : 400}" fill="${cor}" text-anchor="${al}">${xml(s)}</text>`;
type Img = { tipo: string; titulo?: string; sub?: string; rows?: { c: string; d: number[]; f: number[]; ac: number }[]; c?: string; d?: number[] };
function svgLista(d: Img) {
  const rows = (d.rows || []).slice(0, 10), n = Math.max(rows.length, 1), W = 887, H = 210 + n * 107;
  let s = `<rect width="${W}" height="${H}" fill="${C.cr}"/><rect width="${W}" height="126" fill="${C.dk}"/><rect y="${H - 37}" width="${W}" height="37" fill="${C.dk}"/>`;
  s += tx(String(d.titulo || '').slice(0, 60), 443, 52, 40, true, '#fff', 'middle') + tx(String(d.sub || '').slice(0, 80), 443, 96, 22, false, '#fff', 'middle');
  rows.forEach((r, i) => {
    const y = 137 + i * 107;
    s += `<rect x="33" y="${y}" width="821" height="100" fill="${i % 2 ? C.al : '#fff'}"/>`;
    s += tx('CARTELA', 56, y + 27, 17, true, C.tx) + tx(String(r.c).slice(0, 15), 56, y + 60, 30, true, C.gr);
    s += tx('Dezenas: ' + dz(r.d).join(' • '), 237, y + 23, 17, false, '#333333') + tx('Faltam: ' + dz(r.f).join(' • '), 237, y + 54, 17, false, C.br);
    s += tx((Math.floor(Number(r.ac)) || 0) + '/10', 831, y + 41, 24, true, C.gr, 'end');
  });
  s += tx('Resultado das Cartelas', 443, H - 13, 15, false, '#fff', 'middle');
  return { W, H, s };
}
function trofeu(cx: number, cy: number, k: number) {
  const o = '#f5b301', p = (x: number, y: number) => `${(cx + x * k).toFixed(1)} ${(cy + y * k).toFixed(1)}`;
  return `<path d="M${p(-.3, -.5)} L${p(.3, -.5)} L${p(.3, -.1)} Q${p(.3, .22)} ${p(0, .22)} Q${p(-.3, .22)} ${p(-.3, -.1)} Z" fill="${o}"/>` +
    `<path d="M${p(-.3, -.13)} A${.14 * k} ${.14 * k} 0 0 1 ${p(-.3, -.41)}" fill="none" stroke="${o}" stroke-width="${.07 * k}" stroke-linecap="round"/>` +
    `<path d="M${p(.3, -.41)} A${.14 * k} ${.14 * k} 0 0 1 ${p(.3, -.13)}" fill="none" stroke="${o}" stroke-width="${.07 * k}" stroke-linecap="round"/>` +
    `<rect x="${cx - .05 * k}" y="${cy + .2 * k}" width="${.1 * k}" height="${.17 * k}" fill="${o}"/><rect x="${cx - .2 * k}" y="${cy + .37 * k}" width="${.4 * k}" height="${.1 * k}" fill="${o}"/>`;
}
function svgVenc(d: Img) {
  // Moldura dourada, dois troféus, número da cartela e dezenas em dourado (igual à imagem gerada no site).
  const W = 1024, H = 1280, OU = '#e6a700', OU2 = '#ffd54a', OUE = '#b8860b', w = 328.7;   // 328,7 = largura de "VENCEDOR" em 58px
  let s = `<rect width="${W}" height="${H}" fill="${OU}"/><rect x="26" y="26" width="972" height="1228" fill="${C.cr}"/>`;
  s += `<rect x="38" y="38" width="948" height="1204" fill="none" stroke="${OUE}" stroke-width="4"/>`;
  s += `<rect x="44" y="44" width="936" height="180" fill="${C.dk}"/><rect x="44" y="220" width="936" height="6" fill="${OU}"/>`;
  s += tx('VENCEDOR', 512, 118, 58, true, OU2, 'middle') + trofeu(512 - w / 2 - 60, 100, 78) + trofeu(512 + w / 2 + 60, 100, 78);
  s += tx('10 / 10 ACERTOS', 512, 180, 34, true, '#fff', 'middle') + tx('CARTELA', 512, 300, 28, true, C.tx, 'middle');
  s += `<text x="512" y="388" font-family="Liberation Sans" font-size="84" font-weight="700" fill="${OU}" stroke="#7a5a00" stroke-width="3" paint-order="stroke" text-anchor="middle">${xml(String(d.c || '').slice(0, 15))}</text>`;
  [432, 896].forEach((y) => (s += `<line x1="77" y1="${y}" x2="947" y2="${y}" stroke="#d8c790" stroke-width="3" stroke-dasharray="14 12"/>`));
  s += tx('10 DEZENAS DA CARTELA', 512, 496, 28, true, C.tx, 'middle');
  dz(d.d).sort().slice(0, 10).forEach((n, i) => {
    const x = 161 + (i % 5) * 175.25, y = 600 + (i > 4 ? 180 : 0);
    s += `<circle cx="${x}" cy="${y}" r="61" fill="${C.gr}"/><circle cx="${x}" cy="${y}" r="63" fill="none" stroke="${OU}" stroke-width="7"/>` + tx(n, x, y + 15, 42, true, OU2, 'middle');
  });
  s += tx('PARABÉNS! CARTELA COMPLETA', 512, 980, 36, true, C.tx, 'middle') + tx('Todas as 10 dezenas foram acertadas.', 512, 1036, 26, false, C.gy, 'middle');
  s += `<rect x="44" y="1196" width="936" height="40" fill="${C.gr}"/><rect x="44" y="1192" width="936" height="4" fill="${OU}"/>`;
  return { W, H, s };
}
async function png(d: Img): Promise<Uint8Array> {
  await prepararWasm();
  const g = d.tipo === 'venc' ? svgVenc(d) : svgLista(d);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${g.W}" height="${g.H}" viewBox="0 0 ${g.W} ${g.H}">${g.s}</svg>`;
  const r = new Resvg(svg, { font: { fontBuffers: FONTES, loadSystemFonts: false, defaultFontFamily: 'Liberation Sans' } });
  const out = r.render().asPng();
  r.free();
  return out;
}

// ===== Telegram =====
async function tgCred() {
  const tk = await cfg('tg_token'), ch = await cfg('tg_chat');
  if (!tk || !ch) throw new Error('Telegram não configurado (Admin → Telegram).');
  return { tk, ch };
}
// Se o Telegram responder 429 ("muitas mensagens"), espera o tempo que ele pedir e tenta de novo.
async function tgPost(metodo: string, mk: (ch: string) => RequestInit) {
  const c = await tgCred();
  for (let i = 0; i < 3; i++) {
    const r = await fetch(`https://api.telegram.org/bot${c.tk}/${metodo}`, { method: 'POST', ...mk(c.ch) });
    if (r.ok) { await r.body?.cancel(); await sleep(TG_PAUSA_MS); return; }
    const t = await r.text();
    if (r.status === 429) {
      let w = 5; try { w = JSON.parse(t).parameters.retry_after || 5; } catch { /* usa 5 s */ }
      if (w > 60) throw new Error('Telegram pediu para esperar ' + w + ' s');
      await sleep(w * 1000 + 500); continue;
    }
    throw new Error('Telegram: ' + t.slice(0, 200));
  }
  throw new Error('Telegram: limite de envio excedido');
}
const tg = (texto: string) => tgPost('sendMessage', (ch) => ({ headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ chat_id: ch, text: texto, parse_mode: 'HTML' }) }));
const tgFoto = (p: Uint8Array) => tgPost('sendPhoto', (ch) => {
  const f = new FormData(); f.append('chat_id', ch); f.append('photo', new Blob([p], { type: 'image/png' }), 'cartelas.png'); return { body: f };
});
type Item = string | { texto: string; img: Img };
async function enviarItem(it: Item) {
  if (typeof it === 'string') return tg(it);
  try { await tgFoto(await png(it.img)); }
  catch (e) { await log('telegram', 'Imagem falhou (' + (e as Error).message + '); enviei em texto.'); await tg(it.texto); }
}

// Mensagens do sorteio "alvo" (sempre a mesma lista para o mesmo sorteio: a fila depende disso).
function resumo(alvo: { data: string; horario: string }, D: { sorteios: Sorteio[]; jogos: Jogo[] }): Item[] {
  const ordem = ordenar(D.sorteios.slice()), jg = D.jogos;
  const setJ = new Set<number>(), setA = new Set<number>(), acum: number[] = [];
  let vit: Sorteio | null = null, gan: Jogo[] = [], s: Sorteio | null = null;
  for (const x of ordem) {
    x.dezenas.forEach((v) => { const n = Number(v); if (!setA.has(n)) { setA.add(n); acum.push(n); } });
    if (!vit) {
      x.dezenas.forEach((n) => setJ.add(Number(n)));
      const w = jg.filter((g) => g.d.every((n) => setJ.has(n)));
      if (w.length) { vit = x; gan = w; }
    }
    if (x.data === alvo.data && x.horario === alvo.horario) { s = x; break; }
  }
  if (!s) throw new Error('Sorteio não encontrado: ' + alvo.data + ' ' + alvo.horario);
  const p = s.data.split('/').map(Number), dia = DIAS_SEM[new Date(p[2], p[1] - 1, p[0]).getDay()];
  const msgs: Item[] = ['<b>Sorteio de ' + dia + ', horário ' + s.horario + ':</b> ' + s.dezenas.join(' - ') +
    '\n<b>Dezenas Sorteadas:</b>\n' + acum.map(pad).join(' - ')];
  const linhaGan = (g: Jogo) => '🏆 Cartela <b>' + g.c + '</b> (jogo ' + g.j + ') — 10/10';
  if (vit && vit !== s) {
    msgs.push('<b>Situação dos ganhadores:</b>\nJá houve ganhador no sorteio de ' + vit.data + ' (' + vit.horario + ').');
    for (let i = 0; i < gan.length; i += 10) msgs.push(gan.slice(i, i + 10).map(linhaGan).join('\n'));
    return msgs;
  }
  const ent = (g: Jogo) => 'Cartela <b>' + g.c + '</b> (jogo ' + g.j + ')\nDezenas: ' + g.d.map(pad).join(' • ') +
    '\nFaltam: ' + g.d.filter((n) => !setJ.has(n)).map(pad).join(' • ');
  const por: Record<number, Jogo[]> = { 7: [], 8: [], 9: [] };
  jg.forEach((g) => { const ac = g.d.filter((n) => setJ.has(n)).length; if (por[ac]) por[ac].push(g); });
  for (const k of [7, 8, 9]) {
    const l = por[k].sort((a, b) => String(a.c).localeCompare(String(b.c), undefined, { numeric: true }) || Number(a.j) - Number(b.j));
    const tit = '<b>Cartelas com ' + k + ' acertos:</b>';
    if (k === 7 && l.length > LIMITE_7) { msgs.push(tit + '\nMais de ' + LIMITE_7 + ' cartelas (' + l.length + '). Exibindo só 8 e 9 acertos até haver ganhador.'); continue; }
    if (!l.length) { msgs.push(tit + '\nNenhuma cartela atingiu ' + k + ' acertos neste sorteio.'); continue; }
    const np = Math.ceil(l.length / 10);
    for (let i = 0; i < l.length; i += 10) {
      const pg = l.slice(i, i + 10);
      msgs.push({
        texto: tit + (np > 1 ? ' (parte ' + (i / 10 + 1) + '/' + np + ')' : '') + '\n\n' + pg.map(ent).join('\n\n'),
        img: { tipo: 'lista', titulo: 'RESULTADO — ' + k + ' ACERTOS', sub: 'Página ' + (i / 10 + 1) + '/' + np + ' • ' + pg.length + ' cartela(s)',
          rows: pg.map((g) => ({ c: g.c, d: g.d, f: g.d.filter((n) => !setJ.has(n)), ac: k })) },
      });
    }
  }
  if (vit === s) {
    msgs.push('<b>Situação dos ganhadores:</b>\n🎉 Temos ganhador(es) neste sorteio!');
    gan.forEach((g) => msgs.push({ texto: linhaGan(g), img: { tipo: 'venc', c: g.c, d: g.d } }));
    return msgs;
  }
  msgs.push('<b>Situação dos ganhadores:</b>\nAinda não houve nenhum ganhador.');
  return msgs;
}

// Trava do envio (uma execução por vez): vale por 4 minutos, caso uma execução morra no meio.
async function travar() {
  const r = await sql`insert into bolao.config(k, v) values ('tg_lock', now()::text)
    on conflict (k) do update set v = now()::text where bolao.config.v is null or bolao.config.v = '' or bolao.config.v::timestamptz < now() - interval '4 minutes'
    returning k`;
  return r.length > 0;
}
const destravar = () => sql`update bolao.config set v = null where k = 'tg_lock'`;

// Envia o que estiver na fila e, depois, os sorteios ainda não enviados, em ordem.
async function processarFila(): Promise<string> {
  const t0 = Date.now();
  type Fila = { data: string; horario: string; i: number };
  let fila: Fila | null = JSON.parse((await cfg('tg_fila')) || 'null');
  for (;;) {
    if (!fila) {
      const env: string[] = JSON.parse((await cfg('tg_env')) || '[]');
      const s = ordenar((await dados()).sorteios).find((x) => !env.includes(x.data + '|' + x.horario));
      if (!s) return 'ok';
      env.push(s.data + '|' + s.horario);
      await setCfg('tg_env', JSON.stringify(env.slice(-60)));
      fila = { data: s.data, horario: s.horario, i: 0 };
      await setCfg('tg_fila', JSON.stringify(fila));
    }
    const k = fila.data + ' ' + fila.horario;
    try {
      const itens = resumo(fila, await dados());
      while (fila.i < itens.length) {
        if (Date.now() - t0 > TEMPO_MS) return 'parcial';
        await enviarItem(itens[fila.i]);
        fila.i++;
        await setCfg('tg_fila', JSON.stringify(fila));
      }
    } catch (e) {
      await log('telegram', 'Falha ao enviar o sorteio ' + k + ' (parou na mensagem ' + (fila.i + 1) + '): ' + (e as Error).message);
    }
    await setCfg('tg_fila', null);
    fila = null;
  }
}
async function rodarTelegram(): Promise<string> {
  if (!(await cfg('tg_token')) || !(await cfg('tg_chat'))) return 'sem-config';
  if (!(await travar())) return 'ocupado';
  try { return await processarFila(); } finally { await destravar(); }
}

// ===== Entrada =====
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ erro: 'Use POST' }, 405);
  let b: { a?: string; t?: string } = {};
  try { b = await req.json(); } catch { /* corpo vazio */ }
  try {
    // Agendamentos (pg_cron): respondem na hora e trabalham em segundo plano.
    const xc = req.headers.get('x-cron');
    if (xc) {
      if (xc !== (await cfg('cron_segredo'))) return json({ erro: 'Não autorizado' }, 401);
      if (b.a === 'resultados') { EdgeRuntime.waitUntil(atualizarResultados().catch((e) => log('sistema', 'Busca de resultados falhou: ' + e.message))); return json({ ok: true }); }
      if (b.a === 'telegram') { EdgeRuntime.waitUntil(rodarTelegram().catch((e) => log('telegram', 'Envio falhou: ' + e.message))); return json({ ok: true }); }
      return json({ erro: 'Ação desconhecida' }, 400);
    }
    // Botões do admin no site
    const u = await sessaoAdm(b.t || '');
    if (!u) return json({ erro: 'Sessão expirada', sessao: 1 });
    switch (b.a) {
      case 'atualizar': {
        const r = await atualizarResultados();
        if ('gravados' in r && r.gravados?.length) EdgeRuntime.waitUntil(rodarTelegram().catch(() => {}));
        return json(r);
      }
      case 'telegramTeste': await tg('✅ Teste: o bot do ' + NOME_BOT + ' está funcionando.'); return json({ ok: true });
      case 'telegramImagemTeste':
        await tgFoto(await png({ tipo: 'lista', titulo: 'RESULTADO — TESTE', sub: 'Imagem de teste • 2 cartela(s)', rows: [
          { c: '81575', d: [5, 9, 2, 10, 18, 39, 91, 30, 57, 61], f: [5, 18, 57], ac: 7 },
          { c: '78622', d: [32, 44, 52, 55, 39, 81, 71, 61, 35, 13], f: [52, 55, 81], ac: 7 }] }));
        return json({ ok: true });
      case 'telegramReenviar': {
        if (await cfg('tg_fila')) return json({ erro: 'Já há um envio em andamento. Tente de novo em alguns minutos.' });
        const l = ordenar((await dados()).sorteios);
        if (!l.length) return json({ erro: 'Ainda não há sorteios registrados' });
        const s = l[l.length - 1];
        await setCfg('tg_fila', JSON.stringify({ data: s.data, horario: s.horario, i: 0 }));
        await log(u, 'Reenviou ao Telegram o sorteio ' + s.data + ' ' + s.horario);
        EdgeRuntime.waitUntil(rodarTelegram().catch((e) => log('telegram', 'Reenvio falhou: ' + e.message)));
        return json({ ok: true, msg: 'Reenvio iniciado: as mensagens chegam no canal nos próximos minutos.' });
      }
      case 'imagemPrevia': {   // só para conferir o desenho (admin)
        const p = await png((b as unknown as { img: Img }).img || { tipo: 'venc', c: '77777', d: [2, 10, 20, 21, 22, 23, 25, 26, 15, 16] });
        return new Response(p, { headers: { ...cors, 'Content-Type': 'image/png' } });
      }
    }
    return json({ erro: 'Ação desconhecida: ' + b.a });
  } catch (e) {
    return json({ erro: String((e as Error).message || e) });
  }
});
