'use strict';
const crypto = require('crypto');
const { createCanvas, GlobalFonts } = require('@napi-rs/canvas');
const fontes = require('./fontes');
const montar = require('./desenho');

// Fonte embutida (Liberation Sans, licença SIL OFL): o servidor não tem Arial.
GlobalFonts.register(Buffer.from(fontes.regular, 'base64'), 'FonteN');
GlobalFonts.register(Buffer.from(fontes.bold, 'base64'), 'FonteB');

const desenho = montar((w, h) => createCanvas(w, h));

const igual = (a, b) => {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return {statusCode: 405, body: 'Use POST'};
  const chave = process.env.CHAVE;
  if (!chave) return {statusCode: 500, body: 'Variável CHAVE não configurada no Netlify'};
  if (!igual((event.headers || {})['x-chave'] || '', chave)) return {statusCode: 401, body: 'Não autorizado'};

  let d;
  try { d = JSON.parse(event.body || '{}'); } catch (e) { return {statusCode: 400, body: 'JSON inválido'}; }

  try {
    const cv = d.tipo === 'venc' ? desenho.desenharVencedora(d) : desenho.desenharLista(d);
    return {
      statusCode: 200,
      headers: {'Content-Type': 'image/png', 'Cache-Control': 'no-store'},
      body: cv.toBuffer('image/png').toString('base64'),
      isBase64Encoded: true
    };
  } catch (e) {
    return {statusCode: 500, body: String(e && e.message || e)};
  }
};
