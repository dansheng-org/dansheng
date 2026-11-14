// Development smoke artifacts belong to the selected task runtime, outside source.
import fs from 'node:fs';
import path from 'node:path';

function within(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

export function smokeRuntime(sourceRoot) {
  const selected = process.env.DANSHENG_TASK_RUNTIME;
  if (!selected || !path.isAbsolute(selected)) throw new Error('Enter the task first: DANSHENG_TASK_RUNTIME must select its absolute runtime directory.');
  const runtime = path.resolve(selected);
  if (runtime === path.parse(runtime).root || within(path.resolve(sourceRoot), runtime)) throw new Error('Smoke runtime must stay outside source and filesystem roots.');
  for (let cursor = runtime; ; cursor = path.dirname(cursor)) {
    if (fs.existsSync(cursor) && fs.lstatSync(cursor).isSymbolicLink()) throw new Error('Linked smoke runtime paths are refused.');
    if (path.dirname(cursor) === cursor) break;
  }
  return runtime;
}

export function smokeBinary(runtime, configuration = 'debug') {
  if (process.env.DANSHENG_HOST_BIN) return path.resolve(process.env.DANSHENG_HOST_BIN);
  const target = path.resolve(process.env.CARGO_TARGET_DIR || path.join(runtime, 'cargo-target'));
  if (!within(runtime, target)) throw new Error('Cargo target must remain inside the selected task runtime.');
  return path.join(target, configuration, process.platform === 'win32' ? 'dansheng-host.exe' : 'dansheng-host');
}

export function smokeOutput(runtime, defaultRelative) {
  const selected = process.env.DANSHENG_SMOKE_ROOT;
  if (selected && !path.isAbsolute(selected)) throw new Error('DANSHENG_SMOKE_ROOT must be an absolute path inside the selected runtime.');
  const output = path.resolve(selected || path.join(runtime, defaultRelative));
  if (!within(runtime, output)) throw new Error('Smoke output must remain inside the selected task runtime.');
  for (let cursor = output; ; cursor = path.dirname(cursor)) {
    if (fs.existsSync(cursor) && fs.lstatSync(cursor).isSymbolicLink()) throw new Error('Linked smoke output paths are refused.');
    if (path.dirname(cursor) === cursor) break;
  }
  return output;
}
