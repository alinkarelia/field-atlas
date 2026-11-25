import {screenButton,setupScreen} from './screen.js';
import {PROJECTS,TYPES,uid,escapeHTML as e,Track,area,length,coverage,localPoint,missingSteps,validateScan} from './core.js';
import * as db from './db.js';
import {api,syncAll,storeAsset,uploadAsset} from './sync.js';
import {icon} from './icons.js';
import {mapSVG,mapPoint,scanSVG} from './map.js';
import {graveBody,STEP_NAMES} from './forms.js';
import {demoRecords,demoChunk} from './fixtures.js';
import {archivePanel} from './identity.js';
import {showModel} from './model-view.js';
import {MapNavigation} from './map-navigation.js';
import {roomPlanPanel} from './room-plan.js';
import {backupPanel} from './backup.js';
import {conflictPanel} from './conflicts.js';

const root=document.querySelector('#app');
setupScreen({panel,toast});
let projects=[],project=null,records=[],cells=[],scans=[],track=null,draft=null,step=0,picking=false,marker=null,zoom=1,location=null,origin=null,gpsWatch=null;
let saveChain=Promise.resolve(),syncBusy=false,photoURLs={},replayTimer=null,replayChunk=null,replayPoints=[],replayIndex=0,scanVisible=false,toastTimer;
const ui={};
let scanGeneration=0,scanImportRequest=0;
const photoRequests=new Map();
const backups=backupPanel({panel,toast,project:()=>project,reload});
const conflicts=conflictPanel({panel,toast,refresh:queuePanel});
const mapNav=new MapNavigation();
const roomPlanner=roomPlanPanel({panel,toast,project:()=>project});
const archive=archivePanel({panel,toast,project:()=>project});
async function persistTrack(){if(track&&project)await db.put('settings',{id:'unfinished-track:'+project.id,value:structuredClone(track)});}
function toast(message){const notice=document.querySelector('#panel[open] .dialog-notice');if(notice){notice.hidden=false;notice.textContent=message;return;}const el=document.querySelector('#toast');el.textContent=message;el.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.classList.remove('show'),4200);}
function header(){return `<header class="app-header"><div class="brand"><div class="brand-symbol">${icon('map')}</div><div><strong>Полевой атлас</strong><small>Съёмка · карта · наблюдения</small></div></div><div class="header-right">${screenButton()}<span class="pill outline">Песочница</span><button class="btn square ghost" data-action="backup" aria-label="Копия и восстановление">${icon('download')}</button><button class="btn square ghost" data-action="queue" aria-label="Очередь передачи">${icon('cloud')}</button></div></header>`;}
async function reload(){
  projects=(await db.all('settings')).filter(s=>s.id.startsWith('project:')).map(s=>s.value);const pid=project?.id;
  if(pid){const [allRecords,allScans,assembly]=await Promise.all([db.all('records'),db.all('scans'),db.get('settings','assembly:'+pid)]);if(project?.id!==pid)return;
    records=allRecords.filter(r=>r.projectId===pid&&!r.deleted);scans=allScans.filter(r=>r.projectId===pid);
    cells=project.synthetic?(assembly?.value?.referenceFrame==='synthetic-frame-0'?assembly.value.coverage:coverage(scans.filter(s=>s.chunk.frameId==='synthetic-frame-0').flatMap(s=>s.chunk.points))):[];
  }render();
}
function render(){
  if(scanVisible)return;
  if(!project){root.innerHTML=header()+`<main class="home"><div class="intro"><div><div class="eyebrow">Ваши полевые исследования</div><h1>Каждое место.<br>В своей системе.</h1><p>Выберите, что исследуете. Карточки и инструменты подстроятся под задачу, а съёмки останутся в своём проекте.</p></div><button class="btn" data-action="demo">${icon('play')}Учебный участок</button></div><section class="project-types" aria-label="Создать проект">${Object.entries(PROJECTS).map(([key,p])=>`<button class="project-type" data-new-project="${key}">${icon(key)}<div><strong>${p.label}</strong><p>${p.description}</p></div></button>`).join('')}</section><div class="section-title"><h2>Мои проекты</h2><span class="pill outline">${projects.length}</span></div><section class="project-list">${projects.length?projects.map(p=>`<button class="project-row" data-project="${e(p.id)}">${icon(p.type)}<div class="content"><strong>${e(p.title)}</strong><small>${PROJECTS[p.type].label}${p.synthetic?' · учебные данные':''}</small></div>${icon('chevron')}</button>`).join(''):'<div class="empty">Создайте первый проект выше. Материалы сохраняются на устройстве и доступны без сети.</div>'}</section><div class="sandbox-note">${icon('info')}<p>Локальная песочница для проверки работы приложения. Настоящий захват LiDAR выполняется в нативной версии iOS; здесь доступны импорт и воспроизведение учебных измерений.</p></div></main>`;return;}
  const cfg=PROJECTS[project.type],objects=records.filter(r=>['grave','object','room','facade'].includes(r.kind));
  root.innerHTML=header()+`<main class="workspace">${mapSVG(records,cells,track,location,zoom)}<div class="map-heading"><button class="btn square ghost" data-action="projects" aria-label="К проектам">${icon('back')}</button><div><h1>${e(project.title)}</h1><small>${cfg.label}${project.synthetic?' · учебные данные':''}</small></div></div><div class="map-tools"><button class="btn square" data-action="locate" aria-label="Моё положение">${icon('target')}</button><button class="btn square" data-action="zoom" aria-label="Приблизить">${icon('plus')}</button><button class="btn square" data-action="zoom-out" aria-label="Отдалить">${icon('minus')}</button><button class="btn square" data-action="fit-map" aria-label="Показать весь участок">${icon('fit')}</button><button class="btn square" data-action="export" aria-label="Экспорт проекта">${icon('download')}</button></div>${!records.length&&!track?`<div class="map-empty">${icon(project.type)}<h2>${picking?'Укажите место на плане':marker?'Укажите место метки':'Начните с первого объекта'}</h2><p>${picking||marker?'Коснитесь нужного места.':'Добавьте объект или запишите границу. Здесь появится ваш план.'}</p></div>`:''}<div class="map-info"><span class="pill outline">${objects.length} ${project.type==='cemetery'?'захоронений':'объектов'}</span><span class="pill outline">${scans.length} фрагм.</span>${picking||marker?'<button class="btn small" data-action="cancel-pick">Отменить выбор места</button>':''}${ui.pendingTrack&&!track?'<button class="btn small" data-action="track-resume">Продолжить обход</button>':''}${track?.gap?'<span class="pill amber">Разрыв обхода — требуется проверка</span>':''}</div><div class="map-scale">Местный план · м</div>${track?trackUI():''}<nav class="dock" aria-label="Полевые инструменты"><button data-action="new-object">${icon('plus')}<span>${cfg.object}</span></button><button data-action="tools">${icon('path')}<span>Карта</span></button><button data-action="scan">${icon('scan')}<span>Снять</span></button><button data-action="objects">${icon('list')}<span>Объекты</span></button></nav></main>`;mapNav.mount();
}
function trackUI(){return `<section class="track-card"><div class="row"><strong>${TYPES[track.kind]}</strong><span class="pill ${track.paused?'amber':''}">${track.paused?'Пауза':'Запись'}</span></div><p>Идите с GPS или добавляйте точки касанием плана. ${track.points.length} точек · ${track.segments.reduce((sum,points)=>sum+length(points),0).toFixed(1)} м</p><div class="track-actions"><button class="btn small" data-action="track-pause">${icon(track.paused?'play':'pause')}${track.paused?'Продолжить':'Пауза'}</button><button class="btn small" data-action="track-undo">${icon('undo')}Отмена точки</button><button class="btn primary small" data-action="track-finish">Готово</button><button class="btn small ghost danger" data-action="track-cancel">Закрыть</button></div></section>`;}
async function dismissPanel(){
  const owner=document.querySelector('#panel'),returnFocus=ui.returnFocus,form=owner?.querySelector('#wizard,#ocr-status,.photo-preview');
  if(form){await saveCurrentDraft();draft=null;}
  // Keep the modal open while the map refreshes. Otherwise native close() restores
  // focus to an old button that reload() removes before the explicit restoration.
  await reload();
  if(owner!==document.querySelector('#panel'))return;
  closePanel();if(returnFocus)document.querySelector(returnFocus)?.focus();
}
function validWizard(){for(const field of document.querySelectorAll('#wizard input, #wizard textarea')){if(!field.checkValidity()){field.reportValidity();toast('Проверьте выделенное поле');return false;}}return true;}
function closePanel(){document.querySelector('#panel')?.close();document.querySelector('#panel')?.remove();}
function panel(title,body,footer='',subtitle=''){
  const active=document.activeElement;if(!document.querySelector('#panel')&&active?.dataset?.action)ui.returnFocus='[data-action="'+active.dataset.action+'"]';closePanel();const el=document.createElement('dialog');el.id='panel';el.setAttribute('aria-labelledby','panel-title');el.innerHTML=`<div class="dialog-head"><div>${subtitle?`<small>${e(subtitle)}</small>`:''}<h2 id="panel-title" tabindex="-1">${title}</h2></div><button class="btn square ghost" data-action="close" aria-label="Закрыть">${icon('close')}</button></div><div class="dialog-notice warning" role="status" aria-live="polite" hidden></div><div class="dialog-body">${body}</div>${footer?`<div class="dialog-footer">${footer}</div>`:''}`;document.body.append(el);el.showModal();el.querySelector('#panel-title').focus();el.addEventListener('cancel',event=>{event.preventDefault();el.querySelector('[data-action=close]')?.click();});
}
function newProject(type){ui.projectType=type;panel('Новый проект',`<div class="stack"><span class="pill">${PROJECTS[type].label}</span><label class="form-field">Название<input id="project-name" autocomplete="off" maxlength="160" placeholder="Например, дом на Лесной"></label><p class="muted">Снимки, карточки и результаты сборки будут храниться отдельно от других проектов.</p><div id="project-error"></div></div>`,`<button class="btn ghost" data-action="close">Отмена</button><button class="btn primary" data-action="create-project">Создать</button>`);document.querySelector('#project-name').focus();}
async function createProject(){const title=document.querySelector('#project-name').value.trim();if(!title){document.querySelector('#project-error').innerHTML='<p class="error">Введите название проекта.</p>';return;}const created={id:uid(),type:ui.projectType,title,createdAt:Date.now(),synthetic:false};await db.put('settings',{id:'project:'+created.id,value:created});await openProject(created.id);closePanel();}
async function openProject(id){await saveCurrentDraft();draft=null;stopGPS();project=(await db.get('settings','project:'+id)).value;const saved=(await db.get('settings','unfinished-track:'+id))?.value;track=saved?Object.assign(new Track(saved.kind),saved,{paused:true,breakPending:true}):null;ui.pendingTrack=!!saved;mapNav.camera={x:0,y:0,zoom:1};picking=false;marker=null;location=null;origin=(await db.get('settings','origin:'+id))?.value||null;await db.put('settings',{id:'active',value:id});await reload();mapNav.fit(records);}
async function demo(){const p={id:'demo-cemetery',type:'cemetery',title:'Учебное кладбище',synthetic:true,createdAt:0};if(!await db.get('settings','project:'+p.id)){await db.put('settings',{id:'project:'+p.id,value:p});for(const r of demoRecords(p.id))await db.saveRecord(r);}await openProject(p.id);toast('Открыты вымышленные данные для проверки');}
function toolsPanel(){const cfg=PROJECTS[project.type];panel('Инструменты карты',`${project.type==='interior'?'<button class="btn primary room-plan-entry" data-action="room-plan">План помещения и размеры</button>':''}<div class="tool-grid">${cfg.tools.map(t=>`<button class="btn" data-tool="${t}">${icon(t)}${TYPES[t]}</button>`).join('')}</div>`);}
async function beginObject(id,kind){
  await saveCurrentDraft();
  if(id){const item=await db.get('records',id);if(['boundary','road','path'].includes(item.kind))return geometryPanel(item);if(item.roomPlan)return roomPlanner.show(item.roomPlan);}
  draft=id?structuredClone(await db.get('records',id)):{id:uid(),projectId:project.id,kind:kind||PROJECTS[project.type].kind,title:'',point:location?location.slice():null,photos:[],persons:[],transcription:'',comments:'',status:'draft',measureMethod:'none',createdAt:Date.now()};
  if(!draft.photos)draft.photos=[];if(!draft.persons)draft.persons=[];step=0;await saveCurrentDraft();await showWizard();
}
async function showWizard(){
  for(const url of Object.values(photoURLs))URL.revokeObjectURL(url);photoURLs={};
  for(const photo of draft.photos){const asset=await db.get('assets',photo.id);photoURLs[photo.id]=asset?URL.createObjectURL(asset.blob):'/api/assets/'+photo.id;}
  panel(STEP_NAMES[step],`<div id="wizard">${graveBody(draft,step,project,photoURLs)}</div><div class="stepper" aria-label="Шаг ${step+1} из 5">${STEP_NAMES.map((_,i)=>`<span class="${i<=step?'done':''}"></span>`).join('')}</div>`,`<button class="btn ghost" data-action="${step?'wizard-back':'close'}">${step?'Назад':'Свернуть'}</button><button class="btn primary" data-action="${step===4?'wizard-finish':'wizard-next'}">${step===4?'Сохранить':'Далее'}</button>${step===4?'<button class="btn" data-action="wizard-another">Сохранить и следующее</button>':''}`,`${TYPES[draft.kind]} · Шаг ${step+1} из 5`);
}
function geometryPanel(r){draft=null;panel(TYPES[r.kind],`<div class="stack"><strong>${e(r.title||TYPES[r.kind])}</strong><p>${r.points?.length||0} точек · ${r.kind==='boundary'?area(r.points||[]).toFixed(2)+' м²':(r.segments||[r.points||[]]).reduce((sum,p)=>sum+length(p),0).toFixed(1)+' м'}</p>${r.needsReview?'<div class="warning">Есть разрывы или неточные координаты — требуется проверка.</div>':''}<button class="btn" data-focus-geometry="${e(r.id)}">Показать на карте</button><p class="muted">Геометрия сохранена вместе с исходными точками обхода.</p></div>`);}
function readDraftInput(target){
  if(!draft||!target.name)return;const key=target.name,value=target.type==='checkbox'?target.checked:target.value;
  if(key.startsWith('person-')){const [,idx,field]=key.split('-');draft.persons[Number(idx)][field]=value;}
  else if(key==='pointX'||key==='pointY'){const x=document.querySelector('[name=pointX]')?.value,y=document.querySelector('[name=pointY]')?.value;draft.point=x!==''&&y!==''&&Number.isFinite(+x)&&Number.isFinite(+y)?[+x,+y]:null;}
  else if(key.startsWith('measure')&&key!=='measureMethod')draft[key]=value===''?null:Number(value);
  else draft[key]=value;
}
function saveCurrentDraft(){if(!draft)return saveChain;const snapshot=structuredClone(draft);saveChain=saveChain.catch(()=>{}).then(()=>db.saveRecord(snapshot));saveChain.catch(err=>toast('Не удалось сохранить: '+err.message));return saveChain;}
async function addPhoto(file,role){
  if(!file)return;if(file.size>20*1024*1024){toast('Файл больше 20 МБ. Выберите отдельный снимок.');return;}
  if(!['image/jpeg','image/png','image/heic'].includes(file.type)){toast('Выберите JPEG, PNG или HEIC.');return;}
  const recordId=draft.id,projectId=draft.projectId,key=recordId+':'+role,request=(photoRequests.get(key)||0)+1;photoRequests.set(key,request);const asset=await storeAsset(projectId,file,file.type);if(photoRequests.get(key)!==request)return;const current=draft?.id===recordId?draft:await db.get('records',recordId);if(!current)throw new Error('Карточка фотографии не найдена');current.photos=(current.photos||[]).filter(p=>p.role!==role);current.photos.push({id:asset.id,role,sha256:asset.sha256,name:file.name});if(draft?.id===recordId){await saveCurrentDraft();if(step===1&&document.querySelector('#wizard'))await showWizard();}else await db.saveRecord(current);toast('Оригинал сохранён в исходной карточке');
}
async function finishWizard(another=false){if(!validWizard())return;const nextKind=draft.kind;draft.status=draft.kind==='grave'&&missingSteps(draft).length?'draft':'complete';await saveCurrentDraft();const status=draft.status;draft=null;closePanel();await reload();toast(status==='draft'?'Черновик сохранён — можно дополнить позже':'Карточка сохранена');if(another)await beginObject(undefined,nextKind);}
async function objectsPanel(){await reload();const items=records;panel('Объекты проекта',`<label class="form-field">Поиск<input id="object-search" type="search" placeholder="Название или текст надписи"></label><div id="object-list">${items.map(r=>`<button class="object-row" data-open-object="${e(r.id)}" data-search="${e((r.title+' '+TYPES[r.kind]+' '+(r.transcription||'')+' '+(r.persons||[]).map(p=>[p.name,p.birth,p.death].join(' ')).join(' ')).toLowerCase().replaceAll('ё','е'))}">${icon(r.kind==='grave'?'cemetery':r.kind)}<div class="content"><strong>${e(r.title||TYPES[r.kind])}</strong><small>${r.status==='complete'?'Собрано':r.kind==='grave'?'Черновик':TYPES[r.kind]}${r.dirty?' · на устройстве':''}</small></div>${icon('chevron')}</button>`).join('')}<p id="object-empty" class="list-empty" ${items.length?'hidden':''}>${items.length?'Ничего не найдено. Измените запрос.':'Пока нет объектов. Добавьте первый на карте.'}</p></div>`,project.type==='cemetery'?'<button class="btn primary" data-action="archive">Связи с архивом</button>':'');}
async function locate(){
  if(!navigator.geolocation){toast('Геолокация недоступна');return;}
  const capturedProject=project.id;navigator.geolocation.getCurrentPosition(async pos=>{
    if(project?.id!==capturedProject)return;
    if(!origin){origin={lat:pos.coords.latitude,lon:pos.coords.longitude};await db.put('settings',{id:'origin:'+project.id,value:origin});}
    if(project?.id!==capturedProject)return;location=localPoint(pos.coords.latitude,pos.coords.longitude,origin);render();mapNav.center(location);toast(`GPS: погрешность около ${Math.round(pos.coords.accuracy)} м`);
  },err=>toast(err.code===1?'Разрешите геолокацию или укажите место на карте.':'Не удалось получить координаты.'),{enableHighAccuracy:true,timeout:15000,maximumAge:0});
}
function startGPS(){
  if(gpsWatch!==null||!navigator.geolocation)return;
  const capturedProject=project.id;gpsWatch=navigator.geolocation.watchPosition(async pos=>{
    if(project?.id!==capturedProject||!track||track.paused)return;
    if(!origin){origin={lat:pos.coords.latitude,lon:pos.coords.longitude};await db.put('settings',{id:'origin:'+project.id,value:origin});}
    if(project?.id!==capturedProject||!track||track.paused)return;location=localPoint(pos.coords.latitude,pos.coords.longitude,origin);const result=track.add(location,{accuracy:pos.coords.accuracy,time:pos.timestamp});if(result.reason==='jump')toast('Скачок координат отклонён. Проверьте линию.');await persistTrack();render();
  },()=>toast('GPS недоступен. Можно наносить точки вручную.'),{enableHighAccuracy:true,maximumAge:0,timeout:20000});
}
function stopGPS(){if(gpsWatch!==null)navigator.geolocation.clearWatch(gpsWatch);gpsWatch=null;}
async function finishTrack(){const error=track.validate();if(error){toast(error);return;}if(track.gap){panel('Проверьте разрыв',`<p>При записи была пауза или потеря точных координат. Геометрия не будет сохранена как проверенная. Можно вернуться и исправить точки или сохранить с отметкой о проверке.</p>`,`<button class="btn" data-action="close">Вернуться</button><button class="btn primary" data-action="track-confirm">Сохранить с отметкой</button>`);return;}await commitTrack();}
async function commitTrack(){const r={id:uid(),projectId:project.id,kind:track.kind,points:track.points,segments:track.segments,raw:track.raw,origin,title:TYPES[track.kind],needsReview:track.gap,createdAt:Date.now(),area:track.kind==='boundary'?area(track.points):null};await db.saveRecord(r);await db.remove('settings','unfinished-track:'+project.id);ui.pendingTrack=false;track=null;stopGPS();closePanel();await reload();toast('Геометрия сохранена');}
async function queuePanel(){
  const outbox=await db.all('outbox'),assets=await db.all('assets');
  panel('Передача и сборка',`<div class="stack"><p class="muted">Карточки и исходники хранятся локально. Повторная отправка продолжится с принятой части.</p><div class="row"><span>Изменения карточек</span><strong>${outbox.length}</strong></div><div class="row"><span>Файлы ожидают передачи</span><strong>${assets.filter(a=>!a.uploaded).length}</strong></div><button class="btn small" data-action="conflict-history">История сверок</button><div id="sync-status" class="good">${navigator.onLine?'Устройство в сети':'Нет сети — очередь сохранена'}</div>${outbox.filter(m=>m.state==='conflict').map(m=>`<div class="error">Конфликт: ${e(m.record.title||m.record.id)}. Обе версии сохранены.<button class="btn small" data-conflict="${m.id}">Сравнить и выбрать сведения</button></div>`).join('')}${project?`<div class="hr"></div><h3>Общая модель проекта</h3><p class="muted">Собрать принятые фрагменты по общей системе координат или проверяемым ориентирам.</p><button class="btn" data-action="assemble">${icon('layers')}Собрать фрагменты</button><button class="btn" data-action="model">Открыть 3D-модель</button><div id="assembly-status" role="status"></div><button class="btn small" data-action="cancel-assembly" hidden>Остановить сборку</button>`:''}</div>`,`<button class="btn ghost" data-action="close">Закрыть</button><button class="btn primary" data-action="sync" ${syncBusy?'disabled':''}>${icon('cloud')}Передать</button>`);
  if(project){const job=(await db.get('settings','assembly-job:'+project.id))?.value;if(job)watchAssembly(job.id,project.id).catch(error=>toast(error.message));}
}
async function synchronize(){if(syncBusy)return;const owner=document.querySelector('#panel');syncBusy=true;document.querySelector('[data-action=sync]')?.setAttribute('disabled','');try{await syncAll(message=>{const el=document.querySelector('#sync-status');if(el)el.textContent=message;});await reload();toast('Передача завершена');if(owner?.isConnected)await queuePanel();}catch(err){const el=document.querySelector('#sync-status');if(el){el.className='warning';el.textContent='Передача приостановлена: '+err.message+'. Очередь сохранена.';}else toast('Передача приостановлена. Данные сохранены.');}finally{syncBusy=false;document.querySelector('[data-action=sync]')?.removeAttribute('disabled');}}
async function watchAssembly(id,pid){
 const el=document.querySelector('#assembly-status'),cancel=document.querySelector('[data-action=cancel-assembly]');if(!el)return;el.dataset.job=id;
 while(el.isConnected&&project?.id===pid){
  const job=await api('/api/jobs/'+id);if(!el.isConnected||el.dataset.job!==id)return;
  el.textContent=(job.message||'Сборка')+(job.state==='running'?' · '+Math.round(job.progress*100)+'%':'');if(cancel){cancel.hidden=!['queued','running','cancelling'].includes(job.state);cancel.dataset.job=id;}
  if(job.state==='succeeded'){const result=(await api('/api/assemblies?projectId='+encodeURIComponent(pid))).assemblies.find(a=>a.id===job.assemblyId);if(!result)throw Error('Индекс готовой сборки недоступен');await db.put('settings',{id:'assembly:'+pid,value:result});if(el.isConnected){el.className=result.pending.length?'warning':'good';el.textContent=`Совмещено: ${result.registered.length}. Требуют проверки: ${result.pending.length}. ${result.pending.map(p=>p.reason).join('; ')}`;}await reload();return;}
  if(['failed','cancelled'].includes(job.state)){el.className='warning';el.textContent=job.error||job.message;return;}
  await new Promise(resolve=>setTimeout(resolve,350));
 }
}
async function assembleScans(){const pid=project.id,el=document.querySelector('#assembly-status');try{const ids=scans.map(s=>s.assetId);if(!ids.length)throw Error('Сначала сохраните фрагменты съёмки.');el.textContent='Запускаем сборку на сервере…';const job=await api('/api/assembly-jobs',{method:'POST',body:JSON.stringify({projectId:pid,chunks:ids})});await db.put('settings',{id:'assembly-job:'+pid,value:{id:job.id}});if(el.isConnected&&project?.id===pid)await watchAssembly(job.id,pid);}catch(error){if(el.isConnected){el.className='error';el.textContent=error.message;}}}

function scanPanel(){
  scanVisible=true;scanGeneration++;closePanel();document.querySelector('#toast').classList.remove('show');replayPoints=[];replayChunk=null;ui.replayOffset=0;
  root.innerHTML=`<section class="scan-shell"><div class="scan-main"><div id="scan-render"></div><div class="scan-caption"><span class="pill amber">Песочница · ${project.synthetic?'учебные измерения':'импорт измерений'}</span><p>Загрузите фрагмент или запустите учебную съёмку. Настоящий LiDAR работает в приложении iOS. Исходники сохраняются на устройстве.</p></div></div><header class="scan-top"><div><small>${e(project.title)}</small><div class="scan-status"><h2>${project.synthetic?'Учебная съёмка':'Просмотр скана'}</h2><strong id="scan-count" class="number">0 точек</strong></div></div><div class="scan-buttons">${screenButton()}<button class="btn square ghost" data-action="scan-close" aria-label="Вернуться к карте">${icon('close')}</button></div></header><footer class="scan-bottom"><div class="legend" aria-label="Качество покрытия"><span class="green"><i></i>Измерено</span><span class="amber"><i></i>Уточнить</span><span><i></i>Не снято</span></div><div class="scan-actions">${project.synthetic?`<button class="btn" data-action="replay">${icon('play')}Начать пример</button>`:''}<label class="btn square file-button" title="Импорт скана JSON">${icon('layers')}<span class="button-caption">Файл</span><input class="file-input" type="file" accept="application/json,.json" id="import-scan" aria-label="Импорт скана JSON"></label><button class="btn" data-action="scan-save" disabled>${icon('check')}Сохранить</button></div></footer></section>`;

}
function updateScan(){
  if(!scanVisible)return;document.querySelector('#scan-render').innerHTML=scanSVG(replayPoints,replayChunk?.source==='synthetic');document.querySelector('#scan-count').textContent=`${replayPoints.length} точек`;
  document.querySelector('[data-action=scan-save]').disabled=!replayPoints.length;document.querySelector('#import-scan').disabled=!!replayPoints.length;
  const button=document.querySelector('[data-action=replay]');if(button){const finished=replayChunk&&ui.replayOffset>=replayChunk.points.length;button.disabled=!!finished;button.innerHTML=icon(replayTimer?'pause':'play')+(finished?'Фрагмент готов':replayTimer?'Пауза':replayPoints.length?'Продолжить':'Начать пример');}
  document.querySelector('.scan-caption').hidden=!!replayPoints.length;
}
function replay(){
  if(!project.synthetic)return;
  if(replayTimer){clearInterval(replayTimer);replayTimer=null;updateScan();return;}
  if(!replayChunk){replayChunk=demoChunk(replayIndex%2);replayChunk.id=uid();replayPoints=[];ui.replayOffset=0;}
  replayTimer=setInterval(()=>{replayPoints.push(...replayChunk.points.slice(ui.replayOffset,ui.replayOffset+100));ui.replayOffset+=100;if(ui.replayOffset>=replayChunk.points.length){clearInterval(replayTimer);replayTimer=null;}updateScan();},90);updateScan();
}
async function saveScan(){if(!replayChunk||!replayPoints.length)return;clearInterval(replayTimer);replayTimer=null;const chunk={...replayChunk,points:replayPoints};const blob=new Blob([JSON.stringify(chunk)],{type:'application/json'});const asset=await storeAsset(project.id,blob,'application/json');await db.put('scans',{id:chunk.id,projectId:project.id,assetId:asset.id,chunk,createdAt:Date.now()});replayIndex++;scanVisible=false;await reload();toast('Фрагмент и покрытие сохранены');}
async function importScan(file){
  if(!file)return;const pid=project.id,session=scanGeneration,request=++scanImportRequest;
  const current=()=>scanVisible&&project?.id===pid&&session===scanGeneration&&request===scanImportRequest;
  try{
    if(file.size>40*1024**2)throw new Error('Файл больше 40 МБ. Разделите съёмку на фрагменты.');
    if(replayPoints.length)throw new Error('Сначала сохраните текущий фрагмент.');
    const c=JSON.parse(await file.text());if(!current())return;
    if(replayPoints.length)throw new Error('Съёмка уже началась. Сохраните текущий фрагмент перед импортом.');
    const error=validateScan(c);if(error)throw new Error(error);
    if(c.source==='synthetic'&&!project.synthetic)throw new Error('Учебный скан можно открыть только в учебном проекте.');
    clearInterval(replayTimer);replayTimer=null;replayChunk={...c,id:uid()};replayPoints=c.points;ui.replayOffset=c.points.length;updateScan();
  }catch(error){if(current())toast('Скан не импортирован: '+(error instanceof SyntaxError?'некорректный JSON':error.message));}
}
async function exportProject(){const bundle={schema:'field-project-v1',project,records,origin,coverage:cells,scans:scans.map(s=>({id:s.id,assetId:s.assetId,frameId:s.chunk.frameId})),note:'Фото и исходники сканов хранятся отдельно; это экспорт реестра.'};const url=URL.createObjectURL(new Blob([JSON.stringify(bundle,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='field-atlas-'+project.id+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Скачан реестр; исходные файлы остаются на устройстве');}
async function runOCR(){const photo=draft.photos.find(p=>p.role==='inscription');if(!photo){toast('Сначала добавьте фотографию плиты.');return;}await saveCurrentDraft();const capturedDraft=draft.id;panel('Помощник чтения x0','<div id="ocr-status" class="stack"><p>Подготовка фотографии…</p></div>','<button class="btn" data-action="return-wizard">К карточке</button>');try{await api('/api/projects',{method:'POST',body:JSON.stringify(project)});const asset=await db.get('assets',photo.id);if(asset&&!asset.uploaded)await uploadAsset(asset);const key='ocr:'+capturedDraft+':'+photo.id;const saved=(await db.get('settings',key))?.value;let previous=null;if(saved){try{previous=await api('/api/jobs/'+saved.id);}catch(err){if(err.status!==404)throw err;}}const id=previous&&!['failed','blocked'].includes(previous.state)?previous.id:(saved&&!previous?saved.id:uid());await db.put('settings',{id:key,value:{id,assetId:photo.id,recordId:capturedDraft}});const result=previous&&previous.id===id?previous:await api('/api/ocr',{method:'POST',body:JSON.stringify({id,assetId:photo.id,projectId:project.id,recordId:capturedDraft})});ui.ocrJob=result.id;await pollOCR(result.id,capturedDraft);}catch(err){const el=document.querySelector('#ocr-status');if(el)el.innerHTML=`<div class="warning">${e(err.message)}</div><p class="muted">Фотография и карточка сохранены. Можно продолжить обход и вернуться к чтению позже.</p>`;}}
async function pollOCR(id,recordId){const job=await api('/api/jobs/'+id);const el=document.querySelector('#ocr-status');if(!el||ui.ocrJob!==id||draft?.id!==recordId)return;if(job.state==='succeeded'){ui.reading=job;el.innerHTML=`<div class="pill amber">Машинное чтение · требуется проверка</div><div class="reading-text">${e(job.result.text)}</div><button class="btn primary" data-action="accept-reading">Вставить как предложенный текст</button>`;}else if(['failed','blocked'].includes(job.state)){el.innerHTML=`<div class="warning">${e(job.error)}</div>`;}else{el.textContent='x0 читает фотографию. Карточка сохранена.';setTimeout(()=>pollOCR(id,recordId).catch(()=>{}),2000);}}

document.addEventListener('input',event=>{const t=event.target;if(t.closest('#wizard')){readDraftInput(t);saveCurrentDraft();}if(t.id==='object-search'){const query=t.value.trim().toLowerCase().replaceAll('ё','е');let visible=0;document.querySelectorAll('[data-search]').forEach(el=>{el.hidden=!el.dataset.search.includes(query);if(!el.hidden)visible++;});const empty=document.querySelector('#object-empty');if(empty)empty.hidden=visible>0;}});
document.addEventListener('change',event=>{const t=event.target;if(t.dataset.photo)addPhoto(t.files[0],t.dataset.photo).catch(err=>toast(err.message));if(t.id==='import-scan')importScan(t.files[0]);});
document.addEventListener('keydown',event=>{if(['Enter',' '].includes(event.key)&&event.target.matches('[data-record]')){event.preventDefault();event.target.dispatchEvent(new MouseEvent('click',{bubbles:true}));}if(event.key==='Escape'&&!document.querySelector('#panel')&&(picking||marker)){document.querySelector('[data-action=cancel-pick]')?.click();}});
let clickQueue=Promise.resolve();const backgroundActions=new Set();
document.addEventListener('click',event=>{
  if(event.target.closest('#map')&&mapNav.ignoreClick)return;
  const target=event.target.closest('[data-action],[data-conflict]'),action=target?.dataset.action||(target?.dataset.conflict?'conflict':undefined),pid=project?.id;
  if(!document.querySelector('#panel')&&target?.dataset.action)ui.returnFocus='[data-action="'+target.dataset.action+'"]';
  const report=err=>toast(err?.message||'Операция не выполнена.');
  if(['sync','assemble','model','ocr','conflict'].includes(action)){
    const key=[action,pid,draft?.id].join(':');if(backgroundActions.has(key))return;backgroundActions.add(key);target.disabled=true;
    handleClick(event).catch(report).finally(()=>{backgroundActions.delete(key);target.disabled=false;});return;
  }
  if(target?.tagName==='BUTTON')target.disabled=true;
  clickQueue=clickQueue.catch(()=>{}).then(async()=>{try{if(event.target.isConnected&&project?.id===pid)await handleClick(event);}finally{if(target?.tagName==='BUTTON')target.disabled=false;}});
  clickQueue.catch(report);
});
async function handleClick(event){
  const target=event.target.closest('button,[data-record]');
  if(event.detail>0&&!track&&!picking&&!marker&&event.target.closest('#map')){
    const svg=document.querySelector('#map'),matrix=svg.getScreenCTM();let nearest=null,best=24;
    if(matrix)for(const record of records){if(!record.point)continue;const p=svg.createSVGPoint();p.x=record.point[0];p.y=-record.point[1];const screen=p.matrixTransform(matrix),distance=Math.hypot(screen.x-event.clientX,screen.y-event.clientY);if(distance<best){best=distance;nearest=record;}}
    if(nearest)return beginObject(nearest.id);
  }
  if(target?.dataset.removePhoto){const photo=draft.photos.find(p=>p.id===target.dataset.removePhoto);if(photo){const key=draft.id+':'+photo.role;photoRequests.set(key,(photoRequests.get(key)||0)+1);}draft.photos=draft.photos.filter(p=>p.id!==target.dataset.removePhoto);await saveCurrentDraft();return showWizard();}
  if(target?.dataset.removePerson!==undefined){draft.persons.splice(Number(target.dataset.removePerson),1);await saveCurrentDraft();return showWizard();}
  if(target?.dataset.viewPhoto){const photo=draft.photos.find(p=>p.id===target.dataset.viewPhoto);const url=photoURLs[photo.id];panel('Оригинал фотографии',`<div class="photo-preview stack">${photo.name?.toLowerCase().endsWith('.heic')?'<p>Оригинал HEIC сохранён. Для просмотра скачайте его или откройте на совместимом устройстве.</p>':`<img src="${url}" alt="Фотография из карточки">`}<a class="btn" href="${url}" download="${e(photo.name||'photo')}">Скачать оригинал</a></div>`,'<button class="btn" data-action="return-wizard">К карточке</button>');return;}
  if(target?.dataset.newProject)return newProject(target.dataset.newProject);
  if(target?.dataset.project)return openProject(target.dataset.project);
  if(target?.dataset.openObject)return beginObject(target.dataset.openObject);
  if(target?.dataset.focusGeometry){const r=records.find(r=>r.id===target.dataset.focusGeometry);closePanel();mapNav.fit([r]);return;}
  if(target?.dataset.record&&!track&&!picking&&!marker)return beginObject(target.dataset.record);
  if(target?.dataset.tool){const kind=target.dataset.tool;closePanel();if(['boundary','road','path'].includes(kind)){if(track){toast('Продолжите или завершите сохранённый трек');render();return;}const saved=(await db.get('settings','unfinished-track:'+project.id))?.value;track=saved?Object.assign(new Track(saved.kind),saved,{paused:true,breakPending:true}):new Track(kind);ui.pendingTrack=false;await persistTrack();if(!track.paused)startGPS();}else if(['room','object','facade'].includes(kind)){await beginObject(undefined,kind);}else marker=kind;render();return;}
  if(target?.dataset.conflict)return conflicts.show(target.dataset.conflict);
  const action=target?.dataset.action;
  if(action==='close')return dismissPanel();
  if(action==='create-project')return createProject();if(action==='demo')return demo();
  if(action==='projects'){await saveCurrentDraft();draft=null;await persistTrack();track=null;stopGPS();project=null;render();return;}
  if(action==='conflict-history')return conflicts.history(project?.id);if(action==='backup'){await saveCurrentDraft();return backups.show();}if(action==='archive'){await saveCurrentDraft();return archive.show(null);}if(action==='room-plan')return roomPlanner.show();if(action==='new-object')return beginObject();if(action==='tools')return toolsPanel();if(action==='objects')return objectsPanel();
  if(action==='wizard-next'||action==='wizard-back'){if(action==='wizard-next'&&!validWizard())return;await saveCurrentDraft();step=Math.max(0,Math.min(4,step+(action==='wizard-next'?1:-1)));return showWizard();}
  if(action==='wizard-finish')return finishWizard();if(action==='wizard-another')return finishWizard(true);if(action==='add-person'){draft.persons.push({id:uid(),name:'',birth:'',death:''});await saveCurrentDraft();return showWizard();}
  if(action==='pick-point'){await saveCurrentDraft();picking=true;closePanel();render();toast('Укажите место объекта на плане');return;}
  if(action==='locate')return locate();if(action==='zoom'){mapNav.zoom(1.5);return;}if(action==='zoom-out'){mapNav.zoom(1/1.5);return;}if(action==='fit-map'){mapNav.fit(records);return;}if(action==='cancel-pick'){marker=null;if(picking){picking=false;render();return showWizard();}render();return;}
  if(action==='track-pause'){track.pause();await persistTrack();if(!track.paused)startGPS();render();return;}
  if(action==='track-undo'){track.undo();await persistTrack();render();return;}if(action==='track-finish')return finishTrack();if(action==='track-confirm')return commitTrack();
  if(action==='track-cancel'){track.paused=true;await persistTrack();ui.pendingTrack=true;track=null;stopGPS();render();toast('Обход сохранён. Продолжите его кнопкой на карте.');return;}if(action==='track-resume'){const saved=(await db.get('settings','unfinished-track:'+project.id))?.value;if(saved){track=Object.assign(new Track(saved.kind),saved,{paused:true,breakPending:true});ui.pendingTrack=false;render();}return;}
  if(action==='cancel-assembly'){const id=target.dataset.job;if(id)await api('/api/assembly-jobs/'+id+'/cancel',{method:'POST',body:'{}'});return;}if(action==='model'){const saved=(await db.get('settings','assembly:'+project.id))?.value;if(!saved){toast('Сначала соберите переданные фрагменты');return;}return showModel(saved,{panel});}if(action==='queue')return queuePanel();if(action==='sync')return synchronize();if(action==='assemble')return assembleScans();if(action==='scan')return scanPanel();
  if(action==='scan-close'){clearInterval(replayTimer);replayTimer=null;if(replayPoints.length&&replayChunk)await saveScan();else{scanVisible=false;await reload();}return;}
  if(action==='replay')return replay();if(action==='scan-save')return saveScan();if(action==='export')return exportProject();
  if(action==='ocr')return runOCR();if(action==='return-wizard')return showWizard();if(action==='accept-reading'){if(!draft||ui.reading.recordId!==draft.id||!draft.photos.some(p=>p.role==='inscription'&&p.id===ui.reading.assetId&&p.sha256===ui.reading.result.originalSourceHash)){toast('Результат относится к другой карточке или фотографии');return;}draft.machineReadings=[...(draft.machineReadings||[]),ui.reading.result];draft.transcription=ui.reading.result.text;draft.unreadable=true;await saveCurrentDraft();return showWizard();}
  if(event.target.closest('#map')&&(!target||target.dataset.record&&(track||picking||marker))){const p=mapPoint(document.querySelector('#map'),event);if(track){track.add(p,{manual:true});await persistTrack();render();}else if(picking){draft.point=p;picking=false;await saveCurrentDraft();render();await showWizard();}else if(marker){await db.saveRecord({id:uid(),projectId:project.id,kind:marker,title:TYPES[marker],point:p,photos:[],comments:'',createdAt:Date.now()});marker=null;await reload();toast('Метка сохранена');}}
}
window.addEventListener('online',()=>toast('Связь восстановлена. Очередь готова к передаче.'));
window.addEventListener('offline',()=>toast('Работаем без сети. Данные сохраняются на устройстве.'));
await db.openDB();await reload();
if('serviceWorker'in navigator)navigator.serviceWorker.register('/sw.js').catch(()=>{});
