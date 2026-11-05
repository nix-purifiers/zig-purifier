# SPDX-License-Identifier: MIT
{ pkgs, build }:
let
  built = build {
    src = ./fixtures/wasm;
    wasmModules.proof = {
      path = "bin/proof.wasm";
      imports = [
        {
          module = "provider";
          name = "base";
          kind = "function";
        }
      ];
    };
  };
  projected = built.projections;
in
assert built.fetches == [ ];
assert !(projected ? native);
pkgs.runCommand "zig-wasm-ordinary-consumers" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
  test -e ${
    import ./resource-consumer.nix {
      inherit pkgs;
      projection = projected.resources;
    }
  }
  node - <<'JS'
  const fs = require('node:fs');
  const assert = require('node:assert/strict');
  const module = new WebAssembly.Module(fs.readFileSync('${projected.wasm.modules.proof}'));
  const actual = new WebAssembly.Instance(module, {provider: {base: () => 41}});
  assert.equal(actual.exports.answer(), 42);
  assert.throws(() => new WebAssembly.Instance(module, {}));
  const catalog = JSON.parse(fs.readFileSync('${projected.wasm.catalog}'));
  assert.deepEqual(catalog.modules.proof.imports, [{module: 'provider', name: 'base', kind: 'function'}]);
  assert.ok(catalog.modules.proof.exports.some(item => item.name === 'answer' && item.kind === 'function'));
  JS
  touch $out
''
