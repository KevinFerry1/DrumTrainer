import {validateSettings} from './backup-state.mjs';
import {voices} from './core.mjs';
const mappings={
  'DrumTrainer.kickMonitor.enabled':'kickMonitor','DrumTrainer.kickMonitor.gainDB':'kickGain','DrumTrainer.kickMonitor.sound':'kickSound','DrumTrainer.kickMonitor.source':'kickMonitorSource',
  'DrumTrainer.metronome.gainDB':'clickGain','DrumTrainer.metronome.sound':'clickSound','DrumTrainer.metronome.limiterCeilingDBFS':'limiterCeiling',
  'DrumTrainer.practice.gradeKicks':'gradeKicks','DrumTrainer.practice.ghostVelocityCeiling':'ghostCeiling','DrumTrainer.practice.ghostVelocityCeilingEnabled':'ghostCeilingEnabled','DrumTrainer.practiceAudioRecording.enabled':'recordAudio',
};
export function importMacSetup(value){
  if(value?.format!=='DrumTrainerMacSetup'||value.version!==1||!value.preferences||typeof value.preferences!=='object'||Array.isArray(value.preferences))throw new Error('Choose the transferred Mac-setup-backup.json.');
  const prefs=value.preferences,settings={};for(const [from,to]of Object.entries(mappings))if(prefs[from]!=null)settings[to]=prefs[from];validateSettings(settings,voices);
  const profiles=prefs['DrumTrainer.microphoneCalibrationProfiles']??{};validateSettings({microphoneProfiles:profiles},voices);
  return{settings,microphoneProfiles:Object.values(profiles),nativeTimingProfiles:prefs['DrumTrainer.timingAlignmentProfiles']??[]};
}
