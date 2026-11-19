// Input is already schema-validated by the trusted package builder.
// Encode JSON as a Lua long string without allowing a manifest to end it.
export function installEncounter(mod,encounter){
 const payload=JSON.stringify(encounter);let eq='=';
 while(payload.includes(']'+eq+']'))eq+='=';
 mod.FS.writeFile('/bundle/headless/encounter_config.lua',`return assert(require('json_validate').decode([${eq}[${payload}]${eq}]))\n`);
}
