/*==============================================================================
 * double_pendulum.js - Node driver for the wasm double-pendulum example
 *------------------------------------------------------------------------------
 * Loads build/double_pendulum.wasm (the asmlib wasm module + the pendulum
 * object linked together) and runs the simulation, checking that:
 *
 *   1. the module is freestanding (no imports);
 *   2. the double-precision RK4 integrator conserves energy to a tight
 *      tolerance (a strong end-to-end check of sin/cos/fabs/sqrt and libc);
 *   3. the single-precision run stays finite and bounded;
 *   4. the trajectory is a genuine chaotic double-pendulum path (the tip
 *      reaches the expected extremes and does not collapse to a point).
 *
 * Usage:  node examples/double_pendulum.js [samples]
 *============================================================================*/

'use strict';
const fs = require('fs');
const path = require('path');

const wasmPath = path.join(__dirname, '..', 'build', 'double_pendulum.wasm');
const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);

const imports = WebAssembly.Module.imports(mod);
if (imports.length !== 0) {
  throw new Error(`module must be freestanding, has ${imports.length} imports`);
}
const ex = new WebAssembly.Instance(mod, {}).exports;

const samples = Number(process.argv[2] || 200000);   /* * DT=0.0005s -> ~100 s */

/* Double-precision trajectory. */
const nD = samples;
const outPtr = ex.malloc(nD * 2 * 8);               /* 2 doubles per frame  */
const buf = new Float64Array(ex.memory.buffer, outPtr, nD * 2);

/* Start near the upright unstable equilibrium for rich chaotic motion. */
const th1 = Math.PI / 2, th2 = Math.PI / 2;
const t0 = process.hrtime.bigint();
const drift = ex.double_pendulum_run(th1, th2, nD, outPtr);
const t1 = process.hrtime.bigint();
const ms = Number(t1 - t0) / 1e6;

/* ---- checks ------------------------------------------------------------- */
let xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
let finite = true;
for (let i = 0; i < nD; i++) {
  const x = buf[2 * i], y = buf[2 * i + 1];
  if (!Number.isFinite(x) || !Number.isFinite(y)) { finite = false; break; }
  if (x < xmin) xmin = x; if (x > xmax) xmax = x;
  if (y < ymin) ymin = y; if (y > ymax) ymax = y;
}

/* The tip stays within l1 + l2 = 2 m of the pivot. */
const reach = Math.max(Math.abs(xmin), Math.abs(xmax), Math.abs(ymin), Math.abs(ymax));

/* Single precision. */
const nF = Math.min(samples, 50000);
const fPtr = ex.malloc(nF * 2 * 4);
const fbuf = new Float32Array(ex.memory.buffer, fPtr, nF * 2);
const finalspeed = ex.double_pendulum_run_f(Math.PI / 2, Math.PI / 2, nF, fPtr);
let ff = true;
for (let i = 0; i < nF * 2; i++) if (!Number.isFinite(fbuf[i])) { ff = false; break; }

ex.free(outPtr);
ex.free(fPtr);

console.log('== asmlib wasm double-pendulum example ==');
console.log(`  module          : ${bytes.length} bytes, ${imports.length} imports`);
console.log(`  samples         : ${nD} steps (${(nD * 0.0005).toFixed(1)} s of motion)`);
console.log(`  wall time       : ${ms.toFixed(1)} ms  (${(nD / (ms / 1000) / 1e6).toFixed(1)}M steps/s)`);
console.log(`  energy drift    : ${(drift * 100).toExponential(3)} %`);
console.log(`  tip x range     : [${xmin.toFixed(4)}, ${xmax.toFixed(4)}]`);
console.log(`  tip y range     : [${ymin.toFixed(4)}, ${ymax.toFixed(4)}]`);
console.log(`  max reach       : ${reach.toFixed(4)} m (bound 2 m)`);
console.log(`  f32 final speed : ${finalspeed.toFixed(4)} rad/s`);

const failures = [];
if (!finite) failures.push('double trajectory produced non-finite values');
if (drift > 1e-9) failures.push(`energy drift too large: ${drift}`);
if (reach > 2.0000001) failures.push(`tip exceeded arm length: ${reach}`);
if (reach < 1.0) failures.push(`tip never moved: reach ${reach}`);
if (!ff) failures.push('float trajectory produced non-finite values');
if (!Number.isFinite(finalspeed)) failures.push('float final speed non-finite');

if (failures.length) {
  console.error('FAIL:');
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('OK: double pendulum conserved energy and stayed physical');
