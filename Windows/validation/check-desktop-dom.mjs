// Integration check against the real HTML/app modules, without MIDI or audio hardware.
// Install jsdom@26 in a temporary directory; set DRUMTRAINER_TEST_MODULES to its node_modules.
// Run this file with each argument: builtIn, custom, sequence.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import path from 'node:path';
import {exercises,makePattern,score} from '../core.mjs';
import {renderSessionResult,drawResultScore} from '../results-view.mjs';
import {summarizePractice} from '../coaching.mjs';
const require=createRequire(path.join(process.env.DRUMTRAINER_TEST_MODULES,'package.json'));
const {JSDOM}=require('jsdom'),mode=process.argv[2]??'builtIn';
const dom=new JSDOM(fs.readFileSync(new URL('../index.html',import.meta.url),'utf8'),{url:'http://127.0.0.1:8765'});
const {window}=dom,{document}=window,$=id=>document.getElementById(id);
// Newer Node versions expose navigator through a getter; install the test window explicitly.
for(const key of ['window','document','navigator','localStorage','Option','Event'])Object.defineProperty(globalThis,key,{value:window[key],writable:true,configurable:true});
window.HTMLMediaElement.prototype.pause=()=>{};
window.HTMLDialogElement.prototype.showModal=function(){this.open=true;};
window.HTMLDialogElement.prototype.close=function(){this.open=false;this.dispatchEvent(new window.Event('close'));};
let drawFrame;globalThis.requestAnimationFrame=fn=>{drawFrame=fn;return 1;};globalThis.cancelAnimationFrame=()=>{};
globalThis.navigator.mediaDevices={enumerateDevices:async()=>[{kind:'audioinput',deviceId:'snowball',label:'Blue Snowball'},{kind:'audiooutput',deviceId:'scarlett',label:'Focusrite Scarlett'}],addEventListener:()=>{}};
const measure={...structuredClone(exercises[0]),name:'Transferred custom measure'};
const sequence={name:'Transferred sequence',subdivision:'sixteenths',hits:[],sequenceSteps:[{...structuredClone(measure),id:'step',repeats:2}],sequenceRepeats:1};
const library=[{id:'custom',definition:measure},{id:'sequence',definition:sequence}];
const pattern=makePattern(exercises[0],120,4),evidence=pattern.notes.map(n=>({id:n.id,time:n.time,voice:n.voice,source:'midi',velocity:90}));
const session={id:'fixture',date:new Date().toISOString(),name:pattern.name,bpm:120,pattern,metrics:score(pattern,evidence,{gradeKicks:true}),evidence,devices:{}};
const needsWork={...session,id:'needs-work',date:'2026-10-12T12:00:00Z',metrics:score(pattern,[],{gradeKicks:true}),evidence:[]};
const summary={id:'native-summary',exerciseName:'Mac summary',completedAt:'2026-10-11T12:00:00Z',bpm:100,totalExpected:8,recall:1,medianAbsoluteErrorMilliseconds:12,droppedEventCount:0};
const saved={exercises:library,sessions:[session,needsWork],songs:[],nativeArchives:[{sessions:[summary]}]};
globalThis.indexedDB={open:()=>{const req={};queueMicrotask(()=>{req.result={transaction:()=>({objectStore:store=>({get:()=>{const result={};queueMicrotask(()=>{result.result=store==='data'?saved:undefined;result.onsuccess();});return result;}})}),close:()=>{}};req.onsuccess();});return req;}};
if(mode!=='builtIn')localStorage.setItem('DrumTrainerWindows.settings.v1',JSON.stringify({exercise:mode==='sequence'?'sequence':'custom',desktopPracticeType:'custom',desktopSequence:mode==='sequence'}));
const failures=[];window.addEventListener('error',event=>failures.push(event.error));
try{
  await import('../app.mjs');
  assert.equal(document.querySelector('main').inert,false,'App bootstrap unlocks the interface');
  assert.equal($('panel-practice').hidden,false);
  assert.equal($('customEditorPanel').hidden,mode==='builtIn');
  assert.equal($('sequenceEditor').hidden,mode!=='sequence');
  assert.equal($('customSequenceMode').getAttribute('aria-pressed'),String(mode==='sequence'));
  const switchTo=id=>{ $(`tab-${id}`).click();assert.equal($(`panel-${id}`).hidden,false);assert.equal(document.querySelectorAll('[role="tabpanel"]:not([hidden])').length,1); };
  switchTo('live');switchTo('calibration');switchTo('history');switchTo('settings');switchTo('practice');
  assert.equal($('history').querySelectorAll('.history-row').length,3);
  assert.equal($('history').querySelectorAll('.clean-status').length,2,'Both Windows and summary-only Mac clean runs show a seal');
  assert.equal($('history').querySelectorAll('.needs-work').length,1);
  assert.ok($('history').querySelector('.clean-status svg'));
  assert.equal($('history').querySelector('.history-bpm').textContent,'120 BPM');
  assert.equal($('history').querySelector('.history-recall').textContent,'100.0%');
  assert.ok($('progressRecords').querySelector('table').textContent.includes('Highest clean tempo'));
  assert.equal($('historyOverview').children.length,4);
  assert.ok($('historyTrend').querySelector('svg'));
  const bpmMirror=document.querySelector('[data-bind="bpm"]');bpmMirror.value='137';bpmMirror.dispatchEvent(new Event('change',{bubbles:true}));
  assert.equal($('bpm').value,'137');assert.equal(JSON.parse(localStorage.getItem('DrumTrainerWindows.settings.v1')).bpm,'137');
  $('bpmSlider').value='142';$('bpmSlider').dispatchEvent(new Event('input',{bubbles:true}));assert.equal($('bpm').value,'142');
  const outputMirror=document.querySelector('[data-bind="output"]');outputMirror.value='scarlett';outputMirror.dispatchEvent(new Event('change',{bubbles:true}));assert.equal($('output').value,'scarlett');await new Promise(resolve=>setTimeout(resolve,0));
  $('history').querySelector('button').click();assert.equal($('historyDetailDialog').open,true);assert.equal($('result').parentElement,$('historyDetailBody'));
  assert.equal($('resultTitle').textContent,'Practice results');
  assert.ok($('resultSubtitle').textContent.includes('120 BPM · 4 measures'));
  assert.equal($('metrics').querySelectorAll('.compact-metric').length,4);
  assert.deepEqual([...$('metrics').querySelectorAll('.metric-heading>span')].map(n=>n.textContent),['Note recall','Precision','Median error','Timing bias']);
  assert.equal($('hitBreakdown').querySelectorAll('.hit-count').length,5);
  assert.ok($('timingDetails').textContent.includes('Longest clean streak: 32'));
  assert.equal($('voiceMetrics').querySelectorAll('th').length,14);
  assert.equal($('sequenceResults').hidden,true,'A repeated built-in exercise has no native Sequence review box');
  const expectedBoxes=['Performance score','Hit breakdown','Timing details','Detailed timing timeline','Sequence review','Per-voice results','Limb synchronization'];
  assert.deepEqual([...$('result').querySelectorAll(':scope>fieldset>legend')].map(n=>n.textContent),expectedBoxes);
  const richPattern=makePattern({name:'Dynamics and coordination',subdivision:'sixteenths',hits:[{slot:0,voice:'snare',accent:true},{slot:0,voice:'kick'},{slot:1,voice:'snare'},{slot:2,voice:'snare',ghost:true}]},120,4);
  const richEvidence=richPattern.notes.map(n=>({id:n.id,time:n.time+55,voice:n.voice,source:'midi',velocity:n.accent?120:n.ghost?30:n.voice==='kick'?90:80}));
  const rich={...session,id:'rich',name:richPattern.name,pattern:richPattern,evidence:richEvidence,metrics:score(richPattern,richEvidence)};
  renderSessionResult(document,rich,summarizePractice(rich.pattern,rich.metrics));
  assert.equal($('stableTiming').hidden,false);assert.ok($('metrics').textContent.includes('Groove error'));
  assert.deepEqual([...$('dynamicsResults').querySelectorAll('legend')].map(n=>n.textContent),['Accent dynamics','Ghost dynamics']);
  assert.equal($('dynamicsResults').querySelectorAll('.compact-metric').length,8);
  assert.equal($('limbResults').hidden,false);assert.equal($('limbMetrics').children.length,4);
  assert.equal($('limbOffsets').querySelectorAll('tbody tr').length,2);
  const sequencePattern=makePattern(sequence,120,4);
  renderSessionResult(document,{...rich,pattern:sequencePattern,metrics:score(sequencePattern,[])},summarizePractice(sequencePattern,score(sequencePattern,[])));
  assert.equal($('sequenceResults').hidden,false);assert.equal($('sequenceReview').children.length,2);
  renderSessionResult(document,rich,summarizePractice(rich.pattern,rich.metrics));
  // The performance score stays viewport-sized even for long imported songs.
  const labels=[];const context=new Proxy({fillText:(text)=>labels.push(text)},{get:(target,key)=>target[key]??(()=>{})});
  $('resultScore').getContext=()=>context;
  Object.defineProperty($('resultScoreScroll'),'clientWidth',{value:800});
  drawResultScore(document,rich,2);assert.equal($('resultScore').width,1600);assert.equal($('resultScore').height,312);
  assert.equal($('resultScoreTrack').style.width,'1338px');assert.ok(!labels.some(label=>String(label).startsWith('Cymbal ×')));
  $('resultScoreScroll').scrollLeft=320;drawResultScore(document,rich,2);assert.equal($('resultScore').width,1600);
  assert.equal($('resultScoreScroll').scrollLeft,320);
  $('closeHistoryDetail').click();assert.equal($('result').parentElement,$('practiceContent'));assert.equal($('result').hidden,true);
  document.querySelector('[data-practice-type="song"]').click();assert.equal($('songPanel').hidden,false);
  document.querySelector('[data-practice-type="custom"]').click();assert.equal($('customEditorPanel').hidden,false);
  $('customSequenceMode').click();assert.equal($('sequenceEditor').hidden,false);assert.equal($('measureEditor').hidden,true);
  $('customMeasureMode').click();assert.equal($('measureEditor').hidden,false);
  document.querySelector('[data-practice-type="builtIn"]').click();assert.equal($('customEditorPanel').hidden,true);
  $('tab-practice').dispatchEvent(new window.KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));assert.equal($('panel-history').hidden,false);
  // Optional static visual fixtures use the real rendered DOM/CSS and artificial sessions.
  // They have no database access and can be served from an isolated preview directory.
  if(process.env.DRUMTRAINER_VISUAL_OUTPUT){
    const output=process.env.DRUMTRAINER_VISUAL_OUTPUT;fs.mkdirSync(output,{recursive:true});
    for(const file of fs.readdirSync(new URL('../',import.meta.url)))if(file.endsWith('.mjs')||file==='style.css')fs.copyFileSync(new URL(`../${file}`,import.meta.url),path.join(output,file));
    function exportPage(name,drawScore=false){const copy=document.documentElement.cloneNode(true);copy.querySelector('main').removeAttribute('inert');for(const script of copy.querySelectorAll('script'))script.remove();if(drawScore){const script=copy.ownerDocument.createElement('script');script.type='module';script.textContent=`import {drawResultScore} from './results-view.mjs';const session=${JSON.stringify(rich)};const draw=()=>drawResultScore(document,session,window.devicePixelRatio||1);requestAnimationFrame(draw);window.addEventListener('resize',draw);document.getElementById('resultScoreScroll').addEventListener('scroll',draw);`;copy.querySelector('body').append(script);}fs.writeFileSync(path.join(output,name),'<!doctype html>'+copy.outerHTML);}
    exportPage('history.html');
    $('tab-practice').click();renderSessionResult(document,rich,summarizePractice(rich.pattern,rich.metrics));$('result').hidden=false;$('practiceContent').classList.add('showing-results');$('resultScore').removeAttribute('style');
    for(const copy of document.querySelectorAll('[data-text-from]'))copy.textContent=$(copy.dataset.textFrom).textContent;
    exportPage('results.html',true);
  }
  assert.deepEqual(failures,[]);console.log(`Desktop DOM integration passed: ${mode} (startup, restored editor, tabs, shared controls, history details, practice types, keyboard navigation).`);
}finally{window.dispatchEvent(new Event('pagehide'));dom.window.close();}
