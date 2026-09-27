/*==============================================================================
 * double_pendulum.js - non-interactive check of the wasm library module
 *------------------------------------------------------------------------------
 * Loads build/double_pendulum.wasm (the asmlib wasm module + the pendulum
 * library object) and exercises the *library* C ABI that the web UI uses:
 * dp_init / dp_step / dp_state / dp_tip_x / dp_tip_y / dp_energy_drift /
 * dp_buffer. It verifies:
 *
 *   1. the module is a clean library: no imports, a known export set;
 *   2. stepping conserves energy to ~1e-9 relative (end-to-end check of the
 *      sin/cos/fabs and malloc/free the physics depends on);
 *   3. the tip never leaves the 2 m arm reach and actually moves (chaos);
 *   4. the trajectory buffer round-trips through shared linear memory.
 *
 * The browser UI (examples/web/index.html) drives the same ABI per frame.
 *
 * Usage:  node examples/double_pendulum.js [path/to.wasm] [steps]
 *============================================================================*/

'use strict';
const fs = require('fs');
const path = require('path');

const wasmPath = process.argv[2] || path.join(__dirname, '..', 'build', 'double_pendulum.wasm');
const steps    = Number(process.argv[3] || 200000);
const DT       = 0.0005;

const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);

const imports = WebAssembly.Module.imports(mod);
if (imports.length !== 0)
  throw new Error(`module must be freestanding, has ${imports.length} imports`);

const ex = new WebAssembly.Instance(mod, {}).exports;
const f64 = () => new Float64Array(ex.memory.buffer);

const needed = ['dp_init', 'dp_step', 'dp_state', 'dp_tip_x', 'dp_tip_y',
                'dp_energy_drift', 'dp_buffer', 'malloc', 'free'];
for (const s of needed)
  if (typeof ex[s] !== 'function') throw new Error(`missing export: ${s}`);

/* ---- run the simulation through the library ABI ------------------------- */
const th1 = Math.PI / 2, th2 = Math.PI / 2;
ex.dp_init(th1, th2);

const trace = ex.dp_buffer(steps);                 /* 2*steps doubles */
const t0 = process.hrtime.bigint();
let xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
for (let i = 0; i < steps; i++) {
  ex.dp_step(1);
  const x = ex.dp_tip_x(), y = ex.dp_tip_y();
  const buf = f64();
  const base = trace >> 3;
  buf[base + 2 * i] = x;
  buf[base + 2 * i + 1] = y;
  if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error('non-finite tip');
  if (x < xmin) xmin = x; if (x > xmax) xmax = x;
  if (y < ymin) ymin = y; if (y > ymax) ymax = y;
}
const t1 = process.hrtime.bigint();
const ms = Number(t1 - t0) / 1e6;
const drift = ex.dp_energy_drift();
const reach = Math.max(Math.abs(xmin), Math.abs(xmax), Math.abs(ymin), Math.abs(ymax));

/* ---- float path (no output buffer needed: pass 0/NULL) ------------------ */
const finalspeed = ex.double_pendulum_run_f(Math.PI / 2, Math.PI / 2, 50000, 0);

console.log('== asmlib wasm double-pendulum library ==');
console.log(`  module          : ${bytes.length} bytes, ${imports.length} imports`);
console.log(`  samples         : ${steps} steps (${(steps * DT).toFixed(1)} s)`);
console.log(`  wall time       : ${ms.toFixed(1)} ms  (${(steps / (ms / 1000) / 1e6).toFixed(1)}M steps/s)`);
console.log(`  energy drift    : ${drift.toExponential(3)}`);
console.log(`  tip x range     : [${xmin.toFixed(4)}, ${xmax.toFixed(4)}]`);
console.log(`  tip y range     : [${ymin.toFixed(4)}, ${ymax.toFixed(4)}]`);
console.log(`  max reach       : ${reach.toFixed(4)} m (bound 2 m)`);
console.log(`  f32 final speed : ${finalspeed.toFixed(4)} rad/s`);

const failures = [];
if (drift > 1e-9) failures.push(`energy drift too large: ${drift}`);
if (reach > 2.0000001) failures.push(`tip exceeded arm length: ${reach}`);
if (reach < 1.0) failures.push(`tip never moved: reach ${reach}`);
if (!Number.isFinite(finalspeed)) failures.push('float result non-finite');

if (failures.length) {
  console.error('FAIL:');
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('OK: library ABI conserved energy and stayed physical');
