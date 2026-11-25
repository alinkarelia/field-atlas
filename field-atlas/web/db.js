const NAME='field-atlas-v1';
let opening;
export function openDB(){
  return opening ||= new Promise((resolve,reject)=>{
    const req=indexedDB.open(NAME,1);
    req.onupgradeneeded=()=>{for(const name of ['records','outbox','assets','settings','scans'])req.result.createObjectStore(name,{keyPath:'id'});};
    req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);
  });
}
async function transaction(stores,mode,fn){
  const db=await openDB();return new Promise((resolve,reject)=>{
    const tx=db.transaction(stores,mode);let value;
    tx.oncomplete=()=>resolve(value);tx.onerror=event=>reject(tx.error||event.target.error||new Error('Запись прервана'));tx.onabort=()=>reject(tx.error||new Error('Запись прервана'));
    try{value=fn(tx);}catch(e){tx.abort();reject(e);}
  });
}
export async function all(name){const db=await openDB();return new Promise((resolve,reject)=>{const r=db.transaction(name).objectStore(name).getAll();r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
export async function get(name,id){const db=await openDB();return new Promise((resolve,reject)=>{const r=db.transaction(name).objectStore(name).get(id);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
export const put=(name,value)=>transaction([name],'readwrite',tx=>tx.objectStore(name).put(value));
export const remove=(name,id)=>transaction([name],'readwrite',tx=>tx.objectStore(name).delete(id));
export async function saveRecord(record){
  const database=await openDB();return new Promise((resolve,reject)=>{
    const tx=database.transaction(['records','outbox'],'readwrite');let saved;
    const read=tx.objectStore('records').get(record.id);
    read.onsuccess=()=>{const existing=read.result;const content=r=>JSON.stringify(Object.fromEntries(Object.keys(r).sort().filter(k=>!['dirty','localRevision','serverVersion'].includes(k)).map(k=>[k,r[k]])));if(existing&&content(existing)===content(record)){saved=existing;return;}saved={...record,localRevision:(existing?.localRevision||0)+1,serverVersion:existing?.serverVersion||0,dirty:true};
      const mutation={id:crypto.randomUUID(),record:structuredClone(saved),baseVersion:saved.serverVersion,localRevision:saved.localRevision,createdAt:Date.now(),state:'pending'};
      tx.objectStore('records').put(saved);tx.objectStore('outbox').put(mutation);
    };
    tx.oncomplete=()=>resolve(saved);tx.onerror=event=>reject(tx.error||event.target.error||new Error('Сохранение прервано'));tx.onabort=()=>reject(tx.error||new Error('Сохранение прервано'));
  });
}
export async function acknowledge(mutation,serverVersion){
  await transaction(['records','outbox'],'readwrite',tx=>{
    const read=tx.objectStore('records').get(mutation.record.id);
    read.onsuccess=()=>{const current=read.result;tx.objectStore('outbox').delete(mutation.id);
      if(current)tx.objectStore('records').put({...current,serverVersion,dirty:current.localRevision!==mutation.localRevision});
    };
  });
}
export async function saveBundle(records,setting){
  const database=await openDB();return new Promise((resolve,reject)=>{
    const tx=database.transaction(['records','outbox','settings'],'readwrite');
    for(const record of records){const read=tx.objectStore('records').get(record.id);read.onsuccess=()=>{const old=read.result;const saved={...record,localRevision:(old?.localRevision||0)+1,serverVersion:old?.serverVersion||0,dirty:true};tx.objectStore('records').put(saved);tx.objectStore('outbox').put({id:crypto.randomUUID(),record:saved,baseVersion:saved.serverVersion,localRevision:saved.localRevision,createdAt:Date.now(),state:'pending'});};}
    tx.objectStore('settings').put(setting);tx.oncomplete=()=>resolve();tx.onerror=event=>reject(tx.error||event.target.error||new Error('План не сохранён'));tx.onabort=()=>reject(tx.error||new Error('План не сохранён. Предыдущие карточки не изменены.'));
  });
}
export async function projectSnapshot(projectId){
 const database=await openDB();return new Promise((resolve,reject)=>{const names=['records','outbox','assets','settings','scans'],tx=database.transaction(names),snapshot={};
  for(const name of names){const req=tx.objectStore(name).getAll();req.onsuccess=()=>{snapshot[name]=req.result.filter(r=>name==='settings'?(!['model-cache:','assembly:','assembly-job:'].some(prefix=>r.id.startsWith(prefix))&&(r.id.endsWith(':'+projectId)||r.value?.projectId===projectId)):name==='outbox'?r.record.projectId===projectId:r.projectId===projectId);};}
  tx.oncomplete=()=>resolve(snapshot);tx.onerror=e=>reject(tx.error||e.target.error);
 });
}
export async function restoreBackup(manifest,assets){
 const database=await openDB();return new Promise((resolve,reject)=>{const tx=database.transaction(['records','assets','scans','settings','outbox'],'readwrite');
  tx.objectStore('settings').add({id:'project:'+manifest.project.id,value:manifest.project});
  for(const r of manifest.records){const record={...r,serverVersion:0,localRevision:1,dirty:true};tx.objectStore('records').add(record);tx.objectStore('outbox').add({id:crypto.randomUUID(),record,baseVersion:0,localRevision:1,createdAt:Date.now(),state:'pending'});}
  for(const a of manifest.assets)tx.objectStore('assets').add({...a,blob:assets.get(a.id),uploaded:false});
  for(const s of manifest.scans)tx.objectStore('scans').add(s);
  for(const s of manifest.settings)if(!['project:','assembly:','assembly-job:','model-cache:','restored:'].some(prefix=>s.id.startsWith(prefix)))tx.objectStore('settings').add(s);
  tx.objectStore('settings').add({id:'restored:'+manifest.project.id,value:{createdAt:Date.now(),backupCreatedAt:manifest.createdAt,source:'field-backup-v1',priorOutbox:manifest.pendingCount||0}});
  tx.oncomplete=resolve;tx.onerror=e=>reject(tx.error||e.target.error);tx.onabort=()=>reject(tx.error||new Error('Восстановление прервано. Прежние проекты не изменены.'));
 });
}
export async function resolveConflict({local,server,record,mode,reason}){
 const database=await openDB();return new Promise((resolve,reject)=>{const tx=database.transaction(['records','outbox','settings'],'readwrite'),read=tx.objectStore('records').get(local.id),queued=tx.objectStore('outbox').getAll();let current,mutations,failure;
  function apply(){if(!current||!mutations)return;try{
   if(current.localRevision!==local.localRevision)throw Error('Карточка изменилась во время сверки. Откройте конфликт заново.');
   if(server&&server.projectId!==local.projectId)throw Error('Разные проекты');if(mode==='server'&&!server)throw Error('Серверная карточка отсутствует');
   tx.objectStore('settings').add({id:'conflict-history:'+crypto.randomUUID(),value:{projectId:local.projectId,recordId:local.id,createdAt:Date.now(),local:current,server,mutations:mutations.filter(m=>m.record.id===local.id),mode,reason}});
   for(const m of mutations)if(m.record.id===local.id)tx.objectStore('outbox').delete(m.id);
   const enqueue=r=>{tx.objectStore('records').put(r);tx.objectStore('outbox').add({id:crypto.randomUUID(),record:r,baseVersion:r.serverVersion,localRevision:r.localRevision,createdAt:Date.now(),state:'pending'});};
   if(mode==='server'||mode==='copy'){if(server)tx.objectStore('records').put({...server,localRevision:current.localRevision+1,dirty:false});
    if(mode==='copy'){const copy={...current,id:crypto.randomUUID(),title:(current.title||'Объект')+' — локальная копия',copyOf:current.id,serverVersion:0,localRevision:1,dirty:true};enqueue(copy);if(!server)enqueue({...current,serverVersion:0,localRevision:current.localRevision+1,dirty:true});}}
   else enqueue({...record,id:local.id,projectId:local.projectId,serverVersion:server?.serverVersion||0,localRevision:current.localRevision+1,dirty:true});
  }catch(error){failure=error;tx.abort();}}
  read.onsuccess=()=>{current=read.result;if(!current){failure=Error('Карточка удалена');tx.abort();return;}apply();};queued.onsuccess=()=>{mutations=queued.result;apply();};
  tx.oncomplete=resolve;tx.onerror=e=>reject(failure||tx.error||e.target.error);tx.onabort=()=>reject(failure||tx.error||Error('Решение не сохранено'));
 });
}
