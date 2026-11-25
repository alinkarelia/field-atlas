import {icon} from './icons.js';

const appMode=()=>matchMedia('(display-mode: standalone)').matches||matchMedia('(display-mode: fullscreen)').matches||navigator.standalone===true;
export function screenButton(){return `<button class="btn square ghost screen-toggle" type="button" data-screen-toggle aria-label="На весь экран" title="На весь экран" aria-pressed="false">${icon('fit')}</button>`;}

export function setupScreen({panel,toast}){
 let changing=false,frame;
 function update(){
  const vv=window.visualViewport,zoomed=vv&&vv.scale>1.05,height=zoomed?innerHeight:(vv?.height||innerHeight),top=zoomed?0:(vv?.offsetTop||0);
  document.documentElement.style.setProperty('--view-height',height+'px');document.documentElement.style.setProperty('--view-top',top+'px');
  document.documentElement.classList.toggle('keyboard-open',!zoomed&&height<innerHeight*.78);
  for(const button of document.querySelectorAll('[data-screen-toggle]')){const active=!!document.fullscreenElement,label=active?'Выйти из полного экрана':appMode()?'Режим приложения':'На весь экран';button.setAttribute('aria-label',label);button.title=label;button.setAttribute('aria-pressed',String(active||appMode()));}
  const active=document.activeElement,body=active?.closest('.dialog-body');
  if(body&&active.matches('input:not([type=file]),textarea,select')){const a=active.getBoundingClientRect(),b=body.getBoundingClientRect();if(a.bottom>b.bottom-12||a.top<b.top+12)active.scrollIntoView({block:'nearest'});}
 }
 const schedule=()=>{cancelAnimationFrame(frame);frame=requestAnimationFrame(update);};
 window.addEventListener('resize',schedule);window.visualViewport?.addEventListener('resize',schedule);window.visualViewport?.addEventListener('scroll',schedule);document.addEventListener('fullscreenchange',schedule);
 new MutationObserver(schedule).observe(document.querySelector('#app'),{childList:true});
 document.addEventListener('click',event=>{
  const button=event.target.closest('[data-screen-toggle]');if(!button)return;event.preventDefault();event.stopImmediatePropagation();
  if(changing)return;
  if(!document.fullscreenElement&&(!document.fullscreenEnabled||!document.documentElement.requestFullscreen||appMode())){
   panel('Полный экран',`<div class="stack"><p>${appMode()?'Приложение уже открыто отдельным окном. Карта и съёмка используют весь доступный экран.':'Браузер не предоставляет кнопке доступ к полному экрану. Карточки и съёмка уже занимают всю доступную область окна.'}</p><p>На iPhone или iPad откройте меню браузера «Поделиться» → «На экран Домой», затем запускайте приложение с появившегося значка.</p><p class="muted">В нативной версии съёмка открывается сразу на весь экран.</p></div>`);return;
  }
  // Call directly in the user gesture, before any queued writes or awaits.
  changing=true;button.disabled=true;
  try{const operation=document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen();Promise.resolve(operation).catch(()=>toast('Браузер не разрешил полный экран. Работа и материалы сохранены.')).finally(()=>{changing=false;button.disabled=false;schedule();});}
  catch{changing=false;button.disabled=false;toast('Полный экран недоступен в этом браузере.');}
 },true);
 update();
}
