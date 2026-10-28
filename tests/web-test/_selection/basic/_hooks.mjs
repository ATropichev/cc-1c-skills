// Fixture hook: proves the runner refused BEFORE loading hooks — importing this file leaves a marker.
import { writeFileSync } from 'fs';
if (process.env.WEBTEST_SELECTION_MARKER) writeFileSync(process.env.WEBTEST_SELECTION_MARKER, 'imported');
export async function prepare() { throw new Error('prepare ran'); }
