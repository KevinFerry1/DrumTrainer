import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
import {TimingAlignmentCollector} from './timing-alignment.mjs';
const fixtures=JSON.parse(fs.readFileSync(new URL('./validation/native-fixtures.json',import.meta.url)));
for(const f of fixtures.alignment??[])test(`Swift hit alignment: ${f.name}`,()=>{
  const collector=new TimingAlignmentCollector(f.source,f.voice??null);f.references.forEach(t=>collector.recordReference(t));f.events.forEach(e=>collector.record(e));assert.deepEqual(collector.measurement(f.maximumOffsetMilliseconds),f.measurement??null);
});
