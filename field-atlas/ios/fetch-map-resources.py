"""Fetch hash-pinned, redistributable map assets before an Xcode build."""
from pathlib import Path,PurePosixPath
import urllib.request,json,hashlib,zipfile,io
root=Path(__file__).resolve().parent
pin=json.loads((root/'map-resources-pin.json').read_text())
assert pin['url']=='https://archiverf.ru/static/maps/native-map-resources.zip'
request=urllib.request.Request(pin['url'],headers={'User-Agent':'Archiverf-FieldAtlas-Build/0.7'})
with urllib.request.urlopen(request,timeout=120) as response:
    assert response.status==200 and response.url==pin['url']
    raw=response.read(pin['bytes']+1)
assert len(raw)==pin['bytes'] and hashlib.sha256(raw).hexdigest()==pin['sha256'],'Map resources failed integrity check'
with zipfile.ZipFile(io.BytesIO(raw)) as archive:
    members=archive.infolist();assert len(members)<=100 and sum(m.file_size for m in members)<20*1024**2
    for member in members:
        name=PurePosixPath(member.filename)
        assert not name.is_absolute() and '..' not in name.parts and (name.parts[0]=='MapAssets' or str(name)=='world-overview.pmtiles')
        assert not member.is_dir() and not (member.external_attr>>16)&0o170000==0o120000
        path=root/'FieldAtlas'/Path(*name.parts);path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(archive.read(member))
print('Verified local fonts, symbols and world overview installed; regional downloads are not bundled.')
