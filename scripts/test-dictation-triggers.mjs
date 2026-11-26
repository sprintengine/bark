import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('../src/dictationTriggers.ts', import.meta.url), 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { holdAction, toggleAction } = await import(`data:text/javascript;base64,${Buffer.from(output).toString('base64')}`);

const state = (phase, extra = {}) => ({ phase, stopPending: false, cancelPending: false, ...extra });

// The toggle (button or shortcut) starts, stops, and cancels.
assert.equal(toggleAction(state('idle')), 'start');
assert.equal(toggleAction(state('error')), 'start');
assert.equal(toggleAction(state('recording')), 'stop');
assert.equal(toggleAction(state('transcribing')), 'cancel');
// A press while the recording is still starting is kept, not dropped.
assert.equal(toggleAction(state('starting')), 'stopAfterStart');
// Requests already under way are not sent twice.
assert.equal(toggleAction(state('recording', { stopPending: true })), 'none');
assert.equal(toggleAction(state('transcribing', { cancelPending: true })), 'none');
assert.equal(toggleAction(state('idle', { stopPending: true })), 'none');

// Hold-to-talk: press starts, release stops.
assert.equal(holdAction(true, state('idle')), 'start');
assert.equal(holdAction(false, state('recording')), 'stop');
assert.equal(holdAction(false, state('starting')), 'stopAfterStart');

// Cross-trigger: a recording started by the toggle is ended by a hold
// release, and one started by a hold is ended by the toggle.
assert.equal(holdAction(true, state('recording')), 'none');
assert.equal(holdAction(false, state('recording')), 'stop');
assert.equal(toggleAction(state('recording')), 'stop');

// A hold never starts over a dictation in flight, and release does nothing
// once the recording is already stopping or transcribing.
assert.equal(holdAction(true, state('transcribing')), 'none');
assert.equal(holdAction(true, state('starting')), 'none');
assert.equal(holdAction(false, state('transcribing')), 'none');
assert.equal(holdAction(false, state('idle')), 'none');
assert.equal(holdAction(false, state('recording', { stopPending: true })), 'none');
