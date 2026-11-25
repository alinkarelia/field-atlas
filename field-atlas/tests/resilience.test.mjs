import test from 'node:test';
import assert from 'node:assert/strict';
import {sha256} from '../web/core.js';
import {encodeBackup,inspectBackup,validateBackup} from '../web/backup-core.js';
import {chosenRecord,differentFields} from '../web/conflicts.js';
async function fixture(){const blob=new Blob(['original photo bytes']),m={schema:'field-backup-v1',project:{id:'p',type:'cemetery',title:'Test'},records:[{id:'g',projectId:'p',kind:'grave',photos:[{id:'photo'}],persons:[],title:'Нечитаемая плита'}],assets:[{id:'photo',projectId:'p',size:blob.size,sha256:await sha256(blob),mime:'image/png'}],scans:[],settings:[]};return {m,assets:new Map([['photo',blob]])};}
test('Portable backup round trip keeps original bytes and uncertain text',async()=>{const {m,assets}=await fixture(),pack=await encodeBackup(m,assets),restored=await inspectBackup(pack,true);assert.deepEqual(restored.manifest,m);assert.equal(await restored.assets.get('photo').text(),'original photo bytes');});
test('Corrupt original rejected during complete verification',async()=>{const {m,assets}=await fixture(),pack=await encodeBackup(m,assets),bytes=new Uint8Array(await pack.arrayBuffer());bytes[bytes.length-1]^=1;await assert.rejects(inspectBackup(new Blob([bytes]),true),/исходника/);});
test('Corrupt manifest rejected before restoring any records',async()=>{const {m,assets}=await fixture(),pack=await encodeBackup(m,assets),bytes=new Uint8Array(await pack.arrayBuffer());bytes[70]^=1;await assert.rejects(inspectBackup(new Blob([bytes]),true),/реестра/);});
test('Truncated backup rejected',async()=>{const {m,assets}=await fixture(),pack=await encodeBackup(m,assets);await assert.rejects(inspectBackup(pack.slice(0,-1)),/обрезана/);});
test('Missing attachment never produces a successful complete backup',async()=>{const {m}=await fixture();m.assets=[];assert.throws(()=>validateBackup(m),/исходника карточки/);});
test('Cross project and duplicated assets rejected',async()=>{const {m}=await fixture();m.assets[0].projectId='another';assert.throws(()=>validateBackup(m),/принадлежность/);});
test('Conflict choice combines only explicitly chosen fields',()=>{const local={id:'r',projectId:'p',title:'Мой текст',comments:'Моя заметка',localRevision:4},remote={id:'r',projectId:'p',title:'Другой текст',comments:'Серверная заметка',serverVersion:9};const merged=chosenRecord(local,remote,{comments:'server'});assert.equal(merged.title,local.title);assert.equal(merged.comments,remote.comments);assert.equal(merged.id,'r');assert.ok(!differentFields(local,remote).includes('serverVersion'));});
