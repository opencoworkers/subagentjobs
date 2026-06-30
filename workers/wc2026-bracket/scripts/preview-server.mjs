// Minimal static server for the render-test fixture: serves the preview page at
// / and the bracket payload at /api/bracket (the page fetches it on load).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const dir = join(dirname(dirname(fileURLToPath(import.meta.url))), 'tests', '.preview');
const PORT = Number(process.env.PREVIEW_PORT || 8788);

createServer(async (req, res) => {
  try {
    if (req.url.startsWith('/api/bracket')) {
      const body = await readFile(join(dir, 'bracket.json'));
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(body);
    }
    const html = await readFile(join(dir, 'index.html'));
    res.writeHead(200, { 'content-type': 'text/html;charset=utf-8' });
    res.end(html);
  } catch (e) {
    console.error('preview-server error:', e);
    res.writeHead(500, { 'content-type': 'text/plain' });
    res.end('internal error');
  }
}).listen(PORT, () => console.log('preview server on http://127.0.0.1:' + PORT));
