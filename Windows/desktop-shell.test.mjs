import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {desktopTabs,historyValues} from './desktop-shell.mjs';
import {historySessionClean} from './results-view.mjs';

test('Mac-style tabs have unique, connected and accessible panels',()=>{
  const html=fs.readFileSync(new URL('./index.html',import.meta.url),'utf8');
  const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
  assert.equal(ids.length,new Set(ids).size);
  for(const tab of desktopTabs){
    assert.ok(html.includes(`id="tab-${tab}" role="tab" aria-controls="panel-${tab}"`));
    assert.ok(html.includes(`id="panel-${tab}"`));
    assert.ok(html.includes(`role="tabpanel" aria-labelledby="tab-${tab}"`));
  }
  for(const match of html.matchAll(/data-(?:bind|action|text-from)="([^"]+)"/g))assert.ok(ids.includes(match[1]),`Missing shared control ${match[1]}`);
});
test('history combines native summaries and Windows evidence in chronological order',()=>{
  const newer=new Date('2026-10-15'),older=new Date('2026-10-13');
  const values=historyValues([{date:newer,s:{bpm:110,metrics:{recall:1,error:12,spread:8,clean:true},pattern:{duration:8000}}},{date:older,summaryOnly:true,s:{totalExpected:8,bpm:100,recall:.96,medianAbsoluteErrorMilliseconds:18,medianLimbSpreadMilliseconds:9,durationSeconds:10}}]);
  assert.deepEqual(values.map(s=>[s.date,s.duration,s.clean,s.error,s.spread]),[[older,10,true,18,9],[newer,8,true,12,8]]);
});
test('native history trend keeps raw timing while clean qualification uses eligible bias adjustment',()=>{
  const [value]=historyValues([{date:new Date(),summaryOnly:true,s:{totalExpected:8,recall:1,medianAbsoluteErrorMilliseconds:75,latencyAdjustedMedianErrorMilliseconds:10}}]);
  assert.equal(value.error,75);assert.equal(value.clean,true);assert.equal(value.duration,0);
  assert.equal(historyValues([{date:new Date(),summaryOnly:true,s:{totalExpected:8,recall:1,medianAbsoluteErrorMilliseconds:10,droppedEventCount:1}}])[0].clean,false);
});
test('portable runtime and server include the desktop shell',()=>{
  for(const file of ['package.py','Start-DrumTrainer.ps1'])for(const module of ['desktop-shell.mjs','results-view.mjs'])assert.ok(fs.readFileSync(new URL(file,import.meta.url),'utf8').includes(module));
});
test('history Clean seal uses native qualification including dynamics and scored expectations',()=>{
  const summary={totalExpected:8,recall:1,medianAbsoluteErrorMilliseconds:15,droppedEventCount:0};
  assert.equal(historySessionClean({s:summary,summaryOnly:true}),true);
  for(const patch of [{totalExpected:0},{droppedEventCount:1},{recall:.94},{medianAbsoluteErrorMilliseconds:26},{accentMetrics:{accuracy:.89}},{ghostMetrics:{accuracy:.89}}])assert.equal(historySessionClean({s:{...summary,...patch},summaryOnly:true}),false,JSON.stringify(patch));
  assert.equal(historySessionClean({s:{...summary,medianAbsoluteErrorMilliseconds:55,latencyAdjustedMedianErrorMilliseconds:5},summaryOnly:true}),true);
  assert.equal(historySessionClean({s:{...summary,accentMetrics:{expectedCount:0,accuracy:1}},summaryOnly:true}),false);
  assert.equal(historySessionClean({s:{...summary,accentMetrics:{expectedCount:1,accuracy:.9}},summaryOnly:true}),true);
  assert.equal(historySessionClean({s:{metrics:{clean:false}}}),false);
});
