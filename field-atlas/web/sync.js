import * as db from './db.js';
import {sha256} from './core.js';
export async function api(path,options={}){
  const response=await fetch(path,{...options,headers:{...(options.body instanceof Blob?{}:{'Content-Type':'application/json'}),...options.headers}});
  const result=await response.json();if(!response.ok){const error=new Error(result.error||'Ошибка сервера');error.status=response.status;error.detail=result;throw error;}return result;
}
export async function uploadAsset(asset,progress=()=>{}){
  const hash=asset.sha256||await sha256(asset.blob);
  let state=await api('/api/uploads',{method:'POST',body:JSON.stringify({id:asset.id,projectId:asset.projectId,sha256:hash,size:asset.blob.size,mime:asset.mime||asset.blob.type||'application/octet-stream'})});
  while(state.offset<state.size){
    const part=asset.blob.slice(state.offset,Math.min(state.size,state.offset+1024*1024));
    state=await api(`/api/uploads/${asset.id}`,{method:'PATCH',headers:{'Upload-Offset':String(state.offset)},body:part});progress(state.offset/state.size);
  }
  state=await api(`/api/uploads/${asset.id}/complete`,{method:'POST',body:'{}'});
  await db.put('assets',{...asset,sha256:hash,uploaded:!!state.complete});return state;
}
let syncing=false;
export async function syncAll(update=()=>{}){
  if(syncing)return;syncing=true;
  try{
    const settings=await db.all('settings');
    for(const s of settings.filter(s=>s.id.startsWith('project:')))await api('/api/projects',{method:'POST',body:JSON.stringify(s.value)});
    const mutations=(await db.all('outbox')).sort((a,b)=>a.createdAt-b.createdAt);
    const blocked=new Set();
    for(const m of mutations){
      if(blocked.has(m.record.id)||m.state==='conflict'){blocked.add(m.record.id);continue;}
      if(m.attemptBase===undefined){m.attemptBase=(await db.get('records',m.record.id))?.serverVersion||0;await db.put('outbox',m);}
      try{
        const res=await api('/api/records',{method:'POST',body:JSON.stringify({record:m.record,mutationId:m.id,baseVersion:m.attemptBase})});
        await db.acknowledge(m,res.version);update('Карточки сохранены');
      }catch(e){if(e.status!==409)throw e;await db.put('outbox',{...m,state:'conflict',server:e.detail});blocked.add(m.record.id);update('Есть конфликт карточки');}
    }
    for(const a of (await db.all('assets')).filter(a=>!a.uploaded))await uploadAsset(a,p=>update(`Передача файла: ${Math.round(p*100)}%`));
    for(const s of settings.filter(s=>s.id.startsWith('project:'))){
      const result=await api('/api/records?projectId='+encodeURIComponent(s.value.id));
      for(const record of result.records){const local=await db.get('records',record.id);if(!local?.dirty)await db.put('records',{...record,dirty:false,localRevision:local?.localRevision||0});}
    }
    update('Синхронизация завершена');
  }finally{syncing=false;}
}
export async function storeAsset(projectId,blob,mime){
  const asset={id:crypto.randomUUID(),projectId,blob,mime:mime||blob.type,sha256:await sha256(blob),uploaded:false,createdAt:Date.now()};await db.put('assets',asset);return asset;
}
