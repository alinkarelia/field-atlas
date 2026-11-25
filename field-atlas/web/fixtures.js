// Explicit synthetic data only; never loaded into a real project automatically.
export function demoRecords(projectId){
  const record=(id,kind,rest)=>({id:`demo-${id}`,projectId,kind,...rest});
  return [record('boundary','boundary',{points:[[-27,-22],[24,-22],[30,15],[22,26],[-24,25],[-29,0]],title:'Обследуемая граница',source:'synthetic'}),
    record('road','road',{points:[[0,-22],[0,0],[1,26]],title:'Центральная дорожка',source:'synthetic'}),
    record('path-a','path',{points:[[-25,-8],[24,-8]],source:'synthetic'}),record('path-b','path',{points:[[-25,12],[27,12]],source:'synthetic'}),
    ...Array.from({length:12},(_,i)=>record(`grave-${i}`,'grave',{point:[-18+(i%4)*11,-15+Math.floor(i/4)*15],title:`Учебный объект ${String(i+1).padStart(2,'0')}`,status:'draft',persons:[],photos:[],transcription:'',comments:'Вымышленный объект для проверки интерфейса.',source:'synthetic'})),
    ...[[-24,19],[23,18],[-20,-20],[18,-20]].map((point,i)=>record(`tree-${i}`,'tree',{point,title:'Учебное дерево',source:'synthetic'}))];
}
export function demoChunk(index=0){
  const points=[];
  for(let x=-12;x<2;x+=.4)for(let y=-9;y<5;y+=.4){
    // A missing rectangle stays visibly unobserved.
    if(x>-7&&x<-4&&y>-3&&y<0)continue;
    points.push([x+(index?10:0),y,Math.sin(x)*.025,(x<-11||y>4)?1:2]);
  }
  const anchors={A:[-10,-8,0],B:[0,-8,0],C:[-10,3,0],D:[0,3,1]};
  const angle=.18,c=Math.cos(angle),s=Math.sin(angle);
  const toLocal=p=>index?[c*(p[0]-5)+s*(p[1]+3),-s*(p[0]-5)+c*(p[1]+3),p[2]]:p;
  return {schema:'field-scan-v1',id:`synthetic-chunk-${index}`,frameId:`synthetic-frame-${index}`,tracking:'normal',source:'synthetic',
    points:points.map(p=>[...toLocal(p.slice(0,3)),p[3]]),anchors:Object.fromEntries(Object.entries(anchors).map(([k,p])=>[k,toLocal(p)]))};
}
