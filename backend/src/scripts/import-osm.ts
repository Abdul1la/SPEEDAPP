// npm run import-osm -- [--country IQ] [--dry-run] [--prune] [--file data.json] [--save data.json]
//
// Adds every speed camera and speed bump of a country from OpenStreetMap to
// the community map (owned by the community, source = 'import'). Safe to run
// again: points imported before are updated, not duplicated, and points that
// drivers or moderators hid stay hidden.
//
//   --country IQ     ISO country code (default IQ, Iraq)
//   --dry-run        only show what would change
//   --prune          also remove imported points that were deleted from OSM
//   --file x.json    use a saved Overpass answer instead of downloading
//   --save x.json    keep a copy of the downloaded answer
//
// Map data © OpenStreetMap contributors (ODbL). The app credits it in
// Settings.
import { readFile, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';

import { loadConfig } from '../config.ts';
import { createPool } from '../db.ts';
import type { OverpassData } from '../lib/osm.ts';
import { applyPlan, fetchOverpass, loadExisting, mergeNearby, overpassQuery, planImport, toCandidates } from '../lib/osm.ts';
import { runMigrations } from '../migrate.ts';

const { values: args } = parseArgs({
  options: {
    country: { type: 'string', default: 'IQ' },
    'dry-run': { type: 'boolean', default: false },
    prune: { type: 'boolean', default: false },
    file: { type: 'string' },
    save: { type: 'string' },
  },
});
const country = args.country.toUpperCase();

let data: OverpassData;
if (args.file) {
  console.log(`Reading ${args.file}...`);
  data = JSON.parse(await readFile(args.file, 'utf8')) as OverpassData;
} else {
  console.log(`Downloading speed cameras and bumps in ${country} from OpenStreetMap (can take a minute)...`);
  data = await fetchOverpass(overpassQuery(country), (m) => console.log(m));
  if (args.save) await writeFile(args.save, JSON.stringify(data));
}

const { candidates, convention } = toCandidates(data);
const { kept, merged } = mergeNearby(candidates);
const cameras = kept.filter((c) => c.type === 'camera');
const bumps = kept.length - cameras.length;
console.log(
  `OpenStreetMap: ${cameras.length} cameras, ${bumps} bumps` +
    (merged ? ` (${merged} mapped twice, counted once)` : '') +
    `.\n  Cameras with a speed limit: ${cameras.filter((c) => c.speedLimit != null).length}, ` +
    `with a direction: ${cameras.filter((c) => c.direction != null).length} ` +
    `(OSM "direction" read as the way the camera ${convention.meaning === 'facing' ? 'looks' : 'drives'}: ` +
    `${convention.facing} facing / ${convention.travel} travel on one-way roads).`,
);
if (kept.length === 0) {
  console.error('Nothing found. Is the country code right? Nothing was changed.');
  process.exit(1);
}

const config = loadConfig();
await runMigrations(config.databaseUrl);
const db = createPool(config.databaseUrl, 2);
try {
  const { imported, others } = await loadExisting(db, country, kept);
  const plan = planImport(country, kept, imported, others, args.prune);

  // A half-empty download must never wipe the map.
  const active = imported.filter((r) => r.status === 'active').length;
  if (plan.remove.length > Math.max(50, active * 0.3)) {
    console.error(
      `Refusing to remove ${plan.remove.length} of ${active} imported points: the download looks incomplete. ` +
        'Nothing was changed.',
    );
    process.exit(1);
  }

  console.log(
    [
      `${args['dry-run'] ? 'Would add' : 'Adding'}: ${plan.insert.length}`,
      `update: ${plan.update.length}`,
      `unchanged: ${plan.unchanged}`,
      `already added by drivers: ${plan.alreadyOnMap}`,
      `hidden by drivers/moderators (left alone): ${plan.keptHidden}`,
      ...(args.prune ? [`remove (gone from OSM): ${plan.remove.length}`] : []),
    ].join(', ') + '.',
  );
  if (args['dry-run']) {
    console.log('Dry run: nothing was changed.');
  } else {
    await applyPlan(db, plan);
    console.log('Done. Phones get the new points the next time they sync.');
  }
} finally {
  await db.end();
}
