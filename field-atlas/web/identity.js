import {escapeHTML as e} from './core.js';
import {api,syncAll} from './sync.js';
import * as db from './db.js';

export function archivePanel({panel,toast,project}) {
  let recordId=null,current=null,busy=false,generation=0;
  const download=data=>{const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='field-graph.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),5000);};
  async function show(id=recordId) {
    const ticket=++generation,pid=project().id;recordId=id;current=null;
    const records=(await db.all('records')).filter(r=>r.projectId===project().id&&r.kind==='grave'&&!r.deleted);
    if(ticket!==generation||project()?.id!==pid)return;
    panel('Связи с архивом',`<div class="stack" id="identity-panel"><p class="muted">Сопоставьте человека на плите с карточкой на сайте. Связь сохранит оба источника. Совпадения проверяете вы.</p><div class="row wrap"><label class="btn">Импорт карточек<input class="file-input" id="import-people" type="file" accept="application/json" aria-label="Импорт карточек людей"></label>${project().synthetic?'<button class="btn" data-identity="demo">Учебные люди</button>':''}<button class="btn" data-identity="export">Экспорт связей</button></div><small>Импорт JSON field-people-v1 создаёт локальную копию доступных вам карточек. Изменения на сайт ещё не отправляются.</small><label class="form-field">Захоронение<select id="identity-record"><option value="">Выберите карточку</option>${records.map(r=>`<option value="${e(r.id)}" ${r.id===id?'selected':''}>${e(r.title||r.id.slice(0,8))}</option>`).join('')}</select></label><div id="identity-results" class="stack"></div></div>`);
    const results=document.querySelector('#identity-results');
    if(!id){results.innerHTML='<div class="empty">Выберите захоронение с именем в разделе «Сведения».</div>';return;}
    const local=records.find(r=>r.id===id);
    if(!local){recordId=null;return;}
    if(local.dirty){results.innerHTML='<div class="warning">Сначала передайте последние изменения на локальный сервер для сравнения.</div><button class="btn primary" data-identity="sync">Передать изменения</button>';return;}
    results.textContent='Сравниваем сведения…';
    try {
      const result=await api('/api/identity/candidates?recordId='+encodeURIComponent(id));if(ticket!==generation||!results.isConnected)return;current=result;
      results.innerHTML=`<small>В локальной копии архива: ${current.peopleCount} карточек. Рейтинг помогает сортировать варианты и не является вероятностью совпадения.</small>`+current.groups.map(group=>`<section class="identity-group stack"><h3>${e(group.reading.name||'Имя не заполнено')}</h3><p class="muted">На плите: ${e(group.reading.birth||'Рождение неизвестно')} — ${e(group.reading.death||'Смерть неизвестна')}</p>${group.candidates.map(c=>`<article class="identity-candidate stack"><div class="row"><strong>${e(c.person.name)}</strong><span class="pill ${c.conflicts.length?'amber':'outline'}">${c.person.synthetic?'Учебные данные':e(c.person.source)}</span></div><p>${e(c.person.birth||'?')} — ${e(c.person.death||'?')} ${e(c.person.place)}</p>${c.person.url?`<a href="${e(c.person.url)}" target="_blank" rel="noopener noreferrer">Открыть карточку источника ↗</a>`:''}<ul>${c.reasons.map(r=>`<li>${e(r)}</li>`).join('')}</ul>${c.conflicts.length?`<div class="warning">${c.conflicts.map(e).join('. ')}. Сначала уточните исходные сведения.</div>`:''}${c.link?`<div class="${c.link.effectiveState==='confirmed'?'good':'warning'}">${({confirmed:'Связь подтверждена',rejected:'Совпадение отклонено',revoked:'Связь отозвана',needs_review:'Сведения изменились — нужна повторная проверка'})[c.link.effectiveState]}<p>${e(c.link.evidence)}</p></div>`:''}<label class="form-field">Основание решения<textarea id="evidence-${c.id}" placeholder="Например: сверил полное имя, обе даты и фотографию плиты">${e(c.link?.evidence||'')}</textarea></label><div class="row wrap"><button class="btn primary" data-identity="confirmed" data-candidate="${c.id}" ${c.conflicts.length||c.link?.effectiveState==='confirmed'?'disabled':''}>Подтвердить связь</button><button class="btn" data-identity="${c.link?.state==='confirmed'?'revoked':'rejected'}" data-candidate="${c.id}">${c.link?.state==='confirmed'?'Отозвать связь':'Другой человек'}</button></div></article>`).join('')||'<p class="muted">Подходящих карточек пока нет. Импортируйте данные или уточните имя. Нового человека автоматически не создаём.</p>'}${group.total>12?'<small>Показаны первые 12 вариантов. Уточните имя и даты.</small>':''}</section>`).join('')+(current.groups.length?'':'<div class="warning">В разделе «Сведения» карточки добавьте человека. Непрочитанное имя можно оставить неизвестным.</div>');
    } catch(error) {results.innerHTML=`<div class="warning">${e(error.message)}. Локальные карточки сохранены.</div>`;}
  }
  document.addEventListener('change',async event=>{
    try {
      if(event.target.id==='identity-record')await show(event.target.value);
      if(event.target.id==='import-people') {
        const file=event.target.files[0];if(!file)return;if(file.size>2*1024*1024)throw new Error('Разделите экспорт на файлы до 2 МБ');
        const owner=document.querySelector('#identity-panel');const response=await api('/api/identity/import',{method:'POST',body:await file.text()});toast(`Импортировано карточек: ${response.imported}`);if(owner?.isConnected)await show();
      }
    }catch(error){toast(error.message);}
  });
  document.addEventListener('click',async event=>{
    const button=event.target.closest('[data-identity]');if(!button||busy)return;busy=true;button.disabled=true;const owner=document.querySelector('#identity-panel');const selector=document.querySelector('#identity-record');if(selector)selector.disabled=true;
    try {
      const action=button.dataset.identity;
      if(action==='sync'){await syncAll();if(owner?.isConnected)await show();}
      else if(action==='export')download(await api('/api/identity/graph?projectId='+encodeURIComponent(project().id)));
      else if(action==='demo'){
        if(!project().synthetic)throw new Error('Учебные люди доступны только в учебном проекте');
        await api('/api/identity/import',{method:'POST',body:JSON.stringify({schema:'field-people-v1',source:'demo-archive',synthetic:true,people:[{id:'demo-person-1',name:'Иванов Пётр Иванович',birth:'1864',death:'1901',place:'Вымышленный пример'},{id:'demo-person-2',name:'Иванов Пётр Иванович',birth:'1894',death:'1955',place:'Однофамилец — вымышленный пример'}]})});if(owner?.isConnected)await show();
      } else {
        if((await db.get('records',recordId))?.dirty)throw new Error('Карточка изменена на устройстве. Сначала передайте изменения');
        const c=current?.groups.flatMap(g=>g.candidates).find(c=>c.id===button.dataset.candidate);if(!c)throw new Error('Обновите сравнение');
        await api('/api/identity/decide',{method:'POST',body:JSON.stringify({recordId,slot:c.slot,personKey:c.person.key,token:c.token,state:action,evidence:document.querySelector('#evidence-'+c.id).value})});if(owner?.isConnected)await show();toast('Решение сохранено с основанием');
      }
    }catch(error){toast(error.message);}finally{busy=false;if(selector?.isConnected)selector.disabled=false;if(button.isConnected)button.disabled=false;}
  });
  return {show};
}
