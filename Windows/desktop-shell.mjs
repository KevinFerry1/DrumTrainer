// The desktop arrangement follows the native SwiftUI tabs and form layout.
import {historySessionClean} from './results-view.mjs';
export const desktopTabs=['live','calibration','practice','history','settings'];
// Both migrated summaries and full Windows sessions feed the native-style history view.
export function historyValues(entries){
  return entries.map(({s,date,summaryOnly})=>({date,bpm:s.bpm,
    recall:summaryOnly?s.recall:s.metrics.recall,
    error:summaryOnly?s.medianAbsoluteErrorMilliseconds:s.metrics.error,
    spread:summaryOnly?s.medianLimbSpreadMilliseconds:s.metrics.spread,
    duration:summaryOnly?(s.durationSeconds??0):(s.pattern?.duration??0)/1000,
    clean:historySessionClean({s,summaryOnly})
  })).sort((a,b)=>a.date-b.date);
}
export function initializeDesktopShell({onTabChange=()=>{},onPracticeType=()=>{},onReturnSetup=()=>{}}={}){
  let active='practice';
  const $=id=>document.getElementById(id),buttons=[...document.querySelectorAll('[role="tab"][data-tab]')];
  function showTab(tab,{focus=false}={}){
    if(!desktopTabs.includes(tab))return;
    const previous=active;active=tab;
    for(const button of buttons){const selected=button.dataset.tab===tab;button.setAttribute('aria-selected',String(selected));button.tabIndex=selected?0:-1;}
    for(const panel of document.querySelectorAll('[role="tabpanel"]'))panel.hidden=panel.id!==`panel-${tab}`;
    if(focus)$(`tab-${tab}`).focus();if(previous!==tab)onTabChange(tab,previous);
  }
  for(const button of buttons){button.addEventListener('click',()=>showTab(button.dataset.tab));button.addEventListener('keydown',event=>{const index=desktopTabs.indexOf(button.dataset.tab);let next;if(event.key==='ArrowRight')next=(index+1)%buttons.length;if(event.key==='ArrowLeft')next=(index+buttons.length-1)%buttons.length;if(event.key==='Home')next=0;if(event.key==='End')next=buttons.length-1;if(next!=null){event.preventDefault();showTab(desktopTabs[next],{focus:true});}});}
  for(const button of document.querySelectorAll('[data-practice-type]'))button.addEventListener('click',()=>onPracticeType(button.dataset.practiceType));
  for(const button of document.querySelectorAll('[data-action]'))button.addEventListener('click',()=>$(button.dataset.action).click());
  const mirrors=[...document.querySelectorAll('[data-bind]')];
  for(const mirror of mirrors){
    const canonical=$(mirror.dataset.bind);if(!canonical)throw new Error(`Missing shared control ${mirror.dataset.bind}`);
    for(const eventName of ['input','change'])mirror.addEventListener(eventName,()=>{if(mirror.type==='checkbox')canonical.checked=mirror.checked;else canonical.value=mirror.value;canonical.dispatchEvent(new Event(eventName,{bubbles:true}));});
  }
  function sync(){
    for(const action of document.querySelectorAll('[data-action]'))action.disabled=$(action.dataset.action).disabled;
    for(const mirror of mirrors){const canonical=$(mirror.dataset.bind);if(!canonical)continue;
      if(canonical.tagName==='SELECT'&&mirror.innerHTML!==canonical.innerHTML)mirror.innerHTML=canonical.innerHTML;
      mirror.disabled=canonical.disabled;
      if(mirror.type==='checkbox')mirror.checked=canonical.checked;else if(document.activeElement!==mirror)mirror.value=canonical.value;
    }
    for(const copy of document.querySelectorAll('[data-text-from]')){const canonical=$(copy.dataset.textFrom);if(canonical&&copy.textContent!==canonical.textContent)copy.textContent=canonical.textContent;}
    const bpm=$('bpm');$('tempoValue').textContent=`${Math.round(Number(bpm.value)||120)} BPM`;
    const sequence=$('customEditorPanel').dataset.sequence==='true';
    $('customMeasureMode').setAttribute('aria-pressed',String(!sequence));$('customSequenceMode').setAttribute('aria-pressed',String(sequence));
    const song=$('practiceMode').value==='song',custom=!song&&($('exercise').selectedOptions[0]?.parentElement.label==='Your saved exercises'||$('customEditorPanel').dataset.editing==='true');
    const kind=song?'song':custom?'custom':'builtIn';
    for(const button of document.querySelectorAll('[data-practice-type]'))button.setAttribute('aria-pressed',String(button.dataset.practiceType===kind));
    $('customEditorPanel').hidden=!custom;$('exerciseSelectionRow').hidden=song;
    $('sequenceEditor').hidden=!sequence;$('measureEditor').hidden=sequence;
    $('bpmSlider').disabled=bpm.disabled;$('bpmSlider').value=bpm.value;
    $('phaseSummary').textContent=$('phase').textContent;
    const showingResults=!$('result').hidden&&$('result').parentElement===$('practiceContent');$('practiceContent').classList.toggle('showing-results',showingResults);$('practiceReturn').hidden=!showingResults;
    $('practiceRepeatLabel').textContent=song?'Repeats':sequence?'Arrangement':'Measures';
    $('historyEmpty').hidden=$('history').querySelector('.history-row')!==null;
    $('clickProxy').textContent=$('phase').textContent==='CLICK'?'Metronome running…':'Start Metronome';
  }
  $('bpmSlider').addEventListener('input',()=>{if(!$('bpm').disabled){$('bpm').value=$('bpmSlider').value;$('bpm').dispatchEvent(new Event('change',{bubbles:true}));sync();}});
  $('practiceReturn').addEventListener('click',()=>{ $('result').hidden=true;onReturnSetup();sync();});
  showTab('practice');sync();const timer=setInterval(sync,150);window.addEventListener('pagehide',()=>clearInterval(timer),{once:true});
  return{showTab,sync,get activeTab(){return active;}};
}
