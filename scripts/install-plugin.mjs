#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const target = process.argv[2] ?? 'all';
const validTargets = new Set(['all', 'amp', 'codex']);

if (!validTargets.has(target)) {
	console.error('Usage: yarn install-plugin [all|amp|codex]');
	process.exit(2);
}

const binary = path.join(repoRoot, 'zig-out', 'bin', 'ghostty-claude-headless');
const codexMcpScript = path.join(repoRoot, 'plugins', 'codex', 'ask-claude-ghostty', 'scripts', 'ask-claude-ghostty-mcp.mjs');
const ampPluginSource = path.join(repoRoot, 'plugins', 'amp', 'ask-claude-ghostty.ts');

buildBinary();

if (target === 'all' || target === 'amp') installAmpPlugin();
if (target === 'all' || target === 'codex') installCodexPlugin();

function buildBinary() {
	if (existsSync(binary)) return;
	const zig = findExecutable('zig') ?? findExisting('/opt/homebrew/opt/zig@0.15/bin/zig');
	if (!zig) {
		throw new Error('ghostty-claude-headless is not built and zig is not on PATH. Install Zig 0.15.2, then run `zig build`.');
	}
	run(zig, ['build'], { cwd: repoRoot });
	if (!existsSync(binary)) throw new Error(`zig build finished but did not create ${binary}`);
}

function installAmpPlugin() {
	const destDir = path.join(homedir(), '.config', 'amp', 'plugins');
	mkdirSync(destDir, { recursive: true });
	const dest = path.join(destDir, 'ask-claude-ghostty.ts');
	const pluginSource = readFileSync(ampPluginSource, 'utf8').replace(
		"'__GHOSTTY_CLAUDE_HEADLESS_BIN__'",
		JSON.stringify(binary),
	);
	writeFileSync(dest, pluginSource);
	console.log(`Installed Amp plugin: ${dest}`);
}

function installCodexPlugin() {
	const codex = findExecutable('codex');
	if (!codex) throw new Error('codex executable not found on PATH. Install Codex, then rerun this command.');
	if (!existsSync(codexMcpScript)) throw new Error(`Codex MCP script not found: ${codexMcpScript}`);

	// Remove an existing direct MCP registration if present. This does not remove marketplace plugins.
	spawnSync(codex, ['mcp', 'remove', 'ask-claude-ghostty'], { encoding: 'utf8' });
	run(codex, [
		'mcp',
		'add',
		'--env',
		`GHOSTTY_CLAUDE_HEADLESS_BIN=${binary}`,
		'ask-claude-ghostty',
		'--',
		'/usr/bin/env',
		'node',
		codexMcpScript,
	]);
	console.log('Installed Codex MCP tool: ask_claude_ghostty');
}

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		cwd: options.cwd ?? repoRoot,
		stdio: 'inherit',
		env: process.env,
	});
	if (result.status !== 0) {
		throw new Error(`Command failed: ${command} ${args.join(' ')}`);
	}
}

function findExisting(candidate) {
	return existsSync(candidate) ? candidate : undefined;
}

function findExecutable(name) {
	const pathValue = process.env.PATH ?? '';
	for (const dir of pathValue.split(path.delimiter)) {
		if (!dir) continue;
		const candidate = path.join(dir, name);
		if (existsSync(candidate)) return candidate;
	}
	return undefined;
}
