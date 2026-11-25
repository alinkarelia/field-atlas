const {createRequire}=require('node:module');
const {spawn}=require('node:child_process');
const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const assert=require('node:assert/strict');
const runtime=process.env.FIELD_RUNTIME||'C:/Program Files/WindowsApps/OpenAI.CodexPrimaryRuntime.v26-1123-915-0_26.1123.915.0_x64__3k8sg7r9htsxt/dependencies';
const {chromium}=require(process.env.FIELD_PLAYWRIGHT_MODULE||path.join(runtime,'node/node_modules/playwright'));
const root=path.resolve(__dirname,'..'),data=fs.mkdtempSync(path.join(os.tmpdir(),'field-atlas-e2e-'));const reports=path.join(root,'reports');fs.mkdirSync(reports,{recursive:true});
const results=[];const check=(name,condition=true)=>{assert.ok(condition,name);results.push({name,status:'pass'});};
async function main(){
 const python=process.env.FIELD_PYTHON||path.join(runtime,'python/python.exe');
 const server=spawn(python,['-m','server.app','--port','0','--data',data],{cwd:root,windowsHide:true});
 let browser;
 try{
  const base=await new Promise((resolve,reject)=>{let text='';const timeout=setTimeout(()=>reject(new Error('Server startup timeout')),15000);server.stdout.on('data',chunk=>{text+=chunk;const m=text.match(/http:\/\/127\.0\.0\.1:\d+/);if(m){clearTimeout(timeout);resolve(m[0]);}});server.once('error',reject);server.once('exit',code=>{if(code)reject(new Error('Server exited '+code));});});
  browser=await chromium.launch({executablePath:process.env.FIELD_CHROME||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
  const context=await browser.newContext({viewport:{width:1440,height:960}});const page=await context.newPage();const errors=[];page.on('pageerror',err=>errors.push(err.message));page.setDefaultTimeout(8000);
  await page.goto(base);await page.locator('[data-new-project]').first().waitFor();
  check('Four separate project modes',await page.locator('[data-new-project]').count()===4);
  await page.screenshot({path:path.join(reports,'01-projects-desktop.png')});
  await page.locator('[data-new-project=interior]').click();await page.locator('[data-action=create-project]').click();check('Empty project name is rejected',await page.locator('#project-error').innerText()!=='');
  await page.locator('#project-name').fill('Квартира · проверка');await page.locator('[data-action=create-project]').click();await page.locator('.workspace').waitFor();
  await page.locator('[data-action=new-object]').click();check('Interior has room form',await page.locator('.dialog-head').innerText().then(s=>s.includes('Помещение')));
  await page.locator('[name=title]').fill('Кухня');await page.locator('[name=pointX]').fill('2');await page.locator('[name=pointY]').fill('3');await page.locator('[data-action=wizard-next]').click();
  await page.locator('[data-photo=overview]').waitFor();check('Interior never offers portrait',await page.locator('[data-photo=portrait]').count()===0);
  await page.locator('[data-action=wizard-next]').click();check('Interior never offers gravestone x0',await page.locator('[data-action=ocr]').count()===0);
  await page.locator('[data-action=close]').first().click();await page.locator('[data-action=projects]').click();
  await page.locator('[data-action=demo]').click();await page.locator('.workspace').waitFor();check('Demo explicitly labelled',await page.locator('.map-heading').innerText().then(s=>s.includes('учебные данные')));
  await page.screenshot({path:path.join(reports,'02-cemetery-desktop.png')});
  await page.locator('[data-action=new-object]').click();await page.locator('[name=title]').fill('Учебная плита без имени');await page.locator('[data-action=pick-point]').click();
  await page.locator('#map').click({position:{x:900,y:500}});await page.locator('#wizard').waitFor();check('Location picker returns to card',await page.locator('[name=pointX]').inputValue()!=='');
  await page.locator('[data-action=wizard-next]').click();await page.locator('[data-photo=portrait]').waitFor();check('Cemetery has separate portrait field',await page.locator('[data-photo=portrait]').count()===1);
  const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jY1sAAAAASUVORK5CYII=','base64');
  await page.locator('[data-photo=overview]').setInputFiles({name:'overview.png',mimeType:'image/png',buffer:png});await page.waitForTimeout(250);
  await page.locator('[data-photo=inscription]').setInputFiles({name:'plate.png',mimeType:'image/png',buffer:png});await page.waitForTimeout(250);
  await page.locator('[data-action=wizard-next]').click();await page.locator('[name=transcription]').fill('ИВАНОВЪ\n18?4 — 1901');await page.locator('[data-action=add-person]').click();await page.locator('[name=person-0-name]').fill('Иванов Пётр Иванович');await page.locator('[name=person-0-birth]').fill('1864');await page.locator('[name=person-0-death]').fill('1901');
  await page.locator('[data-action=ocr]').click();await page.locator('#ocr-status .warning').waitFor();check('Unconfigured x0 never fabricates a result',(await page.locator('#ocr-status').innerText()).includes('не подключён'));
  await page.locator('[data-action=return-wizard]').click();check('Human text survives failed OCR',(await page.locator('[name=transcription]').inputValue()).includes('18?4'));
  await page.locator('[data-action=wizard-next]').click();await page.locator('[name=measureLength]').fill('3');await page.locator('[name=measureWidth]').fill('2');await page.locator('[name=measureMethod]').selectOption('tape');await page.locator('[name=comments]').fill('Проверка сохранения без сети');
  await page.locator('[data-action=wizard-next]').click();await page.locator('.review-row').first().waitFor();check('Area is shown in square metres',(await page.locator('#wizard').innerText()).includes('6.00 м²'));await page.screenshot({path:path.join(reports,'03-card-review.png')});
  await page.locator('[data-action=wizard-finish]').click();await page.locator('[data-action=objects]').click();await page.locator('#object-search').fill('Учебная плита без имени');check('Search finds saved card',await page.locator('[data-open-object]:visible').count()===1);await page.locator('[data-action=close]').first().click();
  await page.evaluate(()=>navigator.serviceWorker.ready);await page.reload();await page.locator('[data-project=demo-cemetery]').click();
  await context.setOffline(true);await page.reload();await page.locator('[data-project=demo-cemetery]').click();await page.locator('[data-action=objects]').click();await page.locator('#object-search').fill('Учебная плита');check('Offline reload retains cards',await page.locator('[data-open-object]:visible').count()===1);await page.locator('[data-action=close]').first().click();
  await page.locator('[data-action=queue]').click();await page.locator('[data-action=sync]').click();await page.waitForTimeout(300);check('Offline sync reports saved queue',(await page.locator('#sync-status').innerText()).includes('сохранена'));await page.locator('[data-action=close]').first().click();await context.setOffline(false);
  for(let i=0;i<2;i++){await page.locator('[data-action=scan]').click();await page.locator('[data-action=replay]').click();await page.waitForFunction(()=>Number(document.querySelector('#scan-count')?.textContent.split(' ')[0])>1000);await page.waitForTimeout(300);if(i===0)await page.screenshot({path:path.join(reports,'04-coverage.png')});await page.locator('[data-action=scan-save]').click();await page.locator('.workspace').waitFor();}
  check('Two fragments saved',await page.locator('.map-info').innerText().then(s=>s.includes('2 фрагм.')));
  await page.locator('[data-action=queue]').click();await page.locator('[data-action=sync]').click();await page.waitForFunction(()=>document.querySelector('#panel')?.textContent.includes('Файлы ожидают передачи')&&document.querySelector('[data-action=sync]')&&!document.querySelector('[data-action=sync]').disabled,{},{timeout:20000});
  await page.locator('[data-action=assemble]').click();await page.waitForFunction(()=>document.querySelector('#assembly-status')?.textContent.includes('Совмещено:'));check('Server registers two transformed chunks',(await page.locator('#assembly-status').innerText()).includes('Совмещено: 2. Требуют проверки: 0'));
  await page.locator('[data-action=close]').first().click();await page.screenshot({path:path.join(reports,'05-assembled-map.png')});
  await page.locator('[data-action=queue]').click();await page.locator('[data-action=model]').click();await page.locator('#model-canvas').waitFor();await page.waitForFunction(()=>document.querySelector('#model-load')?.textContent.includes('Обзор всей модели'));
  check('Tiled 3D viewer loads measured points',await page.locator('#model-count').innerText().then(t=>!t.startsWith('0 ')));
  const modelBefore=await page.locator('#model-canvas').evaluate(el=>el.toDataURL());await page.locator('#model-canvas').focus();await page.keyboard.press('ArrowRight');const modelAfter=await page.locator('#model-canvas').evaluate(el=>el.toDataURL());check('3D model responds to rotation',modelBefore!==modelAfter);await page.screenshot({path:path.join(reports,'09-model.png')});await page.locator('[data-action=close]').first().click();
  await page.locator('[data-action=objects]').click();await page.locator('[data-action=archive]').click();
  await page.locator('#identity-record').waitFor();const graveId=await page.locator('#identity-record option').evaluateAll(options=>options.find(o=>o.textContent==='Учебная плита без имени').value);
  await page.locator('#identity-record').selectOption(graveId);await page.locator('[data-identity=demo]').click();await page.locator('.identity-candidate').nth(1).waitFor();
  check('Archive namesake shows conflicting dates',(await page.locator('.identity-candidate').nth(1).innerText()).includes('Различается дата'));
  check('Contradictory match cannot be confirmed',await page.locator('.identity-candidate').nth(1).locator('[data-identity=confirmed]').isDisabled());
  await page.locator('.identity-candidate').first().locator('textarea').fill('Сверил полное имя, обе даты и учебную фотографию плиты');
  await page.locator('.identity-candidate').first().locator('[data-identity=confirmed]').click();await page.getByText('Связь подтверждена',{exact:false}).waitFor();
  check('Reviewer can confirm source-to-person link');await page.screenshot({path:path.join(reports,'08-archive-links.png')});
  const graph=await page.evaluate(async()=>await fetch('/api/identity/graph?projectId=demo-cemetery').then(r=>r.json()));
  check('Graph preserves memorial and person separately',graph.memorials.length>0&&graph.people.length===1&&graph.links[0].relation==='inscription_refers_to'&&graph.mergePeople===false);
  await page.locator('[data-action=close]').first().click();
  await page.locator('[data-action=tools]').click();await page.locator('[data-tool=path]').click();
  await page.locator('#map').click({position:{x:250,y:250}});await page.locator('#map').click({position:{x:300,y:250}});
  await page.locator('[data-action=track-pause]').click();await page.locator('[data-action=track-pause]').click();
  await page.locator('#map').click({position:{x:350,y:280}});await page.locator('#map').click({position:{x:400,y:280}});await page.waitForFunction(()=>document.querySelector('.track-card')?.textContent.includes('4 точек'));
  await page.reload();await page.locator('[data-project=demo-cemetery]').click();await page.locator('.track-card').waitFor();
  check('Unfinished track survives reload paused',(await page.locator('.track-card').innerText()).includes('4 точек')&&(await page.locator('.track-card').innerText()).includes('Пауза'));
  const savedTrack=await page.evaluate(async()=>{const db=await import('/db.js');return (await db.get('settings','unfinished-track:demo-cemetery')).value;});
  check('Pause retained as a geometry break',savedTrack.raw[2].breakBefore===true);
  await page.locator('[data-action=track-finish]').click();await page.locator('[data-action=track-confirm]').click();await page.locator('.track-card').waitFor({state:'detached'});
  for(const width of [320,390,768,1024,1440]){await page.setViewportSize({width,height:width<600?844:960});await page.waitForTimeout(80);check(`No horizontal overflow at ${width}`,await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));if(width===390)await page.screenshot({path:path.join(reports,'06-mobile-map.png')});}
  await page.setViewportSize({width:390,height:844});await page.locator('[data-action=new-object]').click();await page.locator('#wizard').waitFor();await page.screenshot({path:path.join(reports,'07-mobile-card.png')});check('Dialog fits mobile height',await page.locator('#panel').evaluate(el=>el.getBoundingClientRect().bottom<=innerHeight));await page.locator('[data-action=close]').first().click();
  check('No uncaught browser exceptions',errors.length===0);
  fs.writeFileSync(path.join(reports,'browser-tests.json'),JSON.stringify({testedAt:new Date().toISOString(),checks:results,errors,scope:'Chromium sandbox; no native LiDAR or real x0 call'},null,2));console.log(JSON.stringify({passed:results.length,report:path.join(reports,'browser-tests.json')}));
 }catch(error){fs.writeFileSync(path.join(reports,'browser-tests.json'),JSON.stringify({checks:results,error:String(error)},null,2));throw error;}
 finally{if(browser)await browser.close();server.kill();}
}
main().catch(error=>{console.error(error);process.exitCode=1;});

