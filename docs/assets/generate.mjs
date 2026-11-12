import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import opentype from 'opentype.js';

const root = new URL('./', import.meta.url);
const check = process.argv.includes('--check');
const read = name => readFile(new URL(name, root));
const geometry = JSON.parse(await read('sources/geometry.json'));
const palette = JSON.parse(await read('sources/palette.json'));
const upstream = JSON.parse(await read('sources/upstream.json'));
const fontBytes = await read('sources/DejaVuSans.ttf');
const font = opentype.parse(fontBytes.buffer.slice(
  fontBytes.byteOffset, fontBytes.byteOffset + fontBytes.byteLength,
));
const sizes = [16, 24, 32, 48, 64, 96, 128, 144, 152, 167, 180, 192, 256, 384, 512, 1024];
const themes = {
  light: { bg: '#F4F4F1', fg: '#20262F', muted: '#576273' },
  dark: { bg: '#12161D', fg: '#F4F5F7', muted: '#B5BDCA' },
};
const files = [];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const xml = value => String(value).replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;',
})[character]);

function drawing(node) {
  const attributes = { ...node.attrs };
  const part = attributes.id;
  delete attributes.id;
  if (part) attributes['data-part'] = part;
  if (node.tag === 'path' && palette[part]) attributes.fill = palette[part];
  return `<${node.tag}${Object.entries(attributes).map(([key, value]) =>
    ` ${key}="${xml(value)}"`).join('')}>${node.children.map(drawing).join('')}</${node.tag}>`;
}

const artwork = drawing(geometry.library);
const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="${geometry.viewBox}" role="img" aria-label="libtmux for Raku" data-language="raku" data-variant="library" focusable="false"><title>libtmux for Raku</title>${artwork}</svg>
`;
const raster = (source, size) => sharp(Buffer.from(source))
  .resize(size, size).png({ compressionLevel: 9 }).toBuffer();

async function save(name, contents, details = {}) {
  const bytes = Buffer.isBuffer(contents) ? contents : Buffer.from(contents);
  if (check) {
    if (!bytes.equals(await read(name))) throw new Error(`Artwork drift: ${name}`);
  } else {
    await writeFile(new URL(name, root), bytes);
  }
  files.push({ file: name, bytes: bytes.length, sha256: digest(bytes), ...details });
}

function textPath(text, x, baseline, size, color, width, centered = false) {
  const glyphs = [...text].map(character => font.charToGlyph(character));
  const advances = glyphs.map((glyph, index) => (glyph.advanceWidth || 0)
    + (index + 1 < glyphs.length ? font.getKerningValue(glyph, glyphs[index + 1]) : 0));
  const units = advances.reduce((sum, value) => sum + value, 0);
  size = Math.min(size, width * font.unitsPerEm / units);
  let cursor = centered ? x - units * size / font.unitsPerEm / 2 : x;
  const outline = glyphs.map((glyph, index) => {
    const path = glyph.getPath(cursor, baseline, size).toPathData(2);
    cursor += advances[index] * size / font.unitsPerEm;
    return path;
  }).join('');
  return `<path fill="${color}" d="${outline}"/>`;
}

function social(theme, width, height) {
  const colors = themes[theme];
  const square = width === height;
  const size = square ? 384 : 320;
  const x = square ? (width - size) / 2 : 88;
  const y = square ? 120 : (height - size) / 2;
  const icon = `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="${geometry.viewBox}">${artwork}</svg>`;
  const text = square
    ? textPath('libtmux', width / 2, 655, 110, colors.fg, 900, true)
      + textPath('Raku / Library', width / 2, 738, 40, colors.fg, 900, true)
      + textPath('In development', width / 2, 812, 29, colors.muted, 900, true)
    : textPath('libtmux', 480, height / 2 - 15, 112, colors.fg, width - 540)
      + textPath('Raku / Library', 486, height / 2 + 55, 37, colors.fg, width - 546)
      + textPath('In development', 486, height / 2 + 118, 27, colors.muted, width - 546);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="libtmux for Raku, in development"><rect width="${width}" height="${height}" fill="${colors.bg}"/>${icon}${text}</svg>\n`;
}

async function icon(size, theme, fraction) {
  const inner = Math.floor(size * fraction);
  return sharp({ create: { width: size, height: size, channels: 3, background: themes[theme].bg } })
    .composite([{ input: await raster(svg, inner), left: Math.floor((size - inner) / 2), top: Math.floor((size - inner) / 2) }])
    .removeAlpha().png({ compressionLevel: 9 }).toBuffer();
}

async function icoFrame(size) {
  if (size === 256) return raster(svg, size);
  const rgba = await sharp(await raster(svg, size)).ensureAlpha().raw().toBuffer();
  const rowBytes = Math.ceil(size / 32) * 4;
  const dib = Buffer.alloc(40 + size * size * 4 + rowBytes * size);
  dib.writeUInt32LE(40, 0);
  dib.writeInt32LE(size, 4);
  dib.writeInt32LE(size * 2, 8);
  dib.writeUInt16LE(1, 12);
  dib.writeUInt16LE(32, 14);
  dib.writeUInt32LE(size * size * 4, 20);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const source = (y * size + x) * 4;
    const target = 40 + ((size - 1 - y) * size + x) * 4;
    dib[target] = rgba[source + 2];
    dib[target + 1] = rgba[source + 1];
    dib[target + 2] = rgba[source];
    dib[target + 3] = rgba[source + 3];
    if (rgba[source + 3] < 128) dib[40 + size * size * 4 + (size - 1 - y) * rowBytes + (x >> 3)] |= 0x80 >> (x & 7);
  }
  return dib;
}

function roundedRectangle({ x, y, width, height, rx }) {
  return `M${x + rx} ${y}H${x + width - rx}A${rx} ${rx} 0 0 1 ${x + width} ${y + rx}V${y + height - rx}A${rx} ${rx} 0 0 1 ${x + width - rx} ${y + height}H${x + rx}A${rx} ${rx} 0 0 1 ${x} ${y + height - rx}V${y + rx}A${rx} ${rx} 0 0 1 ${x + rx} ${y}Z`;
}

await save('logo.svg', svg, { width: 512, height: 512, transparent: true });
for (const size of sizes) {
  await save(`logo-${size}.png`, await raster(svg, size), { width: size, height: size, transparent: true });
}

const iconSizes = [16, 32, 48, 256];
const frames = await Promise.all(iconSizes.map(icoFrame));
const header = Buffer.alloc(6 + frames.length * 16);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(frames.length, 4);
let offset = header.length;
frames.forEach((data, index) => {
  const at = 6 + index * 16;
  header[at] = iconSizes[index] % 256;
  header[at + 1] = iconSizes[index] % 256;
  header.writeUInt16LE(1, at + 4);
  header.writeUInt16LE(32, at + 6);
  header.writeUInt32LE(data.length, at + 8);
  header.writeUInt32LE(offset, at + 12);
  offset += data.length;
});
await save('favicon.ico', Buffer.concat([header, ...frames]), { sizes: iconSizes });

// The flat family retains negative space in a one-color Safari mask.
const maskPath = [geometry.flat.frame, ...geometry.flat.panes].map(roundedRectangle).join('');
await save('safari-pinned-tab.svg', `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 39 39"><title>libtmux for Raku</title><path fill="#000000" fill-rule="evenodd" d="${maskPath}"/></svg>\n`, { monochrome: true, variant: 'port-pane' });

for (const theme of ['light', 'dark']) {
  for (const [name, size, fraction] of [
    ['apple-touch-icon', 180, .76], ['app-icon-1024', 1024, .76],
    ['maskable-192', 192, .52], ['maskable-512', 512, .52],
    ['mstile-150', 150, .72], ['mstile-310', 310, .72],
  ]) {
    await save(`${name}-${theme}.png`, await icon(size, theme, fraction), { width: size, height: size, transparent: false });
  }
  for (const [name, width, height] of [
    ['opengraph', 1200, 630], ['twitter', 1200, 600],
    ['social-square', 1080, 1080], ['github-social', 1280, 640],
  ]) {
    const vector = social(theme, width, height);
    if (name === 'opengraph') await save(`${name}-${theme}.svg`, vector, { width, height, transparent: false });
    const image = sharp(Buffer.from(vector)).removeAlpha();
    await save(`${name}-${theme}.png`, await image.clone().png({ compressionLevel: 9 }).toBuffer(), { width, height, transparent: false });
    if (name === 'opengraph') await save(`${name}-${theme}.jpg`, await image.clone().jpeg({ quality: 92, chromaSubsampling: '4:4:4' }).toBuffer(), { width, height, transparent: false });
  }
  const manifest = {
    name: 'libtmux for Raku', short_name: 'libtmux', display: 'standalone',
    background_color: themes[theme].bg, theme_color: palette.primary,
    icons: [192, 512].flatMap(size => [
      { src: `logo-${size}.png`, sizes: `${size}x${size}`, type: 'image/png', purpose: 'any' },
      { src: `maskable-${size}-${theme}.png`, sizes: `${size}x${size}`, type: 'image/png', purpose: 'maskable' },
    ]),
  };
  await save(theme === 'light' ? 'site.webmanifest' : 'site-dark.webmanifest', JSON.stringify(manifest, null, 2) + '\n');
  await save(theme === 'light' ? 'browserconfig.xml' : 'browserconfig-dark.xml', `<?xml version="1.0" encoding="utf-8"?><browserconfig><msapplication><tile><square150x150logo src="mstile-150-${theme}.png"/><square310x310logo src="mstile-310-${theme}.png"/><TileColor>${palette.primary}</TileColor></tile></msapplication></browserconfig>\n`);
}

const source = {
  schemaVersion: 1,
  repository: 'https://github.com/libtmux/assets',
  revision: upstream[0].revision,
  language: 'raku', variant: 'library', primary: palette.primary,
  githubLanguageColors: 'https://github.com/github-linguist/linguist/blob/d456527fe93355baa28c3c29d542c97282b61bc7/lib/linguist/languages.yml',
  paletteMethod: 'Primary is exact Linguist Raku color. Supporting shades mix primary with black (70%, 90%, 65%, 45% primary) or white (55%, 25% white); channels rounded to nearest integer.',
  preferences: {
    request: 'Create logo images similar to the existing libtmux port family.',
    referenceThread: 'codex://threads/01a0e385-475d-7c13-83a4-7e8b83c1a198',
    recoveredFrom: 'Thread relay records identified libtmux/assets PR 6 and sibling docs/assets/source.json. Original thread prompt unavailable.',
    method: 'Deterministic SVG family adaptation and SVG rasterization; no image-generation model.',
    constraints: ['Preserve library tile and cog geometry', 'Use Raku primary color', 'Core library only', 'Private repository; no publication'],
  },
  ownership: {
    artwork: 'Original libtmux and tmuxp artwork supplied by the project owner. Existing ownership and attribution retained; no new artwork license assigned.',
    sourceNotice: 'https://github.com/libtmux/assets/blob/009ef796a2f89ddfe4e5b7ca0f7142aa47798798/THIRD_PARTY.md',
    font: 'DejaVu Sans; redistribution notice in sources/LICENSE-DejaVu.txt',
  },
  rendering: {
    setup: 'npm ci --prefix docs/assets',
    command: 'npm run build --prefix docs/assets',
    verification: 'npm run check --prefix docs/assets',
    dependencyLock: 'package-lock.json',
    sharp: sharp.versions.sharp,
    vips: sharp.versions.vips,
    safariMask: 'Uses the established flat port-pane silhouette with transparent pane cutouts; recoloring every raised library path black would erase internal distinctions.',
    socialCopy: ['libtmux', 'Raku / Library', 'In development'],
  },
  upstream,
  inputs: await Promise.all(['generate.mjs', 'sources/palette.json', 'package-lock.json'].map(async file => ({ file, sha256: digest(await read(file)) }))),
  files,
};
const metadata = JSON.stringify(source, null, 2) + '\n';
if (check) {
  if (metadata !== (await read('source.json')).toString()) throw new Error('Artwork provenance drift');
} else {
  await writeFile(new URL('source.json', root), metadata);
}
console.log(`${check ? 'Verified' : 'Generated'} ${files.length} Raku artwork files.`);
