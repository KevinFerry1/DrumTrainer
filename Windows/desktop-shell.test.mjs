import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {desktopTabs,historyValues} from './desktop-shell.mjs';

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
  const values=historyValues([{date:newer,s:{bpm:110,metrics:{recall:1,error:12,spread:8,clean:true},pattern:{duration:8000}}},{date:older,summaryOnly:true,s:{bpm:100,recall:.96,medianAbsoluteErrorMilliseconds:18,medianLimbSpreadMilliseconds:9,durationSeconds:10}}]);
  assert.deepEqual(values.map(s=>[s.date,s.duration,s.clean,s.error,s.spread]),[[older,10,true,18,9],[newer,8,true,12,8]]);
});
test('native history trend keeps raw timing while clean qualification uses eligible bias adjustment',()=>{
  const [value]=historyValues([{date:new Date(),summaryOnly:true,s:{recall:1,medianAbsoluteErrorMilliseconds:75,latencyAdjustedMedianErrorMilliseconds:10}}]);
  assert.equal(value.error,75);assert.equal(value.clean,true);assert.equal(value.duration,0);
  assert.equal(historyValues([{date:new Date(),summaryOnly:true,s:{recall:1,medianAbsoluteErrorMilliseconds:10,droppedEventCount:1}}])[0].clean,false);
});
test('portable runtime and server include the desktop shell',()=>{
  for(const file of ['package.py','Start-DrumTrainer.ps1'])assert.ok(fs.readFileSync(new URL(file,import.meta.url),'utf8').includes('desktop-shell.mjs'));
});
