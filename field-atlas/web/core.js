export const TYPES = {boundary:'Граница',road:'Дорога',path:'Тропинка',grave:'Захоронение',tree:'Дерево',dump:'Свалка',obstacle:'Препятствие',anomaly:'Углубление',entrance:'Вход',object:'Объект',room:'Помещение',facade:'Фасад'};
export const PROJECTS = {
  interior:{label:'Внутри помещения',description:'Квартира или дом. Комнаты, проёмы, предметы.',object:'Помещение',kind:'room',tools:['room','object','obstacle']},
  exterior:{label:'Здание снаружи',description:'Фасады, входы и детали здания.',object:'Объект',kind:'facade',tools:['facade','entrance','object','obstacle']},
  land:{label:'Участок',description:'Границы, дорожки, деревья и постройки.',object:'Объект',kind:'object',tools:['boundary','road','path','tree','object','dump','obstacle']},
  cemetery:{label:'Кладбище',description:'Захоронения, надписи и обследование территории.',object:'Захоронение',kind:'grave',tools:['boundary','road','path','tree','dump','obstacle','anomaly','entrance']}
};
export const uid = () => crypto.randomUUID();
export function validateScan(c){
  if(!c||c.schema!=='field-scan-v1'||typeof c.frameId!=='string'||!c.frameId.length||c.frameId.length>100)return 'Не указан формат или система координат скана.';
  if(!['normal','limited'].includes(c.tracking))return 'Не указано качество отслеживания.';
  if(!Array.isArray(c.points)||!c.points.length||c.points.length>250000||c.points.some(p=>!Array.isArray(p)||p.length!==4||!p.every(Number.isFinite)||p.slice(0,3).some(v=>Math.abs(v)>100000)||![0,1,2].includes(p[3])))return 'В скане некорректные точки или качество измерений.';
  if(c.anchors!==undefined&&(!c.anchors||Array.isArray(c.anchors)||typeof c.anchors!=='object'||Object.keys(c.anchors).length>1000||Object.values(c.anchors).some(p=>!Array.isArray(p)||p.length!==3||!p.every(v=>Number.isFinite(v)&&Math.abs(v)<100000))))return 'В скане некорректные ориентиры.';
  return null;
}
export const finitePoint = p => Array.isArray(p) && p.length >= 2 && p.every(Number.isFinite);
export const distance = (a,b) => Math.hypot(a[0]-b[0],a[1]-b[1]);
export function area(points) {
  if(points.length<3) return 0;
  return Math.abs(points.reduce((s,p,i)=>{const q=points[(i+1)%points.length];return s+p[0]*q[1]-q[0]*p[1];},0))/2;
}
export function length(points){return points.slice(1).reduce((s,p,i)=>s+distance(points[i],p),0);}
const orientation=(a,b,c)=>(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);
function intersects(a,b,c,d){
  const o=[orientation(a,b,c),orientation(a,b,d),orientation(c,d,a),orientation(c,d,b)];
  const between=(p,q,r)=>r[0]>=Math.min(p[0],q[0])-1e-8&&r[0]<=Math.max(p[0],q[0])+1e-8&&r[1]>=Math.min(p[1],q[1])-1e-8&&r[1]<=Math.max(p[1],q[1])+1e-8;
  return (o[0]*o[1]<0&&o[2]*o[3]<0)||o.some((v,i)=>Math.abs(v)<1e-8&&[()=>between(a,b,c),()=>between(a,b,d),()=>between(c,d,a),()=>between(c,d,b)][i]());
}
export function validatePolygon(points){
  if(points.length<3||points.some(p=>!finitePoint(p))) return 'Нужны хотя бы три корректные точки.';
  for(let i=0;i<points.length;i++){
    if(distance(points[i],points[(i+1)%points.length])<0.05) return 'Соседние точки совпадают.';
    for(let j=i+1;j<points.length;j++){
      if(j===i+1||(i===0&&j===points.length-1)) continue;
      if(intersects(points[i],points[(i+1)%points.length],points[j],points[(j+1)%points.length])) return 'Контур пересекает сам себя. Исправьте точки.';
    }
  }
  return area(points)<0.1?'Контур слишком мал.':null;
}
export function localPoint(lat,lon,origin){
  return [(lon-origin.lon)*111320*Math.cos(origin.lat*Math.PI/180),(lat-origin.lat)*111320];
}
export class Track {
  constructor(kind){this.kind=kind;this.points=[];this.raw=[];this.paused=false;this.gap=false;this.lastTime=0;this.breakPending=false;}
  get segments(){const parts=[];for(const sample of this.raw){if(!parts.length||sample.breakBefore)parts.push([]);parts.at(-1).push(sample.point);}return parts;}
  pause(){this.paused=!this.paused;if(this.points.length)this.breakPending=true;}
  add(point,{accuracy=0,time=Date.now(),manual=false}={}){
    if(this.paused) return {accepted:false,reason:'paused'};
    if(!finitePoint(point)||accuracy<0||accuracy>12||!Number.isFinite(accuracy)){if(this.points.length){this.breakPending=true;this.gap=true;}return {accepted:false,reason:'accuracy'};}
    const last=this.points.at(-1);
    if(!manual&&!this.breakPending&&last&&this.lastTime&&distance(last,point)/Math.max((time-this.lastTime)/1000,0.1)>6){this.gap=true;this.breakPending=true;return {accepted:false,reason:'jump'};}
    if(last&&distance(last,point)<(manual?0.1:0.7))return {accepted:false,reason:'jitter'};
    this.points.push(point.slice(0,2));this.raw.push({point:point.slice(0,2),accuracy,time,manual,breakBefore:this.breakPending});if(this.breakPending)this.gap=true;this.breakPending=false;this.lastTime=time;
    return {accepted:true};
  }
  undo(){this.points.pop();this.raw.pop();this.lastTime=this.raw.at(-1)?.time||0;}
  validate(){if(this.kind==='boundary')return this.segments.length>1?'Контур содержит разрыв. Отмените точки после разрыва и продолжите контур вручную.':validatePolygon(this.points);return this.segments.some(s=>s.length>=2)?null:'Добавьте минимум две точки одного непрерывного участка.';}
}
export function coverage(points,cell=0.5){
  const cells=new Map();
  for(const p of points){
    if(!Array.isArray(p)||p.length<4||!p.slice(0,4).every(Number.isFinite)||p[3]<1)continue;
    const x=Math.floor(p[0]/cell),y=Math.floor(p[1]/cell),z=Math.floor(p[2]/cell),key=`${x}:${y}:${z}`;
    const prev=cells.get(key);cells.set(key,{x:x*cell,y:y*cell,z:z*cell,quality:Math.max(p[3],prev?.quality||0),cell});
  }
  return [...cells.values()];
}
export function missingSteps(grave){
  const missing=[];const photos=grave.photos||[];
  if(!photos.some(p=>p.role==='overview'))missing.push('Общий вид');
  if(!photos.some(p=>p.role==='inscription')&&!grave.noInscription)missing.push('Плита или отметка «нет надписи»');
  if(!finitePoint(grave.point))missing.push('Место на карте');
  if(!grave.transcription&&!grave.unreadable&&!grave.noInscription)missing.push('Чтение или отметка «не читается»');
  return missing;
}
export function applyReading(grave,result,sourceHash){
  if(result.sourceHash!==sourceHash)throw new Error('Результат относится к другой фотографии.');
  return {...grave,machineReadings:[...(grave.machineReadings||[]),result]};
}
export function summary(records){
  const graves=records.filter(r=>r.kind==='grave'&&!r.deleted);
  return {graves:graves.length,drafts:graves.filter(r=>r.status!=='complete').length,features:records.filter(r=>r.kind!=='grave'&&!r.deleted).length};
}
export const escapeHTML = text => String(text??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export async function sha256(blob){const bytes=blob instanceof Blob?await blob.arrayBuffer():blob;return [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');}
