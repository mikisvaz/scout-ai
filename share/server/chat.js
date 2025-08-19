(function(){
  const API_BASE = ''; // same origin, adjust if your server is hosted elsewhere
  const PREDEFINED_KEYS = ['user','system','assistant','import','file','directory','option','endpoint','model','backend','format','websearch','tool','task','job','inline_job'];
  const ROLE_ONLY = ['user','system','assistant'];
  const FILE_KEYS = ['import','file','directory'];
  const MARKED_CDN = 'https://cdn.jsdelivr.net/npm/marked/marked.min.js';

  // State
  let cells = [];

  // DOM
  const pathEl = document.getElementById('path');
  const cellsDiv = document.getElementById('cells');
  const filesDiv = document.getElementById('files');
  const logDiv = document.getElementById('log');
  const cellCountEl = document.getElementById('cellCount');

  const newFileBtn = document.getElementById('newFileBtn');
  const loadBtn = document.getElementById('loadBtn');
  const saveBtn = document.getElementById('saveBtn');
  const runBtn = document.getElementById('runBtn');
  const runBtnBottom = document.getElementById('runBtnBottom');
  const exportBtn = document.getElementById('exportBtn');
  const listBtn = document.getElementById('listBtn');
  const deleteBtn = document.getElementById('deleteBtn');
  const addUser = document.getElementById('addUser');
  const addSystem = document.getElementById('addSystem');
  const addAssistant = document.getElementById('addAssistant');
  const addOption = document.getElementById('addOption');
  const clearBtn = document.getElementById('clearBtn');
  const loadingIndicator = document.getElementById('loadingIndicator');

  // Modal elements
  const mdModal = document.getElementById('mdModal');
  const mdBody = document.getElementById('mdBody');
  const mdTitle = document.getElementById('mdTitle');
  const mdClose = document.getElementById('mdClose');
  const mdCopy = document.getElementById('mdCopy');

  function log(...args){ const line = document.createElement('div'); line.textContent = '['+new Date().toLocaleTimeString()+'] ' + args.join(' '); logDiv.appendChild(line); logDiv.scrollTop = logDiv.scrollHeight; console.log(...args); }

  // HTTP helpers
  async function fetchJSON(url, opts){
    const res = await fetch(url, opts);
    const text = await res.text();
    let json = null;
    try{ json = text ? JSON.parse(text) : {}; }catch(e){ throw new Error('Invalid JSON from ' + url + ': ' + text); }
    if(!res.ok) throw Object.assign(new Error('HTTP ' + res.status), {status: res.status, body: json});
    return json;
  }

  // Load marked library dynamically
  function loadMarked(){
    return new Promise((resolve, reject)=>{
      if(window.marked) return resolve(window.marked);
      const s = document.createElement('script');
      s.src = MARKED_CDN;
      s.async = true;
      s.onload = ()=>{ try{ return resolve(window.marked); }catch(e){ return reject(e); } };
      s.onerror = (e)=> reject(new Error('Failed to load marked.js'));
      document.head.appendChild(s);
    });
  }

  // Parse/serialize
  function parseTextToCells(text){
    const lines = (text||'').split(/\r?\n/);
    const out = [];
    const headerRe = /^([A-Za-z][\w-]*):\s*(.*)$/;
    let i = 0;
    while(i < lines.length){
      const ln = lines[i];
      const m = ln.match(headerRe);
      if(m){
        const key = m[1].toLowerCase();
        const rest = m[2] || '';
        // collect all lines until the next header (exclusive)
        const bodyLines = [];
        // include the same-line rest (may be empty string)
        bodyLines.push(rest);
        let j = i + 1;
        for(; j < lines.length; j++){
          if(headerRe.test(lines[j])) break;
          bodyLines.push(lines[j]);
        }
        // count non-empty lines in the block
        const nonEmptyCount = bodyLines.reduce((acc, l) => acc + (l && l.trim().length>0 ? 1 : 0), 0);
        const isInline = (nonEmptyCount <= 1);
        let content;
        if(isInline){
          // inline blocks: remove line jumps and join non-empty pieces with a single space
          const parts = bodyLines.map(l => l ? l.trim() : '').filter(s => s.length>0);
          content = parts.join(' ');
        } else {
          // block: preserve lines (including empty lines)
          content = bodyLines.join('\n');
          // trim trailing newlines that come from join
          content = content.replace(/\n+$/,'');
        }

        if(ROLE_ONLY.includes(key)){
          out.push({type:'role', role:key, inline:isInline, content: content});
        } else if(PREDEFINED_KEYS.includes(key)){
          out.push({type:'option', key:key, inline:isInline, content: content});
        } else {
          // unknown headers treated as option-like blocks
          out.push({type:'option', key:key, inline:isInline, content: content});
        }
        i = j;
        continue;
      }

      // Lines not starting with a header: collect until next header and treat as a note block
      let j = i;
      const body = [];
      while(j < lines.length && !headerRe.test(lines[j])){ body.push(lines[j]); j++; }
      const nonEmptyCount = body.reduce((acc, l) => acc + (l && l.trim().length>0 ? 1 : 0), 0);
      if(nonEmptyCount <= 1){
        const parts = body.map(l => l ? l.trim() : '').filter(s => s.length>0);
        const content = parts.join(' ');
        if(content.length>0) out.push({type:'role', role:'note', inline:true, content: content});
      } else {
        out.push({type:'role', role:'note', inline:false, content: body.join('\n')});
      }
      i = j;
    }
    return out;
  }

  function cellsToText(cells){
    let lines = [];
    cells.forEach(c=>{
      if(c.type==='role'){
        const role = c.role || 'user';
        if(c.inline) lines.push(role + ': ' + (c.content || ''));
        else lines.push(role + ':', (c.content || ''), '');
      } else if(c.type==='option'){
        const k = c.key || 'import';
        if(c.inline) lines.push(k + ': ' + (c.content || ''));
        else lines.push(k + ':', (c.content || ''), '');
      }
    });
    return lines.join('\n').replace(/\n{3,}/g,'\n\n');
  }

  // Render
  function render(){
    cellsDiv.innerHTML = '';
    cells.forEach((c, idx)=>{
      const el = document.createElement('div'); el.className='cell panel';
      const header = document.createElement('div'); header.className='cell-header';

      const keyInput = document.createElement('input');
      keyInput.className = 'role-input';
      keyInput.value = (c.type==='role' ? (c.role||'') : (c.key||''));
      keyInput.setAttribute('list','keys_datalist');
      keyInput.style.width = '160px';
      keyInput.onchange = ()=>{
        const v = keyInput.value.trim().toLowerCase();
        if(ROLE_ONLY.includes(v)){
          c.type = 'role'; c.role = v; c.key = undefined; if(c.inline === undefined) c.inline = false;
        } else if(v.length===0){
          // keep
        } else {
          c.type = 'option'; c.key = v; c.role = undefined; c.inline = true;
        }
        updateAndRender();
      };
      header.appendChild(keyInput);

      const inlineToggle = document.createElement('label'); inlineToggle.className='inline-toggle small'; inlineToggle.textContent = (c.inline ? 'inline' : 'block');
      inlineToggle.onclick = ()=>{ if(c.type==='option') return; c.inline = !c.inline; updateAndRender(); };
      header.appendChild(inlineToggle);

      const actions = document.createElement('div'); actions.className='cell-actions';
      const up = document.createElement('button'); up.textContent='↑'; up.title='Move up'; up.onclick = ()=>{ if(idx>0){ const t = cells[idx-1]; cells[idx-1]=cells[idx]; cells[idx]=t; updateAndRender(); } };
      const down = document.createElement('button'); down.textContent='↓'; down.title='Move down'; down.onclick = ()=>{ if(idx<cells.length-1){ const t = cells[idx+1]; cells[idx+1]=cells[idx]; cells[idx]=t; updateAndRender(); } };
      const del = document.createElement('button'); del.textContent='✕'; del.title='Delete'; del.onclick = ()=>{ if(confirm('Delete this cell?')){ cells.splice(idx,1); updateAndRender(); } };
      const convert = document.createElement('button'); convert.className='small';
      if(c.type==='option') convert.textContent = 'option (inline)';
      else convert.textContent = c.inline ? '→block' : '→inline';
      convert.onclick = ()=>{ if(c.type==='option') return; c.inline = !c.inline; updateAndRender(); };

      // preview markdown button (shows the cell content rendered as HTML assuming markdown)
      const previewMd = document.createElement('button'); previewMd.className='small'; previewMd.textContent='Preview MD'; previewMd.title='Render this cell as markdown';
      previewMd.onclick = ()=>{ showMarkdownModal(c.content || '', (c.type==='role' ? (c.role||'') : (c.key||'')).toUpperCase()); };

      actions.appendChild(up); actions.appendChild(down); actions.appendChild(convert); actions.appendChild(previewMd); actions.appendChild(del);
      header.appendChild(actions);

      el.appendChild(header);

      if(c.inline){
        const input = document.createElement('input'); input.className='cell-input'; input.value = c.content || '';
        if(c.type==='option' && FILE_KEYS.includes((c.key||'').toLowerCase())){
          input.setAttribute('list','files_datalist');
        }
        input.oninput = ()=>{ c.content = input.value; };
        el.appendChild(input);
      } else {
        const ta = document.createElement('textarea'); ta.className='cell-text'; ta.value = c.content || '';
        ta.oninput = ()=>{ c.content = ta.value; };
        el.appendChild(ta);
      }

      const footer = document.createElement('div'); footer.style.display='flex'; footer.style.marginTop='6px';
      const preview = document.createElement('div'); preview.className='small muted';
      if(c.type==='role') preview.textContent = (c.role + (c.inline ? ': ' + (c.content||'') : ' (block)'));
      else preview.textContent = (c.key + ': ' + (c.content||''));
      footer.appendChild(preview);
      el.appendChild(footer);

      cellsDiv.appendChild(el);
    });
    cellCountEl.textContent = cells.length;

    renderDatalists();
  }

  function updateAndRender(){ render(); }

  // Actions
  function addCell(role){ if(ROLE_ONLY.includes(role)) cells.push({type:'role', role:role, inline:false, content:''}); else cells.push({type:'option', key:role, inline:true, content:''}); updateAndRender(); }
  function addOptionCell(){ cells.push({type:'option', key:'import', inline:true, content:''}); updateAndRender(); }
  function clearCells(){ if(confirm('Clear all cells?')){ cells=[]; updateAndRender(); } }

  // Server interactions
  async function renderFileList(){
    try{
      const res = await fetchJSON(API_BASE + '/list');
      const wsFiles = res.files || [];
      filesDiv.innerHTML = '';
      if(wsFiles.length===0) filesDiv.innerHTML = '<div class="small muted">(no files)</div>';
      wsFiles.forEach(k=>{
        const div = document.createElement('div'); div.className='file-item';
        const a = document.createElement('a'); a.href='#'; a.textContent = k; a.onclick = (e)=>{ e.preventDefault(); pathEl.value=k; loadFile(); };
        const meta = document.createElement('div'); meta.className='small muted'; meta.textContent = '';
        div.appendChild(a); div.appendChild(meta); filesDiv.appendChild(div);
      });

      // update datalist for files
      renderDatalists(wsFiles);
      log('Listed', wsFiles.length, 'files');
    }catch(e){ log('Error listing files:', e.message || e); filesDiv.innerHTML = '<div class="small muted">(error)</div>'; renderDatalists([]); }
  }

  function renderDatalists(filesList){
    const oldKeys = document.getElementById('keys_datalist'); if(oldKeys) oldKeys.remove();
    const oldFiles = document.getElementById('files_datalist'); if(oldFiles) oldFiles.remove();

    const keys = document.createElement('datalist'); keys.id='keys_datalist';
    PREDEFINED_KEYS.forEach(k=>{ const o=document.createElement('option'); o.value=k; keys.appendChild(o); });
    document.body.appendChild(keys);

    const files = document.createElement('datalist'); files.id='files_datalist';
    (filesList || []).slice().sort().forEach(k=>{ const o=document.createElement('option'); o.value=k; files.appendChild(o); });
    document.body.appendChild(files);
  }

  async function saveFile(){ const p = pathEl.value.trim(); if(!p){ alert('Enter path'); return; } const text = cellsToText(cells);
    try{
      const res = await fetchJSON(API_BASE + '/save', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({path: p, content: text})});
      await renderFileList(); log('Saved ' + p);
    }catch(e){ log('Save failed:', e.message || e); alert('Save failed: ' + (e.message || e)); }
  }

  async function loadFile(){ const p = pathEl.value.trim(); if(!p){ alert('Enter path'); return; } try{
      const res = await fetchJSON(API_BASE + '/load?path=' + encodeURIComponent(p));
      const txt = res.content || '';
      cells = parseTextToCells(txt);
      updateAndRender(); log('Loaded ' + p);
    }catch(e){ log('Load failed:', e.message || e); alert('Load failed: ' + (e.body && e.body.error) ? e.body.error : (e.message || 'error')); }
  }

  async function newFile(){ const p = pathEl.value.trim(); if(!p){ alert('Enter path'); return; } if(!confirm('Create new file at: ' + p + ' ?')) return; cells = []; try{ await saveFile(); }catch(e){} }

  // Truncate file content (server has no delete endpoint in this simple server)
  async function deletePath(){ const p = pathEl.value.trim(); if(!p){ alert('Enter path'); return; } if(!confirm('Truncate ' + p + ' ? This will clear the file content.')) return; try{
      const res = await fetchJSON(API_BASE + '/save', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({path: p, content: ''})});
      await renderFileList(); log('Truncated ' + p);
    }catch(e){ log('Truncate failed:', e.message || e); alert('Truncate failed: ' + (e.message || e)); }
  }

  async function runFile(){ const p = pathEl.value.trim(); if(!p){ alert('Enter path'); return; } const text = cellsToText(cells);
    // show loading state
    setLoading(true);
    try{
      const res = await fetchJSON(API_BASE + '/run', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({path: p, content: text})});
      const newText = res.content || '';
      cells = parseTextToCells(newText);
      // After running, open a new blank block user cell at the end
      cells.push({type:'role', role:'user', inline:false, content:''});
      updateAndRender(); await renderFileList(); log('Ran and appended assistant reply to ' + p);
    }catch(e){ log('Run failed:', e.message || e); alert('Run failed: ' + (e.message || e)); }
    finally{ setLoading(false); }
  }

  function exportText(){ const t = cellsToText(cells); const w = window.open(); w.document.body.style.background='#fff'; w.document.title='Exported Chat'; const pre = w.document.createElement('pre'); pre.textContent = t; pre.style.whiteSpace='pre-wrap'; pre.style.fontFamily='monospace'; pre.style.padding='16px'; w.document.body.appendChild(pre); }

  // Use marked for markdown rendering. If not available, fallback to a safe escaped render.
  function escapeHtml(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

  // Updated: showMarkdownModal now ensures the generated HTML is inserted as real DOM using marked if available
  function showMarkdownModal(md, title){
    mdTitle.textContent = title || 'Preview';
    // Generate HTML from markdown using marked if available
    let html = '';
    if(window.marked){
      try{ html = marked.parse(md || ''); }catch(e){ html = escapeHtml(md || ''); }
    } else {
      // If marked isn't loaded yet, insert escaped markdown and try to load marked in the background for future previews
      html = '<pre style="white-space:pre-wrap">' + escapeHtml(md || '') + '</pre>';
      loadMarked().then(m=>{ /* noop - next previews will use marked */ }).catch(e=>{ console.warn('Could not load marked:', e); });
    }

    // Basic safety: strip <script> tags to avoid executing inline scripts
    html = html.replace(/<script[\s\S]*?>[\s\S]*?<\/script>/gi, '');

    mdBody.innerHTML = html;
    mdBody.style.whiteSpace = 'normal';
    mdModal.style.display = 'flex';
    mdModal.setAttribute('aria-hidden','false');
  }
  function hideMarkdownModal(){ mdModal.style.display = 'none'; mdModal.setAttribute('aria-hidden','true'); }
  mdClose.onclick = hideMarkdownModal;
  mdModal.onclick = function(e){ if(e.target === mdModal) hideMarkdownModal(); };

  // Copy modal content to clipboard (HTML + text) so it can be pasted into Word with formatting
  async function copyMarkdownModal(){
    const html = mdBody.innerHTML || '';
    const text = mdBody.innerText || mdBody.textContent || '';
    if(!navigator.clipboard){
      // last resort, try execCommand on a temporary element
      try{
        const temp = document.createElement('div'); temp.style.position='fixed'; temp.style.left='-10000px'; temp.innerText = text; document.body.appendChild(temp);
        const range = document.createRange(); range.selectNodeContents(temp);
        const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
        document.execCommand('copy');
        sel.removeAllRanges(); document.body.removeChild(temp);
        log('Copied modal content as plain text (execCommand fallback)');
        flashCopyBtn();
        return;
      }catch(e){ alert('Copy not supported: ' + e.message); return; }
    }

    // Preferred: write both text/html and text/plain to the clipboard so Word can accept formatted content
    if(window.ClipboardItem){
      try{
        const blobHtml = new Blob([html], {type: 'text/html'});
        const blobText = new Blob([text], {type: 'text/plain'});
        const item = new ClipboardItem({'text/html': blobHtml, 'text/plain': blobText});
        await navigator.clipboard.write([item]);
        log('Copied modal content (HTML + text)');
        flashCopyBtn();
        return;
      }catch(e){ console.warn('ClipboardItem write failed, falling back to plain text:', e); }
    }

    // Fallback: copy plain text only
    try{
      await navigator.clipboard.writeText(text);
      log('Copied modal content as plain text (fallback)');
      flashCopyBtn();
    }catch(e){ alert('Copy failed: ' + e.message); }
  }

  function flashCopyBtn(){ if(!mdCopy) return; const old = mdCopy.textContent; mdCopy.textContent = 'Copied!'; mdCopy.disabled = true; setTimeout(()=>{ mdCopy.textContent = old; mdCopy.disabled = false; }, 1500); }

  if(mdCopy) mdCopy.onclick = copyMarkdownModal;

  function setLoading(on){ if(on){ loadingIndicator.style.display='inline-flex'; runBtn.disabled = true; runBtnBottom.disabled = true; saveBtn.disabled = true; } else { loadingIndicator.style.display='none'; runBtn.disabled = false; runBtnBottom.disabled = false; saveBtn.disabled = false; } }

  // Wire events
  newFileBtn.onclick = newFile;
  loadBtn.onclick = loadFile;
  saveBtn.onclick = saveFile;
  runBtn.onclick = runFile;
  runBtnBottom.onclick = runFile;
  exportBtn.onclick = exportText;
  listBtn.onclick = renderFileList;
  deleteBtn.onclick = deletePath;
  addUser.onclick = ()=>addCell('user');
  addSystem.onclick = ()=>addCell('system');
  addAssistant.onclick = ()=>addCell('assistant');
  addOption.onclick = ()=>addOptionCell();
  clearBtn.onclick = clearCells;

  // Init
  (async function init(){
    await renderFileList();
    // attempt to load marked for better markdown previews; failures are non-fatal
    try{ await loadMarked(); log('marked.js loaded'); }catch(e){ log('marked.js not available, falling back to plain preview'); }
    // Prefill with a minimal conversation if nothing loaded yet
    cells = [{type:'role', role:'system', inline:false, content:'You are a helpful assistant.'}, {type:'role', role:'user', inline:false, content:'Tell me about genome editing.'}];
    updateAndRender();
    log('Notebook editor ready (server-backed).');
  })();

})();