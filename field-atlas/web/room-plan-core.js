import {validateCeiling,ceilingStats} from './ceiling.js';
import {area,escapeHTML as e,validatePolygon} from './core.js';
export const roomLabels={wall:'Стена',door:'Дверь',window:'Окно',opening:'Проход'};
const metric=(v)=>v.toLocaleString('ru',{minimumFractionDigits:2,maximumFractionDigits:2});
export const metres=v=>metric(v)+' м';
export function wallLength(w){return Math.hypot(w.end[0]-w.start[0],w.end[1]-w.start[1]);}
export function validateRoomPlan(doc){
 if(!doc||doc.schema!=='field-room-plan-v1'||typeof doc.frameId!=='string'||!doc.frameId||doc.frameId.length>200||!Array.isArray(doc.rooms)||!doc.rooms.length||doc.rooms.length>100)return 'Нужен план field-room-plan-v1 с системой координат и комнатами.';
 const point=p=>Array.isArray(p)&&p.length===2&&p.every(v=>Number.isFinite(v)&&Math.abs(v)<100000);const ids=new Set();
 for(const r of doc.rooms){
  if(!r||typeof r.id!=='string'||!r.id||ids.has(r.id)||typeof r.name!=='string'||!r.name.trim()||r.name.length>160||(!Number.isInteger(r.level??0)||(r.level??0)<-20||(r.level??0)>200)||!Array.isArray(r.walls)||!r.walls.length||r.walls.length>500||!Array.isArray(r.openings)||r.openings.length>1000)return 'Некорректные комнаты или стены.';ids.add(r.id);const surfaces=new Set();
  for(const w of r.walls){if(!w||typeof w.id!=='string'||!w.id||surfaces.has(w.id)||!point(w.start)||!point(w.end)||wallLength(w)<.05||!Number.isFinite(w.height)||w.height<=0||w.height>100||!Number.isFinite(w.base)||![0,1,2].includes(w.confidence))return 'Некорректный размер или идентификатор стены.';surfaces.add(w.id);
   if(w.profile!=null&&(!Array.isArray(w.profile)||w.profile.length>500||w.profile.some(p=>!point(p)||p[0]<-.1||p[1]<-.1||p[0]>wallLength(w)+.1||p[1]>w.height+.1)||validatePolygon(w.profile)))return 'Некорректный контур высоты стены.';
  }
  for(const o of r.openings){const w=r.walls.find(w=>w.id===o?.wallId);if(!w||surfaces.has(o.id)||typeof o.id!=='string'||!o.id||!['door','window','opening'].includes(o.kind)||![o.offset,o.width,o.height,o.sill].every(Number.isFinite)||o.offset<-.03||o.width<=0||o.height<=0||o.sill<-.03||o.offset+o.width>wallLength(w)+.05||o.sill+o.height>w.height+.10)return 'Проём выходит за стену или не привязан к ней.';surfaces.add(o.id);}
  if(r.floor!==undefined&&r.floor!==null&&(!Array.isArray(r.floor)||r.floor.length>500||r.floor.some(p=>!point(p))||validatePolygon(r.floor)))return 'Контур пола повреждён, пересекается или не замкнут.';
  if(r.ceiling&&validateCeiling(r.ceiling))return validateCeiling(r.ceiling);
  if(r.ceiling){const stats=ceilingStats(r.ceiling);if(r.ceiling.synthetic&&!doc.synthetic)return 'Учебный потолок нельзя записать как реальный.';if(r.ceilingHeight!=null&&(stats.max-stats.min>.05||Math.abs(r.ceilingHeight-stats.mean)>=.01))return 'Общая высота не соответствует отдельному замеру потолка.';}
  if(r.ceilingSourceId!=null&&(typeof r.ceilingSourceId!=='string'||!r.ceilingSourceId||r.ceilingSourceId.length>200)||r.ceilingSourceHistory!=null&&(!Array.isArray(r.ceilingSourceHistory)||r.ceilingSourceHistory.length>1000||r.ceilingSourceHistory.some(s=>typeof s!=='string'||!s||s.length>200)))return 'Некорректная история замеров потолка.';
  if(r.ceilingHeight!=null&&(!Number.isFinite(r.ceilingHeight)||r.ceilingHeight<=0))return 'Некорректная высота потолка.';
  if(r.notes!=null&&(!Array.isArray(r.notes)||r.notes.length>1000||r.notes.some(n=>typeof n!=='string'||n.length>2000)))return 'Некорректные замечания к плану.';
  if(r.ceilingSource!=null&&typeof r.ceilingSource!=='string'||[...r.walls,...r.openings].some(s=>s.code!=null&&(typeof s.code!=='string'||s.code.length>100)))return 'Некорректные подписи элементов.';
 }
 return null;
}
export function roomArea(room){return room.floor?.length>=3?area(room.floor):null;}
export function openingSegment(room,o){const w=room.walls.find(w=>w.id===o.wallId),l=wallLength(w),d=[(w.end[0]-w.start[0])/l,(w.end[1]-w.start[1])/l];return [w.start.map((v,i)=>v+d[i]*o.offset),w.start.map((v,i)=>v+d[i]*(o.offset+o.width))];}
export function floorPlanSVG(room,selected,dimensions=true){
 const pts=room.walls.flatMap(w=>[w.start,w.end]);const bounds=pts.reduce((b,p)=>[Math.min(b[0],p[0]),Math.min(b[1],p[1]),Math.max(b[2],p[0]),Math.max(b[3],p[1])],[Infinity,Infinity,-Infinity,-Infinity]);
 const factor=60,pad=72,w=(bounds[2]-bounds[0])*factor+pad*2,h=(bounds[3]-bounds[1])*factor+pad*2,xy=p=>[(p[0]-bounds[0])*factor+pad,(bounds[3]-p[1])*factor+pad];const center=[(bounds[0]+bounds[2])/2,(bounds[1]+bounds[3])/2];let svg='';
 if(room.floor)svg+=`<polygon points="${room.floor.map(p=>xy(p).join(',')).join(' ')}" fill="#eef2e8" stroke="#91a48a" stroke-dasharray="4 3"/>`;
 room.walls.forEach((wall,i)=>{const a=xy(wall.start),b=xy(wall.end),dx=b[0]-a[0],dy=b[1]-a[1],len=Math.hypot(dx,dy),mid=[(a[0]+b[0])/2,(a[1]+b[1])/2],c=xy(center);let normal=[-dy/len,dx/len];if(normal[0]*(mid[0]-c[0])+normal[1]*(mid[1]-c[1])<0)normal=normal.map(v=>-v);const offset=36,da=a.map((v,j)=>v+normal[j]*offset),db=b.map((v,j)=>v+normal[j]*offset);let angle=Math.atan2(dy,dx)*180/Math.PI;if(angle>90||angle< -90)angle+=180;const label=wall.code||'С'+(i+1),color=selected===wall.id?'#c06b23':'#244e3c';
  svg+=`<g data-surface="${e(wall.id)}" role="button" tabindex="0" aria-label="${e(label)}: ${metres(wallLength(wall))}"><line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" stroke="transparent" stroke-width="22"/><line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" stroke="${color}" stroke-width="7" ${wall.curved?'stroke-dasharray="8 4"':''}/>${dimensions||selected===wall.id?`<path d="M${a}L${da}L${db}L${b}" fill="none" stroke="${color}" stroke-width="1"/><circle cx="${da[0]}" cy="${da[1]}" r="2" fill="${color}"/><circle cx="${db[0]}" cy="${db[1]}" r="2" fill="${color}"/><text transform="translate(${(da[0]+db[0])/2} ${(da[1]+db[1])/2}) rotate(${angle})" text-anchor="middle" dy="-6" font-size="12" fill="${color}">${e(label)} · ${wall.confidence<2?'≈ ':''}${metres(wallLength(wall))}</text>`:''}</g>`;
 });
 room.openings.forEach((o,i)=>{const [a,b]=openingSegment(room,o).map(xy),color=o.kind==='window'?'#23649a':o.kind==='door'?'#9b592b':'#39694b',code=o.code||(o.kind==='window'?'О':o.kind==='door'?'Д':'П')+(i+1);svg+=`<g data-surface="${e(o.id)}" tabindex="0" role="button" aria-label="${roomLabels[o.kind]} ${e(code)} ${metres(o.width)}"><line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" stroke="#fffdf7" stroke-width="12"/><line x1="${a[0]}" y1="${a[1]}" x2="${b[0]}" y2="${b[1]}" stroke="${selected===o.id?'#c06b23':color}" stroke-width="${o.kind==='window'?4:2}" ${o.kind==='opening'?'stroke-dasharray="4 3"':''}/><text x="${(a[0]+b[0])/2}" y="${(a[1]+b[1])/2-10}" text-anchor="middle" font-size="11" fill="${color}" stroke="#fffdf7" stroke-width="3" paint-order="stroke">${e(code)}</text></g>`;});
 const a=roomArea(room);if(!room.outlines)svg+=`<text x="${w/2}" y="${h/2}" text-anchor="middle" fill="#49614f" font-size="14">${a==null?'Контур пола не подтверждён':metric(a)+' м²'}</text>`;
 for(const outline of room.outlines||[]){const p=outline.points.reduce((sum,p)=>sum.map((v,i)=>v+p[i]/outline.points.length),[0,0]),c=xy(p);svg+=`<text x="${c[0]}" y="${c[1]}" text-anchor="middle" fill="#49614f" font-size="12">${e(outline.name)}</text>`;}
 return `<svg id="room-plan-svg" viewBox="0 0 ${w} ${h}" aria-label="План комнаты с привязанными размерами стен и проёмами" xmlns="http://www.w3.org/2000/svg" style="font-family:Arial,sans-serif;background:#fffdf7">${svg}</svg>`;
}
export function combineFloor(rooms,level){const same=rooms.filter(r=>(r.level||0)===level);return {id:'all',name:'Этаж',walls:same.flatMap((r,i)=>r.walls.map((w,j)=>({...w,id:r.id+'::'+w.id,code:`${i+1} / ${w.code||'С'+(j+1)}`}))),openings:same.flatMap(r=>r.openings.map(o=>({...o,id:r.id+'::'+o.id,wallId:r.id+'::'+o.wallId}))),outlines:same.filter(r=>r.floor?.length).map(r=>({points:r.floor,name:r.name}))};}
export function wallElevationSVG(room,wall){
 const length=wallLength(wall),scale=70,pad=48,w=length*scale+pad*2,h=wall.height*scale+pad*2;
 const openings=room.openings.filter(o=>o.wallId===wall.id);const floorY=pad+wall.height*scale;
 const profile=wall.profile?.length>=3?wall.profile:[[0,0],[length,0],[length,wall.height],[0,wall.height]];
 const polygon=profile.map(p=>`${pad+p[0]*scale},${floorY-p[1]*scale}`).join(' ');
 return `<svg viewBox="0 0 ${w} ${h}" aria-label="Развёртка выбранной стены: пол, верх стены и высоты проёмов" xmlns="http://www.w3.org/2000/svg" style="font-family:Arial,sans-serif;background:#fffdf7"><polygon points="${polygon}" fill="#e8eee2" stroke="#345b42" stroke-width="3"/>${openings.map(o=>`<rect x="${pad+o.offset*scale}" y="${floorY-(o.sill+o.height)*scale}" width="${o.width*scale}" height="${o.height*scale}" fill="${o.kind==='window'?'#d7e9f4':'#fffdf7'}" stroke="#456f83"/><text x="${pad+(o.offset+o.width/2)*scale}" y="${floorY-(o.sill+o.height/2)*scale}" text-anchor="middle" font-size="11">${e(o.code||roomLabels[o.kind])}</text>`).join('')}<text x="${w/2}" y="22" text-anchor="middle" font-size="12">Длина стены · ${metres(length)}</text><text transform="translate(20 ${h/2}) rotate(-90)" text-anchor="middle" font-size="12">Высота стены · ${metres(wall.height)}</text><text x="${w/2}" y="${h-12}" text-anchor="middle" font-size="11">Основание стены</text></svg>`;
}
export function exampleRoomPlan(){return {schema:'field-room-plan-v1',frameId:'example-interior',synthetic:true,rooms:[{id:'example-room',name:'Учебная комната',level:0,walls:[{id:'w1',code:'С1',start:[0,0],end:[4.2,0],height:2.7,base:0,confidence:2},{id:'w2',code:'С2',start:[4.2,0],end:[4.2,3.6],height:2.7,base:0,confidence:2},{id:'w3',code:'С3',start:[4.2,3.6],end:[0,3.6],height:2.7,base:0,confidence:2},{id:'w4',code:'С4',start:[0,3.6],end:[0,0],height:2.7,base:0,confidence:2}],openings:[{id:'door1',code:'Д1',kind:'door',wallId:'w1',offset:.4,width:.9,height:2.1,sill:0},{id:'window1',code:'О1',kind:'window',wallId:'w3',offset:1,width:1.4,height:1.3,sill:.9},{id:'passage1',code:'П1',kind:'opening',wallId:'w2',offset:.4,width:1,height:2.2,sill:0}],floor:[[0,0],[4.2,0],[4.2,3.6],[0,3.6]],ceilingHeight:null}]};}

export function drawingWithCaption(svg,caption){
 const match=svg.match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/);if(!match)return svg;
 const width=Number(match[1]),height=Number(match[2]);
 return svg.replace(match[0],`viewBox="0 0 ${width} ${height+48}"`).replace('</svg>',`<text x="${width/2}" y="${height+20}" text-anchor="middle" font-size="11" fill="#635439">${e(caption)}</text></svg>`);
}
