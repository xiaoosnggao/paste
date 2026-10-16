import { Client } from '../.tools/rea/node_modules/@modelcontextprotocol/client/dist/index.mjs';
import { StdioClientTransport } from '../.tools/rea/node_modules/@modelcontextprotocol/client/dist/stdio.mjs';
import { writeFile } from 'node:fs/promises';

const node = '/Users/gaoxs/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node';
const launcher = new URL('../.tools/rea/node_modules/rea-agents/scripts/rea.mjs', import.meta.url).pathname;
const client = new Client({ name: 'paste-rea-install-check', version: '1.0.0' });
const transport = new StdioClientTransport({ command: node, args: [launcher, 'mcp'], stderr: 'pipe' });
const deadline = setTimeout(() => {
  console.error('REA MCP verification timed out.');
  void client.close().finally(() => { process.exitCode = 1; });
}, 15000);
try {
  await client.connect(transport);
  const result = await client.listTools();
  const names = result.tools.map(tool => tool.name);
  for (const expected of ['inspect_artifact', 'inspect_macho', 'inspect_plist']) {
    if (!names.includes(expected)) throw new Error(`Required tool missing: ${expected}`);
  }
  const verification = { status: 'passed', server: client.getServerVersion(), tool_count: names.length, tools: names };
  await writeFile(new URL('../analysis/evidence/mcp-verification.json', import.meta.url), JSON.stringify(verification, null, 2) + '\n');
  console.log(JSON.stringify({ status: verification.status, server: verification.server, tool_count: verification.tool_count }));
} finally {
  clearTimeout(deadline);
  await client.close();
}
