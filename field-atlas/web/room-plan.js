import {validateCeiling,ceilingStats,ceilingForm,ceilingSVG} from './ceiling.js';
import {escapeHTML as e} from './core.js';
import * as db from './db.js';
import {storeAsset} from './sync.js';
import {validateRoomPlan,exampleRoomPlan,floorPlanSVG,wallElevationSVG,wallLength,metres,roomArea,roomLabels,combineFloor,drawingWithCaption} from './room-plan-core.js';

export function roomPlanPanel({panel,toast,project}){
 let editingRoom=false;
 let doc=null,roomId=null,selected=null,mode='plan',example=false;
 function currentRoom(){return doc.rooms.find(r=>r.id===roomId)||doc.rooms[0];}
 async function saveRoomPatch(context,patch){
  if(editingRoom)throw Error('Дождитесь сохранения комнаты');editingRoom=true;
  try{const {pid,id,frameId,snapshot,example:isExample,owner}=context;let next=structuredClone(snapshot);
   if(!isExample){const all=(await db.all('records')).filter(r=>r.projectId===pid&&r.roomPlan?.frameId===frameId),records=all.filter(r=>r.roomPlan.rooms.some(room=>room.id===id));if(!records.length)throw Error('Карточка комнаты не найдена');
    next.rooms=[...new Map(all.flatMap(r=>r.roomPlan.rooms).map(room=>[room.id,room])).values()];
    const patchRoom=room=>room.id===id?{...room,...patch,...(patch.ceilingSourceId?{ceilingSourceHistory:[...new Set([...(room.ceilingSourceHistory||[]),room.ceilingSourceId].filter(Boolean))]}:{})}:room;
    next.rooms=next.rooms.map(patchRoom);await db.saveBundle(records.map(r=>({...r,roomPlan:{...r.roomPlan,rooms:r.roomPlan.rooms.map(patchRoom)}})),{id:'room-plan:'+pid,value:next});
   }else next.rooms=next.rooms.map(room=>room.id===id?{...room,...patch}:room);
   if(owner?.isConnected&&project()?.id===pid){doc=next;render();toast(isExample?'Изменён учебный пример; в проект не записан':'Изменение комнаты сохранено');}
  }finally{editingRoom=false;}
 }
 function editContext(){return {pid:project().id,id:roomId,frameId:doc.frameId,snapshot:structuredClone(doc),example,owner:document.querySelector('.room-plan-panel')};}
 async function saveCeiling(value,context){if(value.roomId&&value.roomId!==context.id)throw Error('Замер относится к другой комнате');const error=validateCeiling(value);if(error)throw Error(error);const stats=ceilingStats(value),source=value.method==='manual-height'?value.source:value.method==='plane-proposal'?'ARKit: предложенный контур, проверен человеком':'AR: углы выбраны вручную';let asset;
  if(!context.example)asset=await storeAsset(context.pid,new Blob([JSON.stringify({...value,roomId:context.id})],{type:'application/json'}),'application/json');
  await saveRoomPatch(context,{ceiling:value,ceilingSource:source,ceilingHeight:stats.max-stats.min<=.05?stats.mean:null,...(asset?{ceilingSourceId:asset.id}:{})});
 }
 function draw(){
  const room=currentRoom(),floor=mode==='floor'?combineFloor(doc.rooms,room.level||0):room;
  const surface=floor.walls.find(w=>w.id===selected)||floor.openings.find(o=>o.id===selected)||floor.walls[0];
  const wall=surface.wallId?floor.walls.find(w=>w.id===surface.wallId):surface;selected=surface.id;
  const host=document.querySelector('#room-drawing');if(!host)return;
  host.innerHTML=mode==='elevation'?wallElevationSVG(room,wall):floorPlanSVG(floor,selected,mode!=='floor');
  const title=surface.wallId?`${roomLabels[surface.kind]} ${surface.code||''}`:`${wall.code||'Стена'}`;
  const info=[['Элемент',title],...(surface.wallId?[['Стена',wall.code||wall.id],['Ширина проёма',metres(surface.width)],['Высота проёма',metres(surface.height)],['Низ проёма от основания стены',metres(surface.sill)]]:[['Длина стены',metres(wallLength(wall))],[wall.profile?'Габаритная высота стены':'Высота стены',metres(wall.height)],['Качество распознавания',wall.confidence===2?'Высокое':wall.confidence===1?'Среднее · проверить':'Низкое · проверить']])];
  document.querySelector('#room-detail').innerHTML=info.map(([k,v])=>`<div class="review-row"><span>${e(k)}</span><strong>${e(v)}</strong></div>`).join('')+(wall.curved?'<div class="warning">Криволинейная поверхность. Пунктир показывает её хорду; уточняйте форму по исходной 3D-модели.</div>':'');
  document.querySelectorAll('[data-plan-surface]').forEach(button=>{button.classList.toggle('selected',button.dataset.planSurface===selected);button.setAttribute('aria-pressed',button.dataset.planSurface===selected?'true':'false');});
 }
 function render(){
  const room=currentRoom(),area=roomArea(room);
  panel('План помещения',`<div class="stack room-plan-panel"><div class="row wrap"><span class="pill ${example?'amber':'outline'}">${example?'Учебный пример · не измерения':doc.synthetic?'Учебные данные':'Импорт съёмки'}</span><label class="btn file-button">Импорт плана<input id="import-room-plan" class="file-input" type="file" accept="application/json,.json" aria-label="Импорт плана помещения"></label></div><label class="form-field">Комната<select id="room-choice">${doc.rooms.map(r=>`<option value="${e(r.id)}" ${r.id===room.id?'selected':''}>${e(r.name)} · уровень ${r.level||0}</option>`).join('')}</select></label><div class="segmented" aria-label="Вид плана">${[['plan','План комнаты'],['elevation','Стена и высоты'],['floor','Этаж']].map(([key,label])=>`<button data-plan-mode="${key}" aria-pressed="${mode===key}">${label}</button>`).join('')}</div><div id="room-drawing"></div><div class="plan-legend"><span>С — стена</span><span>О — окно</span><span>Д — дверь</span><span>П — проход</span></div><p class="muted">Нажмите на линию или выберите элемент ниже. Размерные линии относятся к подписанной стене; ширина и высота проёмов показаны отдельно.</p><div class="surface-list" aria-label="Элементы комнаты">${room.walls.map((w,i)=>`<button class="btn small" data-plan-surface="${e(w.id)}">${e(w.code||'С'+(i+1))} · ${metres(wallLength(w))}</button>`).join('')}${room.openings.map(o=>`<button class="btn small" data-plan-surface="${e(o.id)}">${e(o.code||roomLabels[o.kind])} · ${metres(o.width)}</button>`).join('')}</div><section id="room-detail" aria-live="polite"></section><div class="floor-editor"><label class="form-field">Этаж / уровень<input id="room-level" type="number" step="1" min="-20" max="200" value="${room.level??0}"></label><button class="btn" data-room-level-save>Сохранить этаж</button></div><p class="muted">Можно указать 0 или отрицательный уровень. Номер этажа меняет группировку комнат, исходные измерения сохраняются.</p><div class="review-row"><span>Площадь пола</span><strong>${area==null?'Контур не подтверждён':area.toLocaleString('ru',{maximumFractionDigits:2})+' м²'}</strong></div><div class="warning">${room.ceiling?`Отдельный замер потолка сохранён. Подробности — в разделе ниже.`:room.ceilingHeight?`Высота потолка: ${metres(room.ceilingHeight)}. Источник: ${e(room.ceilingSource||'требует проверки')}.`:'Отдельный замер потолка отсутствует. Высота стены не подменяет измерение потолка.'}</div>${ceilingForm(room)}${(room.notes||[]).map(note=>`<div class="warning">${e(note)}</div>`).join('')}${example?'<p class="muted">На iPhone режим RoomPlan определяет стены, двери, окна и открытые проходы. Здесь проверяется интерфейс на вымышленных размерах; пример не сохраняется в проект.</p>':''}</div>`,`<button class="btn" data-action="close">К карте</button><button class="btn primary" data-room-export>Скачать чертёж SVG</button>`);
  document.querySelector('#panel').classList.add('room-dialog');draw();
 }
 async function show(explicit){
  if(project()?.type!=='interior')return;
  const pid=project().id,owner=document.querySelector('#panel');
  const saved=explicit||(await db.get('settings','room-plan:'+pid))?.value;
  const records=(await db.all('records')).filter(r=>r.projectId===pid&&r.roomPlan&&!r.deleted);
  const last=saved||records.sort((a,b)=>(a.createdAt||0)-(b.createdAt||0)).at(-1)?.roomPlan;
  const related=last?records.filter(r=>r.roomPlan.frameId===last.frameId).flatMap(r=>r.roomPlan.rooms):[];
  const grouped=last?{...last,rooms:[...new Map([...(last.rooms||[]),...related].map(r=>[r.id,r])).values()]}:null;
  doc=grouped&&!validateRoomPlan(grouped)?grouped:exampleRoomPlan();example=!grouped||!!validateRoomPlan(grouped);
  if(project()?.id!==pid||owner&&!owner.isConnected)return;roomId=explicit?.rooms?.[0]?.id||doc.rooms[0].id;selected=currentRoom().walls[0].id;mode='plan';render();

 }
 document.addEventListener('change',async event=>{
  if(event.target.id==='import-ceiling'){const file=event.target.files[0],context=editContext();if(!file)return;try{if(file.size>200000)throw Error('Замер больше 200 КБ');const value=JSON.parse(await file.text());if(value.synthetic&&!context.snapshot.synthetic)throw Error('Учебный замер нельзя записать как реальный');await saveCeiling(value,context);}catch(error){toast('Замер не сохранён: '+error.message);}return;}
  if(event.target.id==='room-choice'){roomId=event.target.value;selected=currentRoom().walls[0].id;render();return;}
  if(event.target.id!=='import-room-plan')return;const file=event.target.files[0],pid=project().id,owner=document.querySelector('.room-plan-panel');if(!file)return;
  try{if(file.size>2*1024**2)throw new Error('Разделите план на файлы до 2 МБ');const incoming=JSON.parse(await file.text());const problem=validateRoomPlan(incoming);if(problem)throw new Error(problem);if(incoming.synthetic&&!project().synthetic)throw new Error('Учебные измерения нельзя сохранить как съёмку реального помещения. Для знакомства уже открыт отдельный пример.');
   if(incoming.rooms.some(room=>new TextEncoder().encode(JSON.stringify({...incoming,rooms:[room]})).length>190000))throw new Error('Комната слишком велика для карточки. Сохраните её отдельным фрагментом.');
   const asset=await storeAsset(pid,file,'application/json');
   const records=incoming.rooms.map((room,index)=>({id:'room-'+asset.sha256.slice(0,24)+'-'+index,projectId:pid,kind:'room',title:room.name,roomPlan:{...incoming,rooms:[room]},roomPlanSourceId:asset.id,photos:[],persons:[],status:'draft',point:null,comments:'',transcription:'',createdAt:Date.now()}));
   await db.saveBundle(records,{id:'room-plan:'+pid,value:incoming});if(owner?.isConnected&&project()?.id===pid){doc=incoming;example=false;roomId=doc.rooms[0].id;selected=doc.rooms[0].walls[0].id;render();toast('План и исходный файл сохранены');}
  }catch(error){toast('План не импортирован: '+error.message);}
 });
 document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-plan-mode],[data-plan-surface],[data-surface],[data-room-export],[data-room-level-save],[data-ceiling-save],[data-ceiling-export]');if(!target)return;
  if(target.hasAttribute('data-ceiling-export')){const svg=ceilingSVG(currentRoom().ceiling);if(!svg)return;const url=URL.createObjectURL(new Blob([drawingWithCaption(svg,(example||doc.synthetic?'Учебный пример — не измерения · ':'')+'Потолок · высоты от выбранной точки пола')],{type:'image/svg+xml'})),a=document.createElement('a');a.href=url;a.download='Контур-потолка.svg';a.click();setTimeout(()=>URL.revokeObjectURL(url),5000);return;}
  if(target.hasAttribute('data-ceiling-save')){const height=document.querySelector('#ceiling-height'),source=document.querySelector('#ceiling-source');if(!height.checkValidity()||!height.value){height.reportValidity();toast('Укажите высоту');return;}target.disabled=true;try{await saveCeiling({schema:'field-ceiling-v1',method:'manual-height',manualHeight:Number(height.value),source:source.value.trim(),reviewed:true,createdAt:Date.now()},editContext());}catch(error){toast(error.message);}finally{target.disabled=false;}return;}
  if(target.hasAttribute('data-room-level-save')){
   const input=document.querySelector('#room-level'),value=Number(input.value),pid=project().id,owner=document.querySelector('.room-plan-panel');
   if(input.value===''||!input.checkValidity()||!Number.isInteger(value)){input.reportValidity();toast('Укажите целый этаж от −20 до 200');return;}
   target.disabled=true;try{await saveRoomPatch(editContext(),{level:value});}catch(error){toast('Этаж не сохранён: '+error.message);}finally{target.disabled=false;}return;
  }

  if(target.dataset.planMode){const next=target.dataset.planMode;
   if(mode==='floor'&&next!=='floor'){for(const r of doc.rooms){const s=[...r.walls,...r.openings].find(s=>r.id+'::'+s.id===selected);if(s){roomId=r.id;selected=s.id;break;}}}
   else if(next==='floor'&&mode!=='floor')selected=currentRoom().id+'::'+selected;
   mode=next;render();}
  else if(target.hasAttribute('data-room-export')){const room=currentRoom();const svg=mode==='elevation'?document.querySelector('#room-drawing').innerHTML:floorPlanSVG(mode==='floor'?combineFloor(doc.rooms,room.level||0):room,selected,mode!=='floor');const url=URL.createObjectURL(new Blob([drawingWithCaption(svg,example||doc.synthetic?'Учебный пример — не результаты измерений':'План съёмки · размеры в метрах · '+(mode==='floor'?'этаж':room.name))],{type:'image/svg+xml'})),a=document.createElement('a');a.href=url;a.download=(example?'Учебный-план':'План-помещения')+'.svg';a.click();setTimeout(()=>URL.revokeObjectURL(url),5000);}
  else{selected=target.dataset.planSurface||target.dataset.surface;if(target.dataset.planSurface&&mode==='floor'){mode='plan';render();}else draw();}
 });
 document.addEventListener('keydown',event=>{if(['Enter',' '].includes(event.key)&&event.target.matches('[data-surface]')){event.preventDefault();event.target.dispatchEvent(new MouseEvent('click',{bubbles:true}));}});
 return {show};
}
