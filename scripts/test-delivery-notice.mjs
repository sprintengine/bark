import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('../src/delivery.ts', import.meta.url), 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { deliveryNotice } = await import(`data:text/javascript;base64,${Buffer.from(output).toString('base64')}`);

assert.equal(deliveryNotice('inserted', '⌘V'), null);
assert.equal(deliveryNotice('copied', '⌘V'), null);
assert.equal(deliveryNotice(null, '⌘V'), null);
assert.equal(deliveryNotice(undefined, 'Ctrl+V'), null);
assert.equal(deliveryNotice('insertFailed', '⌘V'), 'Copied — press ⌘V to paste');
assert.equal(deliveryNotice('insertFailed', 'Ctrl+V'), 'Copied — press Ctrl+V to paste');
assert.equal(deliveryNotice('notCopied', '⌘V'), 'Not copied — saved in History');
