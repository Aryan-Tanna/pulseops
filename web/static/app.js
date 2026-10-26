/* UI values are fetched from the actual app, Prometheus and Alertmanager. */
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);
const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let currentView = 'overview', toastTimer, statusBusy = false, metricsBusy = false;
async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: {'Content-Type':'application/json', ...(options.headers || {})}, signal: AbortSignal.timeout(12000) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}
function toast(message, error = false) {
  const element = $('#toast'); element.textContent = message; element.className = 'toast' + (error ? ' error' : '');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => element.classList.add('hidden'), 6000);
}
function view(name) {
  currentView = name;
  $$('.view').forEach(el => el.classList.toggle('active', el.id === `view-${name}`));
  $$('.nav').forEach(el => el.classList.toggle('active', el.dataset.view === name));
  $('#breadcrumb').textContent = ({overview:'Overview',tasks:'Task application',lab:'Demo lab',incidents:'Incident inbox',guide:'Presentation guide'})[name];
  if(name === 'tasks') refreshTasks();
  if(name === 'incidents') refreshInbox();
  window.scrollTo({top:0,behavior:'smooth'});
}
$$('[data-view]').forEach(el => el.addEventListener('click', () => view(el.dataset.view)));
$$('[data-go]').forEach(el => el.addEventListener('click', () => view(el.dataset.go)));
function version(data) {
  $$('.release-version').forEach(el => el.textContent = data.version || 'Unavailable');
  $$('.release-commit').forEach(el => el.textContent = (data.commit || '—').slice(0,12));
}
function workload(data) {
  const el = $('#workload-state'); if(!el) return;
  el.innerHTML = `<span><strong>${data.running ? '● '+escapeHTML(data.scenario.toUpperCase()) : '○ IDLE'}</strong></span><span>${data.sent} requests sent</span><span>${data.failed} HTTP / connection errors</span><span>${data.running ? data.remaining+'s remaining' : 'Workload stopped'}</span>`;
  $('#workload-progress').style.width = data.running ? `${100*(1-data.remaining/data.duration)}%` : '0%';
  $$('.scenario-start').forEach(button => button.disabled = data.running);
  $('#stop-traffic').disabled = !data.running;
}
async function refreshStatus() {
  if(statusBusy) return; statusBusy = true;
  try {
    const data = await api('/api/status');
    $('#connection-warning').classList.add('hidden');
    const names = {app:['Web application','Flask · SQLite'],prometheus:['Prometheus','Collection & rule evaluation'],grafana:['Grafana','Metrics visualization'],alertmanager:['Alertmanager','Notification delivery']};
    $('#services').innerHTML = Object.entries(names).map(([name,description]) => `<div class="service-row"><div class="service-name"><span class="live-dot" style="background:${data.services[name] ? 'var(--green)' : 'var(--red)'}"></span><div>${description[0]}<small>${description[1]}</small></div></div><span class="status-pill ${data.services[name] ? '' : 'down'}">${data.services[name] ? 'Ready' : 'Unavailable'}</span></div>`).join('');
    const healthy = Object.values(data.services).every(Boolean);
    $('#environment-health').textContent = healthy ? 'All services ready' : 'Service needs attention';
    $('#overall-dot').style.background = healthy ? 'var(--green)' : 'var(--red)';
    version(data.version); workload(data.traffic);
    const firing = data.alerts.filter(a => a.state === 'firing');
    $('#metric-alerts').textContent = data.services.prometheus ? firing.length : '—';
    $('#alert-foot').textContent = !data.services.prometheus ? 'Prometheus unavailable' : firing.length ? 'Open the incident inbox' : 'No firing alerts';
    $('#active-alerts').innerHTML = !data.services.prometheus ? '<div class="empty-state">Prometheus is unavailable. Alert state cannot be verified.</div>' : data.alerts.length ? data.alerts.map(a => `<div class="alert-row"><span>${escapeHTML(a.labels.alertname)}</span><span class="status-pill ${a.state === 'pending' ? 'pending' : 'down'}">${escapeHTML(a.state)}</span></div>`).join('') : '<div class="empty-state"><strong>No active alerts</strong>Run a demo workload to test your alert rules.</div>';
    const link = $('#actions-link');
    if(data.repository) { link.href = data.repository+'/actions'; link.target='_blank'; link.rel='noreferrer'; link.removeAttribute('aria-disabled'); }
    if(document.activeElement !== $('#repo-url')) $('#repo-url').value = data.repository;
    $('#last-updated').textContent = 'Checked '+new Date(data.checked_at).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'});
  } catch(error) { $('#connection-warning').classList.remove('hidden'); $('#last-updated').textContent = 'Connection lost · readings may be stale'; }
  finally { statusBusy = false; }
}
async function refreshMetrics() {
  if(metricsBusy) return; metricsBusy = true;
  try {
    const data = await api('/api/metrics');
    for(const key of ['rps','latency','errors']) {
      const value = data[key].value;
      $('#metric-'+key).textContent = value == null ? '—' : key === 'latency' ? Math.round(value*1000).toLocaleString() : value.toFixed(1);
    }
  } catch(error) { ['rps','latency','errors'].forEach(key => $('#metric-'+key).textContent = '—'); }
  finally { metricsBusy = false; }
}
async function refreshTasks() {
  try {
    const tasks = await api('/api/tasks'); const done = tasks.filter(task => task.done).length;
    $('#task-summary').innerHTML = `<div><strong>${tasks.length}</strong>Total tasks</div><div><strong>${tasks.length-done}</strong>In progress</div><div><strong>${done}</strong>Completed</div>`;
    $('#task-list').innerHTML = tasks.length ? tasks.map(task => `<div class="task-row"><button class="task-toggle ${task.done ? 'done' : ''}" data-task="${task.id}" data-done="${task.done}" aria-label="${task.done ? 'Mark incomplete' : 'Mark complete'}">${task.done ? '✓' : ''}</button><span class="task-title ${task.done ? 'completed' : ''}">${escapeHTML(task.title)}</span><span class="priority ${escapeHTML(task.priority)}">${escapeHTML(task.priority)}</span><button class="task-delete" data-delete="${task.id}" aria-label="Delete task">×</button></div>`).join('') : '<div class="empty-state"><strong>A clear list. A fresh start.</strong>Add your first task above.</div>';
  } catch(error) { $('#task-list').innerHTML = '<div class="empty-state"><strong>Application unavailable</strong>Restore the app to access its tasks. Your saved tasks remain in SQLite.</div>'; }
}
$('#task-form')?.addEventListener('submit', async event => {
  event.preventDefault(); const button = event.submitter; button.disabled=true;
  try { await api('/api/tasks',{method:'POST',body:JSON.stringify({title:$('#task-title').value,priority:$('#task-priority').value})}); $('#task-title').value=''; await refreshTasks(); }
  catch(error) { toast(error.message,true); } finally { button.disabled=false; }
});
$('#task-list')?.addEventListener('click', async event => {
  const toggle = event.target.closest('[data-task]'), remove = event.target.closest('[data-delete]'); if(!toggle && !remove) return;
  try { if(toggle) await api('/api/tasks/'+toggle.dataset.task,{method:'PATCH',body:JSON.stringify({done:toggle.dataset.done==='0'})}); else await api('/api/tasks/'+remove.dataset.delete,{method:'DELETE',body:'{}'}); await refreshTasks(); }
  catch(error) { toast(error.message,true); }
});
$$('.scenario-start').forEach(button => button.addEventListener('click', async () => {
  button.disabled=true;
  try { const data=await api('/api/traffic',{method:'POST',body:JSON.stringify({scenario:button.dataset.scenario,duration:Number($('#duration').value),workers:Number($('#workers').value)})}); workload(data); toast('Workload started. Open Grafana to watch the response.'); }
  catch(error) { button.disabled=false; toast(error.message,true); }
}));
$('#stop-traffic')?.addEventListener('click',async()=>{try{workload(await api('/api/traffic',{method:'DELETE',body:'{}'}));toast('Stopping traffic. In-flight requests will finish.');}catch(error){toast(error.message,true);}});
async function refreshInbox() {
  try {
    const data=await api('/api/notifications'); $('#inbox-count').textContent=data.length;
    $('#notifications').innerHTML=data.length ? data.map(item=>`<div class="notification"><div class="notification-top"><strong>${escapeHTML(item.commonLabels?.alertname || item.alerts?.[0]?.labels?.alertname || 'Alert notification')}</strong><span class="status-pill ${item.status==='firing'?'down':''}">${escapeHTML(item.status)}</span></div><p>${escapeHTML(item.commonAnnotations?.summary || item.alerts?.[0]?.annotations?.summary || 'Notification received from Alertmanager.')}</p><time>${escapeHTML(new Date(item.received_at).toLocaleString())} · webhook #${item.id}</time></div>`).join('') : '<div class="empty-state"><strong>Your inbox is quiet.</strong>Delivered alerts will appear here automatically. No sample incidents are inserted.</div>';
  } catch(error) { $('#notifications').innerHTML='<div class="empty-state">Unable to load notifications. Reconnecting…</div>'; }
}
$('#repo-form')?.addEventListener('submit',async event=>{event.preventDefault();try{await api('/api/settings',{method:'POST',body:JSON.stringify({repository:$('#repo-url').value.trim()})});toast('Repository link saved.');refreshStatus();}catch(error){toast(error.message,true);}});
$('#actions-link')?.addEventListener('click',event=>{if(event.currentTarget.getAttribute('aria-disabled')==='true'){event.preventDefault();view('guide');toast('Connect your GitHub repository first.');}});
if(window.STANDALONE) { refreshTasks(); api('/api/version').then(version).catch(()=>{}); }
else { refreshStatus(); refreshMetrics(); refreshInbox(); setInterval(refreshStatus,5000); setInterval(refreshMetrics,5000); setInterval(refreshInbox,7000); const clock=()=>$('#clock').textContent=new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});clock();setInterval(clock,30000); }
