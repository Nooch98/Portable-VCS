class EditorAssets {
  static const String html = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.44.0/min/vs/editor/editor.main.min.css">
  <style>
    :root { --bg: #1e1e1e; --panel: #252526; --accent: #007acc; --border: #3c3c3c; --text: #d4d4d4; }
    body { margin: 0; display: flex; flex-direction: column; height: 100vh; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    
    #container { flex-grow: 1; border-bottom: 1px solid var(--border); }
    
    .terminal-panel { height: 180px; background: #000; display: flex; flex-direction: column; }
    .terminal-header { background: #2d2d2d; padding: 5px 15px; font-size: 11px; text-transform: uppercase; color: #888; letter-spacing: 1px; display: flex; justify-content: space-between; }
    #output { flex-grow: 1; padding: 10px; font-family: 'Cascadia Code', 'Fira Code', monospace; font-size: 13px; color: #00ff41; overflow-y: auto; white-space: pre-wrap; }
    
    .toolbar { background: var(--panel); padding: 10px 20px; display: flex; gap: 12px; align-items: center; border-top: 1px solid var(--border); }
    button { background: var(--accent); color: white; border: none; padding: 8px 16px; cursor: pointer; border-radius: 3px; font-weight: 600; font-size: 12px; transition: background 0.2s; }
    button:hover { background: #005f9e; }
    button:disabled { background: #444; cursor: not-allowed; }
  </style>
</head>
<body>
  <div id="container"></div>
  <div class="terminal-panel">
    <div class="terminal-header"><span>Output Terminal</span><span id="status">Idle</span></div>
    <div id="output">Waiting for commands...</div>
  </div>
  <div class="toolbar">
    <button onclick="save()" id="saveBtn">💾 Save Hook</button>
    <button onclick="test()" id="testBtn" style="background: #333;">🧪 Run Test</button>
  </div>

  <script src="https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.44.0/min/vs/loader.min.js"></script>
  <script>
    require.config({ paths: { 'vs': 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.44.0/min/vs' }});
    let editor;

    require(['vs/editor/editor.main'], function () {
      fetch('/api/get-content').then(r => r.json()).then(d => {
        editor = monaco.editor.create(document.getElementById('container'), {
          value: d.content, language: d.language, theme: 'vs-dark',
          automaticLayout: true, minimap: { enabled: true }, fontSize: 14,
          padding: { top: 10 }
        });
      });
    });

    setInterval(() => fetch('/api/heartbeat', { method: 'POST' }), 2000);

    function save() {
      const btn = document.getElementById('saveBtn');
      btn.disabled = true; btn.innerText = "Saving...";
      fetch('/api/save', { method: 'POST', body: JSON.stringify({ content: editor.getValue() }) })
        .then(() => window.close());
    }

    async function test() {
      const out = document.getElementById('output');
      const btn = document.getElementById('testBtn');
      out.innerText = "> Executing script...";
      btn.disabled = true; document.getElementById('status').innerText = "Running...";
      
      const r = await fetch('/api/test', { method: 'POST', body: JSON.stringify({ content: editor.getValue() }) });
      const d = await r.json();
      
      out.innerText = d.output || "Execution finished (no output).";
      btn.disabled = false; document.getElementById('status').innerText = "Idle";
    }
  </script>
</body>
</html>
''';
}
