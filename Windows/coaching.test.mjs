import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {nativeScore} from './native-scoring.mjs';
import {summarizePractice} from './coaching.mjs';
const archive=JSON.parse(fs.readFileSync(new URL('./validation/native-fixtures.json',import.meta.url)));
for(const f of archive.scoring)test(`Swift coaching parity: ${f.name}`,()=>{
  const pattern={expectedEvents:f.expected,notes:f.expected};
  const m=nativeScore(pattern,f.actual.map(a=>({...a,velocityNormalized:a.velocity??null})),{gradeKicks:f.gradeKicks,corrections:f.corrections,voiceCorrections:f.voiceCorrections});
  assert.deepEqual(summarizePractice(pattern,m),f.coaching);
});
