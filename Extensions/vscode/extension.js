// Companion for the Lookout macOS app. Each window publishes its folders and terminal shell PIDs
// to ~/.lookout/vscode/windows/<extension host pid>.json, so Lookout can tell which window (and
// terminal) an agent process belongs to. Lookout asks a window to reveal a terminal by writing
// ~/.lookout/vscode/requests/<extension host pid>.
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');

const base = path.join(os.homedir(), '.lookout', 'vscode');
const windowsDir = path.join(base, 'windows');
const requestsDir = path.join(base, 'requests');
const id = String(process.pid);
const windowFile = path.join(windowsDir, id + '.json');

async function publish() {
    const pids = await Promise.all(vscode.window.terminals.map((t) => t.processId));
    const workspaceFile = vscode.workspace.workspaceFile;
    const folders = vscode.workspace.workspaceFolders || [];
    // Remote windows (e.g. "ssh-remote+myserver"): folders and terminal PIDs are on that machine.
    const remote = folders.find((f) => f.uri.scheme === 'vscode-remote');
    const info = {
        pid: process.pid,
        appRoot: vscode.env.appRoot,
        remoteAuthority: remote ? remote.uri.authority : null,
        remoteFolders: folders.filter((f) => f.uri.scheme === 'vscode-remote').map((f) => f.uri.toString()),
        workspaceFile: workspaceFile && workspaceFile.scheme === 'file' ? workspaceFile.fsPath : null,
        folders: folders.filter((f) => f.uri.scheme === 'file').map((f) => f.uri.fsPath),
        terminals: pids.filter((pid) => typeof pid === 'number'),
    };
    try {
        fs.mkdirSync(windowsDir, { recursive: true });
        fs.writeFileSync(windowFile + '.tmp', JSON.stringify(info));
        fs.renameSync(windowFile + '.tmp', windowFile);
    } catch (e) {
        console.error('[lookout] publish failed', e);
    }
}

async function handleRequest() {
    const file = path.join(requestsDir, id);
    let request;
    try {
        request = JSON.parse(fs.readFileSync(file, 'utf8'));
        fs.unlinkSync(file);
    } catch {
        return; // already handled, or not ours
    }
    for (const terminal of vscode.window.terminals) {
        if ((await terminal.processId) === request.terminal) {
            terminal.show(false);
            return;
        }
    }
}

function activate(context) {
    publish();
    const republish = () => publish();
    context.subscriptions.push(
        vscode.window.onDidOpenTerminal(republish),
        vscode.window.onDidCloseTerminal(republish),
        vscode.workspace.onDidChangeWorkspaceFolders(republish),
    );
    try {
        fs.mkdirSync(requestsDir, { recursive: true });
        const watcher = fs.watch(requestsDir, (_event, name) => { if (name === id) handleRequest(); });
        context.subscriptions.push({ dispose: () => watcher.close() });
        handleRequest(); // a request may have arrived before we started watching
    } catch (e) {
        console.error('[lookout] watch failed', e);
    }
}

function deactivate() {
    try { fs.unlinkSync(windowFile); } catch {}
}

module.exports = { activate, deactivate };
