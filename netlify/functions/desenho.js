'use strict';
// Desenho das imagens (mesmos modelos do site). Recebe a função que cria o canvas, para rodar no servidor ou num teste.

const C = {dk: '#173d2b', gr: '#0b6b43', cr: '#f4efdd', al: '#efe8d6', br: '#8a5a2b', tx: '#1d2330', gy: '#555555'};

const dz = a => (Array.isArray(a) ? a : []).map(n => String(Math.max(0, Math.min(99, Math.floor(Number(n)) || 0))).padStart(2, '0'));
const txt = (v, max) => String(v == null ? '' : v).slice(0, max);

// texto: tamanho em px, negrito sim/não, cor, alinhamento
function tx(g, s, x, y, tam, neg, cor, al) {
  g.font = (neg ? '700 ' : '400 ') + tam + 'px ' + (neg ? 'FonteB' : 'FonteN');
  g.fillStyle = cor; g.textAlign = al || 'left'; g.textBaseline = 'alphabetic';
  g.fillText(s, x, y);
}

// Troféu desenhado com traços (o servidor não tem fonte de emoji). cx,cy = centro; s = altura.
function trofeu(g, cx, cy, s) {
  const ouro = '#f5b301';
  g.fillStyle = ouro; g.strokeStyle = ouro; g.lineCap = 'round';
  g.beginPath();
  g.moveTo(cx - 0.30 * s, cy - 0.50 * s); g.lineTo(cx + 0.30 * s, cy - 0.50 * s); g.lineTo(cx + 0.30 * s, cy - 0.10 * s);
  g.quadraticCurveTo(cx + 0.30 * s, cy + 0.22 * s, cx, cy + 0.22 * s);
  g.quadraticCurveTo(cx - 0.30 * s, cy + 0.22 * s, cx - 0.30 * s, cy - 0.10 * s);
  g.closePath(); g.fill();
  g.lineWidth = 0.07 * s;
  g.beginPath(); g.arc(cx - 0.30 * s, cy - 0.27 * s, 0.14 * s, Math.PI * 0.5, Math.PI * 1.5); g.stroke();
  g.beginPath(); g.arc(cx + 0.30 * s, cy - 0.27 * s, 0.14 * s, -Math.PI * 0.5, Math.PI * 0.5); g.stroke();
  g.fillRect(cx - 0.05 * s, cy + 0.20 * s, 0.10 * s, 0.17 * s);
  g.fillRect(cx - 0.20 * s, cy + 0.37 * s, 0.40 * s, 0.10 * s);
}

module.exports = function montar(criar) {

  // Modelo "RESULTADO — N ACERTOS": até 10 cartelas por imagem. d = {titulo, sub, rows:[{c, d, f, ac}]}
  function desenharLista(d) {
    const rows = (Array.isArray(d.rows) ? d.rows : []).slice(0, 10);
    const n = Math.max(rows.length, 1), W = 887, H = 210 + n * 107;
    const cv = criar(W, H), g = cv.getContext('2d');
    g.fillStyle = C.cr; g.fillRect(0, 0, W, H);
    g.fillStyle = C.dk; g.fillRect(0, 0, W, 126); g.fillRect(0, H - 37, W, 37);
    tx(g, txt(d.titulo, 60), 443, 52, 40, true, '#fff', 'center');
    tx(g, txt(d.sub, 80), 443, 96, 22, false, '#fff', 'center');
    rows.forEach((r, i) => {
      const y = 137 + i * 107;
      g.fillStyle = i % 2 ? C.al : '#fff'; g.fillRect(33, y, 821, 100);
      tx(g, 'CARTELA', 56, y + 27, 17, true, C.tx);
      tx(g, txt(r.c, 15), 56, y + 60, 30, true, C.gr);
      tx(g, 'Dezenas: ' + dz(r.d).join(' • '), 237, y + 23, 17, false, '#333333');
      tx(g, 'Faltam: ' + dz(r.f).join(' • '), 237, y + 54, 17, false, C.br);
      tx(g, (Math.floor(Number(r.ac)) || 0) + '/10', 831, y + 41, 24, true, C.gr, 'right');
    });
    tx(g, 'Resultado das Cartelas', 443, H - 13, 15, false, '#fff', 'center');
    return cv;
  }

  // Modelo "CARTELA VENCEDORA": uma cartela em destaque. d = {c, d:[10 dezenas]}
  function desenharVencedora(d) {
    const cv = criar(1024, 1280), g = cv.getContext('2d');
    g.fillStyle = C.cr; g.fillRect(0, 0, 1024, 1280);
    g.fillStyle = C.dk; g.fillRect(26, 26, 972, 186);
    g.fillStyle = C.gr; g.fillRect(32, 1205, 960, 43);
    g.strokeStyle = C.dk; g.lineWidth = 26; g.strokeRect(13, 13, 998, 1254);

    const titulo = 'CARTELA VENCEDORA';
    g.font = '700 54px FonteB';
    const larg = 70 + 20 + g.measureText(titulo).width, x0 = 512 - larg / 2;
    trofeu(g, x0 + 35, 87, 72);
    tx(g, titulo, x0 + 90, 107, 54, true, '#fff', 'left');
    tx(g, '10 / 10 ACERTOS', 512, 165, 34, true, '#fff', 'center');

    tx(g, 'CARTELA', 512, 288, 28, true, C.tx, 'center');
    tx(g, txt(d.c, 15), 512, 370, 76, true, C.gr, 'center');

    g.strokeStyle = '#c4bfb0'; g.lineWidth = 3; g.setLineDash([14, 12]);
    [427, 891].forEach(y => { g.beginPath(); g.moveTo(77, y); g.lineTo(947, y); g.stroke(); });
    g.setLineDash([]);

    tx(g, '10 DEZENAS DA CARTELA', 512, 492, 28, true, C.tx, 'center');
    dz(d.d).sort().slice(0, 10).forEach((n, i) => {
      const x = 161 + (i % 5) * 175.25, y = 597 + (i > 4 ? 180 : 0);
      g.fillStyle = C.gr; g.beginPath(); g.arc(x, y, 61, 0, Math.PI * 2); g.fill();
      tx(g, n, x, y + 15, 42, true, '#fff', 'center');
    });

    tx(g, 'PARABÉNS! CARTELA COMPLETA', 512, 972, 36, true, C.tx, 'center');
    tx(g, 'Todas as 10 dezenas foram acertadas.', 512, 1028, 26, false, C.gy, 'center');
    tx(g, 'Gerado pelo Dashboard de Cartelas', 512, 1146, 20, false, C.gy, 'center');
    return cv;
  }

  return {desenharLista: desenharLista, desenharVencedora: desenharVencedora};
};
