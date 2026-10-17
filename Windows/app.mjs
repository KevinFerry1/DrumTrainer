import {renderSessionResult,drawResultScore,historySessionRow,historySessionClean,exerciseProgressTable} from './results-view.mjs';
import {initializeDesktopShell,historyValues} from './desktop-shell.mjs';
import {voices,gm,exercises,subdivisions,makePattern,score,median,importBackup} from './core.mjs';
import {analyzeNoise,makeCalibrationProfile,CalibrationHitCollector,CrosstalkGuard,soundSimilarity} from './audio-core.mjs';
import {parseMIDI,validateSong,songMeasures,songBPM,firstSongMeasure,makeSongPattern,importedGM} from './midi.mjs';
import {convertNativeArchives,rescoreSession,compactSession,hydrateSession} from './legacy-data.mjs';
import {emptyProgress,exerciseIdentity,prepareCeiling,recordProgress,mergeNativeProgress} from './practice-progress.mjs';
import {clickSounds,kickSounds,clickSamples,kickSamples,kickDynamics} from './sound-synthesis.mjs';
import {importMacSetup} from './mac-setup.mjs';
import {TimingAlignmentCollector} from './timing-alignment.mjs';
import {PlaybackCapture} from './playback-capture.mjs';
import {playbackStart} from './playback-onset.mjs';
import {portableZIP} from './portable-zip.mjs';
import {timingTimeline,filterTimeline,renderTimingChart} from './timing-timeline.mjs';
import {evaluateDynamics} from './native-scoring.mjs';
import {drawNotation} from './notation.mjs';
import {summarizePractice} from './coaching.mjs';
import {SessionRecorder,getTake,allTakes,saveTake,deleteTake as removeTake} from './recordings.mjs';
const $ = id => document.getElementById(id);
const text = (id,value) => { $(id).textContent = value; };
const notice = message => text('notice',message);
const ms = v => v == null ? '—':`${v.toFixed(1)} ms`;
const percent = v => `${Math.round(v*100)}%`;
const key = 'DrumTrainerWindows.settings.v1';
let settings = {};
try { settings = JSON.parse(localStorage.getItem(key) ?? '{}'); } catch { /* Default settings remain usable. */ }
let library = [], sessions = [], nativeArchives = [], db = null;
let songs = [], progress = emptyProgress(), deletedSessionIDs = [], deletedSongIDs = [], historyLimit = 50;
let audio, midiAccess, stream, micNode, micSource, micMute, clickBus, scheduler, animation, autoTimer;
let pendingAlignment=null;
let playbackCapture=null,playbackTimeout=null;
let ledgerLimit=200;
let run = null, count = 0, peak = 0, noisePeaks = null, currentResult = null;
let calibration = null, pendingProfile = null, soundRejected = 0, crosstalkRejected = 0, micEpoch = 0;
let audioInitialization = null, outputProcessor = null, nextKickVoice = 0, lastMonitoredKick = -Infinity;
let activeRecorder = null, starting = null, finishing = false, finishGeneration = 0, displayedTake = null, takeURL = null;
const soundBuffers = new Map(), kickVoices = Array(6).fill(null);
const crosstalk = new CrosstalkGuard();
const scheduled = new Set(), recent = [], lastKick = new Map();
let draftRevision=0,liveSimulationTimer=null,autoGoDeadline=0;
let draft = {name:'My custom measure',subdivision:'sixteenths',hits:[]};
let sequenceDraft = {name:'My sequence',subdivision:'sixteenths',hits:[],sequenceSteps:[],sequenceRepeats:1};
const mergeByID = (old,added) => { const values=new Map(old.map(v=>[v.id,v])); added.forEach(v=>{if(!values.has(v.id))values.set(v.id,v);}); return [...values.values()]; };

const desktop=initializeDesktopShell({onTabChange:(tab,previous)=>{if(previous==='practice'){clearAuto();if(!run)$('stop').disabled=true;}if(tab!=='live')stopLiveSimulation();},onPracticeType:setPracticeType,onReturnSetup:()=>{cancel();currentResult=null;}});
function stopLiveSimulation(){clearInterval(liveSimulationTimer);liveSimulationTimer=null;$('liveSimulation').textContent='Start Test Simulation';}
function setPracticeType(type){
  cancel();currentResult=null;$('result').hidden=true;
  const custom=type==='custom';$('customEditorPanel').dataset.editing=String(custom);$('practiceMode').value=type==='song'?'song':'exercise';
  if(type==='builtIn'&&library.some(e=>e.id===$('exercise').value))$('exercise').value=exercises[0].id;
  if(custom&&library.length&&!library.some(e=>e.id===$('exercise').value)){$('exercise').value=library[0].id;$('loadExercise').click();}
  updateGuide();saveSettings();desktop.sync();
}
function showHistoryDetail(session){cancel();showResult(session);$('historyDetailBody').append($('result'));$('historyDetailDialog').showModal();desktop.sync();}
$('closeHistoryDetail').onclick=()=>{$('historyDetailDialog').close();};
$('historyDetailDialog').addEventListener('close',()=>{$('practiceContent').append($('result'));$('result').hidden=true;currentResult=null;desktop.sync();});

function openDatabase() {
  return new Promise((resolve,reject) => {
    const req = indexedDB.open('DrumTrainerWindows',2);
    req.onupgradeneeded = () => { for(const store of ['data','takes','takeChunks'])if(!req.result.objectStoreNames.contains(store))req.result.createObjectStore(store); };
    req.onblocked = () => notice('Close older DrumTrainer tabs so the recording database can update.');
    req.onerror = () => reject(req.error);
    req.onsuccess = () => resolve(req.result);
  });
}
function readDatabase() {
  return new Promise((resolve,reject) => {
    const req = db.transaction('data').objectStore('data').get('practice');
    req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error);
  });
}
async function persist() {
  try {
    if (!db) throw new Error('Browser storage is unavailable.');
    await new Promise((resolve,reject) => {
      const tx = db.transaction('data','readwrite');
      tx.objectStore('data').put({exercises:library,sessions:sessions.map(compactSession),nativeArchives,songs,progress,deletedSessionIDs,deletedSongIDs},'practice');
      tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error);
    });
  } catch (error) { notice(`Could not save practice data: ${error.message} Export a backup now to keep this session.`); }
}
try {
  db = await openDatabase(); const saved = await readDatabase();
  db.onversionchange=()=>{cancel('The app database was updated. Reload this window before continuing.');db.close();db=null;};
  if (saved) { library = saved.exercises ?? []; sessions = (saved.sessions ?? []).map(hydrateSession); nativeArchives = saved.nativeArchives ?? []; songs = saved.songs ?? []; progress = saved.progress ?? emptyProgress(); deletedSessionIDs = saved.deletedSessionIDs ?? []; deletedSongIDs = saved.deletedSongIDs ?? []; }
  if (nativeArchives.length) {
    const converted=convertNativeArchives(nativeArchives),before=sessions.length+songs.length;
    sessions=mergeByID(sessions,converted.sessions.filter(s=>!deletedSessionIDs.includes(s.id)));
    songs=mergeByID(songs,converted.songs.filter(s=>!deletedSongIDs.includes(s.id))); mergeNativeProgress(progress,nativeArchives);
    if (before !== sessions.length+songs.length) await persist();
  }
} catch (error) { notice(`Browser storage is unavailable. Practice still works; export a backup to keep your results. ${error.message}`); }

for(const [id,label]of Object.entries(clickSounds))$('clickSound').append(new Option(label,id));
for(const [id,label]of Object.entries(kickSounds))$('kickSound').append(new Option(label,id));
const settingControls = ['bpm','repeats','volume','kickSource','gradeKicks','threshold','lockout','auto','advance','soundFilter','guard','match','autoDelay','cleanRuns','advanceStep','ceiling','ceilingStep','practiceMode','sectionStart','sectionEnd','tolerance','accentFloorEnabled','accentFloor','accentContrast','ghostCeilingEnabled','ghostCeiling','ghostContrast','clickSound','clickGain','limiter','limiterCeiling','kickMonitor','kickMonitorSource','kickSound','kickGain','kickVelocity','kickMonitorLockout','recordAudio','recordInput','recordChannels','scoreView','externalPlayback','playbackOffset','playbackThreshold'];
for (const id of settingControls) {
  if (settings[id] != null) {
    if ($(id).type === 'checkbox') $(id).checked = settings[id] === true;
    else $(id).value = settings[id];
  }
}
function saveSettings() {
  for (const id of settingControls) settings[id] = $(id).type === 'checkbox' ? $(id).checked : $(id).value;
  if($('practiceMode').value==='song'&&selectedSong()&&Number($('sectionStart').value)>0){settings.songSections??={};settings.songSections[selectedSong().id]={start:Number($('sectionStart').value),end:Number($('sectionEnd').value),bpm:Number($('bpm').value)};}
  settings.desktopPracticeType=$('practiceMode').value==='song'?'song':$('customEditorPanel').dataset.editing==='true'?'custom':'builtIn';settings.desktopSequence=$('customEditorPanel').dataset.sequence==='true';
  if (!calibration) { settings.detectors ??= {}; settings.detectors[$('microphone').value] = {threshold:Number($('threshold').value),lockout:Number($('lockout').value)}; }
  try { localStorage.setItem(key,JSON.stringify(settings)); } catch { notice('Settings could not be saved. Export practice data before closing.'); }
}
if (settings.draft) draft = settings.draft;
if (settings.sequenceDraft) sequenceDraft = settings.sequenceDraft;
function scoringOptions() {
  const options={tolerance:Number($('tolerance').value),accentFloor:$('accentFloorEnabled').checked?Number($('accentFloor').value):null,accentContrast:Number($('accentContrast').value),ghostCeiling:$('ghostCeilingEnabled').checked?Number($('ghostCeiling').value):null,ghostContrast:Number($('ghostContrast').value)};
  if(!Number.isFinite(options.tolerance)||options.tolerance<0||options.tolerance>500||[options.accentFloor,options.accentContrast,options.ghostCeiling,options.ghostContrast].some(v=>v!=null&&(!Number.isFinite(v)||v<1||v>127)))throw new Error('Use a valid match tolerance and dynamics values from 1 to 127.');
  return options;
}
function selectedSong() { return songs.find(s=>s.id===$('song').value); }
function currentIdentity() {
  const song=$('practiceMode').value==='song'?selectedSong():null,definition=selectedDefinition(),saved=library.find(e=>e.id===$('exercise').value);
  const identity={name:song?.name??definition.name,kind:song?'importedSong':saved||$('customEditorPanel').dataset.editing==='true'?'custom':'builtIn',customExerciseID:saved?.id??null,importedSongID:song?.id??null};
  identity.id=exerciseIdentity(identity);return identity;
}
function selectedPattern() {
  if($('practiceMode').value==='song') { const song=selectedSong();if(!song)throw new Error('Import or select a MIDI song first.');return makeSongPattern(song,{startMeasure:Number($('sectionStart').value),endMeasure:Number($('sectionEnd').value),repeats:Number($('repeats').value),targetBPM:Number($('bpm').value),tolerance:scoringOptions().tolerance}); }
  return makePattern(selectedDefinition(),Number($('bpm').value),Number($('repeats').value),scoringOptions());
}
let previewCache={key:null,pattern:null};
function previewPattern(){
  const d=selectedDefinition(),song=selectedSong(),key=JSON.stringify([draftRevision,$('practiceMode').value,$('exercise').value,library.find(e=>e.id===$('exercise').value)?.updatedAt,song?.id,song?.updatedAt,song?.selectedTrackIndex,$('bpm').value,$('repeats').value,$('sectionStart').value,$('sectionEnd').value,scoringOptions(),d.name]);
  if(previewCache.key!==key){previewCache={key,pattern:selectedPattern()};}return previewCache.pattern;
}
function renderSequence(){
  draftRevision++;
  $('sequenceName').value=sequenceDraft.name;$('sequenceRepeats').value=sequenceDraft.sequenceRepeats??1;$('sequenceSteps').replaceChildren();
  sequenceDraft.sequenceSteps.forEach((step,index)=>{
    const row=document.createElement('div');row.className='history-row';const label=document.createElement('span');label.textContent=`${index+1}. ${step.name}`;
    const repeats=document.createElement('input');repeats.type='number';repeats.min='1';repeats.max='16';repeats.value=step.repeats;repeats.style.width='65px';repeats.setAttribute('aria-label',`Repeats for sequence step ${index+1}`);repeats.onchange=()=>{step.repeats=Math.min(Math.max(Number(repeats.value)||1,1),16);saveSequenceDraft();};row.append(label,repeats);
    for(const [name,action]of [['↑',()=>{if(index>0)[sequenceDraft.sequenceSteps[index-1],sequenceDraft.sequenceSteps[index]]=[step,sequenceDraft.sequenceSteps[index-1]];}],['↓',()=>{if(index+1<sequenceDraft.sequenceSteps.length)[sequenceDraft.sequenceSteps[index+1],sequenceDraft.sequenceSteps[index]]=[step,sequenceDraft.sequenceSteps[index+1]];}],['Remove',()=>sequenceDraft.sequenceSteps.splice(index,1)]]){
      const button=document.createElement('button');button.className='secondary';button.textContent=name;button.setAttribute('aria-label',`${name} sequence step ${index+1}`);button.onclick=()=>{action();saveSequenceDraft();renderSequence();};row.append(button);
    }$('sequenceSteps').append(row);
  });
}
function saveSequenceDraft(){sequenceDraft.name=$('sequenceName').value.trim()||'Sequence';sequenceDraft.sequenceRepeats=Math.min(Math.max(Number($('sequenceRepeats').value)||1,1),16);settings.sequenceDraft=structuredClone(sequenceDraft);saveSettings();}
async function saveDefinition(definition,update=false){
  makePattern(definition,120,1,scoringOptions());const saved=library.find(e=>e.id===$('exercise').value);
  if(update&&!saved)throw new Error('Select a saved custom exercise to update.');
  let id;
  if(update){saved.definition=structuredClone(definition);saved.updatedAt=new Date().toISOString();id=saved.id;}
  else{if(library.length>=1000)throw new Error('Exercise library is full.');id=crypto.randomUUID();const now=new Date().toISOString();library.push({id,instrument:'drums',definition:structuredClone(definition),createdAt:now,updatedAt:now});}
  await persist();refreshExercises();$('exercise').value=id;$('practiceMode').value='exercise';updateGuide();saveSettings();notice(update?'Saved exercise updated.':'New exercise copy saved.');
}
function renderProgressStatus() {
  const identity=currentIdentity(),p=progress.tempoProgressions.find(p=>p.id===identity.id),c=progress.ceilingRecords.find(c=>c.id===identity.id),active=progress.activeCeilingRun;
  const parts=[];if(p)parts.push(`Best clean ${p.highestCleanBPM??'—'} BPM · ${p.consecutiveCleanSessions}/${$('cleanRuns').value} clean runs · next raise ${Math.min(Number($('bpm').value)+Number($('advanceStep').value),240)} BPM`);
  if(c)parts.push(`Verified ceiling ${c.highestVerifiedBPM} BPM`);if(active?.exerciseID===identity.id)parts.push(`Ceiling search: ${active.phase.kind}${active.phase.bpm?` at ${active.phase.bpm} BPM`:''}`);
  text('progressStatus',parts.join(' · '));
}
const inputKey = source => `${source}/${source === 'midi' ? $('midi').value : $('microphone').value}/${$('output').value}`;
function microphoneProfile() { return settings.microphoneProfiles?.[$('microphone').value] ?? null; }
function loadMicrophoneProfile() {
  const profile = microphoneProfile(), config = settings.detectors?.[$('microphone').value];
  $('threshold').value = config?.threshold ?? profile?.suggestedThreshold ?? settings.threshold ?? .12;
  $('lockout').value = config?.lockout ?? profile?.retriggerLockoutMilliseconds ?? settings.lockout ?? 40;
  text('calibrationStatus',profile ? `Sound filter: ${profile.kickSoundSignature ? 'Learned':'No fingerprint'} · ${profile.quality} separation · ${profile.detectedHitCount} kicks · ${profile.signalToNoiseDecibels.toFixed(1)} dB signal/noise` : 'No learned kick profile. Calibrate with 10 isolated kicks and 10 kicks while adding other pads.');
}
function cancelCalibration() {
  if (!calibration && !pendingProfile) return;
  calibration = null; pendingProfile = null; noisePeaks = null; $('saveCalibration').disabled = true;
  loadMicrophoneProfile(); micNode?.port.postMessage(detectorSettings());
}
async function calibrateKicks() {
  if (!stream) throw new Error('Enable the kick microphone first.');
  cancel(); pendingProfile = null; $('saveCalibration').disabled = true;
  const attempt = {stage:'noise',deviceUID:$('microphone').value,deviceName:$('microphone').selectedOptions[0].textContent,collector:new CalibrationHitCollector(Number($('lockout').value))};
  calibration = attempt; noisePeaks = []; setRunning(true);
  notice('Stay quiet for 3 seconds. Kick calibration is measuring room noise.');
  await new Promise(resolve => setTimeout(resolve,3000));
  if (calibration !== attempt) return;
  attempt.noise = analyzeNoise(noisePeaks); noisePeaks = null;
  if (!attempt.noise || attempt.noise.sampleCount < 10) { cancel('Noise measurement interrupted. Re-enable the microphone and try again.'); return; }
  $('threshold').value = attempt.noise.collectionThreshold.toFixed(3); micNode.port.postMessage(detectorSettings());
  attempt.stage = 'hits'; notice('Kick calibration: play 10 isolated kick strikes, spaced at least 180 ms apart. 0 of 20 collected.');
}
function collectKick(hit) {
  if (calibration?.stage !== 'hits') return;
  const {collector} = calibration;
  if (!collector.record(hit.amplitude,hit.audioFeatures,hit.clock)) return;
  const count = collector.amplitudes.length;
  if (count < 20) { notice(`Kick calibration: ${count} of 20 collected. ${count < 10 ? 'Keep playing isolated kicks.':'Keep kicking while adding simultaneous snare, tom, and cymbal hits.'}`); return; }
  pendingProfile = makeCalibrationProfile({deviceUID:calibration.deviceUID,deviceName:calibration.deviceName,noise:calibration.noise,hitAmplitudes:collector.amplitudes,hitSoundFeatures:collector.soundFeatures,retriggerLockoutMilliseconds:collector.suggestedLockoutMilliseconds});
  calibration = null; setRunning(false); $('saveCalibration').disabled = false;
  loadMicrophoneProfile(); micNode?.port.postMessage(detectorSettings());
  notice(`Calibration ready: ${pendingProfile.quality} separation, ${pendingProfile.signalToNoiseDecibels.toFixed(1)} dB signal/noise, threshold ${pendingProfile.suggestedThreshold.toFixed(3)}, lockout ${pendingProfile.retriggerLockoutMilliseconds} ms. Review and choose Save calibration.`);
}
function receiveMicrophone(data,node) {
  const hit={voice:'kick',source:'microphone',velocity:null,amplitude:data.amplitude,audioFeatures:data.features,clock:data.time,rawTimestamp:data.time,receivedAt:performance.now(),threshold:Number($('threshold').value)};
  if (run?.kind === 'alignment' && run.source === 'microphone') { receive(hit); return; }
  const collecting = calibration?.stage === 'hits';
  if (collecting) collectKick(hit);
  const epoch = micEpoch;
  setTimeout(() => {
    if (micNode !== node || epoch !== micEpoch) return;
    const profile = microphoneProfile(), similarity = soundSimilarity(hit.audioFeatures,profile?.kickSoundSignature),minimumSimilarity = Number($('match').value);
    if (similarity != null) text('calibrationStatus',`Sound filter: Learned · last match ${Math.round(similarity*100)}% · ${profile.quality} separation`);
    if (!collecting && $('soundFilter').checked && similarity != null && similarity < minimumSimilarity) soundRejected++;
    else {
      crosstalk.enabled = $('guard').checked;
      if (crosstalk.shouldSuppress({amplitude:hit.amplitude,threshold:hit.threshold,weakestKick:profile?.weakestHitAmplitude,similarity,minimumSimilarity,time:hit.clock-(corrections().microphone ?? 0)})) crosstalkRejected++;
      else receive(hit);
    }
    text('filtered',`Sound rejected: ${soundRejected} · Crosstalk rejected: ${crosstalkRejected}`);
  },$('guard').checked ? 20:0);
}
function loadCorrections() {
  $('midiCorrection').value = settings.corrections?.[inputKey('midi')] ?? 0;
  $('micCorrection').value = settings.corrections?.[inputKey('microphone')] ?? 0;
}
function corrections() { return {midi:Number($('midiCorrection').value),microphone:Number($('micCorrection').value),simulation:0}; }
function saveCorrection(source,value) {
  settings.corrections ??= {}; settings.corrections[inputKey(source)] = value;
  loadCorrections(); saveSettings();
}
function selectedDefinition() {
  if($('practiceMode').value!=='song'&&$('customEditorPanel').dataset.editing==='true')return $('customEditorPanel').dataset.sequence==='true'?sequenceDraft:draft;
  return exercises.find(e => e.id === $('exercise').value) ?? library.find(e => e.id === $('exercise').value)?.definition ?? exercises[0];
}
function refreshExercises() {
  const previous = $('exercise').value || settings.exercise;
  $('exercise').replaceChildren();
  const built = document.createElement('optgroup'); built.label = 'Exercise library';
  exercises.forEach(e => built.append(new Option(e.name,e.id)));
  $('exercise').append(built);
  if (library.length) {
    const saved = document.createElement('optgroup'); saved.label = 'Your saved exercises';
    library.forEach(e => saved.append(new Option(`${e.definition.name}${e.definition.sequenceSteps ? ' · sequence':''}`,e.id)));
    $('exercise').append(saved);
  }
  if ([...$('exercise').options].some(o => o.value === previous)) $('exercise').value = previous;
  updateGuide();
  refreshSequenceMeasures();
}
function updateGuide() {
  const d = selectedDefinition();
  text('exerciseDifficulty',d.difficulty??'');
  const songMode=$('practiceMode').value==='song';$('songPanel').hidden=!songMode;
  text('guide',songMode?'Practice a mapped MIDI track with its tempo and meter changes; loop the selected section at your chosen tempo.':d.guide ?? (d.sequenceSteps ? 'Saved measure sequence. The sequence’s own repeats determine its length.' : 'Your custom measure, repeated on the selected grid.'));
  $('exercise').disabled=songMode||!!run;$('repeats').disabled=(!songMode&&!!d.sequenceSteps)||!!run;
  $('start').textContent=songMode&&$('externalPlayback').checked?'Arm Songsterr companion':'Start exercise';
  settings.exercise = $('exercise').value;
  renderProgressStatus();
}
function refreshSongs() {
  const previous=$('song').value||settings.song;$('song').replaceChildren(new Option('Select a song',''));
  songs.forEach(s=>$('song').append(new Option(s.name,s.id)));if(songs.some(s=>s.id===previous))$('song').value=previous;else if(songs.length)$('song').value=songs[0].id;
  renderSong();
  if(selectedSong()&&!settings.songSections?.[selectedSong().id]){const bpm=$('bpm').value;chooseSong();if($('practiceMode').value!=='song'){$('bpm').value=bpm;saveSettings();}}
}
function renderSong() {
  const song=selectedSong();$('songTrack').replaceChildren();$('songMap').replaceChildren();
  if(!song){text('songInfo','Import a Standard MIDI format 0/1 file or a Mac backup with songs.');return;}
  for(const track of song.tracks)$('songTrack').append(new Option(`${track.name||`Track ${track.index+1}`} · ${track.notes.length} notes`,track.index));$('songTrack').value=String(song.selectedTrackIndex);
  const track=song.tracks.find(t=>t.index===song.selectedTrackIndex),measures=songMeasures(song),counts=new Map();track.notes.forEach(n=>counts.set(n.noteNumber,(counts.get(n.noteNumber)??0)+1));
  const known=new Map(song.noteMappings.map(n=>[n.noteNumber,n.voice]));for(const noteNumber of counts.keys())if(!known.has(noteNumber))song.noteMappings.push({noteNumber,voice:importedGM[noteNumber]??'unknown'});
  for(const noteNumber of [...counts.keys()].sort((a,b)=>a-b)){
    const row=document.createElement('label');row.textContent=`Note ${noteNumber} · ${counts.get(noteNumber)} hits`;const select=document.createElement('select');optionVoices(select);select.value=song.noteMappings.find(n=>n.noteNumber===noteNumber).voice;
    select.onchange=withError(async()=>{cancel();song.noteMappings.find(n=>n.noteNumber===noteNumber).voice=select.value;song.updatedAt=new Date().toISOString();await persist();renderSong();});row.append(select);$('songMap').append(row);
  }
  $('sectionStart').max=String(measures.length);$('sectionEnd').max=String(measures.length);
  text('songInfo',`${measures.length} measures · source ${songBPM(song,measures[Math.max(0,Number($('sectionStart').value)-1)]?.startTick??0).toFixed(1)} BPM · ${song.tempoChanges.length} tempo changes · ${song.timeSignatureChanges.length} meter changes`);
}
function chooseSong() {
  const song=selectedSong();if(!song)return;const start=firstSongMeasure(song,$('gradeKicks').checked),measures=songMeasures(song),saved=settings.songSections?.[song.id];
  $('sectionStart').value=saved?.start??start;$('sectionEnd').value=saved?.end??Math.min(start+3,measures.length);$('bpm').value=saved?.bpm??Math.min(Math.max(songBPM(song,measures[start-1].startTick),40),240);settings.song=song.id;renderSong();updateGuide();saveSettings();
  settings.songSections??={};settings.songSections[song.id]={start:Number($('sectionStart').value),end:Number($('sectionEnd').value),bpm:Number($('bpm').value)};saveSettings();
}
function refreshSequenceMeasures() {
  const previous=$('sequenceMeasure').value;$('sequenceMeasure').replaceChildren();
  library.filter(e=>!e.definition.sequenceSteps).forEach(e=>$('sequenceMeasure').append(new Option(e.definition.name,e.id)));if([...$('sequenceMeasure').options].some(o=>o.value===previous))$('sequenceMeasure').value=previous;
}
function optionVoices(select) { for (const [v,label] of Object.entries(voices)) select.append(new Option(label,v)); }
optionVoices($('mapVoice'));
loadCorrections(); refreshExercises();

async function ensureAudio() {
  if(!audio||audio.state==='closed') {
    if(!audioInitialization)audioInitialization=(async()=>{
      const context=new AudioContext({latencyHint:'interactive'});audio=context;soundBuffers.clear();
      try{
        clickBus=context.createGain();await context.audioWorklet.addModule('output-worklet.mjs');
        const processor=new AudioWorkletNode(context,'drum-output',{outputChannelCount:[2]});outputProcessor=processor;
        clickBus.connect(processor);processor.connect(context.destination);
        processor.port.onmessage=({data})=>{if(outputProcessor===processor)text('outputMeter',`App output: ${data.peakDBFS.toFixed(1)} dBFS peak · ${data.rmsDBFS.toFixed(1)} dBFS RMS · ${data.limiterReductionDB.toFixed(1)} dB reduction`);};
        configureOutput();
        context.addEventListener('statechange',()=>{if(context.state!=='running'&&run)cancel('Audio paused or disconnected. The attempt was discarded; press Start to try again.');});
        if($('output').value){if(!context.setSinkId)throw new Error('Select the output in Windows sound settings.');try{await context.setSinkId($('output').value);}catch(error){$('output').value='';loadCorrections();throw error;}}
        if(!context.setSinkId)text('outputHelp','This browser uses the Windows default output. Choose the Focusrite/headphones in Windows sound settings.');
      }catch(error){await context.close();if(audio===context){audio=null;clickBus=null;outputProcessor=null;}throw error;}
      finally{audioInitialization=null;}
    })();
    await audioInitialization;
  }else if(audioInitialization)await audioInitialization;
  await audio.resume();if(audio.state!=='running')throw new Error('Audio could not start. Check the selected output.');return audio;
}
// Translate MIDI's monotonic performance timestamp to the output's audible audio clock.
function audibleTime(performanceMs = performance.now()) {
  const stamp = audio?.getOutputTimestamp?.();
  if (stamp?.contextTime > 0 && stamp.performanceTime > 0) return stamp.contextTime*1000+performanceMs-stamp.performanceTime;
  return (audio.currentTime-(audio.outputLatency ?? 0)-(audio.baseLatency ?? 0))*1000+performanceMs-performance.now();
}
function clickAt(time,accent) {
  const sound=$('clickSound').value,gain=Number($('clickGain').value),key=`click/${sound}/${accent}/${gain}`;
  const node=audio.createBufferSource();node.buffer=audioBuffer(key,()=>clickSamples(audio.sampleRate,sound,accent,gain));node.connect(clickBus);node.start(time);scheduled.add(node);
  node.onended=()=>{scheduled.delete(node);node.disconnect();};
}
function audioBuffer(key,make){if(!soundBuffers.has(key)){const samples=make(),buffer=audio.createBuffer(1,samples.length,audio.sampleRate);buffer.copyToChannel(samples,0);soundBuffers.set(key,buffer);if(soundBuffers.size>150)soundBuffers.delete(soundBuffers.keys().next().value);}return soundBuffers.get(key);}
function configureOutput(){
  const gain=Number($('clickGain').value),ceiling=Number($('limiterCeiling').value),kickGain=Number($('kickGain').value),lockout=Number($('kickMonitorLockout').value);
  if(!Number.isFinite(gain)||gain<-36||gain>24||!Number.isFinite(ceiling)||ceiling<-12||ceiling>-.5||!Number.isFinite(kickGain)||kickGain<-36||kickGain>6||!Number.isFinite(lockout)||lockout<10||lockout>150)throw new Error('Use valid click/kick gain, limiter ceiling and monitor lockout values.');
  outputProcessor?.port.postMessage({enabled:$('limiter').checked,ceilingDBFS:ceiling});
}
function reinforceKick(hit,test=false){
  if(!audio||!clickBus||(!test&&(!$('kickMonitor').checked||calibration||run?.kind==='alignment'||hit.voice!=='kick')))return;
  const source=$('kickMonitorSource').value;if(!test&&source!=='both'&&source!==hit.source)return;
  if(!test&&hit.clock-lastMonitoredKick<Number($('kickMonitorLockout').value))return;
  lastMonitoredKick=hit.clock;
  const rawVelocity=hit.velocity!=null?hit.velocity/127:Math.min(Math.max((hit.amplitude-Number($('threshold').value))/Math.max(1-Number($('threshold').value),1e-6),0),1);
  const dynamics=kickDynamics(test?1:rawVelocity,$('kickVelocity').checked),index=Math.min(Math.max(Math.round(dynamics*15),0),15),sound=$('kickSound').value,gain=Number($('kickGain').value),key=`kick/${sound}/${gain}/${index}`,slot=nextKickVoice++%6;
  try{kickVoices[slot]?.stop();}catch{}
  const node=audio.createBufferSource();node.buffer=audioBuffer(key,()=>kickSamples(audio.sampleRate,sound,gain,index/15));node.connect(clickBus);node.start();kickVoices[slot]=node;
  node.onended=()=>{node.disconnect();if(kickVoices[slot]===node)kickVoices[slot]=null;};
}
function clearScheduled() {
  for (const osc of scheduled) { try { osc.stop(); } catch { /* Already stopped. */ } }
  scheduled.clear(); clearInterval(scheduler); scheduler = null;
}
function logHit(hit) {
  const row=document.createElement('tr');for(const value of [Number.isFinite(hit.clock)?`${hit.clock.toFixed(3)} ms`:'—',hit.source,voices[hit.voice]??hit.voice,hit.velocity!=null?`Velocity ${hit.velocity}`:hit.amplitude!=null?`Peak ${hit.amplitude.toFixed(3)}`:'—']){const cell=document.createElement('td');cell.textContent=value;row.append(cell);}if(!count)$('liveEvents').replaceChildren();$('liveEvents').prepend(row);while($('liveEvents').children.length>500)$('liveEvents').lastElementChild.remove();
  count++; text('hitCount',`${count} HITS`);
  recent.unshift(`${new Date().toLocaleTimeString()}  ${voices[hit.voice] ?? hit.voice}  ${hit.source}${hit.note != null ? ` · note ${hit.note} · velocity ${hit.velocity}`:''}`);
  if (recent.length > 50) recent.pop(); text('log',recent.join('\n')); $('log').style.whiteSpace = 'pre-wrap';
}
function receive(hit,{replay=false}={}) {
  if(!replay){logHit(hit);reinforceKick(hit);}
  if(run?.waiting){run.preRoll.push(hit);if(run.preRoll.length>512){const removed=run.preRoll.shift();run.latestDropped=Math.max(run.latestDropped??-Infinity,removed.clock);}return;}
  if (!run || run.demo || run.kind === 'click') return;
  const relative = hit.clock-run.start;
  if(run.kind==='alignment'){
    if(relative>=-run.beatMs&&relative<=run.duration)run.alignmentCollector.record({...hit,sessionTimeNanoseconds:Math.round(hit.clock*1e6)-Math.round(run.start*1e6)});
    return;
  }
  if (hit.voice === 'kick') {
    const desired = run.kickSource;
    if ((desired === 'midi' && hit.source === 'microphone') || (desired === 'microphone' && hit.source === 'midi')) return;
    const adjusted = hit.clock-(run.options.corrections[hit.source] ?? 0);
    // Native grading keeps both sources. Only headphone reinforcement deduplicates audio.
    lastKick.set(hit.source,adjusted);
  }
  // Count-in is excluded, except the 100 ms early window for the first expected note.
  const alignedRelative = relative-(run.options.corrections[hit.source] ?? 0);
  const tolerance=run.options.tolerance??100;
  if(alignedRelative < -tolerance || alignedRelative > run.pattern.duration+tolerance)return;
  if (run.evidence.length >= 10000) { run.options.dropped = (run.options.dropped ?? 0)+1; return; }
  run.evidence.push({...hit,id:hit.id??crypto.randomUUID(),time:relative,timeNanoseconds:Math.round(hit.clock*1e6)-Math.round(run.start*1e6)});
}

function mapping() { return settings.maps?.[$('midi').value] ?? {}; }
function wireMidi() {
  for (const input of midiAccess.inputs.values()) input.onmidimessage = null;
  const input = midiAccess.inputs.get($('midi').value);
  if (input) input.onmidimessage = event => {
    const [status,note,velocity] = event.data;
    if ((status & 0xf0) !== 0x90 || !velocity) return;
    const voice = mapping()[note] ?? gm[note] ?? 'unknown';
    $('mapNote').value = note; $('mapVoice').value = voice;
    text('lastNote',`Note ${note} → ${voices[voice]} · channel ${(status & 15)+1}`);
    const clock=audio ? audibleTime(event.timeStamp || performance.now()):performance.now();
    crosstalk.observeMIDIHit(voice,clock-(corrections().midi ?? 0));
    receive({voice,source:'midi',note,velocity,clock,rawTimestamp:event.timeStamp,channel:(status & 15)+1});
  };
  text('deviceBadge',input ? `MIDI · ${input.name}`:'No MIDI input selected');
}
function refreshMidi() {
  const previous = $('midi').value || settings.midi;
  $('midi').replaceChildren(new Option('None',''));
  for (const input of midiAccess.inputs.values()) if (input.state === 'connected') $('midi').append(new Option(input.name || input.id,input.id));
  if ([...$('midi').options].some(o => o.value === previous)) $('midi').value = previous;
  if (run && previous && $('midi').value !== previous) cancel('The selected MIDI device disconnected. The attempt was discarded.');
  wireMidi(); loadCorrections();
}
async function connectMidi() {
  if (!navigator.requestMIDIAccess) throw new Error('MIDI requires a current version of Chrome or Edge.');
  midiAccess = await navigator.requestMIDIAccess({sysex:false});
  midiAccess.onstatechange = refreshMidi; refreshMidi();
  if (!$('midi').value && $('midi').options.length > 1) { $('midi').selectedIndex = 1; wireMidi(); loadCorrections(); }
  notice($('midi').value ? 'MIDI connected. Strike each pad to check the mapping. Enable the microphone for acoustic kicks.' : 'No MIDI input found. Connect the kit, close other MIDI apps, then click Connect MIDI again.');
  settings.midi = $('midi').value; saveSettings();
}
async function refreshAudioDevices() {
  if (!navigator.mediaDevices?.enumerateDevices) return;
  const devices = await navigator.mediaDevices.enumerateDevices();
  for (const [id,kind] of [['microphone','audioinput'],['output','audiooutput'],['recordInput','audioinput']]) {
    const previous = $(id).dataset.initialized ? $(id).value : settings[id] ?? (id==='recordInput'?'follow':'');
    $(id).dataset.initialized = 'true';
    $(id).replaceChildren(new Option('System default',''));
    if(id==='recordInput')$(id).prepend(new Option('Follow kick microphone','follow'));
    let i = 0;
    for (const device of devices.filter(d => d.kind === kind && d.deviceId && d.deviceId !== 'default' && d.deviceId !== 'communications')) $(id).append(new Option(device.label || `${kind === 'audioinput' ? 'Microphone':'Output'} ${++i}`,device.deviceId));
    if ([...$(id).options].some(o => o.value === previous)) $(id).value = previous;
    if (previous && $(id).value !== previous && run) cancel('An audio device disconnected. The attempt was discarded. Select your devices again.');
  }
  loadCorrections();
}
function stopMicrophone() {
  micEpoch++; crosstalk.reset(); cancelCalibration();
  if (micNode) { micNode.port.onmessage = null; micNode.disconnect(); }
  micSource?.disconnect(); micMute?.disconnect();
  for (const track of stream?.getTracks() ?? []) track.stop();
  stream = null; micNode = null; micSource = null; micMute = null;
  peak = 0; $('level').value = 0; text('listen','Enable microphone');
}
function detectorSettings() {
  const threshold = Number($('threshold').value), lockout = Number($('lockout').value);
  if (!Number.isFinite(threshold) || threshold < .001 || threshold > 1 || !Number.isFinite(lockout) || lockout < 10 || lockout > 200) throw new Error('Use a threshold from 0.001 to 1 and lockout from 10 to 200 ms.');
  return {threshold,lockout};
}
async function startMicrophone() {
  await ensureAudio();
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('Microphone access is unavailable. Use the launcher and a current Chrome or Edge browser.');
  stopMicrophone();
  try {
    stream = await navigator.mediaDevices.getUserMedia({audio:{deviceId:$('microphone').value ? {exact:$('microphone').value}:undefined,echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false});
    await audio.audioWorklet.addModule('kick-worklet.mjs');
    micSource = audio.createMediaStreamSource(stream);
    micNode = new AudioWorkletNode(audio,'kick-input');
    micMute = audio.createGain(); micMute.gain.value = 0;
    micSource.connect(micNode); micNode.connect(micMute); micMute.connect(audio.destination);
    micNode.port.postMessage(detectorSettings());
    const node = micNode;
    micNode.port.onmessage = ({data}) => {
      if (data.type === 'level') { peak = data.peak; $('level').value = peak; if (noisePeaks) noisePeaks.push(peak); }
      else receiveMicrophone(data,node);
    };
    for (const track of stream.getTracks()) track.onended = () => { cancel('Microphone disconnected. The attempt was discarded.'); stopMicrophone(); };
    text('listen','Disable microphone'); await refreshAudioDevices();
    notice('Microphone enabled. Choose Calibrate kicks to learn the kick sound, then check isolated and simultaneous kicks in the live log.');
  } catch (error) { stopMicrophone(); throw error; }
}
function withError(fn) { return async (...args) => { try { await fn(...args); } catch (error) { notice(error.message || String(error)); } }; }

function setRunning(active) {
  const ids = ['start','demo','click','bpm','exercise','repeats','gradeKicks','kickSource','advance','threshold','lockout','alignMidi','alignMic','noise','connect','saveExercise','customName','grid','import','export','restoreNative','again','calibrateKick','saveCalibration','soundFilter','guard','match','practiceMode','song','songTrack','midiFile','deleteSong','sectionStart','sectionEnd','autoDelay','cleanRuns','advanceStep','ceiling','ceilingStep','tolerance','accentFloorEnabled','accentFloor','accentContrast','ghostCeilingEnabled','ghostCeiling','ghostContrast','editTool','loadExercise','updateExercise','deleteExercise','sequenceName','sequenceRepeats','sequenceMeasure','addSequenceStep','saveSequence','updateSequence','saveSessionNotes','rescore','deleteSession'];
  ids.push('externalPlayback','playbackOffset','playbackThreshold','setupImport','applyMacMicrophone');
  ids.push('recordAudio','recordInput','recordChannels','takeFile','takeFolder','deleteTake','downloadTake','exportBundle');
  ids.push('customMeasureMode','customSequenceMode');
  for (const id of ids) $(id).disabled = active;
  for(const button of document.querySelectorAll('[data-practice-type]'))button.disabled=active;
  for (const button of $('editor').querySelectorAll('button')) button.disabled = active;
  for (const control of $('sequenceSteps').querySelectorAll('button,input')) control.disabled = active;
  $('saveAlignment').disabled=active||!pendingAlignment;
  $('syncLost').disabled=!run?.external;
  $('stop').disabled = !active; $('repeats').disabled = active || ($('practiceMode').value!=='song'&&!!selectedDefinition().sequenceSteps);
  $('exercise').disabled=active||$('practiceMode').value==='song';
  $('saveCalibration').disabled = active || !pendingProfile;
  for(const id of ['saveSessionNotes','rescore','deleteSession','takeFile'])$(id).disabled=active||!currentResult||!!currentResult.demo||!!currentResult.experimental;
  for(const id of ['downloadTake','deleteTake'])$(id).disabled=active||!displayedTake;
}
function clearAuto() { clearTimeout(autoTimer); autoTimer = null;autoGoDeadline=0;$('autoGoBanner').hidden=true; }
function cancel(message) {
  finishGeneration++;pendingAlignment=null;$('alignmentReview').hidden=true;
  if(starting)starting.canceled=true;
  clearTimeout(playbackTimeout);playbackTimeout=null;playbackCapture?.stop();playbackCapture=null;
  if(activeRecorder){const recorder=activeRecorder;activeRecorder=null;recorder.abort().catch(error=>notice(`Could not clean up interrupted audio: ${error.message}`));}
  $('takePlayer').pause();
  micEpoch++; cancelCalibration(); crosstalk.reset();
  clearAuto(); clearScheduled(); run = null; lastKick.clear(); setRunning(finishing);
  text('phase','READY'); text('position','8-beat count-in');
  if (message) notice(message);
}
async function begin(kind='practice',demo=false,source=null){
  if(starting||finishing)return;stopLiveSimulation();if(run)cancel();clearAuto();const token={canceled:false};starting=token;setRunning(true);
  try{await beginAttempt(kind,demo,source,token);}catch(error){if(!token.canceled)cancel();throw error;}finally{if(starting===token)starting=null;if(!run)setRunning(false);}
}
async function beginAttempt(kind = 'practice',demo = false,source = null,token) {
  const external=kind==='practice'&&!demo&&$('practiceMode').value==='song'&&$('externalPlayback').checked;
  if(external&&Number($('repeats').value)!==1)throw new Error('Songsterr companion supports one pass. Set repeats to 1 and turn off Songsterr looping and count-in.');
  let pattern;
  if (kind === 'practice') {
    if(!demo&&!external&&$('ceiling').checked){const identity=currentIdentity();$('bpm').value=prepareCeiling(progress,identity,Number($('bpm').value));await persist();}
    pattern = selectedPattern();
    if (!demo) {
      const needsMidi = pattern.notes.some(n => n.voice !== 'kick') || ($('gradeKicks').checked && $('kickSource').value !== 'microphone');
      const needsMic = $('gradeKicks').checked && pattern.notes.some(n => n.voice === 'kick') && $('kickSource').value !== 'midi';
      if (needsMidi && !midiAccess?.inputs.get($('midi').value)) throw new Error('Connect MIDI and select your kit before starting this exercise.');
      if (needsMic && !stream) throw new Error('Enable the kick microphone, or select MIDI only / turn off Grade kicks.');
      if (!$('gradeKicks').checked && pattern.notes.every(n => n.voice === 'kick')) throw new Error('This exercise contains only kicks. Enable Grade kicks or choose a full-kit exercise.');
    }
  }
  const bpm = kind==='alignment'?60:Number($('bpm').value);
  if (!Number.isFinite(bpm) || bpm < 40 || bpm > 240) throw new Error('Use 40–240 BPM.');
  if (kind === 'alignment') {
    if (source === 'midi' && !midiAccess?.inputs.get($('midi').value)) throw new Error('Connect and select a MIDI input first.');
    if (source === 'microphone' && !stream) throw new Error('Enable the microphone first.');
  }
  const opts = {...scoringOptions(),gradeKicks:$('gradeKicks').checked,corrections:corrections()};
  if (Object.values(opts.corrections).some(v => !Number.isFinite(v) || Math.abs(v) > 500)) throw new Error('Timing correction must be between −500 and 500 ms.');
  let capturePromise=null;
  if(external){
    const capture=new PlaybackCapture({onLevel:(level,ready)=>text('playbackStatus',`${ready?'Ready — press Play in Songsterr now.':'Waiting for 0.3 seconds of quiet. Pause Songsterr.'} · ${level.toFixed(1)} dBFS`),onOnset:clock=>{try{startExternalPlayback(clock,capture);}catch(error){if(playbackCapture===capture)cancel(error.message);}},onError:message=>{if(playbackCapture===capture)cancel(message);}});playbackCapture=capture;capturePromise=capture.prepare();
  }
  await Promise.all([ensureAudio(),capturePromise]);
  if(token.canceled)return;
  if(kind==='practice'&&!demo&&!external&&$('recordAudio').checked){
    const recorder=new SessionRecorder(db,audio,{onStatus:message=>text('recordStatus',message)});activeRecorder=recorder;
    await recorder.prepare($('recordInput').value==='follow'?$('microphone').value:$('recordInput').value,$('recordChannels').value);if(token.canceled){await recorder.abort();if(activeRecorder===recorder)activeRecorder=null;return;}
  }
  const beatMs = 60000/bpm, origin = audio.currentTime*1000+300;
  run = {external,waiting:external,preRoll:[],latestDropped:null,armedAt:audibleTime(),kind,demo,source,pattern,origin,start:origin+(kind === 'click' ? 0:8*beatMs),beatMs,duration:kind === 'click' ? Infinity : kind === 'alignment' ? 11*beatMs+600 : pattern.duration,nextClick:0,evidence:[],options:opts,kickSource:$('kickSource').value,alignments:new Map(),late:0,exerciseId:$('exercise').value,devices:{midi:$('midi').selectedOptions[0]?.textContent,microphone:$('microphone').selectedOptions[0]?.textContent,output:$('output').selectedOptions[0]?.textContent}};
  if(external){run.start=Infinity;run.origin=Infinity;}
  if(kind==='alignment')run.alignmentCollector=new TimingAlignmentCollector(source,source==='microphone'?'kick':null);
  run.identity=currentIdentity();
  run.id=crypto.randomUUID();if(activeRecorder)activeRecorder.arm(run.id,run.start,run.start+run.duration);
  if(kind==='practice'&&!external)run.clickPlan=[...Array.from({length:8},(_,i)=>({time:origin+i*beatMs,isAccent:i%4===0})),...pattern.referenceBeats.filter(b=>b.time<pattern.duration).map(b=>({time:run.start+b.time,isAccent:b.isAccent}))].sort((a,b)=>a.time-b.time);
  lastKick.clear(); currentResult = null; $('result').hidden = true; setRunning(true);
  if (demo) run.evidence = pattern.notes.map((n,i) => ({voice:n.voice,time:n.time+[-8,4,11,-3,6][i%5],clock:run.start+n.time,source:'simulation',velocity:n.accent ? 120:n.ghost ? 25:80}));
  notice(kind === 'alignment' ? `After 8 count-in clicks, play one ${source === 'microphone' ? 'kick':'MIDI pad'} hit on each of 12 clicks.` : demo ? 'Simulation: generated hits demonstrate the timeline and scoring. This run is not saved to history.' : kind === 'click' ? 'Metronome running. Cancel to stop.' : 'Eight count-in clicks. Begin playing when the practice playhead moves.');
  const activeRun = run;
  if(external){text('recordStatus','Experimental companion runs do not save history, progress or audio.');text('playbackStatus','Starting capture. Keep Songsterr paused until Ready.');notice('Armed for Songsterr audio. Wait for Ready, then press Play in the shared tab.');await playbackCapture.listen(audio,Number($('playbackThreshold').value));if(run!==activeRun)return;playbackTimeout=setTimeout(()=>{if(run===activeRun&&activeRun.waiting)cancel('No playback start detected within 45 seconds. Pause Songsterr, check Share tab audio and the threshold, then re-arm.');},45000);}
  scheduler = setInterval(() => {
    if (run !== activeRun) return;
    const now = audio.currentTime*1000;
    while (!activeRun.external&&(activeRun.clickPlan ? activeRun.clickPlan[activeRun.nextClick]?.time??Infinity : activeRun.origin+activeRun.nextClick*beatMs) < now+140) {
      const when = activeRun.clickPlan ? activeRun.clickPlan[activeRun.nextClick].time:activeRun.origin+activeRun.nextClick*beatMs;
      if (when >= activeRun.start+activeRun.duration) break;
      if (when < now+10) { activeRun.late++; activeRun.nextClick++; continue; }
      if(activeRun.kind==='alignment'&&when>=activeRun.start)activeRun.alignmentCollector.recordReference(Math.round(when*1e6)-Math.round(activeRun.start*1e6));
      clickAt(when/1000,activeRun.clickPlan ? activeRun.clickPlan[activeRun.nextClick].isAccent:activeRun.nextClick%4 === 0); activeRun.nextClick++;
    }
    const inputTail = activeRun.kind === 'practice' ? Math.max(0,...Object.values(activeRun.options.corrections)):0;
    if (audibleTime() > activeRun.start+activeRun.duration+(activeRun.kind==='alignment'?0:(activeRun.options.tolerance??100)+80+inputTail)) finish();
  },25);
}

function startExternalPlayback(clock,capture){
  if(playbackCapture!==capture||!run?.waiting)return;
  const active=run,start=playbackStart({onset:clock,now:audibleTime(),armedAt:active.armedAt,offset:Number($('playbackOffset').value),duration:active.duration,tolerance:active.options.tolerance,latestDropped:active.latestDropped}),preRoll=active.preRoll;
  clearTimeout(playbackTimeout);playbackTimeout=null;capture.stop();playbackCapture=null;active.preRoll=[];active.waiting=false;active.start=start;active.origin=start;
  for(const hit of preRoll)receive(hit,{replay:true});
  notice('Audio start detected — alignment unverified. Pauses, seeks, loops and tempo changes are not followed. This experimental run is not saved.');text('playbackStatus','Running against the fixed MIDI timeline. Use Sync lost if playback changes.');
}

async function finish() {
  const completed = run; if (!completed) return;
  finishing=true;const generation=finishGeneration;
  const progressOptions={advance:$('advance').checked,requiredCleanSessions:Number($('cleanRuns').value),stepBPM:Number($('advanceStep').value),ceiling:$('ceiling').checked,ceilingStepBPM:Number($('ceilingStep').value)};
  const recorder=activeRecorder;activeRecorder=null;
  try{
  clearScheduled(); run = null; setRunning(true); text('phase','COMPLETE'); text('position','Run complete');
  if(completed.kind==='alignment'){
    const measurement=completed.alignmentCollector.measurement();
    if(!measurement||measurement.sampleCount<8||completed.late){notice('Not enough reliably timed hits were detected. Retry at 60 BPM, using one comfortable MIDI pad or the kick microphone once on each of 12 clicks.');return;}
    pendingAlignment={...measurement,compensationMilliseconds:Math.min(Math.max(measurement.compensationMilliseconds,-250),250),source:completed.source,key:inputKey(completed.source),devices:completed.devices,createdAt:new Date().toISOString()};
    $('alignmentReview').hidden=false;text('alignmentMeasurement',`${completed.source==='midi'?'All e-kit MIDI drums':'Kick microphone'} · ${pendingAlignment.compensationMilliseconds.toFixed(1)} ms compensation · ${measurement.medianAbsoluteDeviationMilliseconds.toFixed(1)} ms spread · ${measurement.sampleCount}/${measurement.referenceCount} clicks matched.`);
    notice('Review the measured alignment, then Save & Apply. Positive compensation moves the input earlier for scoring; raw timestamps are preserved.');return;
  }
  completed.options.dropped = (completed.options.dropped ?? 0)+completed.late;
  const metrics = score(completed.pattern,completed.evidence,completed.options);
  const session = {id:completed.id,name:completed.pattern.name,bpm:completed.pattern.bpm,date:new Date().toISOString(),pattern:completed.pattern,evidence:completed.evidence,metrics,options:completed.options,devices:completed.devices,demo:completed.demo,experimental:completed.external,exerciseKind:completed.identity.kind,customExerciseID:completed.identity.customExerciseID,importedSongID:completed.identity.importedSongID,notes:'',tags:[]};
  if(recorder){setRunning(true);try{session.audio=await recorder.finish({inputName:$('recordInput').selectedOptions[0]?.textContent,channelSelection:$('recordChannels').value});}catch(error){session.audioError=error.message;text('recordStatus',`Recording failed: ${error.message}`);}finally{setRunning(true);}}
  if(generation===finishGeneration){currentResult = session;showResult(session);}
  let decision={found:false};
  if (!completed.demo&&!completed.external) {
    sessions.unshift(session);
    decision=recordProgress(progress,session,progressOptions);
    if(generation===finishGeneration&&decision.message&&(progressOptions.ceiling||progressOptions.advance)){const target=progressOptions.ceiling?'ceilingMessage':'progressionMessage';text(target,decision.message);$(target).hidden=false;}
    if(generation===finishGeneration){$('bpm').value=decision.nextBPM;saveSettings();}
    await persist();renderHistory();renderProgressStatus();
  }
  if(generation!==finishGeneration)return;
  notice(completed.external?'Experimental companion complete. Alignment remains unverified; history and progress were not saved.':completed.demo ? 'Simulation complete. Connect your devices to capture your playing.' : completed.late ? 'Completed with a scheduling interruption. This run cannot qualify as clean; keep the window visible and close demanding apps.' : metrics.clean ? 'Clean run. Good timing and accuracy.' : 'Run saved. Review missed notes and timing, then try again.');
  if(!completed.demo&&decision.message)notice(decision.message);
  if ($('auto').checked && !completed.demo && !completed.external && desktop.activeTab==='practice' && !document.hidden && !decision.found) {
    const delay=Math.min(Math.max(Number($('autoDelay').value)||7,1),30);
    notice(`${decision.message??'Run saved.'} Next count-in starts in ${delay} seconds. Cancel pauses automatic repeats.`);
    $('stop').disabled = false;autoGoDeadline=Date.now()+delay*1000;
    autoTimer = setTimeout(() => { $('stop').disabled = true; withError(() => begin())(); },delay*1000);
  }
  }finally{if(recorder?.id)await recorder.abort().catch(error=>text('recordStatus',error.message));finishing=false;setRunning(!!run||!!starting);if(autoTimer)$('stop').disabled=false;}
}
function showResult(s) {
  const firstDisplay=$('result').hidden||currentResult?.id!==s.id;
  currentResult = s; $('result').hidden = false;desktop.sync();
  const m = s.metrics;
  if(m.accents==null)m.accents=evaluateDynamics('accent',s.pattern.notes,s.evidence,m.results??[]);
  if(m.ghosts==null)m.ghosts=evaluateDynamics('ghost',s.pattern.notes,s.evidence,m.results??[]);
  loadSessionTake(s).catch(error=>text('takeInfo',`Could not load this take: ${error.message}`));
  $('sessionNotes').value=s.notes??'';$('sessionTags').value=(s.tags??[]).join(', ');
  for(const id of ['saveSessionNotes','rescore','deleteSession'])$(id).disabled=!!s.demo||!!s.experimental;
  text('sessionContext',`${s.source==='mac'?'Migrated Mac session':'Windows session'} · scoring version ${m.scoringVersion??1} · MIDI ${s.devices?.midi??'none'} · mic ${s.devices?.microphone??'none'} · output ${s.devices?.output??'default'}${s.rescoredAt?` · rescored ${new Date(s.rescoredAt).toLocaleString()}`:''}`);
  renderSessionResult(document,s,summarizePractice(s.pattern,m));ledgerLimit=200;renderLedger();desktop.sync();
  if(firstDisplay&&desktop.activeTab==='practice')requestAnimationFrame(()=>{if($('result').parentElement===$('practiceContent'))window.scrollTo({top:0,behavior:'instant'});});
}
function renderLedger(){
  if(!currentResult)return;
  const timeline=timingTimeline(currentResult),entries=filterTimeline(timeline,{problems:$('ledgerFilter').value==='problems',voice:$('ledgerVoice').value});
  renderTimingChart($('timingChart'),currentResult,entries,timeline);$('ledger').replaceChildren();
  text('ledgerCount',`Showing ${Math.min(ledgerLimit,entries.length)} of ${entries.length} filtered events · ${timeline.entries.length} total. All events remain in the backup.`);$('ledgerMore').disabled=ledgerLimit>=entries.length;
  for(const r of entries.slice(0,ledgerLimit)){
    const tr=document.createElement('tr');tr.className=r.status==='correct'?'good':'bad';
    const expected=r.expected,actual=r.actual,position=expected?`${expected.measure}.${expected.beat}.${expected.subdivision+1}`:'—';
    for(const value of [position,voices[expected?.voice]??'—',voices[actual?.voice]??'—',`${r.status}${r.dynamics?` · ${r.dynamics}`:''}`,r.offset==null?'—':`${r.offset>0?'+':''}${ms(r.offset)}`,r.expectedTime==null?'—':`${r.expectedTime.toFixed(3)} ms`,r.actualTime==null?'—':`${r.actualTime.toFixed(3)} ms`,actual?.source??'—']){const td=document.createElement('td');td.textContent=value;tr.append(td);}
    const td=document.createElement('td'),button=document.createElement('button');button.className='secondary';button.textContent='Inspect';button.onclick=()=>{text('rawEvidence',JSON.stringify({expected,played:actual,decision:{...r,expected:undefined,actual:undefined}},null,2));$('rawEvidencePanel').open=true;};td.append(button);tr.append(td);$('ledger').append(tr);
  }
}

async function loadSessionTake(session){
  $('takePlayer').pause();$('takePlayer').hidden=true;$('takePlayer').removeAttribute('src');displayedTake=null;
  if(takeURL){URL.revokeObjectURL(takeURL);takeURL=null;}
  $('downloadTake').disabled=true;$('deleteTake').disabled=true;$('takeFile').disabled=!!session.demo||!!session.experimental;
  if(!db||session.demo||session.experimental){text('takeInfo','No recording attached to this simulated or experimental run.');return;}
  const take=await getTake(db,session.id);if(currentResult?.id!==session.id)return;
  if(!take){text('takeInfo',session.audioError?`Recording unavailable: ${session.audioError}`:session.source==='mac'?'Import the transferred Mac-recordings folder to attach this session’s original take.':'No recording attached. Enable Save played audio before the next run, or attach a local take.');return;}
  displayedTake=take;takeURL=URL.createObjectURL(take.blob);$('takePlayer').src=takeURL;$('takePlayer').hidden=false;
  if($('takePlayer').setSinkId)await $('takePlayer').setSinkId($('output').value||'');
  text('takeInfo',`${take.filename??'Saved take'} · ${(take.blob.size/1024/1024).toFixed(1)} MB${take.durationSeconds?` · ${take.durationSeconds.toFixed(1)} seconds`:''}${take.inputName?` · ${take.inputName}`:''}`);$('downloadTake').disabled=false;$('deleteTake').disabled=false;
}
function downloadBlob(blob,name){const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
function nativeDate(value) { return typeof value === 'number' ? new Date((value+978307200)*1000):new Date(value); }
function renderHistoryOverview(entries){
  const values=historyValues(entries),overview=$('historyOverview');overview.replaceChildren();
  const cards=[['Sessions',values.length,'Completed runs'],['Practice time',`${Math.round(values.reduce((sum,s)=>sum+s.duration,0))} s`,'Scored exercise time'],['Best recall',values.length?`${(Math.max(...values.map(s=>s.recall))*100).toFixed(1)}%`:'—','Any completed run'],['Clean sessions',values.filter(s=>s.clean).length,'≥95% recall and ≤25 ms']];
  for(const [label,value,detail]of cards){const card=document.createElement('div');card.className='metric';const title=document.createElement('div');title.textContent=label;const number=document.createElement('strong');number.textContent=value;const caption=document.createElement('span');caption.textContent=detail;card.append(title,number,caption);overview.append(card);}
  $('historyTrendPanel').hidden=!values.length;
  const metric=$('historyMetric').value,trend=values.slice(-30).map(s=>s[metric]).filter(Number.isFinite),target=$('historyTrend');target.replaceChildren();
  if(!trend.length){const empty=document.createElement('p');empty.className='empty';empty.textContent='This metric appears after a compatible exercise is completed.';target.append(empty);return;}
  const width=900,height=180,left=55,top=15,bottom=145,min=Math.min(...trend),max=Math.max(...trend),span=Math.max(max-min,metric==='recall'?.01:1),format=v=>metric==='recall'?`${Math.round(v*100)}%`:metric==='bpm'?`${Math.round(v)} BPM`:`${v.toFixed(1)} ms`;
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox',`0 0 ${width} ${height}`);svg.setAttribute('role','img');svg.setAttribute('aria-label',`${$('historyMetric').selectedOptions[0].textContent} trend across ${trend.length} sessions, older to newer`);
  function shape(tag,attrs,copy){const node=document.createElementNS(svg.namespaceURI,tag);for(const [key,value]of Object.entries(attrs))node.setAttribute(key,value);if(copy)node.textContent=copy;svg.append(node);}
  for(const fraction of [0,.5,1]){const y=bottom-fraction*(bottom-top);shape('line',{x1:left,x2:width-15,y1:y,y2:y,stroke:'#444'});shape('text',{x:left-8,y:y+4,'text-anchor':'end',fill:'#aaa','font-size':10},format(min+fraction*span));}
  const points=trend.map((v,i)=>[left+i*(width-left-15)/Math.max(1,trend.length-1),bottom-(v-min)/span*(bottom-top)]);
  shape('polyline',{points:points.map(p=>p.join(',')).join(' '),fill:'none',stroke:'#0a84ff','stroke-width':2});for(const [cx,cy]of points)shape('circle',{cx,cy,r:3,fill:'#0a84ff'});
  shape('text',{x:left,y:173,fill:'#aaa','font-size':11},format(trend[0]));shape('text',{x:width/2,y:173,'text-anchor':'middle',fill:'#aaa','font-size':11},'Older → newer');shape('text',{x:width-15,y:173,'text-anchor':'end',fill:'#aaa','font-size':11},format(trend.at(-1)));target.append(svg);
}
function renderHistory() {
  const entries=new Map(sessions.filter(s=>!deletedSessionIDs.includes(s.id)).map(s=>[s.id,{s,date:new Date(s.date),summaryOnly:false}]));
  nativeArchives.forEach(a=>(a.sessions??[]).forEach(s=>{if(!entries.has(s.id)&&!deletedSessionIDs.includes(s.id))entries.set(s.id,{s,date:nativeDate(s.completedAt),summaryOnly:true});}));
  renderHistoryOverview([...entries.values()]);
  const query=$('historySearch').value.trim().toLocaleLowerCase(),filter=$('historyFilter').value;
  const ordered=[...entries.values()].filter(({s,summaryOnly})=>{
    const clean=historySessionClean({s,summaryOnly});
    const searchable=[s.name??s.exerciseName,s.notes??'',...(Array.isArray(s.tags)?s.tags:[])].join(' ').toLocaleLowerCase();
    return searchable.includes(query)&&(filter==='all'||(filter==='clean'?clean:!clean));
  }).sort((a,b)=>b.date-a.date);
  $('history').replaceChildren();$('restoreNative').hidden=!nativeArchives.length;
  if(!ordered.length){const p=document.createElement('p');p.className='empty';p.textContent=entries.size?'No sessions match this filter.':'Your completed runs will appear here.';$('history').append(p);}
  for(const entry of ordered.slice(0,historyLimit))$('history').append(historySessionRow(document,entry,{onDetails:showHistoryDetail}));
  const p=document.createElement('p');p.className='hint';p.textContent=`Showing ${Math.min(historyLimit,ordered.length)} of ${ordered.length} sessions. Export includes saved sessions and original archives.`;$('history').append(p);$('historyMore').disabled=historyLimit>=ordered.length;
  $('progressRecords').replaceChildren(exerciseProgressTable(document,[...entries.values()],progress));
  desktop.sync();
}
$('historyMetric').onchange=renderHistory;
function download(value,name) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(value)],{type:'application/json'}));
  const a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000);
}
function renderEditor() {
  draftRevision++;
  const lanes = Object.keys(voices).filter(v=>v!=='unknown'), slots = subdivisions[draft.subdivision]*4;
  $('editor').replaceChildren();
  const createRow = label => { const row = document.createElement('div'); row.className = 'editor-row'; row.style.gridTemplateColumns = `90px repeat(${slots},1fr)`; const l = document.createElement('span'); l.className = 'editor-label'; l.textContent = label; row.append(l); $('editor').append(row); return row; };
  const header = createRow('COUNT');
  for (let slot=0;slot<slots;slot++) { const cell = document.createElement('span'); cell.className = 'editor-label'; cell.textContent = slot%subdivisions[draft.subdivision] === 0 ? `${Math.floor(slot/subdivisions[draft.subdivision])+1}` : draft.subdivision === 'eighths' ? '&' : draft.subdivision === 'triplets' ? ['','trip','let'][slot%3] : ['','e','&','a'][slot%4]; header.append(cell); }
  for (const voice of lanes) {
    const row = createRow(voices[voice]);
    for (let slot=0;slot<slots;slot++) {
      const note = draft.hits.find(h => h.voice === voice && h.slot === slot), button = document.createElement('button');
      button.className = `cell${note ? ' active':''}`; button.textContent = note ? note.accent ? '>':note.ghost ? 'g':'●':'·';
      button.setAttribute('aria-label',`${voices[voice]}, slot ${slot+1}, ${note ? note.accent ? 'accent':note.ghost ? 'ghost':'note':'rest'}`);
      button.onclick = () => {
        const tool=$('editTool').value;
        if(tool==='note'){if(note)draft.hits=draft.hits.filter(h=>h!==note);else draft.hits.push({slot,voice,allowedVoices:[]});}
        else if(!note)draft.hits.push({slot,voice,allowedVoices:[],accent:tool==='accent',ghost:tool==='ghost'});
        else{const was=tool==='accent'?note.accent:note.ghost;note.accent=tool==='accent'&&!was;note.ghost=tool==='ghost'&&!was;}
        settings.draft=structuredClone(draft);saveSettings();renderEditor();
      }; row.append(button);
    }
  }
}

// Draw upcoming beats against a fixed playhead. UI refreshes never schedule audio or hits.
function updateTransportStatus(){
  $('autoGoBanner').hidden=!autoTimer;
  if(autoTimer){const value=`Auto go · next round in ${Math.max(0,Math.ceil((autoGoDeadline-Date.now())/1000))}s`;if($('autoGoCountdown').textContent!==value)text('autoGoCountdown',value);}
  if(run?.waiting){text('phase','WAITING');text('position','Wait for Ready, then press Play in Songsterr.');}
  else if (run) {
    const relative = audibleTime()-run.start;
    if (relative < 0 && run.kind !== 'click') { const remaining = Math.min(8,Math.ceil(-relative/run.beatMs)); text('phase','COUNT IN'); text('position',`Count-in · ${remaining} clicks to go`); }
    else { const beat=run.pattern?.referenceBeats?.filter(b=>b.time<=relative).at(-1);text('phase',run.kind==='alignment'?'ALIGNING':run.kind==='click'?'CLICK':'PLAYING');text('position',run.kind==='alignment'?`Click ${Math.min(12,Math.floor(relative/run.beatMs)+1)} of 12`:run.kind==='click'?`Beat ${Math.floor(Math.max(0,relative)/run.beatMs)%4+1}`:`Measure ${beat?.measure??1} · beat ${beat?.beat??1}`); }
  }
}
function draw() {
  updateTransportStatus();
  drawResultScore(document,currentResult,window.devicePixelRatio||1);
  const canvas = $('score'), width = canvas.clientWidth, height = canvas.clientHeight, dpr = window.devicePixelRatio || 1;
  if (canvas.width !== Math.round(width*dpr) || canvas.height !== Math.round(height*dpr)) { canvas.width = Math.round(width*dpr); canvas.height = Math.round(height*dpr); }
  if(!width||!height){animation=requestAnimationFrame(draw);return;}
  const c = canvas.getContext('2d'); c.setTransform(dpr,0,0,dpr,0,0); c.clearRect(0,0,width,height);
  let pattern = run?.pattern ?? currentResult?.pattern;
  if (!pattern) { try { pattern = previewPattern(); } catch { c.fillStyle='#a1a1a6';c.font='13px Segoe UI, sans-serif';c.textAlign='center';c.fillText($('practiceMode').value==='song'?'Import or select a song to see its drum score.':'Add notes to your custom exercise to preview the score.',width/2,height/2);c.textAlign='start';animation = requestAnimationFrame(draw); return; } }
  const t = run?.kind === 'practice' ? Math.max(0,audibleTime()-run.start):0;
  canvas.classList.toggle('staff',$('scoreView').value==='staff');
  $('scoreMeasure').max=pattern.measures;
  if($('scoreView').value==='staff'){drawNotation(c,width,pattern,{time:run?.kind==='practice'?t:null,metrics:currentResult?.metrics,measure:Number($('scoreMeasure').value)||1});}
  else{
  const laneVoices = [...new Set(pattern.notes.map(n => n.voice))], rowH = Math.min(45,(height-45)/Math.max(laneVoices.length,1)), left = 105;
  const pixelsPerBeat = Math.max(35,(width-left-20)/8), pixelsPerMs = pixelsPerBeat/pattern.beatMs, playhead = left+30;
  c.font = '11px Segoe UI, system-ui'; c.textBaseline = 'middle';
  laneVoices.forEach((voice,i) => { const y=40+i*rowH; c.fillStyle='#94a1b7'; c.fillText(voices[voice] ?? voice,10,y); c.strokeStyle='#273243'; c.beginPath(); c.moveTo(left,y); c.lineTo(width,y); c.stroke(); });
  for(const beat of pattern.referenceBeats??[]){
    if(beat.time<t-400||beat.time>t+pattern.beatMs*10)continue;const x=playhead+(beat.time-t)*pixelsPerMs;if(x<left)continue;
    c.strokeStyle=beat.isAccent?'#4b596e':'#273243';c.beginPath();c.moveTo(x,24);c.lineTo(x,height);c.stroke();
    c.fillStyle='#8392aa';c.fillText(beat.isAccent?`${beat.measure} · 1`:`${beat.beat}`,x+4,13);
  }
  const minTime = t-400, maxTime = t+pattern.beatMs*9;
  for (const n of pattern.notes) {
    if (n.time < minTime || n.time > maxTime) continue;
    const x = playhead+(n.time-t)*pixelsPerMs, y=40+laneVoices.indexOf(n.voice)*rowH;
    if (x < left) continue;
    c.fillStyle=n.voice==='kick' ? '#9feaaf':'#9abaf1'; c.beginPath(); c.arc(x,y,n.ghost ? 3:5,0,Math.PI*2); c.fill();
    if (n.accent) { c.fillStyle='#f3d5a3'; c.fillText('>',x-3,y-13); }
  }
  c.strokeStyle='#e9eaf3'; c.lineWidth=2; c.beginPath(); c.moveTo(playhead,25); c.lineTo(playhead,height-12); c.stroke(); c.lineWidth=1;
  }
  animation = requestAnimationFrame(draw);
}

$('customMeasureMode').onclick=()=>{cancel();$('customEditorPanel').dataset.sequence='false';$('customMeasureMode').setAttribute('aria-pressed','true');$('customSequenceMode').setAttribute('aria-pressed','false');updateGuide();saveSettings();desktop.sync();};
$('customSequenceMode').onclick=()=>{cancel();$('customEditorPanel').dataset.sequence='true';$('customMeasureMode').setAttribute('aria-pressed','false');$('customSequenceMode').setAttribute('aria-pressed','true');updateGuide();saveSettings();desktop.sync();};
$('liveSimulation').onclick=withError(async()=>{if(liveSimulationTimer){stopLiveSimulation();return;}if(run)throw new Error('Stop the active practice before starting the test simulation.');await ensureAudio();let index=0;$('liveSimulation').textContent='Stop Test Simulation';liveSimulationTimer=setInterval(()=>{const voice=['closedHiHat','kick','closedHiHat','snare'][index++%4];logHit({voice,source:'simulation',velocity:80,clock:audibleTime()});},250);});
$('clearLive').onclick=()=>{count=0;recent.length=0;text('hitCount','0 HITS');text('log','Waiting for a MIDI pad or microphone kick…');$('liveEvents').replaceChildren();};
optionVoices($('ledgerVoice'));$('ledgerVoice').prepend(new Option('All voices','all'));$('ledgerVoice').value='all';
for(const id of ['ledgerFilter','ledgerVoice'])$(id).onchange=()=>{ledgerLimit=200;renderLedger();};
$('ledgerMore').onclick=()=>{ledgerLimit+=200;renderLedger();};
$('scoreView').onchange=()=>saveSettings();
$('scoreMeasure').onchange=()=>{$('scoreMeasure').value=Math.min(Math.max(Number($('scoreMeasure').value)||1,1),Number($('scoreMeasure').max)||1);};
$('connect').onclick = withError(connectMidi);
$('midi').onchange = () => { cancel('MIDI input changed. Select Start when ready.'); wireMidi(); settings.midi = $('midi').value; loadCorrections(); saveSettings(); };
$('listen').onclick = withError(async () => { cancel(); if (stream) { stopMicrophone(); notice('Microphone disabled.'); } else await startMicrophone(); });
$('microphone').onchange = withError(async () => { cancel('Microphone changed.'); const wasListening = !!stream; stopMicrophone(); settings.microphone = $('microphone').value; loadCorrections(); loadMicrophoneProfile(); saveSettings(); if (wasListening) await startMicrophone(); });
$('output').onchange = withError(async () => { cancel('Output changed. Check timing alignment with this output.'); await ensureAudio(); if (audio.setSinkId) await audio.setSinkId($('output').value); else if ($('output').value) { $('output').value = ''; notice('Select the output in Windows sound settings.'); } if($('takePlayer').setSinkId)await $('takePlayer').setSinkId($('output').value||''); settings.output = $('output').value; loadCorrections(); saveSettings(); });
$('noise').onclick = withError(async () => {
  if (!stream) throw new Error('Enable the microphone first.');
  if (noisePeaks) return;
  noisePeaks = []; $('noise').disabled = true; notice('Stay quiet for 3 seconds. Measuring the room noise…');
  const node = micNode;
  await new Promise(resolve => setTimeout(resolve,3000));
  const samples = noisePeaks; noisePeaks = null; $('noise').disabled = !!run;
  if (node !== micNode || samples.length < 10) throw new Error('Noise measurement interrupted. Enable the microphone and try again.');
  samples.sort((a,b) => a-b);
  const threshold = Math.max(.01,Math.min(.9,samples[Math.floor(samples.length*.95)]*3));
  $('threshold').value = threshold.toFixed(3); micNode.port.postMessage(detectorSettings()); saveSettings();
  notice('Noise threshold saved. Play isolated kicks and check the live log; raise the threshold if other sounds trigger kicks.');
});
for (const id of ['threshold','lockout']) $(id).onchange = withError(() => { const config = detectorSettings(); micNode?.port.postMessage(config); saveSettings(); });
for (const id of ['soundFilter','guard','match']) $(id).onchange = withError(() => { const value=Number($('match').value); if(!Number.isFinite(value)||value<.01||value>1)throw new Error('Use a minimum match from 0.01 to 1.'); saveSettings(); });
$('calibrateKick').onclick = withError(calibrateKicks);
$('saveCalibration').onclick = withError(() => {
  if (!pendingProfile || pendingProfile.deviceUID !== $('microphone').value) throw new Error('Complete calibration for this microphone first.');
  settings.microphoneProfiles ??= {}; settings.microphoneProfiles[pendingProfile.deviceUID] = pendingProfile;
  settings.detectors ??= {}; settings.detectors[pendingProfile.deviceUID] = {threshold:pendingProfile.suggestedThreshold,lockout:pendingProfile.retriggerLockoutMilliseconds};
  pendingProfile = null; $('saveCalibration').disabled = true; loadMicrophoneProfile(); micNode?.port.postMessage(detectorSettings()); saveSettings(); notice('Kick calibration saved for this microphone. Test isolated and simultaneous kicks before practicing.');
});
for (const [id,source] of [['midiCorrection','midi'],['micCorrection','microphone']]) $(id).onchange = withError(() => { cancel(); const value = Number($(id).value); if (!Number.isFinite(value) || Math.abs(value)>500) throw new Error('Use a correction between −500 and 500 ms.'); saveCorrection(source,value); });
$('saveMap').onclick = withError(() => { if (!$('midi').value) throw new Error('Select a MIDI input first.'); const note = Number($('mapNote').value); if (!Number.isInteger(note) || note<0 || note>127) throw new Error('Use a MIDI note from 0 to 127.'); cancel(); settings.maps ??= {}; settings.maps[$('midi').value] ??= {}; settings.maps[$('midi').value][note] = $('mapVoice').value; saveSettings(); notice(`Saved note ${note} as ${voices[$('mapVoice').value]} for this MIDI input.`); });
$('start').onclick = withError(() => begin()); $('again').onclick = withError(() => begin());
$('demo').onclick = withError(() => begin('practice',true));
$('click').onclick = withError(() => begin('click'));
$('saveAlignment').onclick=withError(()=>{const profile=pendingAlignment;if(!profile)throw new Error('Complete timing alignment first.');if(profile.key!==inputKey(profile.source))throw new Error('The input or output changed. Retry alignment for this setup.');settings.alignmentProfiles??={};settings.alignmentProfiles[profile.key]=profile;saveCorrection(profile.source,profile.compensationMilliseconds);pendingAlignment=null;$('alignmentReview').hidden=true;notice('Timing correction saved and applied to new scores. MIDI alignment applies to every e-kit drum.');});
$('discardAlignment').onclick=()=>cancel('Alignment discarded. The previous saved correction is still active.');
$('alignMidi').onclick = withError(() => begin('alignment',false,'midi'));
$('alignMic').onclick = withError(() => begin('alignment',false,'microphone'));
$('stop').onclick = () => cancel('Practice and automatic repeats paused. No interrupted attempt was saved.');
$('exercise').onchange = () => { cancel(); currentResult = null;$('result').hidden=true;const saved=library.some(e=>e.id===$('exercise').value);$('customEditorPanel').dataset.editing=String(saved);if(saved)$('loadExercise').click();updateGuide();saveSettings();desktop.sync(); };
for (const id of ['bpm','repeats','gradeKicks','kickSource']) $(id).onchange = () => { cancel(); currentResult = null; saveSettings(); };
for (const id of ['auto','advance','volume']) $(id).onchange = () => { if (id==='auto' && !$('auto').checked) { clearAuto(); if (!run) $('stop').disabled = true; } saveSettings(); };
for(const id of ['clickSound','clickGain','limiter','limiterCeiling','kickMonitorSource','kickSound','kickGain','kickVelocity','kickMonitorLockout'])$(id).onchange=withError(()=>{configureOutput();saveSettings();});
$('kickMonitor').onchange=withError(async()=>{if($('kickMonitor').checked)await ensureAudio();configureOutput();saveSettings();});
$('testKick').onclick=withError(async()=>{await ensureAudio();configureOutput();reinforceKick({voice:'kick',source:'midi',velocity:127,clock:audibleTime()},true);notice('Played the selected kick voice through the selected output.');});
$('grid').onchange=()=>{
 const previous=subdivisions[draft.subdivision]*4,next=subdivisions[$('grid').value]*4,groups=new Map();
 for(const hit of draft.hits){const copy={...hit,slot:Math.min(Math.max(Math.round(hit.slot*next/previous),0),next-1)},key=`${copy.slot}/${copy.voice}`,old=groups.get(key);if(!old||(!old.accent&&(copy.accent||(!old.ghost&&copy.ghost))))groups.set(key,copy);}
 draft.subdivision=$('grid').value;draft.hits=[...groups.values()].sort((a,b)=>a.slot-b.slot);settings.draft=structuredClone(draft);saveSettings();renderEditor();
};
$('saveExercise').onclick=withError(async()=>{draft.name=$('customName').value.trim()||'Custom measure';await saveDefinition(draft);});
$('updateExercise').onclick=withError(async()=>{draft.name=$('customName').value.trim()||'Custom measure';await saveDefinition(draft,true);});
$('loadExercise').onclick=withError(()=>{
 const definition=library.find(e=>e.id===$('exercise').value)?.definition??exercises.find(e=>e.id===$('exercise').value)??draft;$('customEditorPanel').dataset.sequence=String(!!definition.sequenceSteps);if(definition.sequenceSteps){sequenceDraft=structuredClone(definition);renderSequence();$('sequenceSteps').closest('details').open=true;$('customSequenceMode').setAttribute('aria-pressed','true');$('customMeasureMode').setAttribute('aria-pressed','false');}
 else{draft=structuredClone(definition);draft.name=library.some(e=>e.id===$('exercise').value)?draft.name:`Custom ${draft.name}`;$('customName').value=draft.name;$('grid').value=draft.subdivision;renderEditor();settings.draft=structuredClone(draft);saveSettings();}
 notice('Selected exercise loaded into the editor. Save copy or Update selected when finished.');
});
$('deleteExercise').onclick=withError(async()=>{const id=$('exercise').value;if(!library.some(e=>e.id===id))throw new Error('Select a saved exercise to delete.');cancel();library=library.filter(e=>e.id!==id);await persist();refreshExercises();notice('Saved exercise deleted. Existing session evidence is retained.');});
$('customName').onchange=()=>{draft.name=$('customName').value;settings.draft=structuredClone(draft);saveSettings();};
$('addSequenceStep').onclick=withError(()=>{const selected=library.find(e=>e.id===$('sequenceMeasure').value);if(!selected||selected.definition.sequenceSteps)throw new Error('Save and select a one-measure exercise first.');if(sequenceDraft.sequenceSteps.length>=32)throw new Error('Use at most 32 sequence steps.');sequenceDraft.sequenceSteps.push({id:crypto.randomUUID(),name:selected.definition.name,subdivision:selected.definition.subdivision,hits:structuredClone(selected.definition.hits),repeats:1});saveSequenceDraft();renderSequence();});
for(const id of ['sequenceName','sequenceRepeats'])$(id).onchange=()=>{saveSequenceDraft();renderSequence();};
$('saveSequence').onclick=withError(async()=>{saveSequenceDraft();await saveDefinition(sequenceDraft);});
$('updateSequence').onclick=withError(async()=>{saveSequenceDraft();await saveDefinition(sequenceDraft,true);});
$('practiceMode').onchange=()=>{cancel();currentResult=null;updateGuide();saveSettings();desktop.sync();};
$('song').onchange=()=>{cancel();currentResult=null;chooseSong();};
$('songTrack').onchange=withError(async()=>{cancel();const song=selectedSong();if(!song)return;song.selectedTrackIndex=Number($('songTrack').value);song.updatedAt=new Date().toISOString();renderSong();chooseSong();await persist();});
for(const id of ['sectionStart','sectionEnd'])$(id).onchange=()=>{cancel();currentResult=null;const song=selectedSong();if(song){settings.songSections??={};settings.songSections[song.id]={start:Number($('sectionStart').value),end:Number($('sectionEnd').value),bpm:Number($('bpm').value)};}renderSong();saveSettings();};
$('midiFile').onchange=withError(async event=>{const file=event.target.files[0];event.target.value='';if(!file)return;if(songs.length>=500)throw new Error('Song library is full.');const song=parseMIDI(await file.arrayBuffer(),file.name);validateSong(song);songs.push(song);await persist();settings.song=song.id;refreshSongs();$('song').value=song.id;$('practiceMode').value='song';chooseSong();notice('MIDI song imported. Review the track, note mapping and section, then Start.');});
$('deleteSong').onclick=withError(async()=>{const song=selectedSong();if(!song)throw new Error('Select a song first.');cancel();songs=songs.filter(s=>s.id!==song.id);deletedSongIDs.push(song.id);await persist();refreshSongs();notice('Song removed from the active library. Saved session evidence is retained.');});
for(const id of ['autoDelay','cleanRuns','advanceStep','ceiling','ceilingStep','tolerance','accentFloorEnabled','accentFloor','accentContrast','ghostCeilingEnabled','ghostCeiling','ghostContrast'])$(id).onchange=()=>{cancel();currentResult=null;saveSettings();renderProgressStatus();};
$('historySearch').oninput=()=>{historyLimit=50;renderHistory();};$('historyFilter').onchange=()=>{historyLimit=50;renderHistory();};$('historyMore').onclick=()=>{historyLimit+=50;renderHistory();};
$('saveSessionNotes').onclick=withError(async()=>{const index=sessions.findIndex(s=>s.id===currentResult?.id);if(index<0)throw new Error('Select a saved session.');sessions[index].notes=$('sessionNotes').value.trim();sessions[index].tags=[...new Set($('sessionTags').value.split(',').map(t=>t.trim()).filter(Boolean))].sort((a,b)=>a.localeCompare(b,undefined,{sensitivity:'base'}));await persist();renderHistory();notice('Session notes and tags saved.');});
$('rescore').onclick=withError(async()=>{cancel();const index=sessions.findIndex(s=>s.id===currentResult?.id);if(index<0)throw new Error('Select a saved session.');sessions[index]=rescoreSession(sessions[index]);await persist();showResult(sessions[index]);renderHistory();notice('Archived evidence rescored with the native-compatible rules and saved source corrections. Progression was not advanced.');});
$('deleteSession').onclick=withError(async()=>{const id=currentResult?.id;if(!id||!sessions.some(s=>s.id===id))throw new Error('Select a saved session.');cancel();sessions=sessions.filter(s=>s.id!==id);deletedSessionIDs.push(id);if(db)await removeTake(db,id);currentResult=null;$('result').hidden=true;await persist();renderHistory();notice('Session removed from active history. Original imported Mac backups remain available.');});
$('syncLost').onclick=()=>{if(run?.external)cancel('Sync lost — this attempt was discarded. Pause Songsterr, return to the selected measure and re-arm.');};
for(const id of ['externalPlayback','playbackOffset','playbackThreshold'])$(id).onchange=()=>{cancel();updateGuide();saveSettings();};
for(const id of ['recordAudio','recordInput','recordChannels'])$(id).onchange=()=>{cancel();saveSettings();};
$('takeFile').onchange=withError(async event=>{const file=event.target.files[0];event.target.value='';if(!file)return;if(!currentResult||currentResult.demo)throw new Error('Select a saved session first.');if(file.size>500*1024*1024)throw new Error('This audio file exceeds 500 MB.');const session=currentResult;await saveTake(db,session.id,file,{filename:file.name,imported:true});await loadSessionTake(session);notice('Take attached to this session.');});
$('takeFolder').onchange=withError(async event=>{const files=[...event.target.files];event.target.value='';if(!files.length)return;let attached=0;const ids=new Map(sessions.map(s=>[s.id.toLowerCase(),s.id]));for(const file of files){if(!/\.(m4a|wav|webm|mp3|ogg|flac)$/i.test(file.name))continue;const id=file.name.replace(/\.[^.]+$/,'').toLowerCase();if(!ids.has(id)||file.size>500*1024*1024)continue;await saveTake(db,ids.get(id),file,{filename:file.name,imported:true});attached++;}if(currentResult)await loadSessionTake(currentResult);notice(`Attached ${attached} recordings to their saved session IDs. Other files were kept in your original folder.`);});
$('downloadTake').onclick=()=>{if(displayedTake)downloadBlob(displayedTake.blob,displayedTake.filename??`${currentResult.id}.wav`);};
$('deleteTake').onclick=withError(async()=>{if(!currentResult||!displayedTake)return;await removeTake(db,currentResult.id);await loadSessionTake(currentResult);notice('The browser copy of this take was deleted. Imported originals remain in your transferred folder.');});
function backupSnapshot(){return {format:'DrumTrainerWindows',version:1,exportedAt:new Date().toISOString(),exercises:library,sessions:sessions.map(compactSession),nativeArchives,songs,progress,deletedSessionIDs,deletedSongIDs,settings};}
function refreshMacProfiles(){const select=$('macMicrophoneProfile');select.replaceChildren();for(const [index,profile]of (settings.importedMacMicrophoneProfiles??[]).entries())select.append(new Option(`${profile.deviceName} · ${profile.quality} calibration`,index));$('macProfilePanel').hidden=!select.options.length;}
refreshMacProfiles();
$('setupImport').onchange=withError(async event=>{const file=event.target.files[0];event.target.value='';if(!file)return;if(file.size>2*1024*1024)throw new Error('Setup backup exceeds 2 MB.');const imported=importMacSetup(JSON.parse(await file.text()));cancel();settings={...settings,...imported.settings,importedMacMicrophoneProfiles:imported.microphoneProfiles,nativeMacTimingProfiles:imported.nativeTimingProfiles};for(const id of settingControls)if(settings[id]!=null){if($(id).type==='checkbox')$(id).checked=settings[id]===true;else $(id).value=settings[id];}saveSettings();refreshMacProfiles();configureOutput();notice('Mac sound and dynamics choices restored. Select the Windows microphone before applying its transferred profile. Run fresh MIDI/mic alignment for Windows; Mac timing values are preserved for reference.');});
$('applyMacMicrophone').onclick=withError(()=>{if(!stream)throw new Error('Enable and select the Windows kick microphone first.');const original=settings.importedMacMicrophoneProfiles?.[Number($('macMicrophoneProfile').value)];if(!original)throw new Error('Select an imported microphone profile.');cancel();settings.microphoneProfiles??={};const deviceUID=$('microphone').value,profile={...structuredClone(original),id:crypto.randomUUID(),nativeDeviceUID:original.deviceUID,deviceUID,deviceName:$('microphone').selectedOptions[0]?.textContent,importedFromMac:true};settings.microphoneProfiles[deviceUID]=profile;settings.detectors??={};settings.detectors[deviceUID]={threshold:profile.suggestedThreshold,lockout:profile.retriggerLockoutMilliseconds};loadMicrophoneProfile();micNode?.port.postMessage(detectorSettings());saveSettings();notice('Transferred kick fingerprint applied to the selected Windows microphone. Check real kicks and crosstalk, then run fresh timing alignment.');});
$('export').onclick = () => download(backupSnapshot(),`DrumTrainer-Windows-${new Date().toISOString().slice(0,10)}.json`);
$('exportBundle').onclick=withError(async()=>{
  if(!db)throw new Error('Browser storage is unavailable. Export the JSON backup and download available takes separately.');
  $('exportBundle').disabled=true;
  try{
    const snapshot=backupSnapshot(),ids=new Set(snapshot.sessions.map(s=>s.id.toLowerCase())),entries=[{name:'Practice-backup.json',blob:new Blob([JSON.stringify(snapshot)],{type:'application/json'})}];
    const takes=(await allTakes(db)).filter(t=>ids.has(t.id)),manifest=[];
    for(const take of takes){const extension=take.filename?.match(/\.(m4a|wav|webm|mp3|ogg|flac)$/i)?.[1]??(take.blob.type==='audio/wav'?'wav':'m4a'),filename=`Recordings/${take.id}.${extension}`;entries.push({name:filename,blob:take.blob});const {blob,...metadata}=take;manifest.push({...metadata,filename});}
    entries.push({name:'Recording-manifest.json',blob:new Blob([JSON.stringify(manifest)],{type:'application/json'})});
    entries.push({name:'Restore-instructions.txt',blob:new Blob(['Extract All on Windows. Import Practice-backup.json in DrumTrainer, then choose Import recordings folder and select Recordings. Your recordings attach by session ID. Keep this ZIP outside the browser before clearing browser data.'],{type:'text/plain'})});
    const zip=await portableZIP(entries,{onProgress:p=>notice(`Preparing portable backup: ${p.completed}/${p.total} files checked.`)});downloadBlob(zip,`DrumTrainer-complete-backup-${snapshot.exportedAt.slice(0,10)}.zip`);notice(`Portable backup prepared with ${snapshot.sessions.length} sessions and ${takes.length} attached recordings. Extract the ZIP to restore its JSON and Recordings folder.`);
  }finally{$('exportBundle').disabled=!!run||!!starting||finishing;}
});
$('restoreNative').onclick = () => nativeArchives.forEach((a,i) => download(a,`DrumTrainer-original-Mac-backup-${i+1}.json`));
$('import').onchange = withError(async event => {
  const file = event.target.files[0]; event.target.value = ''; if (!file) return;
  if (file.size > 500*1024*1024) throw new Error('Backup exceeds 500 MB. Keep the original and use a smaller backup for this edition.');
  const imported = importBackup(JSON.parse(await file.text()));
  const merged = (old,added) => { const values = new Map(old.map(v => [v.id,v])); added.forEach(v => { if (!values.has(v.id)) values.set(v.id,v); }); return [...values.values()]; };
  const converted=convertNativeArchives(imported.nativeArchives);
  const deletedSessions=[...new Set([...deletedSessionIDs,...(imported.deletedSessionIDs??[])])],deletedSongs=[...new Set([...deletedSongIDs,...(imported.deletedSongIDs??[])])];
  const nextExercises=merged(library,imported.exercises),nextSessions=merged(sessions,[...imported.sessions.map(hydrateSession),...converted.sessions].filter(s=>!deletedSessions.includes(s.id))).filter(s=>!deletedSessions.includes(s.id)),nextSongs=merged(songs,[...(imported.songs??[]),...converted.songs].filter(s=>!deletedSongs.includes(s.id))).filter(s=>!deletedSongs.includes(s.id));
  nextSongs.forEach(validateSong);if(nextSongs.length>500)throw new Error('Merged song library exceeds 500 songs.');
  if (nextExercises.length>1000 || nextSessions.length>2000) throw new Error('Merged backup exceeds the Windows library capacity. Your existing data was kept.');
  const nextArchives = [...nativeArchives];
  imported.nativeArchives.forEach(a => { if (!nextArchives.some(old => JSON.stringify(old) === JSON.stringify(a))) nextArchives.push(a); });
  if (nextArchives.length>20) throw new Error('Up to 20 original Mac archives can be kept. Your existing data was kept.');
  library=nextExercises;sessions=nextSessions;songs=nextSongs;nativeArchives=nextArchives;mergeNativeProgress(progress,imported.nativeArchives);
  deletedSessionIDs=deletedSessions;deletedSongIDs=deletedSongs;
  if(imported.settings){settings={...settings,...imported.settings};for(const id of settingControls)if(settings[id]!=null){if($(id).type==='checkbox')$(id).checked=settings[id]===true;else $(id).value=settings[id];}saveSettings();loadMicrophoneProfile();loadCorrections();refreshMacProfiles();}
  if(imported.progress){progress.tempoProgressions=mergeByID(progress.tempoProgressions,imported.progress.tempoProgressions??[]);progress.ceilingRecords=mergeByID(progress.ceilingRecords,imported.progress.ceilingRecords??[]);progress.activeCeilingRun??=imported.progress.activeCeilingRun??null;}
  await persist();refreshExercises();refreshSongs();renderHistory();desktop.showTab('history');notice(`Imported ${imported.exercises.length} exercises, ${imported.sessions.length+converted.sessions.length} detailed sessions and ${converted.songs.length+(imported.songs?.length??0)} songs. Original Mac archives are preserved.`);
});
document.addEventListener('visibilitychange',() => { if (document.hidden && !run?.external && (run || autoTimer)) cancel('Practice paused because this window was hidden. Keep it visible while playing.'); });
window.addEventListener('pagehide',() => { cancel(); stopMicrophone(); stopLiveSimulation();audio?.close(); });
navigator.mediaDevices?.addEventListener('devicechange',withError(refreshAudioDevices));
window.addEventListener('keydown',event => { if (event.code === 'Space' && !['INPUT','SELECT','TEXTAREA','BUTTON'].includes(document.activeElement.tagName)) { event.preventDefault(); run || autoTimer ? cancel('Paused.'):withError(() => begin())(); } });
await withError(refreshAudioDevices)(); loadMicrophoneProfile();refreshSongs();$('customName').value=draft.name;$('grid').value=draft.subdivision;renderEditor();renderSequence();renderHistory();if(settings.desktopPracticeType==='custom'||library.some(e=>e.id===$('exercise').value)){$('customEditorPanel').dataset.editing='true';$('customEditorPanel').dataset.sequence=String(settings.desktopSequence??!!library.find(e=>e.id===$('exercise').value)?.definition.sequenceSteps);if(!settings.draft&&!settings.sequenceDraft)$('loadExercise').click();}desktop.sync();animation=requestAnimationFrame(draw);document.querySelector('main').inert=false;
