// inject-api-key.js
const fs = require('fs');
const path = require('path');

const apiKey = process.env.WAHA_API_KEY || '';
if (!apiKey) {
  console.log('⚠️  WAHA_API_KEY no está definida, no se inyectará nada.');
  process.exit(0);
}

const dashboardDir = path.join(__dirname, 'dist/dashboard/assets');
const files = fs.readdirSync(dashboardDir).filter(f => f.startsWith('index-') && f.endsWith('.js'));

if (files.length === 0) {
  console.log('⚠️  No se encontró el archivo index-*.js del dashboard.');
  process.exit(0);
}

const filePath = path.join(dashboardDir, files[0]);
const content = fs.readFileSync(filePath, 'utf8');

const snippet = `
(function(){
  const apiKey = '${apiKey}';
  const originalFetch = window.fetch;
  window.fetch = function(...args) {
    const [url, opts = {}] = args;
    if (url.includes('/api/')) {
      opts.headers = opts.headers || {};
      if (!opts.headers['X-Api-Key']) {
        opts.headers['X-Api-Key'] = apiKey;
      }
    }
    return originalFetch(url, opts);
  };
  const OriginalWebSocket = window.WebSocket;
  window.WebSocket = function(url, protocols) {
    if (url.includes('/api/ws')) {
      url += (url.includes('?') ? '&' : '?') + 'api_key=' + apiKey;
    }
    return new OriginalWebSocket(url, protocols);
  };
})();
`;

if (!content.includes('X-Api-Key')) {
  fs.writeFileSync(filePath, snippet + '\n' + content);
  console.log('✅ X-Api-Key inyectada en', filePath);
} else {
  console.log('ℹ️  X-Api-Key ya estaba inyectada.');
}
