import {voices,gm,exercises,subdivisions,makePattern,score,median,importBackup} from './core.mjs';
import {analyzeNoise,makeCalibrationProfile,CalibrationHitCollector,CrosstalkGuard,soundSimilarity} from './audio-core.mjs';
const $ = id => document.getElementById(id);
const text = (id,value) => { $(id).textContent = value; };
const notice = message => text('notice',message);
const key = 'DrumTrainerWindows.settings.v1';
let settings = {};
try { settings = JSON.parse(localStorage.getItem(key) ?? '{}'); } catch { /* Default settings remain usable. */ }
let library = [], sessions = [], nativeArchives = [], db = null;
let audio, midiAccess, stream, micNode, micSource, micMute, clickBus, scheduler, animation, autoTimer;
let run = null, count = 0, peak = 0, noisePeaks = null, currentResult = null, streak = 0, streakKey = null;
let calibration = null, pendingProfile = null, soundRejected = 0, crosstalkRejected = 0, micEpoch = 0;
const crosstalk = new CrosstalkGuard();
const scheduled = new Set(), recent = [], lastKick = new Map();
let draft = {name:'My custom measure',subdivision:'sixteenths',hits:[]};

function openDatabase() {
  return new Promise((resolve,reject) => {
    const req = indexedDB.open('DrumTrainerWindows',1);
    req.onupgradeneeded = () => req.result.createObjectStore('data');
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
      tx.objectStore('data').put({exercises:library,sessions,nativeArchives},'practice');
      tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error);
    });
  } catch (error) { notice(`Could not save practice data: ${error.message} Export a backup now to keep this session.`); }
}
try {
  db = await openDatabase(); const saved = await readDatabase();
  if (saved) { library = saved.exercises ?? []; sessions = saved.sessions ?? []; nativeArchives = saved.nativeArchives ?? []; }
} catch (error) { notice(`Browser storage is unavailable. Practice still works; export a backup to keep your results. ${error.message}`); }

const settingControls = ['bpm','repeats','volume','kickSource','gradeKicks','threshold','lockout','auto','advance','soundFilter','guard','match'];
for (const id of settingControls) {
  if (settings[id] != null) {
    if ($(id).type === 'checkbox') $(id).checked = settings[id] === true;
    else $(id).value = settings[id];
  }
}
function saveSettings() {
  for (const id of settingControls) settings[id] = $(id).type === 'checkbox' ? $(id).checked : $(id).value;
  if (!calibration) { settings.detectors ??= {}; settings.detectors[$('microphone').value] = {threshold:Number($('threshold').value),lockout:Number($('lockout').value)}; }
  try { localStorage.setItem(key,JSON.stringify(settings)); } catch { notice('Settings could not be saved. Export practice data before closing.'); }
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
}
function updateGuide() {
  const d = selectedDefinition();
  text('guide',d.guide ?? (d.sequenceSteps ? 'Saved measure sequence. The sequence’s own repeats determine its length.' : 'Your custom measure, repeated on the selected grid.'));
  $('repeats').disabled = !!d.sequenceSteps || !!run;
  settings.exercise = $('exercise').value;
}
function optionVoices(select) { for (const [v,label] of Object.entries(voices)) select.append(new Option(label,v)); }
optionVoices($('mapVoice'));
loadCorrections(); refreshExercises();

async function ensureAudio() {
  if (!audio) {
    audio = new AudioContext({latencyHint:'interactive'});
    clickBus = audio.createGain(); clickBus.connect(audio.destination);
    audio.addEventListener('statechange',() => {
      if (audio.state !== 'running' && run) cancel('Audio paused or disconnected. The attempt was discarded; press Start to try again.');
    });
    if ($('output').value) {
      if (!audio.setSinkId) throw new Error('Select the output in Windows sound settings.');
      try { await audio.setSinkId($('output').value); }
      catch (error) { $('output').value = ''; loadCorrections(); throw error; }
    }
    if (!audio.setSinkId) text('outputHelp','This browser uses the Windows default output. Choose the Focusrite/headphones in Windows sound settings.');
  }
  await audio.resume();
  if (audio.state !== 'running') throw new Error('Audio could not start. Check the selected output.');
  return audio;
}
// Translate MIDI's monotonic performance timestamp to the output's audible audio clock.
function audibleTime(performanceMs = performance.now()) {
  const stamp = audio?.getOutputTimestamp?.();
  if (stamp?.contextTime > 0 && stamp.performanceTime > 0) return stamp.contextTime*1000+performanceMs-stamp.performanceTime;
  return (audio.currentTime-(audio.outputLatency ?? 0)-(audio.baseLatency ?? 0))*1000+performanceMs-performance.now();
}
function clickAt(time,accent) {
  const osc = audio.createOscillator(), gain = audio.createGain();
  osc.frequency.value = accent ? 1600:1050;
  gain.gain.setValueAtTime(0,time);
  gain.gain.linearRampToValueAtTime(Number($('volume').value),time+.001);
  gain.gain.exponentialRampToValueAtTime(.0001,time+.035);
  osc.connect(gain); gain.connect(clickBus); osc.start(time); osc.stop(time+.04);
  scheduled.add(osc);
  osc.onended = () => { scheduled.delete(osc); osc.disconnect(); gain.disconnect(); };
}
function clearScheduled() {
  for (const osc of scheduled) { try { osc.stop(); } catch { /* Already stopped. */ } }
  scheduled.clear(); clearInterval(scheduler); scheduler = null;
}
function logHit(hit) {
  count++; text('hitCount',`${count} HITS`);
  recent.unshift(`${new Date().toLocaleTimeString()}  ${voices[hit.voice] ?? hit.voice}  ${hit.source}${hit.note != null ? ` · note ${hit.note} · velocity ${hit.velocity}`:''}`);
  if (recent.length > 50) recent.pop(); text('log',recent.join('\n')); $('log').style.whiteSpace = 'pre-wrap';
}
function receive(hit) {
  logHit(hit);
  if (!run || run.demo || run.kind === 'click') return;
  const relative = hit.clock-run.start;
  if (run.kind === 'alignment') {
    if (hit.source !== run.source || relative < -run.beatMs*.4 || relative > run.duration+run.beatMs*.4) return;
    const beat = Math.round(relative/run.beatMs);
    const offset = relative-beat*run.beatMs;
    if (beat >= 0 && beat < 12 && Math.abs(offset) <= run.beatMs*.4 && !run.alignments.has(beat)) run.alignments.set(beat,offset);
    return;
  }
  if (hit.voice === 'kick') {
    const desired = run.kickSource;
    if ((desired === 'midi' && hit.source === 'microphone') || (desired === 'microphone' && hit.source === 'midi')) return;
    const adjusted = hit.clock-(run.options.corrections[hit.source] ?? 0);
    if (desired === 'both' && [...lastKick].some(([source,time]) => source !== hit.source && Math.abs(adjusted-time) < 25)) return;
    lastKick.set(hit.source,adjusted);
  }
  // Count-in is excluded, except the 100 ms early window for the first expected note.
  const alignedRelative = relative-(run.options.corrections[hit.source] ?? 0);
  if (alignedRelative < -100 || alignedRelative > run.pattern.duration+100) return;
  if (run.evidence.length >= 10000) { run.options.dropped = (run.options.dropped ?? 0)+1; return; }
  run.evidence.push({...hit,time:relative});
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
  for (const [id,kind] of [['microphone','audioinput'],['output','audiooutput']]) {
    const previous = $(id).dataset.initialized ? $(id).value : settings[id] || '';
    $(id).dataset.initialized = 'true';
    $(id).replaceChildren(new Option('System default',''));
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
  const ids = ['start','demo','click','bpm','exercise','repeats','gradeKicks','kickSource','advance','threshold','lockout','alignMidi','alignMic','noise','connect','saveExercise','customName','grid','import','export','restoreNative','again','calibrateKick','saveCalibration','soundFilter','guard','match'];
  for (const id of ids) $(id).disabled = active;
  for (const button of $('editor').querySelectorAll('button')) button.disabled = active;
  $('stop').disabled = !active; $('repeats').disabled = active || !!selectedDefinition().sequenceSteps;
  $('saveCalibration').disabled = active || !pendingProfile;
}
function clearAuto() { clearTimeout(autoTimer); autoTimer = null; }
function cancel(message) {
  micEpoch++; cancelCalibration(); crosstalk.reset();
  clearAuto(); clearScheduled(); run = null; lastKick.clear(); setRunning(false);
  text('phase','READY'); text('position','8-beat count-in');
  if (message) notice(message);
}
async function begin(kind = 'practice',demo = false,source = null) {
  clearAuto(); if (run) cancel();
  let pattern;
  if (kind === 'practice') {
    pattern = makePattern(selectedDefinition(),Number($('bpm').value),Number($('repeats').value));
    if (!demo) {
      const needsMidi = pattern.notes.some(n => n.voice !== 'kick') || ($('gradeKicks').checked && $('kickSource').value !== 'microphone');
      const needsMic = $('gradeKicks').checked && pattern.notes.some(n => n.voice === 'kick') && $('kickSource').value !== 'midi';
      if (needsMidi && !midiAccess?.inputs.get($('midi').value)) throw new Error('Connect MIDI and select your kit before starting this exercise.');
      if (needsMic && !stream) throw new Error('Enable the kick microphone, or select MIDI only / turn off Grade kicks.');
      if (!$('gradeKicks').checked && pattern.notes.every(n => n.voice === 'kick')) throw new Error('This exercise contains only kicks. Enable Grade kicks or choose a full-kit exercise.');
    }
  }
  const bpm = Number($('bpm').value);
  if (!Number.isFinite(bpm) || bpm < 40 || bpm > 240) throw new Error('Use 40–240 BPM.');
  if (kind === 'alignment') {
    if (source === 'midi' && !midiAccess?.inputs.get($('midi').value)) throw new Error('Connect and select a MIDI input first.');
    if (source === 'microphone' && !stream) throw new Error('Enable the microphone first.');
  }
  const opts = {gradeKicks:$('gradeKicks').checked,corrections:corrections()};
  if (Object.values(opts.corrections).some(v => !Number.isFinite(v) || Math.abs(v) > 500)) throw new Error('Timing correction must be between −500 and 500 ms.');
  await ensureAudio();
  const beatMs = 60000/bpm, origin = audio.currentTime*1000+300;
  run = {kind,demo,source,pattern,origin,start:origin+(kind === 'click' ? 0:8*beatMs),beatMs,duration:kind === 'click' ? Infinity : kind === 'alignment' ? 12*beatMs : pattern.duration,nextClick:0,evidence:[],options:opts,kickSource:$('kickSource').value,alignments:new Map(),late:0,exerciseId:$('exercise').value,devices:{midi:$('midi').selectedOptions[0]?.textContent,microphone:$('microphone').selectedOptions[0]?.textContent,output:$('output').selectedOptions[0]?.textContent}};
  lastKick.clear(); currentResult = null; $('result').hidden = true; setRunning(true);
  if (demo) run.evidence = pattern.notes.map((n,i) => ({voice:n.voice,time:n.time+[-8,4,11,-3,6][i%5],clock:run.start+n.time,source:'simulation',velocity:n.accent ? 120:n.ghost ? 25:80}));
  notice(kind === 'alignment' ? `After 8 count-in clicks, play one ${source === 'microphone' ? 'kick':'MIDI pad'} hit on each of 12 clicks.` : demo ? 'Simulation: generated hits demonstrate the timeline and scoring. This run is not saved to history.' : kind === 'click' ? 'Metronome running. Cancel to stop.' : 'Eight count-in clicks. Begin playing when the practice playhead moves.');
  const activeRun = run;
  scheduler = setInterval(() => {
    if (run !== activeRun) return;
    const now = audio.currentTime*1000;
    while (activeRun.origin+activeRun.nextClick*beatMs < now+140) {
      const when = activeRun.origin+activeRun.nextClick*beatMs;
      if (when >= activeRun.start+activeRun.duration) break;
      if (when < now+10) { activeRun.late++; activeRun.nextClick++; continue; }
      clickAt(when/1000,activeRun.nextClick%4 === 0); activeRun.nextClick++;
    }
    const inputTail = activeRun.kind === 'practice' ? Math.max(0,...Object.values(activeRun.options.corrections)):0;
    if (audibleTime() > activeRun.start+activeRun.duration+180+inputTail) finish();
  },25);
}

function finish() {
  const completed = run; if (!completed) return;
  clearScheduled(); run = null; setRunning(false); text('phase','COMPLETE'); text('position','Run complete');
  if (completed.kind === 'alignment') {
    const offsets = [...completed.alignments.values()], correction = median(offsets);
    if (offsets.length < 8 || median(offsets.map(v => Math.abs(v-correction))) > 40 || completed.late) {
      notice('Alignment was too inconsistent to save. Repeat with one hit on each of 12 clicks; keep this window visible.'); return;
    }
    saveCorrection(completed.source,Math.round(correction));
    notice(`Saved ${Math.round(correction)} ms ${completed.source === 'midi' ? 'MIDI':'microphone'} correction from ${offsets.length} clicks for the selected input/output. This includes your playing bias.`); return;
  }
  completed.options.dropped = (completed.options.dropped ?? 0)+completed.late;
  const metrics = score(completed.pattern,completed.evidence,completed.options);
  const session = {id:crypto.randomUUID(),name:completed.pattern.name,bpm:completed.pattern.bpm,date:new Date().toISOString(),pattern:completed.pattern,evidence:completed.evidence,metrics,options:completed.options,devices:completed.devices,demo:completed.demo};
  currentResult = session; showResult(session);
  if (!completed.demo) { sessions.unshift(session); if (sessions.length > 2000) sessions.length = 2000; persist(); renderHistory(); }
  const progressionKey = JSON.stringify([completed.exerciseId,completed.pattern.bpm,completed.options.gradeKicks,completed.devices,completed.options.corrections]);
  if (progressionKey !== streakKey) { streak = 0; streakKey = progressionKey; }
  streak = !completed.demo && metrics.clean ? streak+1 : 0;
  if (streak >= 3 && $('advance').checked) { $('bpm').value = Math.min(240,completed.pattern.bpm+5); streak = 0; saveSettings(); }
  notice(completed.demo ? 'Simulation complete. Connect your devices to capture your playing.' : completed.late ? 'Completed with a scheduling interruption. This run cannot qualify as clean; keep the window visible and close demanding apps.' : metrics.clean ? 'Clean run. Good timing and accuracy.' : 'Run saved. Review missed notes and timing, then try again.');
  if ($('auto').checked && !completed.demo && !document.hidden) {
    notice('Run saved. Next count-in starts in 7 seconds. Cancel pauses automatic repeats.');
    $('stop').disabled = false;
    autoTimer = setTimeout(() => { $('stop').disabled = true; withError(() => begin())(); },7000);
  }
}
const ms = v => v == null ? '—':`${v.toFixed(1)} ms`;
const percent = v => `${Math.round(v*100)}%`;
function showResult(s) {
  currentResult = s; $('result').hidden = false;
  const m = s.metrics; text('resultTitle',`${s.demo ? 'Simulated · ':''}${m.clean ? 'Clean run':'Practice results'} · ${s.bpm} BPM`);
  $('metrics').replaceChildren();
  for (const [value,label] of [[percent(m.recall),'Notes correct'],[ms(m.error),'Median timing error'],[ms(m.bias),'Timing bias · − early / + late'],[`${m.missed} / ${m.extra}`,'Missed / extra']]) {
    const card = document.createElement('div'); card.className = 'metric';
    const strong = document.createElement('strong'); strong.textContent = value;
    const span = document.createElement('span'); span.textContent = label; card.append(strong,span); $('metrics').append(card);
  }
  const summary = document.createElement('p'); summary.className = 'hint';
  summary.textContent = `Precision ${percent(m.precision)} · Wrong voice ${m.wrong} · Ambiguous ${m.ambiguous ?? 0} · Timing consistency ${ms(m.consistency)} · Simultaneous hit spread ${ms(m.spread)}${m.stableTiming ? ` · Steady shared bias: grading uses ${ms(m.stableTiming.adjustedMedianAbsoluteErrorMilliseconds)} centered error`:''}${s.options?.dropped ? ' · Interrupted / dropped evidence':''}`;
  const table = document.createElement('table');
  table.innerHTML = '<thead><tr><th>Voice</th><th>Correct / expected</th><th>Median error</th></tr></thead>';
  for (const v of m.perVoice ?? []) {
    const tr = document.createElement('tr');
    for (const cell of [voices[v.voice] ?? v.voice,`${v.correct} / ${v.expected}`,ms(v.error)]) { const td = document.createElement('td'); td.textContent = cell; tr.append(td); }
    table.append(tr);
  }
  $('voiceMetrics').replaceChildren(summary,table); $('ledger').replaceChildren();
  for (const r of (m.results ?? []).slice(0,2000)) {
    const tr = document.createElement('tr'); tr.className = r.status === 'correct' && (!r.dynamics || r.dynamics === 'achieved') ? 'good':'bad';
    for (const value of [r.expected?.measure ?? '—',voices[r.expected?.voice] ?? '—',voices[r.actual?.voice] ?? '—',`${r.status}${r.dynamics ? ` · ${r.dynamics}`:''}`,r.offset == null ? '—':`${r.offset > 0 ? '+':''}${ms(r.offset)}`]) { const td = document.createElement('td'); td.textContent = value; tr.append(td); }
    $('ledger').append(tr);
  }
}
function nativeDate(value) { return typeof value === 'number' ? new Date((value+978307200)*1000):new Date(value); }
function renderHistory() {
  const windows = sessions.map(s => ({s,date:new Date(s.date),native:false}));
  const unique = new Map();
  nativeArchives.forEach(a => (a.sessions ?? []).forEach(s => unique.set(s.id,{s,date:nativeDate(s.completedAt),native:true})));
  const entries = [...windows,...unique.values()].sort((a,b) => b.date-a.date);
  $('history').replaceChildren();
  $('restoreNative').hidden = !nativeArchives.length;
  if (!entries.length) { const p = document.createElement('p'); p.className = 'empty'; p.textContent = 'Your completed runs will appear here.'; $('history').append(p); return; }
  for (const entry of entries.slice(0,50)) {
    const {s,date,native} = entry, row = document.createElement('div'); row.className = 'history-row';
    const copy = document.createElement('div'); copy.textContent = `${s.name ?? s.exerciseName} · ${s.bpm} BPM`;
    const small = document.createElement('small'); small.textContent = `${date.toLocaleString()} · ${percent(native ? s.recall:s.metrics.recall)} correct · ${ms(native ? s.medianAbsoluteErrorMilliseconds:s.metrics.error)}${native ? ' · Mac archive':''}`; copy.append(small); row.append(copy);
    if (!native) { const button = document.createElement('button'); button.className = 'secondary'; button.textContent = 'Details'; button.onclick = () => { clearAuto(); showResult(s); $('result').scrollIntoView({behavior:'smooth',block:'center'}); }; row.append(button); }
    $('history').append(row);
  }
  if (entries.length > 50) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = `Showing the latest 50 of ${entries.length} sessions. Export includes all sessions.`; $('history').append(p); }
}
function download(value,name) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(value,null,2)],{type:'application/json'}));
  const a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000);
}
function renderEditor() {
  const lanes = ['crash1','ride','closedHiHat','openHiHat','highTom','midTom','lowTom','snare','kick'], slots = subdivisions[draft.subdivision]*4;
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
        if (!note) draft.hits.push({slot,voice,allowedVoices:[]});
        else if (!note.accent && !note.ghost) note.accent = true;
        else if (note.accent) { note.accent = false; note.ghost = true; }
        else draft.hits = draft.hits.filter(h => h !== note);
        renderEditor();
      }; row.append(button);
    }
  }
}

// Draw upcoming beats against a fixed playhead. UI refreshes never schedule audio or hits.
function draw() {
  const canvas = $('score'), width = canvas.clientWidth, height = canvas.clientHeight, dpr = window.devicePixelRatio || 1;
  if (canvas.width !== Math.round(width*dpr) || canvas.height !== Math.round(height*dpr)) { canvas.width = Math.round(width*dpr); canvas.height = Math.round(height*dpr); }
  const c = canvas.getContext('2d'); c.setTransform(dpr,0,0,dpr,0,0); c.clearRect(0,0,width,height);
  let pattern = run?.pattern ?? currentResult?.pattern;
  if (!pattern) { try { pattern = makePattern(selectedDefinition(),Number($('bpm').value),Number($('repeats').value)); } catch { animation = requestAnimationFrame(draw); return; } }
  const t = run?.kind === 'practice' ? Math.max(0,audibleTime()-run.start):0;
  const laneVoices = [...new Set(pattern.notes.map(n => n.voice))], rowH = Math.min(45,(height-45)/Math.max(laneVoices.length,1)), left = 105;
  const pixelsPerBeat = Math.max(35,(width-left-20)/8), pixelsPerMs = pixelsPerBeat/pattern.beatMs, playhead = left+30;
  c.font = '11px Segoe UI, system-ui'; c.textBaseline = 'middle';
  laneVoices.forEach((voice,i) => { const y=40+i*rowH; c.fillStyle='#94a1b7'; c.fillText(voices[voice] ?? voice,10,y); c.strokeStyle='#273243'; c.beginPath(); c.moveTo(left,y); c.lineTo(width,y); c.stroke(); });
  for (let beat=Math.max(0,Math.floor(t/pattern.beatMs)-1);beat<Math.min(pattern.measures*4,Math.floor(t/pattern.beatMs)+10);beat++) {
    const x = playhead+(beat*pattern.beatMs-t)*pixelsPerMs;
    if (x < left) continue;
    c.strokeStyle=beat%4===0 ? '#4b596e':'#273243'; c.beginPath(); c.moveTo(x,24); c.lineTo(x,height); c.stroke();
    c.fillStyle='#8392aa'; c.fillText(beat%4===0 ? `${Math.floor(beat/4)+1} · 1`:`${beat%4+1}`,x+4,13);
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
  if (run) {
    const relative = audibleTime()-run.start;
    if (relative < 0 && run.kind !== 'click') { const remaining = Math.min(8,Math.ceil(-relative/run.beatMs)); text('phase','COUNT IN'); text('position',`Count-in · ${remaining} clicks to go`); }
    else { text('phase',run.kind==='alignment' ? 'ALIGNING':run.kind==='click' ? 'CLICK':'PLAYING'); text('position',run.kind==='alignment' ? `Click ${Math.min(12,Math.floor(relative/run.beatMs)+1)} of 12` : `Measure ${Math.min(pattern.measures,Math.floor(Math.max(0,relative)/run.beatMs/4)+1)} · beat ${Math.floor(Math.max(0,relative)/run.beatMs)%4+1}`); }
  }
  animation = requestAnimationFrame(draw);
}

$('connect').onclick = withError(connectMidi);
$('midi').onchange = () => { cancel('MIDI input changed. Select Start when ready.'); wireMidi(); settings.midi = $('midi').value; loadCorrections(); saveSettings(); };
$('listen').onclick = withError(async () => { cancel(); if (stream) { stopMicrophone(); notice('Microphone disabled.'); } else await startMicrophone(); });
$('microphone').onchange = withError(async () => { cancel('Microphone changed.'); const wasListening = !!stream; stopMicrophone(); settings.microphone = $('microphone').value; loadCorrections(); loadMicrophoneProfile(); saveSettings(); if (wasListening) await startMicrophone(); });
$('output').onchange = withError(async () => { cancel('Output changed. Check timing alignment with this output.'); await ensureAudio(); if (audio.setSinkId) await audio.setSinkId($('output').value); else if ($('output').value) { $('output').value = ''; notice('Select the output in Windows sound settings.'); } settings.output = $('output').value; loadCorrections(); saveSettings(); });
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
$('alignMidi').onclick = withError(() => begin('alignment',false,'midi'));
$('alignMic').onclick = withError(() => begin('alignment',false,'microphone'));
$('stop').onclick = () => cancel('Practice and automatic repeats paused. No interrupted attempt was saved.');
$('exercise').onchange = () => { cancel(); currentResult = null; updateGuide(); saveSettings(); };
for (const id of ['bpm','repeats','gradeKicks','kickSource']) $(id).onchange = () => { cancel(); currentResult = null; saveSettings(); };
for (const id of ['auto','advance','volume']) $(id).onchange = () => { if (id==='auto' && !$('auto').checked) { clearAuto(); if (!run) $('stop').disabled = true; } saveSettings(); };
$('grid').onchange = () => { draft.subdivision = $('grid').value; draft.hits = []; renderEditor(); };
$('saveExercise').onclick = withError(async () => { draft.name = $('customName').value.trim() || 'Custom measure'; makePattern(draft,120,1); if (library.length>=1000) throw new Error('Exercise library is full.'); const saved = {id:crypto.randomUUID(),definition:structuredClone(draft)}; library.push(saved); await persist(); refreshExercises(); $('exercise').value = saved.id; updateGuide(); saveSettings(); notice('Exercise saved. Select Start to practice it.'); });
$('export').onclick = () => download({format:'DrumTrainerWindows',version:1,exportedAt:new Date().toISOString(),exercises:library,sessions,nativeArchives},`DrumTrainer-Windows-${new Date().toISOString().slice(0,10)}.json`);
$('restoreNative').onclick = () => nativeArchives.forEach((a,i) => download(a,`DrumTrainer-original-Mac-backup-${i+1}.json`));
$('import').onchange = withError(async event => {
  const file = event.target.files[0]; event.target.value = ''; if (!file) return;
  if (file.size > 150*1024*1024) throw new Error('Backup exceeds 150 MB. Keep the original and use a smaller backup for this edition.');
  const imported = importBackup(JSON.parse(await file.text()));
  const merged = (old,added) => { const values = new Map(old.map(v => [v.id,v])); added.forEach(v => { if (!values.has(v.id)) values.set(v.id,v); }); return [...values.values()]; };
  const nextExercises = merged(library,imported.exercises), nextSessions = merged(sessions,imported.sessions);
  if (nextExercises.length>1000 || nextSessions.length>2000) throw new Error('Merged backup exceeds the Windows library capacity. Your existing data was kept.');
  const nextArchives = [...nativeArchives];
  imported.nativeArchives.forEach(a => { if (!nextArchives.some(old => JSON.stringify(old) === JSON.stringify(a))) nextArchives.push(a); });
  if (nextArchives.length>20) throw new Error('Up to 20 original Mac archives can be kept. Your existing data was kept.');
  library = nextExercises; sessions = nextSessions; nativeArchives = nextArchives;
  await persist(); refreshExercises(); renderHistory(); notice(`Imported ${imported.exercises.length} exercises and ${imported.sessions.length} Windows sessions. Original Mac archives are preserved; Mac songs and audio recordings are not playable in this edition.`);
});
document.addEventListener('visibilitychange',() => { if (document.hidden && (run || autoTimer)) cancel('Practice paused because this window was hidden. Keep it visible while playing.'); });
window.addEventListener('pagehide',() => { cancel(); stopMicrophone(); audio?.close(); });
navigator.mediaDevices?.addEventListener('devicechange',withError(refreshAudioDevices));
window.addEventListener('keydown',event => { if (event.code === 'Space' && !['INPUT','SELECT','TEXTAREA','BUTTON'].includes(document.activeElement.tagName)) { event.preventDefault(); run || autoTimer ? cancel('Paused.'):withError(() => begin())(); } });
await withError(refreshAudioDevices)(); loadMicrophoneProfile(); renderEditor(); renderHistory(); animation = requestAnimationFrame(draw);
