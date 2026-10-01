// Execute the actual QML JavaScript with a minimal Process lifecycle harness.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const qml = fs.readFileSync(path.join(__dirname, '..', 'TrackPoint.qml'), 'utf8');

function blockAfter(marker, source = qml) {
  const markerStart = source.indexOf(marker);
  assert.ok(markerStart >= 0, marker);
  const start = source.indexOf('{', markerStart);
  assert.ok(start >= 0, marker);
  let depth = 1, end = start + 1;
  // These handlers have no braces inside string literals or comments.
  while (depth && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  return source.slice(start + 1, end - 1);
}

function harness() {
  const later = [];
  const ctx = {
    deviceEnabled: true, device: '', sensitivity: 0, status: '',
    deviceQueue: [], stateRevision: 0, helper: 'control.py',
    deviceWriter: { running: false, completed: false, command: [] },
    reader: { running: false, revision: 0 }, writer: { running: false },
    Qt: { callLater: fn => later.push(fn) }
  };
  ctx.root = ctx;
  // Unqualified Process properties in QML resolve to that Process instance.
  // Forward them instead of resetting separate globals in simulated events.
  for (const name of ['completed', 'running']) {
    Object.defineProperty(ctx, name, {
      get: () => ctx.deviceWriter[name],
      set: value => { ctx.deviceWriter[name] = value; }
    });
  }
  vm.createContext(ctx);
  for (const name of ['refreshDevice', 'setDeviceEnabled', 'requestDevice', 'startDeviceWrite', 'deviceIpc']) {
    const start = qml.indexOf('  function ' + name + '(');
    const brace = qml.indexOf('{', start);
    const declaration = qml.slice(start, brace);
    vm.runInContext(declaration + '{' + blockAfter('function ' + name + '(') + '}', ctx);
  }
  const readerCode = blockAfter('onStreamFinished:', qml.slice(qml.indexOf('    id: reader')));
  const deviceCode = qml.slice(qml.indexOf('    id: deviceWriter'));
  const streamCode = blockAfter('onStreamFinished:', deviceCode);
  const exitCode = blockAfter('onExited:', deviceCode);
  const runningCode = blockAfter('onRunningChanged:', deviceCode);
  const timerCode = blockAfter('Timer {');
  const timerTrigger = timerCode.match(/onTriggered:\s*([^\n]+)/);
  assert.ok(timerTrigger, 'periodic refresh callback');
  const ipcCode = blockAfter('IpcHandler {');
  function run(code, vars = {}) {
    Object.assign(ctx, vars);
    return vm.runInContext('(function() {' + code + '})()', ctx);
  }
  return {
    ctx,
    tick() {
      assert.match(timerCode, /running:\s*true\b/);
      assert.match(timerCode, /repeat:\s*true\b/);
      run(timerTrigger[1]);
    },
    panel(method, action) {
      return run(blockAfter('function ' + method + '(', ipcCode), { action });
    },
    read(data) {
      ctx.reader.running = false;
      run(readerCode, { text: JSON.stringify(data) });
    },
    finish(data, exit = 0) {
      // Quickshell clears running, delivers stdout, emits exited, then
      // runningChanged. FailedToStart emits only runningChanged.
      ctx.deviceWriter.running = false;
      run(streamCode, { text: JSON.stringify(data) });
      run(exitCode, { exitCode: exit, exitStatus: 0 });
      run(runningCode);
      while (later.length) later.shift()();
    },
    failedStart() {
      ctx.deviceWriter.running = false;
      run(runningCode);
      while (later.length) later.shift()();
    }
  };
}

test('off followed immediately by on executes both in order', () => {
  const h = harness(), c = h.ctx;
  assert.equal(c.deviceIpc('off'), 'queued off');
  assert.equal(c.deviceIpc('on'), 'queued on');
  assert.equal(c.deviceWriter.command[2], 'off');
  h.finish({ enabled: false, device: 'trackpoint' });
  assert.equal(c.deviceWriter.command[2], 'on');
  h.finish({ enabled: true, device: 'trackpoint' });
  assert.equal(c.deviceEnabled, true);
  assert.equal(c.deviceQueue.length, 0);
});

test('toggle is passed unchanged regardless of cached state', () => {
  for (const enabled of [true, false]) {
    const { ctx: c } = harness();
    c.deviceEnabled = enabled;
    assert.equal(c.deviceIpc('toggle'), 'queued toggle');
    assert.equal(c.deviceWriter.command[2], 'toggle');
  }
});

test('a read from before a completed action cannot overwrite it', () => {
  const h = harness(), c = h.ctx;
  c.refreshDevice();
  c.deviceIpc('off');
  h.finish({ enabled: false, device: 'trackpoint' });
  h.read({ enabled: true, value: 0.25 });
  assert.equal(c.deviceEnabled, false);
  assert.equal(c.status, 'TrackPoint off');
});

test('refresh waits for pending writes, then observes external changes', () => {
  const h = harness(), c = h.ctx;
  c.deviceIpc('off');
  c.refreshDevice();
  assert.equal(c.reader.running, false);
  h.finish({ enabled: false });
  c.refreshDevice();
  assert.equal(c.reader.running, true);
  h.read({ enabled: true, value: 0.5 });
  assert.equal(c.deviceEnabled, true);
  assert.equal(c.sensitivity, 0.5);
});

test('periodic refresh repeatedly observes external changes after each read finishes', () => {
  const h = harness(), c = h.ctx;
  for (const data of [
    { enabled: false, value: -0.2 },
    { enabled: true, value: 0.4 },
    { enabled: false, value: 0 }
  ]) {
    h.tick();
    assert.equal(c.reader.running, true);
    h.read(data);
    assert.equal(c.reader.running, false);
    assert.equal(c.deviceEnabled, data.enabled);
    assert.equal(c.sensitivity, data.value);
  }
});

test('helper failure preserves known state and still runs queued recovery', () => {
  const h = harness(), c = h.ctx;
  c.deviceIpc('off'); c.deviceIpc('on');
  h.finish({ error: 'validation failed' }, 1);
  assert.equal(c.deviceEnabled, true);
  assert.equal(c.deviceWriter.command[2], 'on');
  h.finish({ enabled: true });
  assert.equal(c.status, 'TrackPoint on');
});

test('failed process startup reports error and does not strand the queue', () => {
  const h = harness(), c = h.ctx;
  c.deviceIpc('off'); c.deviceIpc('on');
  h.failedStart();
  assert.equal(c.deviceWriter.command[2], 'on');
  h.failedStart();
  assert.equal(c.status, 'Could not start the TrackPoint helper.');
  assert.equal(c.deviceQueue.length, 0);
});

test('failed startup after a successful request resets completion and reports failure', () => {
  const h = harness(), c = h.ctx;
  c.deviceIpc('off');
  h.finish({ enabled: false });
  assert.equal(c.deviceWriter.completed, true);
  c.deviceIpc('on');
  assert.equal(c.deviceWriter.completed, false);
  h.failedStart();
  assert.equal(c.status, 'Could not start the TrackPoint helper.');
  assert.equal(c.deviceEnabled, false);
  assert.equal(c.deviceQueue.length, 0);
  c.deviceIpc('on');
  h.finish({ enabled: true });
  assert.equal(c.status, 'TrackPoint on');
});

test('device IPC preserves existing panel open, close, show, hide, and toggle methods', () => {
  const h = harness(), c = h.ctx;
  const calls = [];
  for (const method of ['open', 'close', 'toggle']) {
    c[method] = () => calls.push(method);
  }
  assert.match(qml, /manageIpc:\s*false\b/);
  for (const method of ['open', 'close', 'show', 'hide', 'toggle']) h.panel(method);
  assert.deepEqual(calls, ['open', 'close', 'open', 'close', 'toggle']);
  assert.equal(h.panel('device', 'off'), 'queued off');
  assert.equal(c.deviceWriter.command[2], 'off');
  assert.deepEqual(calls, ['open', 'close', 'open', 'close', 'toggle']);
});

test('invalid and over-capacity requests explicitly reject without enqueueing', () => {
  const { ctx: c } = harness();
  assert.match(c.deviceIpc('invalid'), /^usage:/);
  assert.equal(c.deviceWriter.running, false);
  for (let i = 0; i < 33; i++) assert.equal(c.deviceIpc('toggle'), 'queued toggle');
  assert.match(c.deviceIpc('on'), /^busy:/);
  assert.equal(c.deviceQueue.length, 32);
});
