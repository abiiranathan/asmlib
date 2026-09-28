/*==============================================================================
 * image_edit.js - non-interactive check of the wasm image-editing module
 *------------------------------------------------------------------------------
 * Loads build/image_edit.wasm and drives the same C ABI the browser UI uses:
 * ie_adjust / ie_grayscale / ie_invert / ie_convolve3 / ie_box_blur /
 * ie_sharpen / ie_warp / ie_rotate. It checks the module is freestanding and
 * that the operations behave correctly on a synthetic RGBA image.
 *
 * Usage:  node examples/image_edit.js [path/to.wasm]
 *============================================================================*/

'use strict';
const fs = require('fs');
const path = require('path');

const wasmPath = process.argv[2] || path.join(__dirname, '..', 'build', 'image_edit.wasm');
const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);

const imports = WebAssembly.Module.imports(mod);
if (imports.length !== 0)
  throw new Error(`module must be freestanding, has ${imports.length} imports`);

const ex = new WebAssembly.Instance(mod, {}).exports;
const needed = ['ie_adjust', 'ie_grayscale', 'ie_invert', 'ie_convolve3',
                'ie_box_blur', 'ie_sharpen', 'ie_warp', 'ie_rotate', 'malloc', 'free'];
for (const s of needed)
  if (typeof ex[s] !== 'function') throw new Error(`missing export: ${s}`);

const W = 64, H = 48, NPX = W * H;
const src = ex.malloc(NPX * 4);
const dst = ex.malloc(NPX * 4);
const kern = ex.malloc(9 * 4);
const mem = () => new Uint8Array(ex.memory.buffer);

function gradient() {
  const img = new Uint8Array(NPX * 4);
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      img[i] = (x * 4) & 255; img[i + 1] = (y * 5) & 255; img[i + 2] = ((x + y) * 2) & 255; img[i + 3] = 255;
    }
  /* a white square so edges/blur have something to work on */
  for (let y = 8; y < 24; y++)
    for (let x = 8; x < 24; x++) {
      const i = (y * W + x) * 4;
      img[i] = img[i + 1] = img[i + 2] = 255;
    }
  return img;
}
const flat = (r, g, b) => { const a = new Uint8Array(NPX * 4); for (let i = 0; i < NPX; i++) { a[4*i] = r; a[4*i+1] = g; a[4*i+2] = b; a[4*i+3] = 255; } return a; };
const upload = (img) => mem().set(img, src);
const download = (base) => mem().slice(base, base + NPX * 4);
const maxdiff = (a, b, chans) => { let m = 0; for (let i = 0; i < NPX; i++) for (let c = 0; c < chans; c++) m = Math.max(m, Math.abs(a[4*i+c] - b[4*i+c])); return m; };

const failures = [];
const check = (cond, msg) => { if (!cond) failures.push(msg); };

const img = gradient();

/* 1. grayscale -> R == G == B */
upload(img); ex.ie_grayscale(src, NPX);
{
  const g = download(src);
  let mono = true;
  for (let i = 0; i < NPX; i++)
    if (g[4*i] !== g[4*i+1] || g[4*i+1] !== g[4*i+2]) { mono = false; break; }
  check(mono, 'grayscale did not produce R==G==B');
}

/* 2. invert is its own inverse */
upload(img); ex.ie_invert(src, NPX); ex.ie_invert(src, NPX);
check(maxdiff(download(src), img, 3) === 0, 'double invert did not restore the image');

/* 3. adjust(1,1,1) is (nearly) the identity */
upload(img); ex.ie_adjust(src, NPX, 1, 1, 1);
check(maxdiff(download(src), img, 3) <= 1, 'adjust identity drifted');

/* 4. adjust brightness=0.5 halves the channels (within rounding) */
upload(img); ex.ie_adjust(src, NPX, 0.5, 1, 1);
{
  const a = download(src); let ok = true;
  for (let i = 0; i < NPX; i++)
    for (let c = 0; c < 3; c++)
      if (Math.abs(a[4*i+c] - img[4*i+c] * 0.5) > 2) ok = false;
  check(ok, 'adjust brightness=0.5 mismatch');
}

/* 5. identity convolution returns the source */
new Float32Array(ex.memory.buffer, kern, 9).set([0,0,0, 0,1,0, 0,0,0]);
upload(img); ex.ie_convolve3(src, dst, W, H, kern, 0);
check(maxdiff(download(dst), img, 3) === 0, 'identity kernel changed the image');

/* 6. box blur / sharpen leave a flat image flat */
{
  const f = flat(100, 150, 200);
  upload(f); ex.ie_box_blur(src, dst, W, H);
  check(maxdiff(download(dst), f, 3) === 0, 'box blur of a flat image changed it');
  upload(f); ex.ie_sharpen(src, dst, W, H);
  check(maxdiff(download(dst), f, 3) === 0, 'sharpen of a flat image changed it');
}

/* 7. blur reduces the high-frequency energy of the white square edge */
{
  const sharp = gradient();
  upload(sharp); ex.ie_box_blur(src, dst, W, H);
  const blurred = download(dst);
  /* the corner pixel of the white square jumps to a background pixel */
  const iAt = (y, x) => (y * W + x) * 4;
  const edge = Math.abs(sharp[iAt(8, 8)] - sharp[iAt(8, 7)]) + Math.abs(sharp[iAt(8, 8)] - sharp[iAt(7, 8)]);
  const edgeB = Math.abs(blurred[iAt(8, 8)] - blurred[iAt(8, 7)]) + Math.abs(blurred[iAt(8, 8)] - blurred[iAt(7, 8)]);
  check(edgeB < edge, 'blur did not smooth the edge');
}

/* 8. rotate by 0 is the identity; a full turn also returns the image */
upload(img); ex.ie_rotate(src, W, H, dst, 0);
check(maxdiff(download(dst), img, 3) === 0, 'rotate(0) is not the identity');
upload(img); ex.ie_rotate(src, W, H, dst, 2 * Math.PI);
check(maxdiff(download(dst), img, 3) <= 2, 'rotate(2pi) drifted');

/* 9. warp with the identity matrix matches rotate(0) */
{
  const id = [1,0,0, 0,1,0, 0,0,1];
  const m = ex.malloc(9 * 4);
  new Float32Array(ex.memory.buffer, m, 9).set(id);
  upload(img); ex.ie_warp(src, W, H, dst, W, H, m);
  check(maxdiff(download(dst), img, 3) === 0, 'identity warp mismatch');
  ex.free(m);
}

console.log('== asmlib wasm image-editing library ==');
console.log(`  module          : ${bytes.length} bytes, ${imports.length} imports`);
console.log(`  image           : ${W}x${H} RGBA (${NPX} px)`);
console.log(`  operations      : adjust grayscale invert convolve3 box_blur sharpen warp rotate`);
console.log(`  failures        : ${failures.length}`);

if (failures.length) {
  console.error('FAIL:');
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('OK: every image operation behaved correctly');
