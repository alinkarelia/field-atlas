import {sha256,TYPES} from './core.js';
import {validateRoomPlan} from './room-plan-core.js';
const encoder=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true});
export const MAGIC=encoder.encode('FIELDATLASPACK1\n');
const MAX_MANIFEST=32*1024**2,MAX_ASSET=512*1024**2,MAX_PACK=2*1024**3;
const id=value=>typeof value==='string'&&/^[A-Za-z0-9_-]{1,100}$/.test(value);
export function validateBackup(m){
 if(!m||m.schema!=='field-backup-v1'||!id(m.project?.id)||!['interior','exterior','land','cemetery'].includes(m.project.type)||typeof m.project.title!=='string')throw Error('Неизвестный формат копии');
 for(const name of ['records','assets','scans','settings'])if(!Array.isArray(m[name])||m[name].length>100000)throw Error('Повреждён реестр '+name);
 for(const name of ['records','assets','scans']){const ids=new Set();for(const item of m[name]){if(!id(item.id)||ids.has(item.id)||item.projectId!==m.project.id)throw Error('Неверная принадлежность или повтор ID: '+name);ids.add(item.id);}}
 let size=0;for(const a of m.assets){if(!Number.isSafeInteger(a.size)||a.size<1||a.size>MAX_ASSET||!/^[0-9a-f]{64}$/.test(a.sha256)||typeof a.mime!=='string')throw Error('Некорректный исходный файл');size+=a.size;}
 if(size>MAX_PACK)throw Error('Копия больше 2 ГБ. Разделите проект на отдельные экспедиции.');
 const point=p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite);
 for(const r of m.records){if(r.point!=null&&!point(r.point)||r.points!=null&&(!Array.isArray(r.points)||r.points.length>50000||r.points.some(p=>!point(p)))||r.segments!=null&&(!Array.isArray(r.segments)||r.segments.some(s=>!Array.isArray(s)||s.some(p=>!point(p)))))throw Error('Повреждена геометрия карточки');}
 for(const r of m.records){if(!Object.hasOwn(TYPES,r.kind)||r.kind==='grave'&&m.project.type!=='cemetery'||!['title','comments','transcription'].every(k=>r[k]==null||typeof r[k]==='string')||!Array.isArray(r.photos||[])||!Array.isArray(r.persons||[])||(r.persons||[]).some(p=>!p||!['name','birth','death'].every(k=>p[k]==null||typeof p[k]==='string'))||(r.photos||[]).some(p=>!p||!id(p.id)))throw Error('Повреждена карточка');if(r.roomPlan&&(m.project.type!=='interior'||r.kind!=='room'||validateRoomPlan(r.roomPlan)))throw Error('Повреждён план помещения');}
 const assets=new Set(m.assets.map(a=>a.id));for(const scan of m.scans)if(!assets.has(scan.assetId))throw Error('В копии нет исходника фрагмента');
 for(const r of m.records)for(const assetId of references(r))if(!assets.has(assetId))throw Error('В копии нет исходника карточки: '+assetId);
 const settings=new Set();for(const s of m.settings){if(typeof s.id!=='string'||settings.has(s.id)||!(s.id.endsWith(':'+m.project.id)||s.value?.projectId===m.project.id))throw Error('Некорректные настройки проекта');settings.add(s.id);}
 for(const s of m.settings){if(s.id.startsWith('unfinished-track:')){const t=s.value;if(!t||!['boundary','road','path'].includes(t.kind)||Object.hasOwn(t,'segments')||!Array.isArray(t.points)||!Array.isArray(t.raw)||t.points.length!==t.raw.length||t.points.some(p=>!point(p))||t.raw.some((sample,i)=>!sample||!point(sample.point)||JSON.stringify(sample.point)!==JSON.stringify(t.points[i])))throw Error('Повреждён незавершённый обход');}if(s.id.startsWith('origin:')&&(!s.value||!Number.isFinite(s.value.lat)||Math.abs(s.value.lat)>90||!Number.isFinite(s.value.lon)||Math.abs(s.value.lon)>180))throw Error('Повреждено начало координат');}
 return size;
}
export function references(record){
 return [...new Set([...(record.photos||[]).map(p=>p.id),...(record.roomPlan?.rooms||[]).flatMap(r=>[r.ceilingSourceId,...(r.ceilingSourceHistory||[])]),...['roomPlanSourceId','roomPlanAssetId','roomPlanStructureId','roomPlanModelId','ceilingSourceId'].map(k=>record[k])].filter(Boolean))];
}
export async function encodeBackup(manifest,assets,progress=()=>{}){
 validateBackup(manifest);const content=encoder.encode(JSON.stringify(manifest));if(content.length>MAX_MANIFEST)throw Error('Реестр слишком велик');
 const digest=await sha256(new Blob([content])),header=new Uint8Array(MAGIC.length+4+32);header.set(MAGIC);new DataView(header.buffer).setUint32(MAGIC.length,content.length,true);header.set(digest.match(/../g).map(b=>parseInt(b,16)),MAGIC.length+4);
 const pieces=[header,content];for(const [i,a] of manifest.assets.entries()){const blob=assets.get(a.id);if(!blob||blob.size!==a.size||await sha256(blob)!==a.sha256)throw Error('Исходник повреждён: '+a.id);pieces.push(blob);progress(i+1,manifest.assets.length);}
 return new Blob(pieces,{type:'application/octet-stream'});
}
export async function inspectBackup(blob,verify=false,progress=()=>{}){
 if(blob.size>MAX_PACK+MAX_MANIFEST)throw Error('Копия слишком велика');const header=new Uint8Array(await blob.slice(0,MAGIC.length+4+32).arrayBuffer());
 if(header.length!==MAGIC.length+4+32||MAGIC.some((v,i)=>header[i]!==v))throw Error('Это не файл .atlaspack');
 const length=new DataView(header.buffer).getUint32(MAGIC.length,true);if(length>MAX_MANIFEST||length<2)throw Error('Повреждён размер реестра');
 const hash=Array.from(header.slice(MAGIC.length+4),v=>v.toString(16).padStart(2,'0')).join(''),raw=blob.slice(header.length,header.length+length);
 if(await sha256(raw)!==hash)throw Error('Контрольная сумма реестра не совпала');const manifest=JSON.parse(decoder.decode(await raw.arrayBuffer()));let offset=header.length+length;
 const size=validateBackup(manifest);if(offset+size!==blob.size)throw Error('Копия обрезана или содержит посторонние данные');const assets=new Map();
 for(const [i,a] of manifest.assets.entries()){const file=blob.slice(offset,offset+a.size,a.mime);offset+=a.size;if(verify&&await sha256(file)!==a.sha256)throw Error('Контрольная сумма исходника не совпала: '+a.id);assets.set(a.id,file);progress(i+1,manifest.assets.length);}
 return {manifest,assets,sha256:hash};
}
