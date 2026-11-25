import {escapeHTML as esc,TYPES} from './core.js';
export const VIEW={width:100,height:76};
export function mapSVG(records,coverage=[],track=null,location=null,zoom=1){
  const w=100/zoom,h=76/zoom;
  let content=`<defs><pattern id="grid" width="5" height="5" patternUnits="userSpaceOnUse"><path d="M5 0H0V5" fill="none" stroke="#c5d3c0" stroke-width=".08"/></pattern><pattern id="hatch" width=".7" height=".7" patternUnits="userSpaceOnUse"><path d="M0 .7L.7 0" stroke="#ba852a" stroke-width=".1"/></pattern></defs><rect x="-5000" y="-5000" width="10000" height="10000" fill="#e8ede4"/><rect x="-5000" y="-5000" width="10000" height="10000" fill="url(#grid)"/>`;
  const points=p=>p.map(([x,y])=>`${x},${-y}`).join(' ');
  for(const r of records.filter(r=>r.kind==='boundary'))content+=`<polygon points="${points(r.points||[])}" fill="#d3e0c9" fill-opacity=".4" stroke="#6b8661" stroke-width=".25" stroke-dasharray=".7 .5"/>`;
  for(const c of coverage)content+=`<rect x="${c.x}" y="${-c.y-c.cell}" width="${c.cell}" height="${c.cell}" fill="${c.quality===2?'#5b9259':'url(#hatch)'}" opacity=".55"/>`;
  for(const r of records.filter(r=>['road','path'].includes(r.kind))){const width=r.kind==='road'?2.4:1.1;for(const segment of (r.segments||[r.points||[]]))content+=`<polyline points="${points(segment)}" fill="none" stroke="#bec8b4" stroke-width="${width+.25}" stroke-linecap="round"/><polyline points="${points(segment)}" fill="none" stroke="#fffdf3" stroke-width="${width}" stroke-linecap="round"/>`;}
  for(const r of records.filter(r=>r.point)){
    const [x,y]=r.point;const tree=r.kind==='tree';
    content+=`<g class="feature" data-record="${esc(r.id)}" role="button" tabindex="0" aria-label="${esc(r.title||TYPES[r.kind])}" transform="translate(${x},${-y})"><title>${esc(r.title||TYPES[r.kind])}</title>`;
    if(tree)content+='<circle r="1.8" fill="#90ad7b" opacity=".5"/><circle r="1.1" fill="#82a16e" opacity=".5"/><circle r=".25" fill="#647c51"/>';
    else if(r.kind==='grave')content+=`<rect x="-1.35" y="-1.8" width="2.7" height="3.6" rx=".35" fill="${r.status==='complete'?'#e6f0e3':'#fbfcf8'}" stroke="#73916a" stroke-width=".17"/><rect x="-.8" y="-1.3" width="1.6" height=".65" rx=".15" fill="#b8c8ae"/>`;
    else content+='<circle r="1" fill="#fff" stroke="#345d43" stroke-width=".2"/><circle r=".3" fill="#345d43"/>';
    content+='</g>';
  }
  if(track){for(const segment of track.segments)content+=`<polyline points="${points(segment)}" fill="none" stroke="#285e44" stroke-width=".35" stroke-dasharray=".7 .3"/>`;for(const [x,y] of track.points)content+=`<circle cx="${x}" cy="${-y}" r=".38" fill="#fff" stroke="#285e44" stroke-width=".2"/>`;}
  if(location)content+=`<circle cx="${location[0]}" cy="${-location[1]}" r="2" fill="#9dc8c0" opacity=".45"/><circle cx="${location[0]}" cy="${-location[1]}" r=".65" fill="#214f3d" stroke="white" stroke-width=".25"/>`;
  return `<svg id="map" class="map" viewBox="${-w/2} ${-h/2} ${w} ${h}" preserveAspectRatio="xMidYMid meet" tabindex="0" aria-label="План проекта. Перемещение пальцем или стрелками, масштаб кнопками плюс и минус">${content}</svg>`;
}
export function mapPoint(svg,event){const p=svg.createSVGPoint();p.x=event.clientX;p.y=event.clientY;const q=p.matrixTransform(svg.getScreenCTM().inverse());return [Math.round(q.x*100)/100,Math.round(-q.y*100)/100];}
export function scanSVG(points,synthetic=false){
  if(!points.length)return '';
  const visible=points.filter(p=>p[3]>=1);if(!visible.length)return '';const bounds=visible.reduce((b,p)=>[Math.min(b[0],p[0]),Math.max(b[1],p[0]),Math.min(b[2],p[1]),Math.max(b[3],p[1])],[Infinity,-Infinity,Infinity,-Infinity]);const [minX,maxX,minY,maxY]=[bounds[0]-1,bounds[1]+1,bounds[2]-1,bounds[3]+1];
  return `<svg viewBox="${minX} ${-maxY} ${Math.max(1,maxX-minX)} ${Math.max(1,maxY-minY)}" preserveAspectRatio="xMidYMid meet" aria-label="${synthetic?'Покрытие учебного фрагмента':'Покрытие импортированного фрагмента'}">${visible.map(p=>`<rect x="${p[0]}" y="${-p[1]}" width=".36" height=".36" fill="${p[3]===2?'#8dc47d':'#dbb977'}" opacity=".85"/>`).join('')}</svg>`;
}
