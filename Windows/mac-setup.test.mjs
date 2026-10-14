import test from 'node:test';import assert from 'node:assert/strict';import {importMacSetup} from './mac-setup.mjs';
test('Mac setup restores supported sound/dynamics choices and preserves timing without applying Mac latency or device IDs',()=>{
 const result=importMacSetup({format:'DrumTrainerMacSetup',version:1,preferences:{'DrumTrainer.metronome.sound':'woodblock','DrumTrainer.metronome.gainDB':21,'DrumTrainer.practice.ghostVelocityCeiling':70,'DrumTrainer.practice.gradeKicks':false,'DrumTrainer.timingAlignmentProfiles':[{compensationMilliseconds:25}],'DrumTrainer.practiceAudioRecording.inputUID':'native-device'}});
 assert.deepEqual(result.settings,{clickSound:'woodblock',clickGain:21,ghostCeiling:70,gradeKicks:false});assert.equal(result.nativeTimingProfiles.length,1);assert.equal(result.settings.corrections,undefined);assert.equal(result.settings.recordInput,undefined);
});
test('invalid Mac setup and unsupported sound values leave current settings untouched',()=>{
 assert.throws(()=>importMacSetup({}));assert.throws(()=>importMacSetup({format:'DrumTrainerMacSetup',version:1,preferences:{'DrumTrainer.metronome.sound':'invalid'}}));assert.throws(()=>importMacSetup({format:'DrumTrainerMacSetup',version:1,preferences:{'DrumTrainer.metronome.gainDB':500}}));
});
