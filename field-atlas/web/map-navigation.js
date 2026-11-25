export function viewBox(camera,width,height){
  const ratio=Math.max(.25,width/Math.max(height,1)),w=Math.max(70,76*ratio)/camera.zoom,h=w/ratio;
  return [camera.x-w/2,-camera.y-h/2,w,h];
}
export function fitCamera(records,width,height){
  const points=records.flatMap(r=>r.point?[r.point]:(r.points||[])).filter(p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite));
  if(!points.length)return {x:0,y:0,zoom:1};
  const [x0,y0,x1,y1]=points.reduce((b,p)=>[Math.min(b[0],p[0]),Math.min(b[1],p[1]),Math.max(b[2],p[0]),Math.max(b[3],p[1])],[Infinity,Infinity,-Infinity,-Infinity]);
  const base=viewBox({x:0,y:0,zoom:1},width,height);
  return {x:(x0+x1)/2,y:(y0+y1)/2,zoom:Math.max(.05,Math.min(8,base[2]/Math.max(50,(x1-x0)*1.5),base[3]/Math.max(50,(y1-y0)*1.6)))};
}
export class MapNavigation {
  constructor(){this.camera={x:0,y:0,zoom:1};this.pointers=new Map();this.ignoreClick=false;this.dragged=false;this.install();}
  mount(){this.apply();}
  apply(){const map=document.querySelector('#map');if(!map)return;const b=map.getBoundingClientRect();map.setAttribute('viewBox',viewBox(this.camera,b.width,b.height).join(' '));}
  fit(records){const box=document.querySelector('#map')?.getBoundingClientRect();if(box)this.camera=fitCamera(records,box.width,box.height);this.apply();}
  center(point){this.camera.x=point[0];this.camera.y=point[1];this.apply();}
  zoom(factor){this.camera.zoom=Math.max(.05,Math.min(16,this.camera.zoom*factor));this.apply();}
  install(){
    document.addEventListener('pointerdown',event=>{const map=event.target.closest('#map');if(!map||event.button>0)return;this.pointers.set(event.pointerId,[event.clientX,event.clientY]);this.dragged=false;});
    document.addEventListener('pointermove',event=>{
      const old=this.pointers.get(event.pointerId),map=document.querySelector('#map');if(!old||!map)return;const next=[event.clientX,event.clientY];
      if(Math.hypot(next[0]-old[0],next[1]-old[1])>3)this.dragged=true;
      if(this.pointers.size===2){const other=[...this.pointers.entries()].find(([id])=>id!==event.pointerId)[1];const before=Math.hypot(old[0]-other[0],old[1]-other[1]),after=Math.hypot(next[0]-other[0],next[1]-other[1]);if(before>5)this.zoom(after/before);this.dragged=true;}
      else if(this.dragged){const box=map.getBoundingClientRect(),v=viewBox(this.camera,box.width,box.height);this.camera.x-=(next[0]-old[0])*v[2]/box.width;this.camera.y+=(next[1]-old[1])*v[3]/box.height;this.apply();}
      if(this.dragged)this.ignoreClick=true;this.pointers.set(event.pointerId,next);
    });
    const end=event=>{if(!this.pointers.has(event.pointerId))return;this.pointers.delete(event.pointerId);if(!this.pointers.size){this.dragged=false;setTimeout(()=>this.ignoreClick=false,0);}};
    document.addEventListener('pointerup',end);document.addEventListener('pointercancel',end);
    document.addEventListener('wheel',event=>{if(event.target.closest('#map')){event.preventDefault();this.zoom(Math.exp(-event.deltaY*.001));}},{passive:false});
    document.addEventListener('keydown',event=>{if(event.target.id!=='map')return;const v=viewBox(this.camera,event.target.clientWidth,event.target.clientHeight);if(event.key==='ArrowLeft')this.camera.x-=v[2]/10;else if(event.key==='ArrowRight')this.camera.x+=v[2]/10;else if(event.key==='ArrowUp')this.camera.y+=v[3]/10;else if(event.key==='ArrowDown')this.camera.y-=v[3]/10;else if(['+','='].includes(event.key))this.zoom(1.4);else if(event.key==='-')this.zoom(1/1.4);else return;event.preventDefault();this.apply();});
    window.addEventListener('resize',()=>this.apply());
  }
}
