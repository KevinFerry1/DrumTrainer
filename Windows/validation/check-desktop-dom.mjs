// Integration check against the real HTML/app modules, without MIDI or audio hardware.
// Install jsdom@26 in a temporary directory; set DRUMTRAINER_TEST_MODULES to its node_modules.
// Run this file with each argument: builtIn, custom, sequence.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import path from 'node:path';
import {exercises,makePattern,score} from '../core.mjs';
const require=createRequire(path.join(process.env.DRUMTRAINER_TEST_MODULES,'package.json'));
const {JSDOM}=require('jsdom'),mode=process.argv[2]??'builtIn';
const dom=new JSDOM(fs.readFileSync(new URL('../index.html',import.meta.url),'utf8'),{url:'http://127.0.0.1:8765'});
const {window}=dom,{document}=window,$=id=>document.getElementById(id);
for(const key of ['window','document','navigator','localStorage','Option','Event'])globalThis[key]=window[key];
window.HTMLMediaElement.prototype.pause=()=>{};
window.HTMLDialogElement.prototype.showModal=function(){this.open=true;};
window.HTMLDialogElement.prototype.close=function(){this.open=false;this.dispatchEvent(new window.Event('close'));};
let drawFrame;globalThis.requestAnimationFrame=fn=>{drawFrame=fn;return 1;};globalThis.cancelAnimationFrame=()=>{};
globalThis.navigator.mediaDevices={enumerateDevices:async()=>[{kind:'audioinput',deviceId:'snowball',label:'Blue Snowball'},{kind:'audiooutput',deviceId:'scarlett',label:'Focusrite Scarlett'}],addEventListener:()=>{}};
const measure={...structuredClone(exercises[0]),name:'Transferred custom measure'};
const sequence={name:'Transferred sequence',subdivision:'sixteenths',hits:[],sequenceSteps:[{...structuredClone(measure),id:'step',repeats:2}],sequenceRepeats:1};
const library=[{id:'custom',definition:measure},{id:'sequence',definition:sequence}];
const pattern=makePattern(exercises[0],120,4),session={id:'fixture',date:new Date().toISOString(),name:pattern.name,bpm:120,pattern,metrics:score(pattern,[],{gradeKicks:true}),evidence:[],devices:{}};
const saved={exercises:library,sessions:[session],songs:[],nativeArchives:[]};
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
  assert.equal($('history').querySelectorAll('.history-row').length,1);
  assert.equal($('historyOverview').children.length,4);
  assert.ok($('historyTrend').querySelector('svg'));
  const bpmMirror=document.querySelector('[data-bind="bpm"]');bpmMirror.value='137';bpmMirror.dispatchEvent(new Event('change',{bubbles:true}));
  assert.equal($('bpm').value,'137');assert.equal(JSON.parse(localStorage.getItem('DrumTrainerWindows.settings.v1')).bpm,'137');
  $('bpmSlider').value='142';$('bpmSlider').dispatchEvent(new Event('input',{bubbles:true}));assert.equal($('bpm').value,'142');
  const outputMirror=document.querySelector('[data-bind="output"]');outputMirror.value='scarlett';outputMirror.dispatchEvent(new Event('change',{bubbles:true}));assert.equal($('output').value,'scarlett');await new Promise(resolve=>setTimeout(resolve,0));
  $('history').querySelector('button').click();assert.equal($('historyDetailDialog').open,true);assert.equal($('result').parentElement,$('historyDetailBody'));
  $('closeHistoryDetail').click();assert.equal($('result').parentElement,$('practiceContent'));assert.equal($('result').hidden,true);
  document.querySelector('[data-practice-type="song"]').click();assert.equal($('songPanel').hidden,false);
  document.querySelector('[data-practice-type="custom"]').click();assert.equal($('customEditorPanel').hidden,false);
  $('customSequenceMode').click();assert.equal($('sequenceEditor').hidden,false);assert.equal($('measureEditor').hidden,true);
  $('customMeasureMode').click();assert.equal($('measureEditor').hidden,false);
  document.querySelector('[data-practice-type="builtIn"]').click();assert.equal($('customEditorPanel').hidden,true);
  $('tab-practice').dispatchEvent(new window.KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));assert.equal($('panel-history').hidden,false);
  assert.deepEqual(failures,[]);console.log(`Desktop DOM integration passed: ${mode} (startup, restored editor, tabs, shared controls, history details, practice types, keyboard navigation).`);
}finally{window.dispatchEvent(new Event('pagehide'));dom.window.close();}
