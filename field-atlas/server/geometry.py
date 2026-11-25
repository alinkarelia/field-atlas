"""Metric local geometry. Registration never infers global accuracy from GPS."""
import math
import numpy as np

class GeometryError(ValueError):
    pass

def validate_chunk(chunk):
    if not isinstance(chunk,dict) or chunk.get('schema')!='field-scan-v1':
        raise GeometryError('Неизвестный формат скана')
    if not isinstance(chunk.get('frameId'),str) or not 1<=len(chunk['frameId'])<=100:
        raise GeometryError('Нет системы координат')
    points=chunk.get('points')
    if not isinstance(points,list) or not 1<=len(points)<=250000:
        raise GeometryError('Некорректное число точек')
    for p in points:
        if not isinstance(p,list) or len(p)!=4 or any(type(v) not in (int,float) or not math.isfinite(v) for v in p):
            raise GeometryError('Некорректная точка')
        if max(abs(v) for v in p[:3])>100000 or p[3] not in (0,1,2):
            raise GeometryError('Точка вне диапазона')
    anchors=chunk.get('anchors',{})
    if not isinstance(anchors,dict) or len(anchors)>1000:
        raise GeometryError('Некорректные ориентиры')
    for key,p in anchors.items():
        if not isinstance(key,str) or not isinstance(p,list) or len(p)!=3 or not all(type(v) in (int,float) and math.isfinite(v) and abs(v)<100000 for v in p):
            raise GeometryError('Некорректный ориентир')
    if chunk.get('tracking') not in ('normal','limited'):
        raise GeometryError('Неизвестное качество отслеживания')
    return chunk

def register(source,target,max_error=0.12):
    """Rigid Kabsch transform using >=3 named, noncollinear control points."""
    common=sorted(set(source)&set(target))
    if len(common)<3: raise GeometryError('Нужны минимум три общих ориентира')
    a=np.asarray([source[k] for k in common],dtype=float);b=np.asarray([target[k] for k in common],dtype=float)
    ac=a-a.mean(axis=0);bc=b-b.mean(axis=0)
    if np.linalg.svd(ac,compute_uv=False)[1]<0.2 or np.linalg.svd(bc,compute_uv=False)[1]<0.2:
        raise GeometryError('Ориентиры слишком близки или лежат на одной линии')
    u,_,vt=np.linalg.svd(ac.T@bc)
    r=vt.T@u.T
    if np.linalg.det(r)<0: vt[-1,:]*=-1;r=vt.T@u.T
    t=b.mean(axis=0)-r@a.mean(axis=0)
    errors=np.linalg.norm((r@a.T).T+t-b,axis=1)
    if errors.max()>max_error:raise GeometryError('Ориентиры не согласуются: требуется проверка')
    return r,t,float(np.sqrt(np.mean(errors**2)))

def align_chunks(chunks):
    if not chunks:raise GeometryError('Нет сканов')
    reference=next((c for c in chunks if c['tracking']=='normal'),None)
    if reference is None:raise GeometryError('Нет скана с устойчивым отслеживанием')
    transforms={reference['frameId']:(np.eye(3),np.zeros(3),0.0)}
    anchors=dict(reference.get('anchors',{}));pending=list(chunks);accepted=[];reasons={}
    while pending:
        progress=False
        for c in pending[:]:
            cid=c['id']
            if c['tracking']!='normal':reasons[cid]='Неустойчивое отслеживание';continue
            try:
                if c['frameId'] in transforms:r,t,error=transforms[c['frameId']]
                else:r,t,error=register(c.get('anchors',{}),anchors)
                # Shared frame identifiers do not override conflicting named controls.
                for key,p in c.get('anchors',{}).items():
                    if key in anchors and np.linalg.norm(r@np.array(p)+t-np.array(anchors[key]))>0.12:
                        raise GeometryError('Конфликт ориентиров внутри системы координат')
                transforms[c['frameId']]=(r,t,error)
                for key,p in c.get('anchors',{}).items():anchors[key]=(r@np.array(p)+t).tolist()
                accepted.append((c,r,t,error));pending.remove(c);progress=True
            except GeometryError as e:reasons[cid]=str(e)
        if not progress:break
    return reference,accepted,pending,reasons

def assemble(chunks):
    for c in chunks:validate_chunk(c)
    reference,accepted,pending,reasons=align_chunks(chunks)
    tiles={};coverage={};transformation=[]
    for c,r,t,error in accepted:
        transformation.append({'id':c['id'],'frameId':c['frameId'],'rotation':r.tolist(),'translation':t.tolist(),'controlRMSE':error})
        for p in c['points']:
            if p[3]<1:continue
            q=r@np.array(p[:3])+t
            tile=f'{math.floor(q[0]/10)}_{math.floor(q[1]/10)}'
            # Spatial deduplication affects only derived previews, never originals.
            key=tuple(math.floor(v/0.1) for v in q)
            bucket=tiles.setdefault(tile,{})
            old=bucket.get(key)
            if old is None or old[3]<p[3]:bucket[key]=[round(float(v),4) for v in q]+[p[3]]
            cell=tuple(math.floor(v/0.5) for v in q)
            coverage[cell]=max(coverage.get(cell,0),p[3])
    return {'schema':'field-assembly-v1','referenceFrame':reference['frameId'],'registered':[c['id'] for c,*_ in accepted],
            'pending':[{'id':c['id'],'reason':reasons.get(c['id'],'Не удалось связать')} for c in pending],
            'transforms':transformation,'tiles':{key:list(value.values()) for key,value in tiles.items()},
            'coverage':[{'x':k[0]*.5,'y':k[1]*.5,'z':k[2]*.5,'quality':v,'cell':.5} for k,v in coverage.items()],
            'method':'shared-frame-or-named-controls','geodeticAccuracy':None}
